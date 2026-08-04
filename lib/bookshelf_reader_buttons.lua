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
--   reader_launcher_scale (%, default 100)  glyph size.
--   reader_launcher_top   (bool, false)     anchor to the TOP edge instead.
local function _cfg()
    return {
        lift  = tonumber(BookshelfSettings.read("reader_launcher_lift", 0)) or 0,
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

-- Final geometry of the hamburger: centre x, glyph top y, scaled metrics.
function ReaderButtons.barsGeom(side)
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local cfg = _cfg()
    local m0  = FooterGeom.barMetrics()
    local m   = FooterGeom.barMetrics(cfg.scale)
    local cx, base_top = FooterGeom.launcherBarsAnchor(sw, sh, side)
    return cx, _resolveY(base_top, m0.span, m.span, cfg), m
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
    return x, _resolveY(base_oy, g0.H, g.H, cfg), g
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
    return cfg.lift ~= 0 or cfg.scale ~= 100 or cfg.top
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
