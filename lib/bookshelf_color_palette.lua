--[[
Bookshelf color palette picker.

A grid of 25 curated swatches (5 families of 5 shades) plus a hex input for
custom values. Tap-to-preview: every swatch tap applies immediately via the
apply_callback, so the book repaints around the edges of the dialog; Apply
(or a tap outside) just closes, Cancel reverts via revert_callback, Default
clears the field.

Storage shape is always {hex = "#RRGGBB"} — the palette is pure UX; changing
the palette in a future release doesn't invalidate any stored preset.
]]

local _ = require("lib/bookshelf_i18n").gettext

local Blitbuffer        = require("ffi/blitbuffer")
local CenterContainer   = require("ui/widget/container/centercontainer")
local Device            = require("device")
local FocusManager      = require("ui/widget/focusmanager")
local FrameContainer    = require("ui/widget/container/framecontainer")
local Geom              = require("ui/geometry")
local GestureRange      = require("ui/gesturerange")
local HorizontalGroup   = require("ui/widget/horizontalgroup")
local HorizontalSpan    = require("ui/widget/horizontalspan")
local InputText         = require("ui/widget/inputtext")
local LeftContainer     = require("ui/widget/container/leftcontainer")
local LineWidget        = require("ui/widget/linewidget")
local MovableContainer  = require("ui/widget/container/movablecontainer")
local Notification      = require("ui/widget/notification")
local Size              = require("ui/size")
local TextWidget        = require("lib/bookshelf_colour_text")
local TitleBar          = require("ui/widget/titlebar")
local UIManager         = require("ui/uimanager")
local VerticalGroup     = require("ui/widget/verticalgroup")
local VerticalSpan      = require("ui/widget/verticalspan")
local WidgetContainer   = require("ui/widget/container/widgetcontainer")
local Font              = require("ui/font")
local BFont             = require("lib/bookshelf_fonts")
local Space             = require("lib/bookshelf_space")
local Screen            = Device.screen

-- 5 rows × 5 cols: neutrals / warm dark / warm light / cool dark / cool light.
-- Luminance-separated rows so dark/light pairings survive the greyscale fallback.
local PALETTE = {
    { "#000000", "#404040", "#808080", "#BFBFBF", "#FFFFFF" },
    { "#C00000", "#FF6600", "#8B4513", "#B8860B", "#8B0000" },
    { "#FF69B4", "#FFA07A", "#DEB887", "#FFD700", "#FF8C69" },
    { "#0000CD", "#228B22", "#008B8B", "#8B008B", "#2F4F4F" },
    { "#87CEEB", "#98FB98", "#DDA0DD", "#B0E0E6", "#FFB6C1" },
}

-- A greyscale screen's palette (greys): fifteen shades, white to black, light
-- to dark, as they LOOK on screen. One step (about 18) is wider than a PW5's
-- grey band (16), so no two chips show the same grey. In place of the "% black"
-- dialog, where it was hard to tell in night mode whether the number was the
-- darkness or the brightness (maintainer).
local GREYS = {}
do
    local row
    for i = 0, 14 do
        if i % 5 == 0 then row = {}; GREYS[#GREYS + 1] = row end
        local v = math.floor(255 - 255 * i / 14 + 0.5)
        row[#row + 1] = string.format("#%02X%02X%02X", v, v, v)
    end
end

local SWATCH_SIDE  = Screen:scaleBySize(60)
local SWATCH_GAP   = Space.px(8)

-- Swatch: a rounded colored square that renders via paintRoundedRectRGB32.
-- A WidgetContainer subclass — owns its own dimen, not a CenterContainer.
local Swatch = WidgetContainer:extend{
    dimen    = nil,
    hex      = nil,
    selected = false,
    side     = nil,
    -- seen: the swatch shows its grey as it looks on screen, in night mode
    -- too (painted pre-inverted on an inverted buffer).
    seen     = false,
}

function Swatch:init()
    local r = tonumber(self.hex:sub(2, 3), 16)
    local g = tonumber(self.hex:sub(4, 5), 16)
    local b = tonumber(self.hex:sub(6, 7), 16)
    self._fill = Blitbuffer.ColorRGB32(r, g, b, 0xFF)
end

function Swatch:getSize()
    return Geom:new{ w = self.side, h = self.side }
end

-- A swatch is the popup style's card (STYLE.md): light grey with the hairline
-- shadow down and right, black when it is the colour picked, the colour set
-- in it with a margin of the card round it.
function Swatch:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.side, h = self.side }
    local Kit = require("lib/bookshelf_popup_kit")
    local side, r, s = self.side, Kit.RADIUS, Kit.shadowSize()
    bb:paintRoundedRect(x + s, y + s, side, side, Kit.SHADOW, r)
    bb:paintRoundedRect(x, y, side, side,
        self.selected and Blitbuffer.COLOR_BLACK or Kit.STRIP_BG, r)
    local m = Space.px(6)
    local inner = side - 2 * m
    local fill = self._fill
    if self.seen and bb.getInverse and bb:getInverse() == 1 then
        local v = 0xFF - fill:getR()
        fill = Blitbuffer.ColorRGB32(v, v, v, 0xFF)
    end
    bb:paintRoundedRectRGB32(x + m, y + m, inner, inner, fill, math.max(0, r - Space.px(2)))
    -- A hairline round the colour, so white and the palest shades read on
    -- the grey card.
    bb:paintBorder(x + m, y + m, inner, inner, Size.border.thin, Blitbuffer.COLOR_GRAY,
        math.max(0, r - Space.px(2)))
end

-- woodSwatch(path, side) -> a side x side bitmap of a plank design's own
-- wood (its middle band: top surface and front face), or nil.
local function woodSwatch(path, side)
    local ok, bb = pcall(function()
        local RenderImage = require("ui/renderimage")
        local src = RenderImage:renderImageFile(path, false)
        if not src then return nil end
        local band = math.floor(src:getHeight() / 3)
        local sq = Blitbuffer.new(band, band, Blitbuffer.TYPE_BBRGB32)
        sq:blitFrom(src, 0, 0, math.floor(band / 2), band, band, band)
        src:free()
        return RenderImage:scaleBlitBuffer(sq, side, side)
    end)
    return ok and bb or nil
end

-- nullTile: a labelled white tile used as the "No background" sentinel.
-- Rendered at grid position [0,0] of the palette when null_tile is set.
-- With image_path (a plank design), the tile shows that wood, its label on a
-- white strip along the bottom. fit (a word, no picture: Shelf menu
-- background's Transparent): as wide as its label, never narrower than
-- square, so the word is not cut to "Transpa..." (maintainer, 2026-10-09).
local function nullTileWidth(label, side, image_path, fit)
    if not fit or image_path then return side end
    local nt_face, nt_bold = BFont:getFace("ffont", 16)
    local probe = TextWidget:new{ text = label, face = nt_face, bold = nt_bold }
    -- A large padding: at the default one a picked tile's outline met the
    -- first and last letters (PW5).
    local w = math.max(side, probe:getSize().w + 2 * Space.padding.large)
    probe:free()
    return w
end

local function nullTile(label, selected, side, on_tap, image_path, fit)
    local nt_face, nt_bold = BFont:getFace("ffont", 16)
    local w = nullTileWidth(label, side, image_path, fit)
    local tw = TextWidget:new{
        text      = label,
        face      = nt_face,
        bold      = nt_bold,
        max_width = w - 2 * Space.padding.small,
    }
    local wood = image_path and woodSwatch(image_path, side)
    local inner
    if wood then
        local ImageWidget  = require("ui/widget/imagewidget")
        local OverlapGroup = require("ui/widget/overlapgroup")
        local strip_h = tw:getSize().h + 2 * Space.padding.small
        local strip = FrameContainer:new{
            bordersize = 0, padding = 0, margin = 0, radius = 0,
            background = Blitbuffer.COLOR_WHITE,
            CenterContainer:new{ dimen = Geom:new{ w = side, h = strip_h }, tw },
        }
        strip.overlap_offset = { 0, side - strip_h }
        inner = OverlapGroup:new{
            dimen = Geom:new{ w = side, h = side },
            ImageWidget:new{ image = wood, image_disposable = true, width = side, height = side },
            strip,
        }
    end
    -- A card as the swatches beside it are; the one picked outlined (a
    -- picture would be hidden by black).
    local frame = require("lib/bookshelf_popup_kit").cardify(FrameContainer:new{
        bordersize = 0,
        padding    = 0,
        margin     = 0,
        inner or CenterContainer:new{
            dimen = Geom:new{ w = w, h = side },
            tw,
        },
    }, { outline = selected })
    -- A kit tap cell: the tap at once (it is drawn again to show the pick)
    -- and the keys' ring round the card (STYLE.md).
    local Kit = require("lib/bookshelf_popup_kit")
    local cell = Kit.tapCell(frame, w, side, on_tap, true, nil, true)
    cell.focus_radius = Kit.RADIUS
    return cell
end

-- swatchTile: a Swatch as a kit tap cell (the tap, and the keys' ring).
local function swatchTile(hex, selected, side, on_tap, seen)
    local Kit = require("lib/bookshelf_popup_kit")
    local swatch = Swatch:new{ hex = hex, selected = selected, side = side, seen = seen }
    local cell = Kit.tapCell(swatch, side, side, function() on_tap(hex) end, true, nil, true)
    cell.focus_radius = Kit.RADIUS
    return cell
end

-- Footer button: plain text in a kit tap cell, matching the
-- preset-library modal's Close | Manage… | Apply row (no bezel, just text
-- plus a vertical LineWidget divider between buttons — see preset_manager_modal.lua).
local function makeFooterBtn(text, width, height, on_tap)
    local btn_face, btn_bold = BFont:getFace("cfont", 18, { bold = true })
    local label = TextWidget:new{
        text     = text,
        face     = btn_face,
        bold     = btn_bold,
        fgcolor  = Blitbuffer.COLOR_BLACK,
    }
    -- A kit tap cell, for the keys' ring, set in clear of the dividers.
    local Kit = require("lib/bookshelf_popup_kit")
    local cell = Kit.tapCell(CenterContainer:new{ dimen = Geom:new{ w = width, h = height }, label },
        width, height, on_tap, true, nil, true)
    cell.focus_inset, cell.focus_radius = Space.px(4), Kit.RADIUS
    return cell
end

local ColorPaletteWidget = FocusManager:extend{
    -- Mirrors KOReader's stock InputDialog (inputdialog.lua:124) — required
    -- so we still receive tap events while the on-screen keyboard is shown.
    -- Without it, UIManager:sendEvent (uimanager.lua:943) only dispatches to
    -- widgets *under* the keyboard if they're flagged is_always_active. The
    -- result on a Kobo Libra Color was a hard lockup: keyboard couldn't be
    -- dismissed and Apply/Cancel were unreachable, requiring a forced reboot.
    is_always_active = true,
    title            = nil,
    selected_hex     = nil,
    -- hex_text: what the hex field starts with when no swatch is the choice
    -- (an untouched colour: the row shows its default or the theme's, so
    -- the field does too rather than opening empty). Marks nothing.
    hex_text         = nil,
    apply_callback   = nil,
    default_callback = nil,
    revert_callback  = nil,
    ok_callback      = nil,
    null_tile        = nil,
    -- special_tile { label, image, selected, on_tap }: a non-colour choice at
    -- the start of the hex row, "[tile] or # RRGGBB" (the plank's built-in
    -- wood). Not in the grid: the grid is colours only.
    special_tile     = nil,
    -- When set, a "White" footer button appears that taps apply_callback with
    -- this hex and closes the picker (one-tap commit, like Default but to
    -- a fixed color rather than off). Used by the background-color picker
    -- as a shortcut to the page-background color.
    white_callback   = nil,
    -- greys: a greyscale screen's picker, the GREYS chips and no hex field;
    -- a tap hands apply_callback the grey as it looks ("#RRGGBB").
    greys            = false,
    -- anchor: where to open (MovableContainer's), below the chip bar for the
    -- selected-chip colours so the strip being coloured stays in view;
    -- centred when nil.
    anchor           = nil,
}

function ColorPaletteWidget:init()
    self.screen_width  = Screen:getWidth()
    self.screen_height = Screen:getHeight()

    -- Dialog inner width: palette grid + outer padding on each side. The
    -- horizontal padding here is matched against the vertical span above /
    -- below the palette in update(), so the grid sits inside even gutters
    -- on all four sides.
    self.palette_width = SWATCH_SIDE * 5 + SWATCH_GAP * 4
    if self.null_tile then
        local nt = self.null_tile
        self.palette_width = self.palette_width + SWATCH_GAP
            + nullTileWidth(nt.label, SWATCH_SIDE, nt.image, not nt.image)
    end
    self.inner_width   = self.palette_width + Space.padding.fullscreen * 2
    self.dialog_width  = self.inner_width + 2 * Size.border.thin

    -- The keys (STYLE.md: every popup takes them): Back is Cancel; the cursor
    -- across rebuilds (every pick rebuilds) in _key_state.
    self._key_state = {}
    if Device:hasKeys() then
        self.key_events = self.key_events or {}
        self.key_events.Close = { { Device.input.group.Back } }
    end
    if Device:isTouchDevice() then
        self.ges_events = {
            TapOutside = {
                GestureRange:new{
                    ges   = "tap",
                    range = Geom:new{
                        x = 0, y = 0,
                        w = self.screen_width, h = self.screen_height,
                    },
                },
            },
        }
    end

    self:update()
end

-- Returns true if the on-screen keyboard is currently up for our hex_input.
function ColorPaletteWidget:_keyboardVisible()
    return self.hex_input
        and self.hex_input.isKeyboardVisible
        and self.hex_input:isKeyboardVisible()
end

-- Tear down the on-screen keyboard (if any) for our hex_input. Safe to call
-- from any callback path; idempotent.
function ColorPaletteWidget:_closeKeyboard()
    if self:_keyboardVisible() then
        self.hex_input:onCloseKeyboard()
    end
end

function ColorPaletteWidget:onClose()
    if self:_keyboardVisible() then self:_closeKeyboard(); return true end
    if self.revert_callback then self.revert_callback() end
    return true
end

function ColorPaletteWidget:onTapOutside(arg, ges)
    -- If the keyboard is up and the user tapped outside it, dismiss the
    -- keyboard rather than consuming the tap silently. Mirrors stock
    -- InputDialog's behaviour (inputdialog.lua:562-576); the picker stays.
    if self:_keyboardVisible() then
        local kb_dimen = self.hex_input.keyboard and self.hex_input.keyboard.dimen
        if not kb_dimen or (ges and ges.pos and ges.pos:notIntersectWith(kb_dimen)) then
            self:_closeKeyboard()
        end
        return true
    end
    -- Else a tap outside the frame closes the picker, keeping what it shows
    -- (a swatch tap already previews; Apply keeps it). The old % dialog
    -- took rapid taps, so it could not close on one that missed; the
    -- picker's taps are one at a time (maintainer).
    local d = self._frame and self._frame.dimen
    if d and d.x and ges and ges.pos and ges.pos:notIntersectWith(d) then
        if self.ok_callback then self.ok_callback() end
    end
    return true
end

-- Always tear down the keyboard before leaving the widget — our callbacks
-- close the picker via UIManager:close, but the InputText's keyboard is a
-- separate top-level widget that needs explicit cleanup.
function ColorPaletteWidget:onCloseWidget()
    self:_closeKeyboard()
    if FocusManager.onCloseWidget then
        return FocusManager.onCloseWidget(self)
    end
end

-- _box(prev) -> a setDirty function for the picker's own box (and prev, where
-- it was before a rebuild): the widget spans the screen, so a bare
-- setDirty(self) refreshed the whole of it on every swatch tap.
function ColorPaletteWidget:_box(prev)
    return function()
        local d = self._frame and self._frame.dimen
        if d and d.x and prev then d = d:combine(prev) end
        return "ui", (d and d.x) and d or prev
    end
end

function ColorPaletteWidget:update()
    local d0 = self._frame and self._frame.dimen
    local prev = d0 and d0.x and Geom:new{ x = d0.x, y = d0.y, w = d0.w, h = d0.h } or nil
    local side = SWATCH_SIDE
    local gap  = SWATCH_GAP
    local iw   = self.inner_width

    -- Palette grid: explicit VerticalSpan + HorizontalGroup rows. NB. KOReader's
    -- VerticalSpan uses `width` as its extent along the group's axis — using
    -- `height` gives a zero-extent span, collapsing the row gap.
    local palette_vgroup = VerticalGroup:new{ align = "center" }
    local rows = self.greys and GREYS or PALETTE
    -- The keys' rows, top to bottom (Kit.keyFocus at the end).
    local layout, grid_from = {}, nil
    -- Greys: the chip nearest the current shade is the one marked (a value
    -- set with the old % dialog need not be one of the fifteen).
    local selected_hex = self.selected_hex
    if self.greys and selected_hex then
        local want, best, dist = tonumber(selected_hex:sub(2, 3), 16) or 0, nil, math.huge
        for _r, row in ipairs(GREYS) do
            for _c, hex in ipairs(row) do
                local d = math.abs((tonumber(hex:sub(2, 3), 16) or 0) - want)
                if d < dist then best, dist = hex, d end
            end
        end
        selected_hex = (dist <= 9) and best or nil
    end
    local grid_rows = {}
    local null_w
    for row_idx, row_hexes in ipairs(rows) do
        local hgroup = HorizontalGroup:new{ align = "center" }
        local keys_row = {}
        grid_rows[row_idx] = keys_row
        -- Prepend the null tile at grid position [0,0] of the first row only.
        -- A word with no picture is as wide as its label (fit), as the
        -- Transparent tile is: square, "No background" was cut to "No bac..."
        -- (maintainer, bookends PW5).
        if row_idx == 1 and self.null_tile then
            local sel = self.null_tile.selected
            if sel == nil then sel = (self.selected_hex == nil) end
            hgroup[#hgroup + 1] = nullTile(self.null_tile.label, sel, side, function()
                self.null_tile.on_tap()
            end, self.null_tile.image, not self.null_tile.image)
            keys_row[#keys_row + 1] = hgroup[#hgroup]
            null_w = hgroup[#hgroup]:getSize().w
            hgroup[#hgroup + 1] = HorizontalSpan:new{ width = gap }
        elseif self.null_tile then
            -- The rows below the tile keep its column empty, so the grid stays
            -- six aligned columns rather than each row centring on its own.
            hgroup[#hgroup + 1] = HorizontalSpan:new{ width = (null_w or side) + gap }
        end
        for col_idx, hex in ipairs(row_hexes) do
            if col_idx > 1 then
                hgroup[#hgroup + 1] = HorizontalSpan:new{ width = gap }
            end
            local is_selected = (hex == selected_hex)
            hgroup[#hgroup + 1] = swatchTile(hex, is_selected, side, function(tapped_hex)
                self.selected_hex = tapped_hex
                if self.special_tile then self.special_tile.selected = false end
                if self.apply_callback then self.apply_callback(tapped_hex) end
                self:update()
            end, self.greys)
            keys_row[#keys_row + 1] = hgroup[#hgroup]
        end
        if row_idx > 1 then
            palette_vgroup[#palette_vgroup + 1] = VerticalSpan:new{ width = gap }
        end
        palette_vgroup[#palette_vgroup + 1] = hgroup
    end

    -- Hex row: a static "#" prefix label, an InputText for the six hex
    -- digits, and a live-preview swatch on the right.
    local hex_face, hex_bold = BFont:getFace("cfont", 18)
    local hash_label = TextWidget:new{
        text    = "#",
        face    = hex_face,
        bold    = hex_bold,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    -- Strip any leading # from the seed value — the # is rendered as a
    -- separate static label so the user only edits the six hex digits.
    local initial_text = self.selected_hex or self.hex_text or ""
    if initial_text:sub(1, 1) == "#" then initial_text = initial_text:sub(2) end
    -- InputText draws its own border (Size.border.inputtext, 2px) and
    -- handles its own focus highlight, so wrap it directly in the row
    -- rather than inside an extra FrameContainer — the latter produced
    -- a visible double border.
    self.hex_input = InputText:new{
        text           = initial_text,
        hint           = "RRGGBB",
        input_type     = "string",
        width          = Screen:scaleBySize(140),
        face           = hex_face,
        focused        = false,
        parent         = self,
        enter_callback = function() self:onHexSubmit() end,
        -- InputText fires edit_callback during its own init() with edited=false
        -- (also on programmatic setText). Filtering on `edited=true` keeps
        -- _updatePreview from running during update()'s widget rebuild — which
        -- otherwise reads from a stale self.hex_input reference (the field
        -- pointer hasn't been reassigned yet at that point) and reverts the
        -- just-applied selected_hex back to the prior value.
        edit_callback  = function(edited) if edited then self:_updatePreview() end end,
    }
    -- Preview swatch on the right. Refreshes on every keystroke via
    -- _updatePreview (which only re-paints the swatch's bounds), so the
    -- whole picker doesn't rebuild while the user is typing.
    local preview_side = Screen:scaleBySize(36)
    local preview_hex = self.selected_hex or self.hex_text or "#FFFFFF"
    if #preview_hex ~= 7 then preview_hex = "#FFFFFF" end
    self.preview_swatch = Swatch:new{
        hex      = preview_hex,
        selected = false,
        side     = preview_side,
    }
    local hex_row = HorizontalGroup:new{
        align = "center",
        -- Left margin matches the palette's horizontal gutter (padding.fullscreen)
        -- so the "#" prefix aligns with the leftmost column of swatches.
        HorizontalSpan:new{ width = Space.padding.fullscreen },
    }
    local special_cell
    if self.special_tile then
        local st = self.special_tile
        special_cell = nullTile(st.label, st.selected, side, function() st.on_tap() end, st.image, true)
        hex_row[#hex_row + 1] = special_cell
        hex_row[#hex_row + 1] = HorizontalSpan:new{ width = Space.padding.large }
        hex_row[#hex_row + 1] = TextWidget:new{ text = _("or"), face = hex_face,
                                                fgcolor = Blitbuffer.COLOR_BLACK }
        hex_row[#hex_row + 1] = HorizontalSpan:new{ width = Space.padding.large }
    end
    for _i, w in ipairs({
        hash_label,
        HorizontalSpan:new{ width = Space.padding.small },
        self.hex_input,
        HorizontalSpan:new{ width = Space.padding.large },
        self.preview_swatch,
    }) do hex_row[#hex_row + 1] = w end

    -- Footer row: Cancel | Default | [White] | Apply, matching the preset-library
    -- modal's Close | Manage… | Apply pattern (no button borders, LineWidget
    -- dividers). White is conditional — present only when white_callback is set
    -- (currently the background-color picker).
    local footer_h = Screen:scaleBySize(44)
    local n_btns   = self.white_callback and 4 or 3
    -- Edge to edge under a full-width line, the dividers the buttons'
    -- full height (STYLE.md: lines set in from the frame end nowhere).
    local foot_w   = self.dialog_width
    local btn_w    = math.floor(foot_w / n_btns)
    local cancel_btn  = makeFooterBtn(_("Cancel"),  btn_w, footer_h,
        function() if self.revert_callback  then self.revert_callback()  end end)
    local default_btn = makeFooterBtn(_("Default"), btn_w, footer_h,
        function() if self.default_callback then self.default_callback() end end)
    local apply_btn   = makeFooterBtn(_("Apply"),   btn_w, footer_h,
        function() if self.ok_callback      then self.ok_callback()      end end)
    local white_btn   = self.white_callback and makeFooterBtn(_("White"), btn_w, footer_h,
        function() self.white_callback() end) or nil

    local vdiv = function() return LineWidget:new{
        background = Blitbuffer.COLOR_DARK_GRAY,
        dimen = Geom:new{ w = Size.line.thin, h = footer_h },
    } end

    local footer_row
    if white_btn then
        footer_row = HorizontalGroup:new{
            cancel_btn, vdiv(), default_btn, vdiv(), white_btn, vdiv(), apply_btn,
        }
    else
        footer_row = HorizontalGroup:new{
            cancel_btn, vdiv(), default_btn, vdiv(), apply_btn,
        }
    end
    local footer_separator = LineWidget:new{
        background = Blitbuffer.COLOR_DARK_GRAY,
        dimen      = Geom:new{ w = foot_w, h = Size.line.thin },
    }

    local title_bar = TitleBar:new{
        title_face = require("lib/bookshelf_popup_kit").titleFace(),
        width            = self.dialog_width,
        title            = self.title or _("Pick a color"),
        with_bottom_line = true,
        show_parent      = self,
    }
    require("lib/bookshelf_popup_kit").centreTitle(title_bar)

    -- Hex row sits above the palette so the field stays visible when the
    -- on-screen keyboard slides up from the bottom of the screen — otherwise
    -- the user can't see what they're typing into the field. LeftContainer
    -- pins the row to the left edge (looked off when centred); the
    -- HorizontalSpan inside hex_row provides a deliberate left margin.
    local vgroup = VerticalGroup:new{
        align = "center",
        title_bar,
    }
    -- Greys: no hex field (a grey is picked by eye); the plank's wood tile
    -- alone, when there is one.
    if self.greys then
        hex_row = nil
        if self.special_tile then
            local st = self.special_tile
            special_cell = nullTile(st.label, st.selected, side, function() st.on_tap() end, st.image, true)
            hex_row = HorizontalGroup:new{ align = "center",
                HorizontalSpan:new{ width = Space.padding.fullscreen }, special_cell }
        end
    end
    if hex_row then
        vgroup[#vgroup + 1] = VerticalSpan:new{ width = Space.padding.large }
        vgroup[#vgroup + 1] = LeftContainer:new{
            dimen = Geom:new{ w = iw, h = Screen:scaleBySize(60) },
            hex_row,
        }
    end
    for _i, w in ipairs({
        VerticalSpan:new{ width = Space.padding.fullscreen },
        CenterContainer:new{
            dimen = Geom:new{ w = iw, h = side * #rows + gap * (#rows - 1) },
            palette_vgroup,
        },
        VerticalSpan:new{ width = Space.padding.fullscreen },
        footer_separator,
        footer_row,
    }) do vgroup[#vgroup + 1] = w end

    -- Match the preset-library modal's outer frame (preset_manager_modal.lua:580)
    -- so the picker reads as part of the same dialog family — Size.border.thin
    -- (0.5px) was visibly lighter than every other dialog the user sees.
    local frame = FrameContainer:new{
        radius     = Space.radius.window,
        bordersize = Size.border.window,
        padding    = 0,
        margin     = 0,
        background = Blitbuffer.COLOR_WHITE,
        vgroup,
    }

    self._frame = frame   -- its painted box: where a tap is outside (onTapOutside)

    -- The keys: the plank's tile (when there is one), the grid row by row,
    -- then the footer; seeded on the grid. The hex field is left to touch
    -- (a keys-only device types through KOReader's own keyboard there).
    if special_cell then layout[#layout + 1] = { special_cell } end
    grid_from = #layout + 1
    for _i, r in ipairs(grid_rows) do layout[#layout + 1] = r end
    local foot = { cancel_btn, default_btn }
    if white_btn then foot[#foot + 1] = white_btn end
    foot[#foot + 1] = apply_btn
    layout[#layout + 1] = foot
    self.layout = layout
    local Kit = require("lib/bookshelf_popup_kit")
    Kit.keyFocus(self, self._key_state, grid_from, "palette")
    local movable = MovableContainer:new{ frame, anchor = self.anchor }

    -- CenterContainer dimen is set once at construction and never reassigned
    -- post-paint (see feedback_centercontainer_dimen.md).
    self[1] = CenterContainer:new{
        dimen = Geom:new{
            x = 0, y = 0,
            w = self.screen_width, h = self.screen_height,
        },
        movable,
    }

    UIManager:setDirty(self, self:_box(prev))
end

-- Mid-edit hook: revalidates the typed hex and, when it forms a fresh valid
-- value, both pushes the color to the underlying reader overlay (via the
-- caller-supplied apply_callback) and refreshes the in-dialog preview swatch.
-- The apply_callback path schedules its own repaint of the bookshelf overlay
-- (see colors_menu.lua's saveColors → markDirty), which in turn brings the
-- picker's preview region back to screen — no extra setDirty needed here,
-- which avoids racing InputText's per-keystroke dirty tracking.
function ColorPaletteWidget:_updatePreview()
    if not self.preview_swatch or not self.hex_input then return end
    local Color = require("lib/bookshelf_color")
    local hex = Color.normaliseHex(self.hex_input:getText() or "")
    if not hex then return end
    if hex == self.selected_hex then return end  -- no-op if unchanged
    self.selected_hex = hex
    local r = tonumber(hex:sub(2, 3), 16)
    local g = tonumber(hex:sub(4, 5), 16)
    local b = tonumber(hex:sub(6, 7), 16)
    self.preview_swatch._fill = Blitbuffer.ColorRGB32(r, g, b, 0xFF)
    if self.apply_callback then self.apply_callback(hex) end
end

function ColorPaletteWidget:onHexSubmit()
    local txt = self.hex_input:getText()
    if not txt then return end
    -- Accept #RRGGBB or short #RGB (leading # optional, whitespace tolerated).
    -- Store the normalised #RRGGBB form so presets on disk are canonical.
    local Color = require("lib/bookshelf_color")
    local hex = Color.normaliseHex(txt)
    if not hex then
        Notification:notify(_("Invalid hex color (use #RGB or #RRGGBB)"))
        return
    end
    self.selected_hex = hex
    if self.special_tile then self.special_tile.selected = false end
    if self.apply_callback then self.apply_callback(hex) end
    -- Tear down the keyboard so the user lands back on the palette /
    -- footer-row buttons rather than being stuck in the keyboard. update()
    -- below rebuilds the widget tree; without this, the keyboard widget
    -- leaks across the rebuild and continues to capture taps.
    self:_closeKeyboard()
    self:update()
end

function ColorPaletteWidget:onShow()
    UIManager:setDirty(self, self:_box())
    return true
end

-- Public entry point.
-- special_tile (optional): { label, selected, on_tap, image } -- a labelled tile
-- before the hex field ("[tile] or # RRGGBB") that is not a colour: the
-- plank's built-in wood. Tapping
-- it runs on_tap and closes; it shows selected while `selected` is true.
-- opts (optional): { greys = true } -- a greyscale screen's picker (GREYS);
-- { anchor = fn } -- open there rather than centred.
local function showColorPicker(bookshelf, title, current_hex, default_hex, on_apply, on_default, on_revert, touchmenu_instance, null_tile_label, white_hex, special_tile, hex_text, opts)
    local restoreMenu = bookshelf:hideMenu(touchmenu_instance)

    -- opts.on_closed: once, however it closes, before the menu comes back.
    local closed = false
    local function finish()
        if closed then return end
        closed = true
        if opts and opts.on_closed then opts.on_closed() end
        restoreMenu()
    end

    local widget
    -- Closed with its own box refreshed, not the whole screen.
    local function closeIt()
        local d = widget._frame and widget._frame.dimen
        UIManager:close(widget, "ui", (d and d.x) and d or nil)
    end
    widget = ColorPaletteWidget:new{
        title            = title or _("Pick a color"),
        selected_hex     = current_hex,
        hex_text         = hex_text,
        greys            = (opts and opts.greys) and true or false,
        anchor           = opts and opts.anchor or nil,
        apply_callback   = on_apply,
        default_callback = function()
            closeIt()
            if on_default then on_default() end
            finish()
        end,
        revert_callback  = function()
            closeIt()
            if on_revert then on_revert() end
            finish()
        end,
        ok_callback      = function()
            closeIt()
            finish()
        end,
        special_tile     = special_tile and {
            label    = special_tile.label,
            image    = special_tile.image,
            selected = special_tile.selected and true or false,
            on_tap   = function()
                closeIt()
                special_tile.on_tap()
                finish()
            end,
        } or nil,
        null_tile        = null_tile_label and {
            label  = null_tile_label,
            on_tap = function()
                closeIt()
                if on_default then on_default() end
                finish()
            end,
        } or nil,
        white_callback   = white_hex and function()
            if on_apply then on_apply(white_hex) end
            closeIt()
            finish()
        end or nil,
    }
    UIManager:show(widget)
end

local M = {}
function M.attach(Bookshelf)
    function Bookshelf:showColorPicker(title, current_hex, default_hex, on_apply, on_default, on_revert, touchmenu_instance, null_tile_label, white_hex, special_tile, hex_text, opts)
        showColorPicker(self, title, current_hex, default_hex, on_apply, on_default, on_revert, touchmenu_instance, null_tile_label, white_hex, special_tile, hex_text, opts)
    end
end
-- KOReader's own gestures (the menu, brightness) keep working around it,
-- as over the shelf (GestureZones.overlayEvent; maintainer, PW5).
function ColorPaletteWidget:handleEvent(event)
    return require("lib/bookshelf_gesture_zones").overlayEvent(self, event, FocusManager,
        function(pos)
            if self:_keyboardVisible() then return true end
            local d = self._frame and self._frame.dimen
            return not (d and d.x) or not pos:notIntersectWith(d)
        end)
end

return M
