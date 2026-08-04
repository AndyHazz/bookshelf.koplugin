--[[
Persistent Bookshelf launcher buttons for the reader view: the start-menu
hamburger and (when micro-modules are enabled) the micro-module grid button.

Registered with ReaderView via view:registerViewModule (the Bookends overlay
mechanism), so paintTo runs as part of every ReaderView paint pass -- drawn INTO
the reader frame, surviving page turns / refreshes. main.lua registers a touch
zone over each button.

Position + glyph design come from lib/bookshelf_footer_geom -- the single source
the home-screen footer buttons also use -- so the launchers are pixel-identical
and track any footer change (the real painted rects are remembered when the
bookshelf is shown; otherwise a computed fallback).
]]
local Blitbuffer = require("ffi/blitbuffer")
local Device     = require("device")
local FooterGeom = require("lib/bookshelf_footer_geom")
local Geom       = require("ui/geometry")
local Widget     = require("ui/widget/widget")
local Screen     = Device.screen
local BookshelfSettings = require("lib/bookshelf_settings_store")

-- User adjustments for the in-reader launchers (#279), applied ONLY in this
-- file so the home-screen footer buttons -- which come from the same shared
-- geometry source -- are untouched:
--   reader_launcher_lift  (dp, default 0)   offset along the anchored edge.
--                                           POSITIVE = away from that edge
--                                           (inward), NEGATIVE = closer to it.
--   reader_launcher_offset_x (dp, default 0) offset from the SIDE edge the
--                                           launcher sits against. POSITIVE =
--                                           inward, NEGATIVE = closer to it --
--                                           same convention as lift, so
--                                           "positive moves away from the
--                                           anchored edge" holds on both axes.
--   reader_launcher_scale (%, default 100)  glyph size.
--   reader_launcher_top   (bool, false)     anchor to the TOP edge instead.
local function _cfg()
    return {
        lift  = tonumber(BookshelfSettings.read("reader_launcher_lift", 0)) or 0,
        offx  = tonumber(BookshelfSettings.read("reader_launcher_offset_x", 0)) or 0,
        scale = tonumber(BookshelfSettings.read("reader_launcher_scale", 100)) or 100,
        top    = BookshelfSettings.read("reader_launcher_top", false) == true,
    }
end

local function _px(dp)
    if dp == 0 then return 0 end
    local neg = dp < 0
    local v = Screen:scaleBySize(neg and -dp or dp)
    return neg and -v or v
end

-- Resolve a launcher's final position from the shared anchor, honouring all
-- three knobs. `base_y` is the anchor's glyph-top; `h0` the UNSCALED glyph
-- height (the anchor's own reference) and `h` the scaled one, so a shrunken
-- glyph stays visually centred on the anchor rather than drifting. Clamped to
-- the screen so no combination can push a glyph (or its tap box) out of view.
local function _resolveY(base_y, h0, h, cfg)
    local sh = Screen:getHeight()
    local centre = math.floor((h0 - h) / 2)
    local y
    if cfg.top then
        -- Mirror the anchor about the screen's midline so the distance from the
        -- top edge equals what the distance from the bottom edge was. The offset
        -- flips with it, so "positive = inward" holds for both edges rather than
        -- silently reversing meaning when the user ticks the top toggle.
        y = sh - (base_y + h0) + centre + _px(cfg.lift)
    else
        y = base_y + centre - _px(cfg.lift)
    end
    return math.max(0, math.min(math.max(0, sh - h), y))
end


local ReaderButtons = Widget:extend{
    side           = "left",  -- hamburger side (start_menu_position)
    grid_side      = "right", -- grid side (opposite the hamburger)
    show_hamburger = true,    -- draw the start-menu hamburger (off when start menu = off)
    show_grid      = false,   -- draw the micro-module grid button (fullscreen placement only)
}

-- Resolve a launcher's x, honouring the horizontal offset. `w` is the glyph's
-- own width so the clamp keeps it fully on screen. Which way "inward" points
-- depends on the side the launcher is anchored to: a left-side launcher moves
-- RIGHT for a positive offset, a right-side one moves LEFT.
local function _resolveX(base_x, w, side, cfg)
    local sw = Screen:getWidth()
    local dx = _px(cfg.offx)
    local x = (side == "right") and (base_x - dx) or (base_x + dx)
    return math.max(0, math.min(math.max(0, sw - w), x))
end

-- Final geometry of the hamburger: centre x, glyph top y, scaled metrics.
function ReaderButtons.barsGeom(side)
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local cfg = _cfg()
    local m0  = FooterGeom.barMetrics()
    local m   = FooterGeom.barMetrics(cfg.scale)
    local cx, base_top = FooterGeom.launcherBarsAnchor(sw, sh, side)
    -- launcherBarsAnchor gives a CENTRE x; clamp on the glyph's left edge then
    -- convert back, so the clamp accounts for the bar width.
    local left = _resolveX(cx - math.floor(m.bar_w / 2), m.bar_w, side, cfg)
    return left + math.floor(m.bar_w / 2), _resolveY(base_top, m0.span, m.span, cfg), m
end

-- Final geometry of the 2x2 grid glyph: left x, top y, scaled metrics.
function ReaderButtons.gridGeom(grid_side)
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local cfg = _cfg()
    local g0  = FooterGeom.gridMetrics()
    local g   = FooterGeom.gridMetrics(cfg.scale)
    local gx, base_oy = FooterGeom.launcherGridAnchor(sw, sh, grid_side)
    -- Keep a shrunken grid centred horizontally on the anchor too (its width
    -- shrinks as well, unlike the hamburger whose centre x is given directly).
    local x = gx + math.floor((g0.W - g.W) / 2)
    return _resolveX(x, g.W, grid_side, cfg), _resolveY(base_oy, g0.H, g.H, cfg), g
end

-- Scale for callers that need to paint the glyph themselves.
function ReaderButtons.scalePct()
    return _cfg().scale
end

-- True when any of the knobs moves/resizes the launcher away from the shared
-- footer geometry, so callers know the REMEMBERED shelf-mode frame no longer
-- describes where the reader launcher actually is.
function ReaderButtons.adjusted()
    local cfg = _cfg()
    return cfg.lift ~= 0 or cfg.offx ~= 0 or cfg.scale ~= 100 or cfg.top
end

-- Rect to hang an overlay on (the start menu's close-X, the fullscreen
-- overlay's glyphs). Prefers the REMEMBERED shelf-mode button frame, which is
-- the exact painted rect and centres the close glyph in the full frame rather
-- than the smaller tap box -- but that frame predates these adjustments, so
-- once any is active the computed tap rect is the only truthful answer.
function ReaderButtons.overlayRect(side)
    if not ReaderButtons.adjusted() then
        local r = FooterGeom.rememberedButtonRect(side)
        if r then return r end
    end
    return ReaderButtons.tapRect(side)
end

function ReaderButtons.gridOverlayRect(grid_side)
    if not ReaderButtons.adjusted() then
        local r = FooterGeom.rememberedGridRect(grid_side)
        if r then return r end
    end
    return ReaderButtons.gridTapRect(grid_side)
end

-- previewWidget(): a full-screen BLANK canvas with the launcher glyphs painted
-- exactly where the reader would put them. Used by the launcher settings dialog
-- so the controls always have something visibly moving -- adjusting them from the
-- library used to change nothing on screen, which read as "the setting does
-- nothing". Deliberately blank (no shelf, no book text): the launcher is the
-- only thing being positioned, and a busy background made it hard to see.
--
-- It shares barsGeom/gridGeom with the real launcher, so the preview is the
-- actual geometry rather than an approximation that could drift from it.
function ReaderButtons.previewWidget()
    local W = Widget:extend{}
    function W:getSize()
        return Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() }
    end
    function W:paintTo(bb, x, y)
        local sw, sh = Screen:getWidth(), Screen:getHeight()
        self.dimen = Geom:new{ x = x, y = y, w = sw, h = sh }
        bb:paintRect(x, y, sw, sh, Blitbuffer.COLOR_WHITE)
        local side = BookshelfSettings.read("start_menu_position", "left")
        if side ~= "right" then side = "left" end
        -- Mirror the reader's own gating: the hamburger is hidden when the start
        -- menu is off, and the grid only exists in the fullscreen placement.
        if BookshelfSettings.read("start_menu_position", "left") ~= "off" then
            local cx, top, m = ReaderButtons.barsGeom(side)
            local left = cx - math.floor(m.bar_w / 2)
            for i = 0, 2 do
                bb:paintRect(x + left, y + top + i * (m.bar_t + m.gap),
                    m.bar_w, m.bar_t, Blitbuffer.COLOR_BLACK)
            end
        end
        if BookshelfSettings.microFullscreenButton() then
            local grid_side = (side == "left") and "right" or "left"
            local gx, goy = ReaderButtons.gridGeom(grid_side)
            FooterGeom.paintGrid(bb, x + gx, y + goy, ReaderButtons.scalePct())
        end
    end
    return W:new{}
end

function ReaderButtons:paintTo(_bb, _x, _y)
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    -- Hamburger (start menu), unless the start menu is set to "off".
    if self.show_hamburger then
        local cx, top, m = ReaderButtons.barsGeom(self.side)
        local left = cx - math.floor(m.bar_w / 2)
        for i = 0, 2 do
            _bb:paintRect(left, top + i * (m.bar_t + m.gap), m.bar_w, m.bar_t,
                Blitbuffer.COLOR_BLACK)
        end
    end
    -- Grid (micro-modules), opposite corner, when enabled.
    if self.show_grid then
        local gx, goy = ReaderButtons.gridGeom(self.grid_side)
        FooterGeom.paintGrid(_bb, gx, goy, ReaderButtons.scalePct())
    end
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
end

-- Comfortable tap box around the hamburger bars (NOT the full footer-button
-- width, which would swallow the corner's page-turn taps).
function ReaderButtons.tapRect(side)
    local cx, top, m = ReaderButtons.barsGeom(side)
    local pad = Screen:scaleBySize(10)
    return Geom:new{ x = math.max(0, cx - math.floor(m.bar_w / 2) - pad),
                     y = math.max(0, top - pad),
                     w = m.bar_w + 2 * pad, h = m.span + 2 * pad }
end

-- Comfortable tap box around the grid glyph.
function ReaderButtons.gridTapRect(grid_side)
    local gx, goy, g = ReaderButtons.gridGeom(grid_side)
    local pad = Screen:scaleBySize(10)
    return Geom:new{ x = math.max(0, gx - pad),
                     y = math.max(0, goy - pad),
                     w = g.W + 2 * pad, h = g.H + 2 * pad }
end

return ReaderButtons
