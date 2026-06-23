--[[
Single source of truth for the footer's layout primitives and the start-menu
(hamburger) button's on-screen position, so the home-screen footer button and
the in-reader launcher are pixel-identical and any change here moves both.

The home-screen widget's _layoutPrimitives and _buildStartMenuIcon delegate
here; the reader launcher (bookshelf_reader_buttons) reads startMenuBarsRect /
barMetrics. Everything is a pure function of screen size + settings.
]]
local Device = require("device")
local Geom   = require("ui/geometry")
local Size   = require("ui/size")
local Screen = Device.screen

local M = {}

-- PAD (side margin), content_w, footer_h used by the footer build. PAD/content_w
-- match _computeDims / _layoutPrimitives; footer_h matches the FOOTER_H the
-- footer is actually built with (note: distinct from _layoutPrimitives' own
-- footer_h, which is row-math only). Used for the fallback geometry when the
-- real painted rect hasn't been remembered yet.
function M.primitives(width)
    width = width or Screen:getWidth()
    local pad_natural = math.floor(Size.padding.fullscreen * 2 * 0.8)
    local pad_capped  = math.floor(width * 0.03)
    local PAD         = math.min(pad_natural, pad_capped)
    local content_w   = width - PAD * 2
    local footer_h    = Screen:scaleBySize(32) + 2 * Screen:scaleBySize(4) -- FOOTER_H
    return PAD, content_w, footer_h
end

-- Width of one side strip the footer corner buttons sit in (the nav/pagination
-- strip is the central 75% of content_w; the two side strips split the rest).
function M.sideStripW(width)
    width = width or Screen:getWidth()
    local _PAD, content_w = M.primitives(width)
    local nav_strip_w = math.floor(content_w * 0.75)
    return math.floor((width - nav_strip_w) / 2)
end

-- Hamburger bar geometry (art box, stroke, span). Single source for the design
-- shared by the footer icon, its close-X, and the reader launcher.
function M.barMetrics()
    local art   = Screen:scaleBySize(32)
    local bar_w = art
    local bar_t = math.max(1, math.floor(art / 14)) -- == FOOTER_STROKE_W
    local span0 = math.floor(art * 0.62)
    local gap   = math.max(1, math.floor((span0 - 3 * bar_t) / 2))
    local span  = 3 * bar_t + 2 * gap
    return { art = art, bar_w = bar_w, bar_t = bar_t, gap = gap, span = span }
end

-- The footer button's hit-extension padding (FOOTER_HIT_EXTENSION): empty space
-- below the bars inside the frame, so the frame is `art + hit` tall.
function M.hitExtension()
    return Screen:scaleBySize(12)
end

-- Focus-ring reserve (_wrapAsFooterButton's focus_border): a margin around the
-- frame at rest, so the bars sit this far in from the frame's top/left edge.
function M.focusBorder()
    return Screen:scaleBySize(4)
end

-- The ACTUAL painted rect of the home-screen start-menu button, remembered each
-- time the footer paints (BookshelfWidget:paintTo). KOReader is a single Lua
-- state, so the reader launcher can read the real geometry the home screen used
-- -- no drift, and rotation / resize / setting changes propagate for free. nil
-- until the bookshelf has been shown once this session (then the reader falls
-- back to the computed startMenuBarsRect).
-- _remembered = { rect = {x,y,w,h}, side = "left"|"right" } -- the side the
-- footer painted it on, so the reader can MIRROR it when its own
-- start_menu_position differs (the footer is symmetric, so the mirror is exact
-- -- this is what makes a left/right flip move the reader launcher even though
-- the bookshelf hasn't repainted at the new side).
local _remembered
local function startMenuSide()
    local p = require("lib/bookshelf_settings_store").read("start_menu_position", "left")
    return (p == "right") and "right" or "left"
end
-- Mirror a remembered rect to want_side if it was stored for the other side.
local function rectForSide(stored, want_side)
    if not stored then return nil end
    local r = stored.rect
    if stored.side == want_side then return { x = r.x, y = r.y, w = r.w, h = r.h } end
    return { x = Screen:getWidth() - r.x - r.w, y = r.y, w = r.w, h = r.h }
end
-- A remembered rect is only valid for the screen geometry it was captured at:
-- it holds ABSOLUTE pixels, so reusing it after a rotation or window resize
-- would place the launcher off-screen (issue #196: the portrait y falls below a
-- shorter landscape screen, painting the glyph invisibly). When the geometry
-- differs, treat it as absent so callers fall back to the computed anchor, which
-- is a pure function of the current screen size.
local function freshForScreen(stored)
    return stored and stored.sw == Screen:getWidth()
        and stored.sh == Screen:getHeight()
end
function M.rememberButtonRect(d)
    if d and d.x and d.w and d.w > 0 then
        _remembered = { rect = { x = d.x, y = d.y, w = d.w, h = d.h },
            side = startMenuSide(), sw = Screen:getWidth(), sh = Screen:getHeight() }
    end
end
-- Rect for the hamburger on `side` (mirrored from the remembered one if it was
-- painted on the other side); nil until the bookshelf has been shown, or when
-- the screen geometry has changed since it was captured.
function M.rememberedButtonRect(side)
    if not freshForScreen(_remembered) then return nil end
    return rectForSide(_remembered, side or startMenuSide())
end

-- Grid (micro-module) button glyph metrics, mirroring _buildMicroModuleIcon:
-- a 2x2 of separate outlined boxes, the ink box W x H (H is the bar span x1.25)
-- centred in the art box.
function M.gridMetrics()
    local art  = Screen:scaleBySize(32)
    local t    = math.max(1, math.floor(art / 14))
    local span0 = math.floor(art * 0.62)
    local bgap = math.max(1, math.floor((span0 - 3 * t) / 2))
    local span = 3 * t + 2 * bgap
    local W, H = art, math.floor(span * 1.25)
    local gap  = math.max(2, 2 * t)
    local cw   = math.floor((W - gap) / 2)
    local ch   = math.floor((H - gap) / 2)
    return { art = art, t = t, W = W, H = H, gap = gap, cw = cw, ch = ch }
end

-- Paint the 2x2 grid glyph: left edge at x, top of the H ink box at oy.
function M.paintGrid(bb, x, oy)
    local Blitbuffer = require("ffi/blitbuffer")
    local g = M.gridMetrics()
    local function box(rx, ry)
        bb:paintRect(rx, ry, g.cw, g.t, Blitbuffer.COLOR_BLACK)
        bb:paintRect(rx, ry + g.ch - g.t, g.cw, g.t, Blitbuffer.COLOR_BLACK)
        bb:paintRect(rx, ry, g.t, g.ch, Blitbuffer.COLOR_BLACK)
        bb:paintRect(rx + g.cw - g.t, ry, g.t, g.ch, Blitbuffer.COLOR_BLACK)
    end
    for r = 0, 1 do
        for c = 0, 1 do
            box(x + c * (g.cw + g.gap), oy + r * (g.ch + g.gap))
        end
    end
end

-- Real painted rect of the footer micro-module (grid) button + the side it was
-- on (opposite the start menu), so the reader grid launcher mirrors it on a flip.
local _remembered_grid
local function gridSide()
    local p = require("lib/bookshelf_settings_store").read("start_menu_position", "left")
    return (p == "left") and "right" or ((p == "right") and "left" or "right")
end
function M.rememberGridRect(d)
    if d and d.x and d.w and d.w > 0 then
        _remembered_grid = { rect = { x = d.x, y = d.y, w = d.w, h = d.h },
            side = gridSide(), sw = Screen:getWidth(), sh = Screen:getHeight() }
    end
end
function M.rememberedGridRect(side)
    if not freshForScreen(_remembered_grid) then return nil end
    return rectForSide(_remembered_grid, side or gridSide())
end

-- Left x + top y for painting the grid glyph, from the remembered frame when
-- available, else a computed fallback (grid sits in the side strip opposite the
-- start menu). Returns left_x, oy.
function M.launcherGridAnchor(width, height, side)
    width  = width or Screen:getWidth()
    height = height or Screen:getHeight()
    local g = M.gridMetrics()
    local rect = M.rememberedGridRect(side) -- fresh-geometry only (exact)
    if rect then
        local cx = rect.x + math.floor(rect.w / 2)
        local oy = rect.y + M.focusBorder() + math.floor((g.art - g.H) / 2)
        return cx - math.floor(g.W / 2), oy
    end
    -- Stale geometry: remap the remembered grid button to the current screen,
    -- preserving its bottom gap (geometry-invariant) and recomputing x. Same
    -- reasoning as launcherBarsAnchor (#196).
    if _remembered_grid then
        local cap_oy     = _remembered_grid.rect.y + M.focusBorder()
                           + math.floor((g.art - g.H) / 2)
        local bottom_gap = _remembered_grid.sh - cap_oy
        local side_strip = M.sideStripW(width)
        local cx = (side == "right") and (width - math.floor(side_strip / 2))
                   or math.floor(side_strip / 2)
        return cx - math.floor(g.W / 2), height - bottom_gap
    end
    -- Never remembered this session: centre in the side strip, flush-bottom band.
    local _PAD, _cw, footer_h = M.primitives(width)
    local side_strip = M.sideStripW(width)
    local cx = (side == "right") and (width - math.floor(side_strip / 2))
               or math.floor(side_strip / 2)
    local hit = M.hitExtension()
    local frame_top = (height - footer_h) + math.floor((footer_h - (g.art + hit)) / 2)
    local oy = frame_top + math.floor((g.art - g.H) / 2)
    return cx - math.floor(g.W / 2), oy
end

-- Where to paint the bars and centre the tap target: from the remembered button
-- frame when available (exact), else the computed fallback. Returns the bars'
-- centre x and top y.
function M.launcherBarsAnchor(width, height, side)
    width  = width or Screen:getWidth()
    height = height or Screen:getHeight()
    local m   = M.barMetrics()
    local rect = M.rememberedButtonRect(side) -- fresh-geometry only (exact)
    if rect then
        -- Bars are centred in the frame; the frame reserves focusBorder() of
        -- margin above the bars and hitExtension() of padding below them.
        return rect.x + math.floor(rect.w / 2),
               rect.y + M.focusBorder() + math.floor((m.art - m.span) / 2)
    end
    -- Stale geometry (rotation / resize): REMAP the remembered button to the
    -- current screen rather than recomputing from scratch. The footer button is
    -- bottom-anchored with geometry-invariant vertical metrics, so the bars' gap
    -- from the screen bottom is constant -- preserve the remembered button's
    -- measured gap exactly (startMenuBarsRect's from-scratch y lands a few px
    -- low, #196) and recompute x from the current side strip.
    if _remembered then
        local cap_top    = _remembered.rect.y + M.focusBorder()
                           + math.floor((m.art - m.span) / 2)
        local bottom_gap = _remembered.sh - cap_top
        local side_strip = M.sideStripW(width)
        local cx = (side == "right") and (width - math.floor(side_strip / 2))
                   or math.floor(side_strip / 2)
        return cx, height - bottom_gap
    end
    -- Never remembered this session: pure computed anchor.
    local r = M.startMenuBarsRect(width, height, side)
    return r.x + math.floor(r.w / 2), r.y
end

-- Screen rect of the 3 hamburger bars, positioned exactly as the footer button:
-- bars centred in the side strip, in the flush-bottom footer band, with the
-- (art + hit)-tall frame vertically centred in footer_h (the LeftContainer /
-- BottomContainer composition _buildFooterRow uses, reduced to coordinates).
function M.startMenuBarsRect(width, height, side)
    width  = width or Screen:getWidth()
    height = height or Screen:getHeight()
    local _PAD, _cw, footer_h = M.primitives(width)
    local side_strip = M.sideStripW(width)
    local m   = M.barMetrics()
    local hit = M.hitExtension()
    local band_top  = height - footer_h
    local frame_top = band_top + math.floor((footer_h - (m.art + hit)) / 2)
    local first_y   = frame_top + math.floor((m.art - m.span) / 2)
    local cx = (side == "right") and (width - math.floor(side_strip / 2))
               or math.floor(side_strip / 2)
    return Geom:new{ x = cx - math.floor(m.bar_w / 2), y = first_y,
                     w = m.bar_w, h = m.span }
end

return M
