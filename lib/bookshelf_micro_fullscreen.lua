--[[
Full-screen micro-module overlay (issue #176/#180). Opened by the footer grid
button when Micro-modules placement == "fullscreen". Shows the hero micro-module
grid filling the screen; closes on a tap outside a module (the close-X over the
footer button is the visual cue), or Back.

Mirrors the start menu overlay's pattern: a full-screen InputContainer that
paints an opaque close-X over the launching footer button's region, with the
grid's own cells consuming module taps and a TapDismiss on the rest closing it.

The grid is HeroModules.build, the same renderer the hero uses; in fullscreen
placement the hero behind is the book card, so there's no _hero_cells conflict.
Pages: dots in the footer band (tap one) and a sideways swipe over the grid.
The pencil opposite the close X opens the layout editor, with this view as
its host (model / render / footerRect).
]]
local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local FrameContainer  = require("ui/widget/container/framecontainer")
local logger          = require("logger")
local Geom            = require("ui/geometry")
local InputContainer  = require("ui/widget/container/inputcontainer")
local OverlapGroup    = require("ui/widget/overlapgroup")
local Size            = require("ui/size")
local Space           = require("lib/bookshelf_space")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Widget          = require("ui/widget/widget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Screen          = Device.screen

-- Paints its single child at a fixed offset within the overlay (no core widget
-- for this -- the start menu defines the same helper).
local OffsetContainer = WidgetContainer:extend{ x_off = 0, y_off = 0 }
function OffsetContainer:getSize() return self[1]:getSize() end
function OffsetContainer:paintTo(bb, x, y)
    local sz = self[1]:getSize()
    self.dimen = Geom:new{ x = x + self.x_off, y = y + self.y_off, w = sz.w, h = sz.h }
    self[1]:paintTo(bb, x + self.x_off, y + self.y_off)
end

local MicroFullscreen = InputContainer:extend{
    name = "micro_modules_fullscreen",
    -- Its ground is opaque (see _build), so nothing under it need paint:
    -- without this every repaint (closing a module's colour menu, say) drew
    -- the whole shelf beneath it too, ~400 ms on a PW5 for nothing.
    covers_fullscreen = true,
}

-- Reader context only: the exact painted boxes of the in-reader launcher glyphs
-- (nil on the home screen, where the footer's own button frames are the truth).
-- The overlay's white background hides the real launcher, so it repaints the
-- glyphs -- and they must land pixel-identically, not be recomputed from the tap
-- rect and an unscaled art box.
local function _launcherSpec(bw)
    if not (bw and bw._reader_context) then return nil end
    local ok, RB = pcall(require, "lib/bookshelf_reader_buttons")
    if not (ok and RB and RB.paintSpec) then return nil end
    local ok_s, spec = pcall(RB.paintSpec)
    return ok_s and spec or nil
end

-- Paint a custom X (two diagonal strokes) at the launching button's region, so
-- the user sees a clear close target where the grid button was -- identical
-- approach to the start menu's close indicator.
-- reserve_ring: leave room for a d-pad focus border so the glyph's outer size is
-- the same focused or not. focused: draw the ring now (close button has focus).
-- exact (optional): the launcher's real painted box (reader context) -- the X
-- then fills that box at the launcher's own scale, instead of being centred in
-- the tap dimen at the unscaled footer size.
-- _glyphBacking(bw) -> COLOR_WHITE, or nil when something already covers here.
--
-- These glyphs are repainted over the real launcher's spot, and the white fill
-- existed to match the overlay's own white background -- it was never a look,
-- just a way of matching the ground. Now that ground can be a wallpaper with
-- the footer panel on top, and a white box there does two visible things: it
-- punches a hole in the panel, and it squares off the panel's rounded ends
-- (which is what made the panel look like a full-width bar).
--
-- nil, not false: FrameContainer skips its fill on `if self.background then`.
local function _glyphBacking(bw)
    local ok, has = pcall(function()
        return bw and bw.groundIsPainted and bw:groundIsPainted()
    end)
    if ok and has then return nil end
    return Blitbuffer.COLOR_WHITE
end

-- _glyphInk(bw) -> the colour these strokes should be painted in.
--
-- The shelf paints the very same two glyphs in its own footer and asks
-- _chromeInk for their colour (bars_ink, grid_ink in bookshelf_widget). These
-- are repaints of those, at the same coordinates, so they have to ask the same
-- question -- and once _glyphBacking stopped laying white underneath them, a
-- hard-coded black was black strokes on the dark panel. The footer simply went
-- missing, which on a touch-only device is the close button going missing.
--
-- Device night mode is deliberately NOT considered here. It inverts the whole
-- frame beneath whatever the shelf decided to look like, so COLOR_BLACK reaches
-- the panel as white without anyone asking; _chromeInk answers only for the
-- manual dark theme, where nothing inverts and the strokes must carry the
-- colour themselves.
local function _glyphInk(bw)
    local ok, ink = pcall(function()
        return bw and bw._chromeInk and bw:_chromeInk()
    end)
    -- A blitbuffer colour is ffi cdata: `ok and ink or default` would take the
    -- cdata every time, but a nil one still has to fall through, and paintRect
    -- indexes whatever it is handed.
    if ok and type(ink) ~= "nil" then return ink end
    return Blitbuffer.COLOR_BLACK
end

local function _closeGlyph(bw, button_dimen, reserve_ring, focused, exact)
    local box, art
    if exact and exact.w and exact.w > 0 then
        -- The grid glyph's own box: the X replaces it in place.
        box = { x = exact.x, y = exact.y, w = exact.w, h = exact.h }
        art = exact.art or Screen:scaleBySize(32)
    else
        if not (button_dimen and button_dimen.w and button_dimen.w > 0) then return nil end
        local bd = button_dimen
        -- Centre the X in the VISUAL button height: the footer button's dimen has
        -- the tap hit-extension baked into its height, so centring in the full
        -- dimen drops the X too low. Mirrors the start menu close so the two
        -- corners line up.
        local hit_ext = (bw and bw.FOOTER_HIT_EXTENSION) or Screen:scaleBySize(12)
        box = { x = bd.x, y = bd.y, w = bd.w, h = math.max(0, bd.h - hit_ext) }
        art = Screen:scaleBySize(32)
    end
    -- Stroke tracks the art size: bw.FOOTER_STROKE_W is the UNSCALED footer
    -- weight, so a scaled launcher must derive its own (same formula as
    -- footer_geom.barMetrics) or the X reads heavier than the bars beside it.
    local stroke = (not exact and bw and bw.FOOTER_STROKE_W)
        or math.max(1, math.floor(art / 14))
    local xspan  = math.floor(art * 0.62)
    -- Focus-ring reserve is taken out of the box, so clamp the ink to what's left
    -- (a heavily shrunken launcher leaves less room than the nominal 62%).
    local fb = reserve_ring and Screen:scaleBySize(2) or 0
    xspan = math.max(stroke, math.min(xspan, box.w - 2 * fb, box.h - 2 * fb))
    local ink = _glyphInk(bw)
    local XWidget = Widget:extend{}
    function XWidget:getSize() return Geom:new{ w = xspan, h = xspan } end
    function XWidget:paintTo(b, x, y)
        local last = xspan - stroke
        for t = 0, last do
            b:paintRect(x + t,        y + t, stroke, stroke, ink)
            b:paintRect(x + last - t, y + t, stroke, stroke, ink)
        end
    end
    -- Focus ring (border-swap, dimen-constant — matches the grid cells). Reserved
    -- above whenever the close button is reachable by d-pad so focusing it doesn't
    -- nudge the X; the border is drawn only when it actually holds focus.
    local frame = FrameContainer:new{
        background = _glyphBacking(bw),
        bordersize = focused and fb or 0,
        margin     = focused and 0 or fb,
        radius     = fb > 0 and Space.px(4) or 0,
        padding    = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = math.max(1, box.w - 2 * fb), h = math.max(1, box.h - 2 * fb) },
            XWidget:new{},
        },
    }
    return OffsetContainer:new{ x_off = box.x, y_off = box.y, frame }
end

-- The layout editor's pencil, painted over the footer's start-menu button
-- spot (or, with the start menu off, the corner opposite the close X): the
-- same pen glyph as the plugin's other Edit buttons (the Hardcover row in the
-- book modal), in the footer glyphs' ink. Its tap opens the layout editor
-- (handleEvent, _pencil_rect).
-- exact (optional): the launcher's real painted bars box (reader context), so
-- the pencil lands where the launcher's own glyph is.
local PENCIL = "\xEE\xAB\xAA" -- nf-md-pencil, U+EAEA
local function _pencilGlyph(bw, button_dimen, exact, reserve_ring, focused)
    local box
    if exact and exact.w and exact.w > 0 then
        box = { x = exact.x, y = exact.y, w = exact.w, h = exact.h }
    else
        if not (button_dimen and button_dimen.w and button_dimen.w > 0) then return nil end
        local hit_ext = (bw and bw.FOOTER_HIT_EXTENSION) or Screen:scaleBySize(12)
        box = { x = button_dimen.x, y = button_dimen.y, w = button_dimen.w,
                h = math.max(0, button_dimen.h - hit_ext) }
    end
    local TextWidget = require("lib/bookshelf_colour_text")
    local BFont = require("lib/bookshelf_fonts")
    local glyph = TextWidget:new{
        text    = PENCIL,
        face    = BFont:getFace("symbols", 26),
        fgcolor = _glyphInk(bw),
    }
    -- Focus ring as the close X's: reserved when keys can reach the pencil,
    -- drawn only while it holds focus.
    local fb = reserve_ring and Screen:scaleBySize(2) or 0
    local frame = FrameContainer:new{
        background = _glyphBacking(bw),
        bordersize = focused and fb or 0,
        margin     = focused and 0 or fb,
        radius     = fb > 0 and Space.px(4) or 0,
        padding    = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = math.max(1, box.w - 2 * fb), h = math.max(1, box.h - 2 * fb) },
            glyph,
        },
    }
    return OffsetContainer:new{ x_off = box.x, y_off = box.y, frame }
end

function MicroFullscreen.open(bw, button_dimen, footer_h)
    MicroFullscreen.hold_paint = nil
    local self = MicroFullscreen:new{
        bw           = bw,
        button_dimen = button_dimen,
        footer_h     = footer_h or Screen:scaleBySize(40),
    }
    -- Pass an explicit refreshtype + region. UIManager:show with no refreshtype
    -- calls setDirty(self, nil), and current KOReader DROPS a nil-mode refresh
    -- ("to avoid enqueuing a useless full-screen refresh") -- so the overlay
    -- paints to the framebuffer but never flushes to the e-ink panel, leaving
    -- the bookshelf visible underneath until some per-cell module refresh (e.g.
    -- the analogue clock tick) happens to flush its region. init()>_build() has
    -- already set self.dimen to the full screen. Mirrors StartMenu.open.
    UIManager:show(self, "ui", self.dimen)
    return self
end

function MicroFullscreen:init()
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    -- D-pad cell navigation (mirrors the start menu's focus nav, but 2D across
    -- the grid). Gated on hasDPad so touch-only devices keep just Back/tap.
    if Device:hasDPad() then
        self.key_events.MFFocusUp    = { { "Up" } }
        self.key_events.MFFocusDown  = { { "Down" } }
        self.key_events.MFFocusLeft  = { { "Left" } }
        self.key_events.MFFocusRight = { { "Right" } }
        self.key_events.MFPress      = { { "Press" } }
        self.key_events.MFHold = { { "ScreenKB", "Press" }, { "Shift", "Press" } }
        self._dpad = true
    end
    -- Register so a module add/edit/remove rebuilds THIS overlay live: the edit
    -- reload path routes through HeroModules._rebuild, which checks this ref.
    if self.bw then self.bw._micro_fullscreen = self end
    self:_build()  -- sets self.dimen + size-dependent ges_events + content
end

function MicroFullscreen:_build()
    local Perf = require("lib/bookshelf_perf")
    local t_build = Perf.now()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    -- Track the built size so paintTo can re-layout on resize / rotation.
    self._built_w, self._built_h = sw, sh
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    -- Tap-to-close + system-gesture passthrough are both handled in
    -- handleEvent (below), not via a whole-screen TapClose ges range: that
    -- range would swallow the top-edge menu tap, edge brightness swipes and
    -- corner gestures before they could reach FileManager.
    local margin = math.min(
        math.floor(Space.padding.fullscreen * 2 * 0.8),
        math.floor(sw * 0.03))
    local PAD       = margin
    local content_w = sw - 2 * margin
    local top       = margin

    local HeroModules = require("lib/bookshelf_hero_modules")
    -- The full-screen surface has its OWN module list, independent of the hero
    -- (seeded from a copy of the hero list on first enable, then divergent).
    local FSModel     = require("lib/bookshelf_fullscreen_modules_model")
    local HeroCard    = require("lib/bookshelf_hero_card")

    -- The ground: the shelf's wallpaper (see bg below), else plain white.
    -- Decided first, as the status line's ink follows it: inside a book there
    -- is no wallpaper, and a dark theme's white ink vanished on the white.
    local wall
    if self.bw and self.bw._wallpaperWidget then
        local ok_bg, w = pcall(function() return self.bw:_wallpaperWidget() end)
        if ok_bg and w then wall = w end
    end
    self._status_ink = (not wall) and Blitbuffer.COLOR_BLACK or nil

    -- Full-width status line + hairline at the top, like the in-hero grid.
    local current = (self.bw._currentHeroBook and self.bw:_currentHeroBook()) or nil
    local state   = (self.bw._buildDeviceState and self.bw:_buildDeviceState()) or nil
    local ok_s, status_row = pcall(HeroCard.buildStatusRow, current, state, content_w, true, nil, self._status_ink)
    if not ok_s then status_row = nil end
    local status_h = (status_row and status_row:getSize().h) or 0
    local gap      = math.max(1, math.floor(margin / 2))

    -- Keep the grid clear of the launcher buttons. In reader context the user can
    -- move and resize them (and put them at the TOP), so ask for the band they
    -- actually occupy rather than assuming the old fixed bottom footer height --
    -- which left a dead strip at the bottom and let the grid run under the
    -- buttons once they moved. Outside reader context (or if anything fails) fall
    -- back to the footer band, matching the shelf's own bottom margin.
    -- Reader context only: on the home screen the band to clear is the shelf's
    -- own footer (self.footer_h), and asking the reader launcher would reserve the
    -- wrong edge entirely once "launcher at top" is set.
    local launcher = _launcherSpec(self.bw)
    local reserve_edge, reserve_px = "bottom", self.footer_h + margin
    -- Shelf context: reserve against the footer PANEL, not against footer_h.
    --
    -- footer_h is what the opener happened to pass, and it falls back to a
    -- 40dp approximation -- about 17px short of the band the footer actually
    -- occupies. The grid therefore stopped that much closer to the panel than
    -- to its own neighbours, and the row above the footer read as cramped.
    -- footerPanelRect knows where the panel really starts, so the gap becomes
    -- PAD: the same figure the grid puts between any two cards (gap = PAD).
    -- footerPanelRect runs the whole ground/theme chain; ask it ONCE per
    -- build and hand the answer to the three places below that need it.
    local fp_x, fp_y, fp_w, fp_h, fp_radius, fp_strength, fp_ground
    if self.bw and self.bw.footerPanelRect then
        local ok_p, a, b, c, d, e, f, g = pcall(function() return self.bw:footerPanelRect() end)
        if ok_p and a then
            fp_x, fp_y, fp_w, fp_h, fp_radius, fp_strength, fp_ground = a, b, c, d, e, f, g
        end
    end
    if fp_y then reserve_px = (sh - fp_y) + PAD end
    if launcher then
        local ok_rb, RB = pcall(require, "lib/bookshelf_reader_buttons")
        if ok_rb and RB and RB.reservedBand then
            local ok_b, edge, px = pcall(RB.reservedBand)
            if ok_b and px and px > 0 then
                reserve_edge, reserve_px = edge, px + margin
            end
        end
    end
    local bottom_reserve = (reserve_edge == "top") and margin or reserve_px
    -- Where the grid would naturally start (below the status row)...
    local content_top = top + status_h + (status_row and gap or 0)
    -- ...pushed down if the launcher band at the TOP reaches further than that.
    -- max(), not +, so the status row and the glyph band aren't double-counted
    -- when they overlap. The spacer below actually MOVES the grid; adding to
    -- used_top alone would only have shortened it and left it under the buttons.
    local grid_top = content_top
    if reserve_edge == "top" then
        grid_top = math.max(content_top, reserve_px)
    end
    local top_pad  = grid_top - content_top
    local grid_h   = math.max(1, sh - grid_top - bottom_reserve)

    -- Reflow ALL modules (the full-screen list, no paging): pass an explicit
    -- item list so build() bypasses its per-page assignment.
    local items = FSModel.load()
    -- D-pad: keep the cursor on a module that's still present (seed to the first
    -- on open, after an edit removes the focused one, etc.).
    if self._dpad then
        local present = false
        for _i, it in ipairs(items) do
            if it.id == self._cursor_id then present = true; break end
        end
        if not present then self._cursor_id = items[1] and items[1].id or nil end
    end
    local ok, grid = pcall(HeroModules.build, self.bw, content_w, grid_h, PAD,
        { items = items, focusable = self._dpad or nil,
          focused_id = (not self._focus_close and not self._focus_pencil) and self._cursor_id or nil,
          surface = "fullscreen", page = self._page, edit = self._edit })
    if not ok or not grid then
        grid = Widget:new{}  -- defensive: empty, still closeable
    end
    -- The page the grid settled on (it snaps a stale page to a real one), and
    -- where the grid sits, for the page swipe.
    -- Keep this view's own copy: bw._module_grid is shared with the top panel,
    -- whose rebuilds (a file poll, a cover load) can overwrite it while this
    -- view is open.
    local info = self.bw and self.bw._module_grid
    if info and info.surface == "fullscreen" then
        self._grid_info = info
        self._page = info.page
    end
    info = self._grid_info
    self._grid_rect = Geom:new{ x = margin, y = grid_top, w = content_w, h = grid_h }

    local col = VerticalGroup:new{ align = "left" }
    self._status_rec = nil
    if status_row then
        -- Recorded so the shelf's minute tick can rebuild it in place
        -- (refreshStatus): the clock and battery on it would otherwise stay as
        -- they were when the view opened.
        self._status_rec = { group = col, idx = #col + 1, content_w = content_w }
        col[#col + 1] = status_row
        col[#col + 1] = VerticalSpan:new{ width = gap }
    end
    if top_pad > 0 then
        -- Clear the launcher buttons when they sit at the top edge.
        col[#col + 1] = VerticalSpan:new{ width = top_pad }
    end
    col[#col + 1] = grid

    -- The overlay's ground. It has to be OPAQUE whatever it is: this covers
    -- the shelf (or the reader page) and the real launcher underneath, which
    -- is what lets the close X and hamburger be repainted at the same spots.
    --
    -- A wallpaper satisfies that as well as white does -- it is a full-screen
    -- picture -- so the library's backdrop carries into this view instead of
    -- the overlay reading as a different app. Falls back to white whenever
    -- there is no wallpaper, or it cannot be decoded.
    local bg = wall
    if not bg then
        bg = FrameContainer:new{
            background = Blitbuffer.COLOR_WHITE,
            bordersize = 0, padding = 0, margin = 0,
            dimen      = Geom:new{ w = sw, h = sh },
            Widget:new{ dimen = Geom:new{ w = sw, h = sh } },
        }
    end
    -- The footer's panel, from the shelf's own definition rather than a second
    -- copy of the arithmetic. This view repaints the footer's buttons at their
    -- real positions so it keeps the shelf's furniture; without the panel
    -- underneath they sat on bare picture and the two views did not match.
    --
    -- Straight after bg, so it is under the grid and under the glyphs.
    local panel
    if fp_x then
        local px, py, pw, ph, radius, strength, ground =
            fp_x, fp_y, fp_w, fp_h, fp_radius, fp_strength, fp_ground
        if ground then
            local ok_wp, Wallpaper = pcall(require, "lib/bookshelf_wallpaper")
            if ok_wp then
                -- ONE panel behind everything: the status line, every
                -- micro-module, and the footer buttons, as a single surface.
                --
                -- Not a panel per band. The cards are opaque and evenly
                -- spaced, so panelling them separately leaves the gaps
                -- BETWEEN them on bare picture -- the spacing stops reading as
                -- rhythm and starts reading as holes. The same applies to the
                -- seam between the content and the footer: two panels there
                -- read as two objects in a view that is one thing.
                --
                -- The footer panel's rect gives the left edge, the width and
                -- the bottom, so this cannot drift from the shelf's footer;
                -- only the TOP is this view's own, from the status line.
                -- bleed = PAD - floor(PAD/2), the top panel's expression, so
                -- the top edge lands floor(PAD/2) from the screen -- the same
                -- inset footerPanelRect already uses on the sides.
                local bleed  = PAD - math.floor(PAD / 2)
                local c_top  = ((status_h > 0) and top or grid_top) - bleed
                if c_top < 0 then c_top = 0 end
                local c_h    = (py + ph) - c_top
                -- A 1px gap across the panel where the footer begins, as on
                -- the shelf's own full panel: the picture shows through, so
                -- the footer reads as its own bar (maintainer, 2026-10-04, in
                -- place of a hairline rule). Shelf context only: under the
                -- reader there is no footer bar, just the launcher's glyphs.
                local gap_y = (not launcher) and py or nil
                -- Blurred under the tint (Theme > Wallpaper > Blur) only over the
                -- picture: bg is the wallpaper itself, not the white fallback.
                local frost = type(bg) == "table" and type(bg.bb) ~= "nil"
                panel = Widget:new{ dimen = Geom:new{ w = sw, h = sh } }
                function panel:paintTo(b)
                    Wallpaper.panel(b, px, c_top, pw, c_h, ground, strength, radius, frost)
                    if gap_y and gap_y > c_top then Wallpaper.restoreBare(b, px, gap_y, pw, 1) end
                end
            end
        end
    end
    local children = OverlapGroup:new{
        dimen = self.dimen:copy(),
        allow_mirroring = false,
        bg,
    }
    if panel then children[#children + 1] = panel end
    children[#children + 1] =
        OffsetContainer:new{ x_off = margin, y_off = top, col }
    -- Read the CURRENT footer button dimen (refreshed when the bookshelf behind
    -- rebuilds on resize), falling back to the open-time value.
    local close_dimen = (self.bw and self.bw._micromod_dimen) or self.button_dimen
    if not (close_dimen and close_dimen.w and close_dimen.w > 0) then
        -- Footer grid button hidden ("Show fullscreen button" off) -> no
        -- remembered rect, so without this the close X never renders and a
        -- touch-only device is trapped (#218). Fall back to the same computed
        -- corner the reader launcher uses, mirroring the grid side (opposite
        -- the start menu).
        local ok_rb, ReaderButtons = pcall(require, "lib/bookshelf_reader_buttons")
        if ok_rb and ReaderButtons then
            local menu_pos = (self.bw and self.bw._startMenuPosition
                and self.bw:_startMenuPosition()) or "left"
            local grid_side = (menu_pos == "right") and "left" or "right"
            close_dimen = ReaderButtons.gridTapRect(grid_side)
        end
    end
    local close_glyph = _closeGlyph(self.bw, close_dimen, self._dpad, self._focus_close,
        launcher and launcher.grid or nil)
    if close_glyph then
        children[#children + 1] = close_glyph
        -- Screen rect of the close target, so a tap there dismisses with priority
        -- over any FM/gesture zone sharing that corner (see handleEvent).
        self._close_rect = close_dimen and Geom:new{
            x = close_dimen.x, y = close_dimen.y, w = close_dimen.w, h = close_dimen.h } or nil
    else
        self._close_rect = nil
    end

    -- The layout editor's pencil, over the footer's start-menu button spot; with
    -- the start menu off, in the corner opposite the close X.
    local pencil_dimen = self.bw and self.bw._burger_dimen
    if not (pencil_dimen and self.bw._startMenuPosition
            and self.bw:_startMenuPosition() ~= "off") then
        pencil_dimen = nil
        local ok_rb, ReaderButtons = pcall(require, "lib/bookshelf_reader_buttons")
        if ok_rb and ReaderButtons and close_dimen then
            local close_side = (close_dimen.x + close_dimen.w / 2 < sw / 2) and "left" or "right"
            pencil_dimen = ReaderButtons.gridTapRect(close_side == "left" and "right" or "left")
        end
    end
    local pg = pencil_dimen and _pencilGlyph(self.bw, pencil_dimen, launcher and launcher.bars or nil,
        self._dpad, self._focus_pencil)
    if pg and not self._edit then
        children[#children + 1] = pg
        self._pencil_rect = Geom:new{ x = pencil_dimen.x, y = pencil_dimen.y,
            w = pencil_dimen.w, h = pencil_dimen.h }
    else
        self._pencil_rect = nil
    end

    -- Page dots in the middle of the footer band when there is more than one
    -- page (the editor brings its own footer).
    self._footer_rect = fp_x and Geom:new{ x = fp_x, y = fp_y, w = fp_w, h = fp_h } or nil
    self._dots = nil
    local pages = info and info.surface == "fullscreen" and info.pages
    if pages and #pages > 1 and not self._edit then
        local band = self._footer_rect
            or Geom:new{ x = 0, y = sh - self.footer_h, w = sw, h = self.footer_h }
        -- On the same line as the close X and the pencil: those centre in the
        -- button's visible height, which leaves out the tap extension below it.
        local dy, dh = band.y, band.h
        if close_dimen and close_dimen.h then
            local hit_ext = (self.bw and self.bw.FOOTER_HIT_EXTENSION) or Screen:scaleBySize(12)
            dy, dh = close_dimen.y, math.max(1, close_dimen.h - hit_ext)
        end
        local dw = math.floor(band.w / 2)
        -- Footer-sized: big enough to see and to tap one.
        local dots = HeroModules.pageDots(#pages, HeroModules.pageIndex(info), dw, dh,
            Screen:scaleBySize(16), Screen:scaleBySize(44))
        children[#children + 1] = OffsetContainer:new{
            x_off = band.x + math.floor((band.w - dw) / 2), y_off = dy, dots }
        self._dots = dots
    end
    self[1] = children
    Perf.part("build view", t_build)
end

-- Gesture handling. The overlay is the topmost widget, and UIManager:sendEvent
-- only delivers to the topmost widget (it does NOT propagate unhandled events
-- down the stack), so without this the KOReader-native system gestures would
-- die here: the top-edge menu tap/swipe, edge brightness/warmth swipes and
-- corner taps registered by FileManager + gestures.koplugin never fire.
--
-- Order: our own children (grid cells, the close button) first; then walk FM's
-- native touch zones (same filtered walk as BookshelfWidget:handleEvent — FM's
-- own filemanager_* zones + user-configured gestures.koplugin zones, skipping
-- the file_chooser body); finally, an unhandled tap anywhere dismisses the
-- overlay (the close-X is the cue, empty space closes too). Non-gesture events
-- (keys, lifecycle) go straight to InputContainer.handleEvent.
local function _tapInRect(ev, r)
    if not (ev and ev.pos and r) then return false end
    local p = ev.pos
    return p.x >= r.x and p.x <= r.x + r.w and p.y >= r.y and p.y <= r.y + r.h
end

function MicroFullscreen:handleEvent(event)
    if event.handler == "onGesture" then
        -- Don't intercept while a gesture-unlock screensaver is up (mirrors the
        -- bookshelf's guard so the wake gesture reaches the lock widget).
        if Device.screen_saver_lock then return false end
        if InputContainer.handleEvent(self, event) then return true end
        local ev = event.args[1]

        -- The close button takes priority over any FM/gesture zone at that
        -- corner: tapping the X always dismisses (a corner zone was otherwise
        -- swallowing the tap and the overlay stayed open).
        if ev and ev.ges == "tap" and _tapInRect(ev, self._close_rect) then
            return self:onTapClose()
        end
        -- The pencil opens the layout editor on this view.
        if ev and ev.ges == "tap" and _tapInRect(ev, self._pencil_rect) then
            return self:_openEditor()
        end
        -- A footer dot goes to its page.
        if ev and ev.ges == "tap" and self._dots and _tapInRect(ev, self._dots.dimen) then
            local Grid = require("lib/bookshelf_module_grid")
            local i = Grid.dotAt(self._dots.rects, self._dots.spacing,
                ev.pos.x - self._dots.dimen.x)
            local info = self._grid_info
            local p = i and info and info.pages and info.pages[i]
            if p and p ~= self._page then
                self._page = p
                self:rebuildGrid()
            end
            return true
        end
        -- A sideways swipe over the grid turns the page. Swipes elsewhere (the
        -- screen edges) stay KOReader's.
        if ev and ev.ges == "swipe" and (ev.direction == "west" or ev.direction == "east")
                and _tapInRect(ev, self._grid_rect) then
            self:_turnPage(ev.direction == "west" and 1 or -1)
            return true
        end

        -- KOReader-native gestures (top-edge menu tap/swipe, edge
        -- brightness/warmth swipes, corner taps): the same zone walk as
        -- BookshelfWidget:handleEvent, on FileManager or the parked reader.
        if require("lib/bookshelf_gesture_zones").tryLiveZones(ev, { open_book = true }) then return true end

        -- Fallback: a tap on empty space dismisses the overlay.
        if ev and ev.ges == "tap" then return self:onTapClose() end
        return false
    end

    -- Non-gesture events. Our own key / lifecycle handlers run first.
    if InputContainer.handleEvent(self, event) then return true end
    -- A gesture zone fired above (brightness/warmth/night mode), or an Action
    -- card, emits its action as a SEPARATE Dispatcher event via
    -- UIManager:sendEvent, which only reaches the topmost widget (us). Forward
    -- it to whichever host is live, exactly as BookshelfWidget:handleEvent
    -- does: FM, or the parked reader once a book has been opened and closed.
    -- This used to know FM only, so every card went dead after the first book
    -- (#533).
    return require("lib/bookshelf_gesture_zones").forwardToLive(event, self, { open_book = true })
end

-- Re-layout on screen resize / rotation (desktop window resize), the same way
-- the main bookshelf view rebuilds in its paintTo on a size change.
--
-- hold_paint (main.lua onShowingReader): a book is opening from this view.
-- Inside a book the old reader closes first and marks everything under it
-- dirty, then showReader forces a repaint, which put the opening book back on
-- its shelf before it opened (maintainer, PW5). The screen keeps the opening
-- pose instead, as the shelf does with _suppress_transition_paint.
function MicroFullscreen:paintTo(bb, x, y)
    if MicroFullscreen.hold_paint then return end
    if Screen:getWidth() ~= self._built_w or Screen:getHeight() ~= self._built_h then
        self:_build()
    end
    local Perf = require("lib/bookshelf_perf")
    local t = Perf.now()
    InputContainer.paintTo(self, bb, x, y)
    Perf.part("paint view", t)
end

-- Step through the pages that hold modules; no-op at either end.
function MicroFullscreen:_turnPage(delta)
    local info = self._grid_info
    local pages = info and info.pages or { 1 }
    local idx = 1
    for i, p in ipairs(pages) do if p == self._page then idx = i end end
    local nxt = pages[idx + delta]
    if not nxt then return false end
    self._page = nxt
    self:rebuildGrid()
    return true
end

-- ── Layout-editor host (see bookshelf_module_grid_editor) ────────────────────
function MicroFullscreen:model()
    return require("lib/bookshelf_fullscreen_modules_model")
end
function MicroFullscreen:render(edit)
    self._edit = edit
    if edit and edit.page then self._page = edit.page end
    self:rebuildGrid()
end
-- reselect(edit) -> true when only the selection changed and the grid as
-- built can show it: the outline and the dimming read edit.selected_id as
-- they paint, so a repaint does, without the 150-200 ms rebuild of every
-- module (PW5).
function MicroFullscreen:reselect(edit)
    local cur = self._edit
    if not (cur and edit and edit.page == cur.page and edit.items == cur.items
            and edit.boxes == cur.boxes) then
        return false
    end
    cur.selected_id = edit.selected_id
    UIManager:setDirty(self, "ui")
    return true
end
function MicroFullscreen:footerRect()
    return self._footer_rect
end
function MicroFullscreen:gridInfo()
    return self._grid_info
end

-- Rebuild the overlay's grid in place after a module add/edit/remove, so it
-- updates live like the in-hero grid (no close+reopen needed).
function MicroFullscreen:rebuildGrid()
    self:_build()
    UIManager:setDirty(self, "ui")
end

-- ── D-pad cell navigation ─────────────────────────────────────────────────────
-- Move the focus cursor across the recorded row/col map and rebuild. Edges are
-- no-ops here (the overlay is a closed workspace; Back exits), unlike the hero
-- zone which hands focus back to the chips/shelf at its edges.
function MicroFullscreen:_openEditor()
    local ok, Editor = pcall(require, "lib/bookshelf_module_grid_editor")
    if ok and Editor then
        -- pcall: in the reader the view runs on a context shim, and an
        -- editor that fails to open must not take the reader down.
        local ok_open, err = pcall(Editor.open, { bw = self.bw, host = self })
        if not ok_open then logger.warn("[bookshelf] layout editor failed to open:", err) end
    end
    return true
end
function MicroFullscreen:_setFocusClose(on)
    if self._focus_close == on and not self._focus_pencil then return end
    self._focus_close = on
    self._focus_pencil = false
    self:rebuildGrid()
end
-- The footer as keys see it: the pencil and the close X in their screen
-- order, so Left / Right go to whichever stands that way (maintainer: keys
-- could not reach the pencil). No pencil while editing.
function MicroFullscreen:_footerStep(dir)
    local p, c = self._pencil_rect, self._close_rect
    if not p then return end
    local pencil_left = c == nil or p.x < c.x
    local to_pencil = (dir == "left") == pencil_left
    if to_pencil and not self._focus_pencil then
        self._focus_pencil, self._focus_close = true, false
        self:rebuildGrid()
    elseif not to_pencil and self._focus_pencil then
        self._focus_pencil, self._focus_close = false, true
        self:rebuildGrid()
    end
end
function MicroFullscreen:_navCell(dir)
    local HeroModules = require("lib/bookshelf_hero_modules")
    return HeroModules.navMove(self.bw and self.bw._hero_grid_rows, self._cursor_id, dir)
end
function MicroFullscreen:_moveTo(dir)
    local nid = self:_navCell(dir)
    if nid and nid ~= self._cursor_id then self._cursor_id = nid; self:rebuildGrid() end
end
-- Up/Down cross between the grid and the footer (the close X, and the pencil
-- beside it), so both are reachable by d-pad, not only by Back and a tap.
-- Left/Right move within the grid, or along the footer.
function MicroFullscreen:onMFFocusUp()
    if self._focus_close or self._focus_pencil then self:_setFocusClose(false) else self:_moveTo("up") end
    return true
end
function MicroFullscreen:onMFFocusDown()
    if self._focus_close or self._focus_pencil then return true end
    if self:_navCell("down") then self:_moveTo("down") else self:_setFocusClose(true) end
    return true
end
function MicroFullscreen:onMFFocusLeft()
    if self._focus_close or self._focus_pencil then self:_footerStep("left") else self:_moveTo("left") end
    return true
end
function MicroFullscreen:onMFFocusRight()
    if self._focus_close or self._focus_pencil then self:_footerStep("right") else self:_moveTo("right") end
    return true
end

-- Press / Hold act on the focused cell exactly as a tap / long-press would.
function MicroFullscreen:_focusedRec()
    return self.bw and self.bw._hero_cells and self._cursor_id
        and self.bw._hero_cells[self._cursor_id] or nil
end
function MicroFullscreen:onMFPress()
    if self._focus_pencil then return self:_openEditor() end
    if self._focus_close then return self:onTapClose() end
    local HeroModules = require("lib/bookshelf_hero_modules")
    local rec = self:_focusedRec()
    if rec and rec.entry then
        HeroModules._tap(self.bw, rec.entry,
            function() HeroModules._reloadCellById(self.bw, rec.entry.id) end)
    end
    return true
end
function MicroFullscreen:onMFHold()
    if self._focus_close or self._focus_pencil then return true end
    local HeroModules = require("lib/bookshelf_hero_modules")
    local rec = self:_focusedRec()
    if rec and rec.entry and HeroModules._hold then
        HeroModules._hold(self.bw, rec.entry)
    end
    return true
end

-- refreshStatus() -- rebuild the status line (time, battery, wifi) in place and
-- repaint just its rect. Called by the shelf's minute tick while this view is
-- open (BookshelfWidget._status_timer_func).
function MicroFullscreen:refreshStatus()
    local rec = self._status_rec
    local old = rec and rec.group[rec.idx]
    if not old then return false end
    local HeroCard = require("lib/bookshelf_hero_card")
    local bw = self.bw
    local current = (bw and bw._currentHeroBook and bw:_currentHeroBook()) or nil
    local state   = (bw and bw._buildDeviceState and bw:_buildDeviceState()) or nil
    local ok, row = pcall(HeroCard.buildStatusRow, current, state, rec.content_w, true, nil, self._status_ink)
    if not ok or not row then return false end
    rec.group[rec.idx] = row
    if rec.group.resetLayout then rec.group:resetLayout() end
    if old.free then UIManager:nextTick(function() pcall(function() old:free() end) end) end
    local scope = old.dimen and old.dimen:copy()
    if scope then
        UIManager:setDirty(self, function() return "ui", scope end)
    else
        UIManager:setDirty(self, "ui")
    end
    return true
end

local function _clearRef(self)
    if self.bw and self.bw._micro_fullscreen == self then
        self.bw._micro_fullscreen = nil
    end
end

function MicroFullscreen:onTapClose()
    _clearRef(self)
    UIManager:close(self)
    if self.bw then
        -- If the hero is ALSO showing its (now separate) micro-module grid, the
        -- overlay just overwrote the shared cell registry (bw._hero_cells) with
        -- its own cells. Rebuild the hero so its cells -- and their async updates
        -- (clock tick etc.) -- are restored; a plain repaint can't (the registry
        -- would still point at the freed overlay cells). The book hero has no
        -- grid, so a repaint is enough there.
        if self.bw._hero_mode == "micro" and self.bw._rebuild then
            self.bw:_rebuild()
        end
        UIManager:setDirty(self.bw, "ui")
    end
    return true
end
MicroFullscreen.onClose = MicroFullscreen.onTapClose
function MicroFullscreen:onCloseWidget() _clearRef(self) end

return MicroFullscreen
