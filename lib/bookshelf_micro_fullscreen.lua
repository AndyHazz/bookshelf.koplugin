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
Pagination is the grid's own in-grid chevrons for now; shelf-style footer paging
is a planned refinement.
]]
local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local InputContainer  = require("ui/widget/container/inputcontainer")
local OverlapGroup    = require("ui/widget/overlapgroup")
local Size            = require("ui/size")
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
    local XWidget = Widget:extend{}
    function XWidget:getSize() return Geom:new{ w = xspan, h = xspan } end
    function XWidget:paintTo(b, x, y)
        local last = xspan - stroke
        for t = 0, last do
            b:paintRect(x + t,        y + t, stroke, stroke, Blitbuffer.COLOR_BLACK)
            b:paintRect(x + last - t, y + t, stroke, stroke, Blitbuffer.COLOR_BLACK)
        end
    end
    -- Focus ring (border-swap, dimen-constant — matches the grid cells). Reserved
    -- above whenever the close button is reachable by d-pad so focusing it doesn't
    -- nudge the X; the border is drawn only when it actually holds focus.
    local frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = focused and fb or 0,
        margin     = focused and 0 or fb,
        radius     = fb > 0 and Screen:scaleBySize(4) or 0,
        padding    = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = math.max(1, box.w - 2 * fb), h = math.max(1, box.h - 2 * fb) },
            XWidget:new{},
        },
    }
    return OffsetContainer:new{ x_off = box.x, y_off = box.y, frame }
end

-- The start-menu hamburger, painted over the footer's start-menu button spot so
-- it stays reachable from the full-screen view (its tap opens the start menu --
-- handled in handleEvent via _burger_rect). Mirrors the bookshelf footer's
-- _buildStartMenuIcon bar geometry so the two line up.
-- exact (optional): the launcher's real painted bars box (reader context) -- the
-- bars are then reproduced from the launcher's own metrics at its own position,
-- so they don't move or resize when the overlay opens over them.
local function _hamburgerGlyph(bw, button_dimen, exact)
    if exact and exact.w and exact.w > 0 then
        local e = exact
        local Bars = Widget:extend{}
        function Bars:getSize() return Geom:new{ w = e.w, h = e.h } end
        function Bars:paintTo(b, x, y)
            for i = 0, 2 do
                b:paintRect(x, y + i * (e.bar_t + e.gap), e.w, e.bar_t,
                    Blitbuffer.COLOR_BLACK)
            end
        end
        -- No white backing frame: the overlay's own full-screen white background
        -- has already covered the reader page (and the real launcher) beneath.
        return OffsetContainer:new{ x_off = e.x, y_off = e.y, Bars:new{} }
    end
    if not (button_dimen and button_dimen.w and button_dimen.w > 0) then return nil end
    local bd       = button_dimen
    local hit_ext  = (bw and bw.FOOTER_HIT_EXTENSION) or Screen:scaleBySize(12)
    local visual_h = math.max(0, bd.h - hit_ext)
    local art   = Screen:scaleBySize(32)
    local bar_t = (bw and bw.FOOTER_STROKE_W) or math.max(1, math.floor(art / 14))
    local bar_w = art
    local span0 = math.floor(art * 0.62)
    local gap   = math.max(1, math.floor((span0 - 3 * bar_t) / 2))
    local span  = 3 * bar_t + 2 * gap
    local Bars = Widget:extend{}
    function Bars:getSize() return Geom:new{ w = bar_w, h = art } end
    function Bars:paintTo(b, x, y)
        local top = y + math.floor((art - span) / 2)
        for i = 0, 2 do
            b:paintRect(x, top + i * (bar_t + gap), bar_w, bar_t, Blitbuffer.COLOR_BLACK)
        end
    end
    local frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0, padding = 0, margin = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = bd.w, h = visual_h },
            Bars:new{},
        },
    }
    return OffsetContainer:new{ x_off = bd.x, y_off = bd.y, frame }
end

function MicroFullscreen.open(bw, button_dimen, footer_h)
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
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    -- Track the built size so paintTo can re-layout on resize / rotation.
    self._built_w, self._built_h = sw, sh
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    -- Tap-to-close + system-gesture passthrough are both handled in
    -- handleEvent (below), not via a whole-screen TapClose ges range: that
    -- range would swallow the top-edge menu tap, edge brightness swipes and
    -- corner gestures before they could reach FileManager.
    local margin = math.min(
        math.floor(Size.padding.fullscreen * 2 * 0.8),
        math.floor(sw * 0.03))
    local PAD       = margin
    local content_w = sw - 2 * margin
    local top       = margin

    local HeroModules = require("lib/bookshelf_hero_modules")
    -- The full-screen surface has its OWN module list, independent of the hero
    -- (seeded from a copy of the hero list on first enable, then divergent).
    local FSModel     = require("lib/bookshelf_fullscreen_modules_model")
    local HeroCard    = require("lib/bookshelf_hero_card")

    -- Full-width status line + hairline at the top, like the in-hero grid.
    local current = (self.bw._currentHeroBook and self.bw:_currentHeroBook()) or nil
    local state   = (self.bw._buildDeviceState and self.bw:_buildDeviceState()) or nil
    local ok_s, status_row = pcall(HeroCard.buildStatusRow, current, state, content_w, true)
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
          focused_id = (not self._focus_close) and self._cursor_id or nil,
          surface = "fullscreen" })
    if not ok or not grid then
        grid = Widget:new{}  -- defensive: empty, still closeable
    end

    local col = VerticalGroup:new{ align = "left" }
    if status_row then
        col[#col + 1] = status_row
        col[#col + 1] = VerticalSpan:new{ width = gap }
    end
    if top_pad > 0 then
        -- Clear the launcher buttons when they sit at the top edge.
        col[#col + 1] = VerticalSpan:new{ width = top_pad }
    end
    col[#col + 1] = grid

    local bg = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0, padding = 0, margin = 0,
        dimen      = Geom:new{ w = sw, h = sh },
        Widget:new{ dimen = Geom:new{ w = sw, h = sh } },
    }
    local children = OverlapGroup:new{
        dimen = self.dimen:copy(),
        allow_mirroring = false,
        bg,
        OffsetContainer:new{ x_off = margin, y_off = top, col },
    }
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

    -- Keep the start-menu hamburger reachable from the full-screen view, painted
    -- over the footer's start-menu button spot (its tap opens the start menu --
    -- see _burger_rect in handleEvent). Hidden when the start menu is off.
    local burger_dimen = self.bw and self.bw._burger_dimen
    if burger_dimen and self.bw._startMenuPosition
            and self.bw:_startMenuPosition() ~= "off" then
        local hb = _hamburgerGlyph(self.bw, burger_dimen,
            launcher and launcher.bars or nil)
        if hb then
            children[#children + 1] = hb
            self._burger_rect = Geom:new{ x = burger_dimen.x, y = burger_dimen.y,
                w = burger_dimen.w, h = burger_dimen.h }
        else
            self._burger_rect = nil
        end
    else
        self._burger_rect = nil
    end
    self[1] = children
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
        -- The hamburger opens the start menu (over this overlay), so it stays
        -- reachable from the full-screen view.
        if ev and ev.ges == "tap" and _tapInRect(ev, self._burger_rect) then
            if self.bw and self.bw._openStartMenu then self.bw:_openStartMenu() end
            return true
        end

        -- KOReader-native gestures (top-edge menu tap/swipe, edge
        -- brightness/warmth swipes, corner taps): same filtered FM touch-zone
        -- walk as BookshelfWidget:handleEvent.
        local fm = require("apps/filemanager/filemanager").instance
        if fm and ev then
            local user_gestures = (fm.gestures and fm.gestures.gestures) or {}
            local zone_lists = { fm._ordered_touch_zones }
            for _i, child in ipairs(fm) do
                if child ~= fm.file_chooser and type(child) == "table"
                   and child._ordered_touch_zones then
                    zone_lists[#zone_lists + 1] = child._ordered_touch_zones
                end
            end
            for _i, zones in ipairs(zone_lists) do
                for _j, tzone in ipairs(zones) do
                    local id = tzone.def and tzone.def.id
                    local allowed = id and (id:find("^filemanager_") or user_gestures[id])
                    if allowed and tzone.gs_range:match(ev) and tzone.handler(ev) then
                        return true
                    end
                end
            end
        end

        -- Fallback: a tap on empty space dismisses the overlay.
        if ev and ev.ges == "tap" then return self:onTapClose() end
        return false
    end

    -- Non-gesture events. Our own key / lifecycle handlers run first.
    if InputContainer.handleEvent(self, event) then return true end
    -- A gesture zone fired above (brightness/warmth/night mode) emits its action
    -- as a SEPARATE Dispatcher event via UIManager:sendEvent, which only reaches
    -- the topmost widget (us). Forward it to FM so its DeviceListener acts on it
    -- -- without this the swipe is recognised but nothing happens. Mirrors
    -- BookshelfWidget:handleEvent's second forward, incl. its exclusions.
    local NEVER_FORWARD = { onCloseWidget = true, onFlushSettings = true,
                            onShow = true, onClose = true }
    if NEVER_FORWARD[event.handler] then return end
    if event._bookshelf_from_broadcast then return end
    local fm = require("apps/filemanager/filemanager").instance
    if fm then return fm:handleEvent(event) end
end

-- Re-layout on screen resize / rotation (desktop window resize), the same way
-- the main bookshelf view rebuilds in its paintTo on a size change.
function MicroFullscreen:paintTo(bb, x, y)
    if Screen:getWidth() ~= self._built_w or Screen:getHeight() ~= self._built_h then
        self:_build()
    end
    InputContainer.paintTo(self, bb, x, y)
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
function MicroFullscreen:_setFocusClose(on)
    if self._focus_close == on then return end
    self._focus_close = on
    self:rebuildGrid()
end
function MicroFullscreen:_navCell(dir)
    local HeroModules = require("lib/bookshelf_hero_modules")
    return HeroModules.navMove(self.bw and self.bw._hero_grid_rows, self._cursor_id, dir)
end
function MicroFullscreen:_moveTo(dir)
    local nid = self:_navCell(dir)
    if nid and nid ~= self._cursor_id then self._cursor_id = nid; self:rebuildGrid() end
end
-- Up/Down cross between the grid and the close button (the single exit), so the
-- X is reachable by d-pad, not only by Back. Left/Right stay within the grid.
function MicroFullscreen:onMFFocusUp()
    if self._focus_close then self:_setFocusClose(false) else self:_moveTo("up") end
    return true
end
function MicroFullscreen:onMFFocusDown()
    if self._focus_close then return true end
    if self:_navCell("down") then self:_moveTo("down") else self:_setFocusClose(true) end
    return true
end
function MicroFullscreen:onMFFocusLeft()
    if not self._focus_close then self:_moveTo("left") end
    return true
end
function MicroFullscreen:onMFFocusRight()
    if not self._focus_close then self:_moveTo("right") end
    return true
end

-- Press / Hold act on the focused cell exactly as a tap / long-press would.
function MicroFullscreen:_focusedRec()
    return self.bw and self.bw._hero_cells and self._cursor_id
        and self.bw._hero_cells[self._cursor_id] or nil
end
function MicroFullscreen:onMFPress()
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
    if self._focus_close then return true end
    local HeroModules = require("lib/bookshelf_hero_modules")
    local rec = self:_focusedRec()
    if rec and rec.entry and HeroModules._hold then
        HeroModules._hold(self.bw, rec.entry)
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
