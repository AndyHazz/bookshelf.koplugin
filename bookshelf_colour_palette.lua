--[[
Bookshelf colour palette picker.

A grid of 25 curated swatches (5 families of 5 shades) plus a hex input for
custom values. Tap-to-preview: every swatch tap applies immediately via the
apply_callback, so the book repaints around the edges of the dialog; Apply
just closes, Cancel reverts via revert_callback, Default clears the field.

Storage shape is always {hex = "#RRGGBB"} — the palette is pure UX; changing
the palette in a future release doesn't invalidate any stored preset.
]]

local _ = require("bookshelf_i18n").gettext

local Blitbuffer        = require("ffi/blitbuffer")
local CenterContainer   = require("ui/widget/container/centercontainer")
local Device            = require("device")
local FocusManager      = require("ui/widget/focusmanager")
local FrameContainer    = require("ui/widget/container/framecontainer")
local Geom              = require("ui/geometry")
local GestureRange      = require("ui/gesturerange")
local HorizontalGroup   = require("ui/widget/horizontalgroup")
local HorizontalSpan    = require("ui/widget/horizontalspan")
local InputContainer    = require("ui/widget/container/inputcontainer")
local InputText         = require("ui/widget/inputtext")
local LeftContainer     = require("ui/widget/container/leftcontainer")
local LineWidget        = require("ui/widget/linewidget")
local MovableContainer  = require("ui/widget/container/movablecontainer")
local Notification      = require("ui/widget/notification")
local Size              = require("ui/size")
local TextWidget        = require("ui/widget/textwidget")
local TitleBar          = require("ui/widget/titlebar")
local UIManager         = require("ui/uimanager")
local VerticalGroup     = require("ui/widget/verticalgroup")
local VerticalSpan      = require("ui/widget/verticalspan")
local WidgetContainer   = require("ui/widget/container/widgetcontainer")
local Font              = require("ui/font")
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

local SWATCH_SIDE  = Screen:scaleBySize(60)
local SWATCH_GAP   = Screen:scaleBySize(8)
local SWATCH_RADIUS = Size.radius.default

-- Swatch: a rounded coloured square that renders via paintRoundedRectRGB32.
-- A WidgetContainer subclass — owns its own dimen, not a CenterContainer.
local Swatch = WidgetContainer:extend{
    dimen    = nil,
    hex      = nil,
    selected = false,
    side     = nil,
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

function Swatch:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.side, h = self.side }
    local r = SWATCH_RADIUS
    bb:paintRoundedRectRGB32(x, y, self.side, self.side, self._fill, r)
    local bw = self.selected and Size.border.thick or Size.border.thin
    local bc = self.selected and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY
    bb:paintBorder(x, y, self.side, self.side, bw, bc, r)
end

-- nullTile: a labelled white tile used as the "No background" sentinel.
-- Rendered at grid position [0,0] of the palette when null_tile is set.
local function nullTile(label, selected, side, on_tap)
    local tw = TextWidget:new{
        text      = label,
        face      = Font:getFace("ffont", 12),
        max_width = side - 2 * Size.padding.small,
    }
    local frame = FrameContainer:new{
        bordersize = selected and Size.border.thick or Size.border.thin,
        padding    = 0,
        margin     = 0,
        radius     = 0,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = side, h = side },
            tw,
        },
    }
    local container = InputContainer:new{
        dimen = Geom:new{ w = side, h = side },
        frame,
    }
    container.ges_events = {
        TapSelect = {
            GestureRange:new{ ges = "tap", range = container.dimen },
        },
    }
    function container:onTapSelect()
        on_tap()
        return true
    end
    return container
end

-- swatchTile: InputContainer wrapping a Swatch for gesture handling.
local function swatchTile(hex, selected, side, on_tap)
    local swatch = Swatch:new{ hex = hex, selected = selected, side = side }
    local container = InputContainer:new{
        dimen = Geom:new{ w = side, h = side },
        swatch,
    }
    container.ges_events = {
        TapSelect = {
            GestureRange:new{ ges = "tap", range = container.dimen },
        },
    }
    function container:onTapSelect()
        on_tap(hex)
        return true
    end
    return container
end

-- Footer button: plain text in a tappable InputContainer, matching the
-- preset-library modal's Close | Manage… | Apply row (no bezel, just text
-- plus a vertical LineWidget divider between buttons — see preset_manager_modal.lua).
local function makeFooterBtn(text, width, height, on_tap)
    local label = TextWidget:new{
        text     = text,
        face     = Font:getFace("cfont", 18),
        bold     = true,
        fgcolor  = Blitbuffer.COLOR_BLACK,
    }
    local ic = InputContainer:new{
        dimen = Geom:new{ w = width, h = height },
        CenterContainer:new{ dimen = Geom:new{ w = width, h = height }, label },
    }
    ic.ges_events = { TapSelect = { GestureRange:new{ ges = "tap", range = ic.dimen } } }
    ic.onTapSelect = function() on_tap(); return true end
    return ic
end

local ColourPaletteWidget = FocusManager:extend{
    -- Mirrors KOReader's stock InputDialog (inputdialog.lua:124) — required
    -- so we still receive tap events while the on-screen keyboard is shown.
    -- Without it, UIManager:sendEvent (uimanager.lua:943) only dispatches to
    -- widgets *under* the keyboard if they're flagged is_always_active. The
    -- result on a Kobo Libra Colour was a hard lockup: keyboard couldn't be
    -- dismissed and Apply/Cancel were unreachable, requiring a forced reboot.
    is_always_active = true,
    title            = nil,
    selected_hex     = nil,
    apply_callback   = nil,
    default_callback = nil,
    revert_callback  = nil,
    ok_callback      = nil,
    null_tile        = nil,
    -- When set, a "White" footer button appears that taps apply_callback with
    -- this hex and closes the picker (one-tap commit, like Default but to
    -- a fixed colour rather than off). Used by the background-colour picker
    -- as a shortcut to the page-background colour.
    white_callback   = nil,
}

function ColourPaletteWidget:init()
    self.screen_width  = Screen:getWidth()
    self.screen_height = Screen:getHeight()

    -- Dialog inner width: palette grid + outer padding on each side. The
    -- horizontal padding here is matched against the vertical span above /
    -- below the palette in update(), so the grid sits inside even gutters
    -- on all four sides.
    local ncols = self.null_tile and 6 or 5
    self.palette_width = SWATCH_SIDE * ncols + SWATCH_GAP * (ncols - 1)
    self.inner_width   = self.palette_width + Size.padding.fullscreen * 2
    self.dialog_width  = self.inner_width + 2 * Size.border.thin

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
function ColourPaletteWidget:_keyboardVisible()
    return self.hex_input
        and self.hex_input.isKeyboardVisible
        and self.hex_input:isKeyboardVisible()
end

-- Tear down the on-screen keyboard (if any) for our hex_input. Safe to call
-- from any callback path; idempotent.
function ColourPaletteWidget:_closeKeyboard()
    if self:_keyboardVisible() then
        self.hex_input:onCloseKeyboard()
    end
end

function ColourPaletteWidget:onTapOutside(arg, ges)
    -- If the keyboard is up and the user tapped outside it, dismiss the
    -- keyboard rather than consuming the tap silently. Mirrors stock
    -- InputDialog's behaviour (inputdialog.lua:562-576). The picker itself
    -- stays open; non-keyboard taps outside the dialog frame are still
    -- consumed silently to keep the picker non-dismissable.
    if self:_keyboardVisible() then
        local kb_dimen = self.hex_input.keyboard and self.hex_input.keyboard.dimen
        if not kb_dimen or (ges and ges.pos and ges.pos:notIntersectWith(kb_dimen)) then
            self:_closeKeyboard()
        end
    end
    return true
end

-- Always tear down the keyboard before leaving the widget — our callbacks
-- close the picker via UIManager:close, but the InputText's keyboard is a
-- separate top-level widget that needs explicit cleanup.
function ColourPaletteWidget:onCloseWidget()
    self:_closeKeyboard()
    if FocusManager.onCloseWidget then
        return FocusManager.onCloseWidget(self)
    end
end

function ColourPaletteWidget:update()
    local side = SWATCH_SIDE
    local gap  = SWATCH_GAP
    local iw   = self.inner_width

    -- Palette grid: explicit VerticalSpan + HorizontalGroup rows. NB. KOReader's
    -- VerticalSpan uses `width` as its extent along the group's axis — using
    -- `height` gives a zero-extent span, collapsing the row gap.
    local palette_vgroup = VerticalGroup:new{ align = "center" }
    for row_idx, row_hexes in ipairs(PALETTE) do
        local hgroup = HorizontalGroup:new{ align = "center" }
        -- Prepend the null tile at grid position [0,0] of the first row only.
        if row_idx == 1 and self.null_tile then
            local sel = (self.selected_hex == nil)
            hgroup[#hgroup + 1] = nullTile(self.null_tile.label, sel, side, function()
                self.null_tile.on_tap()
            end)
            hgroup[#hgroup + 1] = HorizontalSpan:new{ width = gap }
        end
        for col_idx, hex in ipairs(row_hexes) do
            if col_idx > 1 then
                hgroup[#hgroup + 1] = HorizontalSpan:new{ width = gap }
            end
            local is_selected = (hex == self.selected_hex)
            hgroup[#hgroup + 1] = swatchTile(hex, is_selected, side, function(tapped_hex)
                self.selected_hex = tapped_hex
                if self.apply_callback then self.apply_callback(tapped_hex) end
                self:update()
            end)
        end
        if row_idx > 1 then
            palette_vgroup[#palette_vgroup + 1] = VerticalSpan:new{ width = gap }
        end
        palette_vgroup[#palette_vgroup + 1] = hgroup
    end

    -- Hex row: a static "#" prefix label, an InputText for the six hex
    -- digits, and a live-preview swatch on the right.
    local hex_face = Font:getFace("cfont", 18)
    local hash_label = TextWidget:new{
        text    = "#",
        face    = hex_face,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    -- Strip any leading # from the seed value — the # is rendered as a
    -- separate static label so the user only edits the six hex digits.
    local initial_text = self.selected_hex or ""
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
    local preview_hex = self.selected_hex or "#FFFFFF"
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
        HorizontalSpan:new{ width = Size.padding.fullscreen },
        hash_label,
        HorizontalSpan:new{ width = Size.padding.small },
        self.hex_input,
        HorizontalSpan:new{ width = Size.padding.large },
        self.preview_swatch,
    }

    -- Footer row: Cancel | Default | [White] | Apply, matching the preset-library
    -- modal's Close | Manage… | Apply pattern (no button borders, LineWidget
    -- dividers). White is conditional — present only when white_callback is set
    -- (currently the background-colour picker).
    local footer_h = Screen:scaleBySize(44)
    local n_btns   = self.white_callback and 4 or 3
    local btn_w    = math.floor(iw / n_btns)
    local cancel_btn  = makeFooterBtn(_("Cancel"),  btn_w, footer_h,
        function() if self.revert_callback  then self.revert_callback()  end end)
    local default_btn = makeFooterBtn(_("Default"), btn_w, footer_h,
        function() if self.default_callback then self.default_callback() end end)
    local apply_btn   = makeFooterBtn(_("Apply"),   btn_w, footer_h,
        function() if self.ok_callback      then self.ok_callback()      end end)
    local white_btn   = self.white_callback and makeFooterBtn(_("White"), btn_w, footer_h,
        function() self.white_callback() end) or nil

    local vdiv_inset = Screen:scaleBySize(10)
    local vdiv = function() return CenterContainer:new{
        dimen = Geom:new{ w = Size.line.thin, h = footer_h },
        LineWidget:new{
            background = Blitbuffer.COLOR_DARK_GRAY,
            dimen = Geom:new{ w = Size.line.thin, h = footer_h - 2 * vdiv_inset },
        },
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
        dimen      = Geom:new{ w = iw, h = Size.line.thin },
    }

    local title_bar = TitleBar:new{
        width            = self.dialog_width,
        title            = self.title or _("Pick a color"),
        with_bottom_line = true,
        show_parent      = self,
    }

    -- Hex row sits above the palette so the field stays visible when the
    -- on-screen keyboard slides up from the bottom of the screen — otherwise
    -- the user can't see what they're typing into the field. LeftContainer
    -- pins the row to the left edge (looked off when centred); the
    -- HorizontalSpan inside hex_row provides a deliberate left margin.
    local vgroup = VerticalGroup:new{
        align = "center",
        title_bar,
        VerticalSpan:new{ width = Size.padding.large },
        LeftContainer:new{
            dimen = Geom:new{ w = iw, h = Screen:scaleBySize(60) },
            hex_row,
        },
        VerticalSpan:new{ width = Size.padding.fullscreen },
        CenterContainer:new{
            dimen = Geom:new{ w = iw, h = side * 5 + gap * 4 },
            palette_vgroup,
        },
        VerticalSpan:new{ width = Size.padding.fullscreen },
        footer_separator,
        footer_row,
    }

    -- Match the preset-library modal's outer frame (preset_manager_modal.lua:580)
    -- so the picker reads as part of the same dialog family — Size.border.thin
    -- (0.5px) was visibly lighter than every other dialog the user sees.
    local frame = FrameContainer:new{
        radius     = Size.radius.window,
        bordersize = Size.border.window,
        padding    = 0,
        margin     = 0,
        background = Blitbuffer.COLOR_WHITE,
        vgroup,
    }

    local movable = MovableContainer:new{ frame }

    -- CenterContainer dimen is set once at construction and never reassigned
    -- post-paint (see feedback_centercontainer_dimen.md).
    self[1] = CenterContainer:new{
        dimen = Geom:new{
            x = 0, y = 0,
            w = self.screen_width, h = self.screen_height,
        },
        movable,
    }

    UIManager:setDirty(self, "ui")
end

-- Mid-edit hook: revalidates the typed hex and, when it forms a fresh valid
-- value, both pushes the colour to the underlying reader overlay (via the
-- caller-supplied apply_callback) and refreshes the in-dialog preview swatch.
-- The apply_callback path schedules its own repaint of the bookshelf overlay
-- (see colours_menu.lua's saveColors → markDirty), which in turn brings the
-- picker's preview region back to screen — no extra setDirty needed here,
-- which avoids racing InputText's per-keystroke dirty tracking.
function ColourPaletteWidget:_updatePreview()
    if not self.preview_swatch or not self.hex_input then return end
    local Colour = require("bookshelf_colour")
    local hex = Colour.normaliseHex(self.hex_input:getText() or "")
    if not hex then return end
    if hex == self.selected_hex then return end  -- no-op if unchanged
    self.selected_hex = hex
    local r = tonumber(hex:sub(2, 3), 16)
    local g = tonumber(hex:sub(4, 5), 16)
    local b = tonumber(hex:sub(6, 7), 16)
    self.preview_swatch._fill = Blitbuffer.ColorRGB32(r, g, b, 0xFF)
    if self.apply_callback then self.apply_callback(hex) end
end

function ColourPaletteWidget:onHexSubmit()
    local txt = self.hex_input:getText()
    if not txt then return end
    -- Accept #RRGGBB or short #RGB (leading # optional, whitespace tolerated).
    -- Store the normalised #RRGGBB form so presets on disk are canonical.
    local Colour = require("bookshelf_colour")
    local hex = Colour.normaliseHex(txt)
    if not hex then
        Notification:notify(_("Invalid hex colour (use #RGB or #RRGGBB)"))
        return
    end
    self.selected_hex = hex
    if self.apply_callback then self.apply_callback(hex) end
    -- Tear down the keyboard so the user lands back on the palette /
    -- footer-row buttons rather than being stuck in the keyboard. update()
    -- below rebuilds the widget tree; without this, the keyboard widget
    -- leaks across the rebuild and continues to capture taps.
    self:_closeKeyboard()
    self:update()
end

function ColourPaletteWidget:onShow()
    UIManager:setDirty(self, "ui")
    return true
end

-- Public entry point.
local function showColourPicker(bookshelf, title, current_hex, default_hex, on_apply, on_default, on_revert, touchmenu_instance, null_tile_label, white_hex)
    local restoreMenu = bookshelf:hideMenu(touchmenu_instance)

    local closed = false
    local function finish()
        if closed then return end
        closed = true
        restoreMenu()
    end

    local widget
    widget = ColourPaletteWidget:new{
        title            = title or _("Pick a color"),
        selected_hex     = current_hex,
        apply_callback   = on_apply,
        default_callback = function()
            UIManager:close(widget, "ui")
            if on_default then on_default() end
            finish()
        end,
        revert_callback  = function()
            UIManager:close(widget, "ui")
            if on_revert then on_revert() end
            finish()
        end,
        ok_callback      = function()
            UIManager:close(widget, "ui")
            finish()
        end,
        null_tile        = null_tile_label and {
            label  = null_tile_label,
            on_tap = function()
                UIManager:close(widget, "ui")
                if on_default then on_default() end
                finish()
            end,
        } or nil,
        white_callback   = white_hex and function()
            if on_apply then on_apply(white_hex) end
            UIManager:close(widget, "ui")
            finish()
        end or nil,
    }
    UIManager:show(widget)
end

local M = {}
function M.attach(Bookshelf)
    function Bookshelf:showColourPicker(title, current_hex, default_hex, on_apply, on_default, on_revert, touchmenu_instance, null_tile_label, white_hex)
        showColourPicker(self, title, current_hex, default_hex, on_apply, on_default, on_revert, touchmenu_instance, null_tile_label, white_hex)
    end
end
return M
