--[[
Book shadows from three image masks (assets/shadows), in place of the banded
ramps the recess painter computes. Each file is a black PNG whose alpha is
the shadow's opacity; loaded once per screen scale and night state as a
BB8A (black by day, white in a night frame, as Wallpaper.shadeRect darkens
or lightens) and alpha-blitted, so where two shadows overlap they multiply:
a narrow gap is darker than either side.

  side  the wedge beside a book, drawn for its RIGHT side and mirrored for
        the left. Its outline runs from just above the book's top corner,
        out and down to the wall line (where the plank's surface meets the
        wall), then back to the book's bottom corner. The taper is stretched
        to the book's height and joined to the plank part, one buffer per
        size, cached.
  top   the halo above a spine: uniform across, tiled to the spine's width.
  foot  the contact line on the plank surface under a run of books, with a
        fade-in cap at each end.
]]
local Blitbuffer = require("ffi/blitbuffer")
local Device     = require("device")
local logger     = require("logger")
local Screen     = Device.screen

local M = {}

-- dp layout of the files; keep in step with shadowgen.py
M.DP = { side = 16, up = 96, wall = 10, below = 0, above = 2,
         halo = 6, tile = 48, cap = 5, foot = 4 }
-- joined wedges kept per set (a page holds a few dozen book heights)
M.WEDGE_CACHE = 96

M._cache = {}

local function pluginRoot()
    local src = debug.getinfo(1, "S").source or ""
    local dir = src:match("^@(.*)/lib/[^/]+$")
    return dir or "."
end

-- load(path, w, h) -> the file at w x h as a BB8A (black, alpha = the
-- shadow), or nil. The files are LA PNGs, which MuPDF decodes straight into
-- a BB8A (black premultiplied is still black), so nothing is tinted per
-- pixel in Lua.
local function load(path, w, h)
    local ok_r, RenderImage = pcall(require, "ui/renderimage")
    if not ok_r then return nil end
    local ok, bb = pcall(function()
        return RenderImage:renderImageFile(path, false, w, h)
    end)
    if not ok or not bb then return nil end
    if bb:getWidth() ~= w or bb:getHeight() ~= h then
        local ok_s, sc = pcall(function()
            return RenderImage:scaleBlitBuffer(bb, w, h)
        end)
        if ok_s and sc then bb = sc end
    end
    if bb:getType() ~= Blitbuffer.TYPE_BB8A then
        logger.warn("[bookshelf] shadow asset is not grey + alpha:", path)
        pcall(function() bb:free() end)
        return nil
    end
    return bb
end

-- typeOf(bb) -> bb's buffer type: a set's buffers are all grey + alpha, or
-- all RGB32 (the colour set, see M._colourMask).
local function typeOf(bb)
    return (type(bb.getType) == "function" and bb:getType()) or Blitbuffer.TYPE_BB8A
end

-- M._colourMask(bb) -> a BB8A mask as an RGB32 one: the same shade (black,
-- or a night frame's white) with the same alpha. KOReader's C alpha blit of
-- a BB8A onto a colour buffer flattens what is under it to grey (beige under
-- black at 25% came out (169,169,169)); an RGB32 source darkens it and keeps
-- its hue (184,168,145), so a shadow over a colour wallpaper is the colour
-- darker, not grey (maintainer). Per pixel in Lua, once per set: the three
-- masks are a few thousand pixels. Frees bb.
function M._colourMask(bb)
    local w, h = bb:getWidth(), bb:getHeight()
    local out = Blitbuffer.new(w, h, Blitbuffer.TYPE_BBRGB32)
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            local c = bb:getPixel(x, y)
            out:setPixel(x, y, Blitbuffer.ColorRGB32(c.a, c.a, c.a, c.alpha))
        end
    end
    pcall(function() bb:free() end)
    return out
end

-- rows(bb, y0, h) -> rows [y0, y0+h) of bb as their own buffer (a C copy)
local function rows(bb, y0, h)
    local out = Blitbuffer.new(bb:getWidth(), h, typeOf(bb))
    out:blitFrom(require("lib/bookshelf_clip_bb").real(bb), 0, 0, 0, y0, bb:getWidth(), h)
    return out
end

-- mirrored(bb) -> bb flipped left to right: one C copy per column
local function mirrored(bb)
    local w, h = bb:getWidth(), bb:getHeight()
    local out = Blitbuffer.new(w, h, typeOf(bb))
    for x = 0, w - 1 do out:blitFrom(require("lib/bookshelf_clip_bb").real(bb), w - 1 - x, 0, x, 0, 1, h) end
    return out
end

-- lit(bb, night) -> bb itself by day; in a night frame a white copy (the
-- grey inverted, alpha kept), as Wallpaper.shadeRect lightens there
local function lit(bb, night)
    if not night then return bb end
    local out = bb:copy()
    out:invertRect(0, 0, out:getWidth(), out:getHeight())
    return out
end

-- Taper heights are rounded UP to this many px and the spare rows cut from
-- the tip, where the wedge is faintest: a page's books then share a handful
-- of stretched wedges instead of one per height.
M.BUCKET = 4

local function scaled(src, w, h)
    if src:getWidth() == w and src:getHeight() == h then return src end
    return require("ffi/mupdf").scaleBlitBuffer(src, w, h)
end

-- wedge(a, up_b, low_h, dir, w) -> the whole wedge, taper (up_b rows) over
-- plank part (low_h rows), w wide, joined once into one buffer so each
-- visible part is a single blit; cached per size
local function wedge(a, up_b, low_h, dir, w)
    local key = dir .. up_b .. "/" .. low_h .. "x" .. w
    local t = a.wedges[key]
    if t then return t end
    local side = (dir == "left") and "_l" or "_r"
    local ok, out = pcall(function()
        local o = Blitbuffer.new(w, up_b + low_h, typeOf(a.up_r))
        if up_b > 0 then
            local u = scaled(a["up" .. side], w, up_b)
            o:blitFrom(u, 0, 0, 0, 0, w, up_b)
            if u ~= a["up" .. side] then u:free() end
        end
        -- the plank part only changes with the row's wall line and the
        -- width, so it is stretched once for all the wedges that share them
        local lkey = side .. low_h .. "x" .. w
        local l = a.lows[lkey]
        if not l then
            l = scaled(a["low" .. side], w, low_h)
            a.lows[lkey] = l
        end
        o:blitFrom(l, 0, up_b, 0, 0, w, low_h)
        return o
    end)
    if not ok or not out then return nil end
    a.n_wedges = a.n_wedges + 1
    if a.n_wedges > M.WEDGE_CACHE then
        for k, bb in pairs(a.wedges) do
            pcall(function() bb:free() end)
            a.wedges[k] = nil
        end
        a.n_wedges = 1
    end
    a.wedges[key] = out
    return out
end

-- get(night, colour) -> the set for this screen, or nil (files missing).
-- colour: the masks as RGB32, for a colour buffer (M._colourMask).
function M.get(night, colour)
    local key = (night and "n" or "d") .. (colour and "c" or "g") .. Screen:scaleBySize(100)
    local c = M._cache[key]
    if c ~= nil then return c or nil end
    local D = M.DP
    local s = function(dp) return math.max(1, Screen:scaleBySize(dp)) end
    local side_w, up = s(D.side), s(D.up)
    local below = Screen:scaleBySize(D.below)
    local low = s(D.wall) + below
    local tile, cap, halo, foot = s(D.tile), s(D.cap), s(D.halo), s(D.foot)
    local dir = pluginRoot() .. "/assets/shadows/"
    local side = load(dir .. "shadow.side.png", side_w, up + low)
    local top  = load(dir .. "shadow.top.png", tile, halo)
    local ft   = load(dir .. "shadow.foot.png", cap + tile, foot)
    if not (side and top and ft) then
        logger.warn("[bookshelf] shadow assets missing in", dir)
        for _k, bb in pairs({ side, top, ft }) do pcall(function() bb:free() end) end
        M._cache[key] = false
        return nil
    end
    side, top, ft = lit(side, night), lit(top, night), lit(ft, night)
    if colour then
        side, top, ft = M._colourMask(side), M._colourMask(top), M._colourMask(ft)
    end
    local up_r, low_r = rows(side, 0, up), rows(side, up, low)
    c = {
        up_r = up_r, up_l = mirrored(up_r), low_r = low_r, low_l = mirrored(low_r),
        top = top, foot_l = ft, foot_r = mirrored(ft),
        side_w = side_w, low = low, wall = s(D.wall), below = below,
        above = s(D.above), tile = tile, cap = cap, halo = halo, foot = foot,
        lip = math.max(1, Screen:scaleBySize(1)),   -- the page block's hairline
        wedges = {}, n_wedges = 0, lows = {},
    }
    pcall(function() side:free() end)
    M._cache[key] = c
    return c
end

local function blit(bb, src, dx, dy, sx, sy, w, h)
    if w > 0 and h > 0 then bb:alphablitFrom(src, dx, dy, sx, sy, w, h) end
end

-- side(bb, a, edge_x, dir, book_top, floor, parts, wall_h, fit): the wedge
-- beside a book whose edge is at edge_x, toward dir ("right" or "left"). It
-- runs from a.above over book_top, out to the wall line wall_h above the
-- floor (where the plank's top surface meets the wall; default a.wall), and
-- back across the plank to a.below under the floor. parts: a list of
-- { x0, x1, y0, y1 } (x measured from the edge, y absolute) where the
-- wedge shows; the rest is under a neighbour. fit: squeeze the wedge to
-- that width (the room left at a shelf's end) instead of cutting it off.
-- Absolute bb coordinates.
function M.side(bb, a, edge_x, dir, book_top, floor, parts, wall_h, fit, n)
    local W = a.side_w
    if fit and fit < W then W = math.max(1, math.floor(fit)) end
    wall_h = math.max(1, math.floor(tonumber(wall_h) or a.wall))
    local top  = book_top - a.above
    local wall = floor - wall_h                -- taper / plank boundary
    local bot  = floor + a.below
    local up_h = wall - top
    local up_b = up_h > 0 and (math.ceil(up_h / M.BUCKET) * M.BUCKET) or 0
    local src  = wedge(a, up_b, bot - wall, dir, W)
    if not src then return end
    local origin = wall - up_b                 -- the wedge buffer's row 0
    for i = 1, n or #parts do
        local p = parts[i]
        local x0, x1 = math.max(0, p[1]), math.min(W, p[2])
        if x1 > x0 then
            local sx, dx
            if dir == "left" then sx, dx = W - x1, edge_x - x1
            else sx, dx = x0, edge_x + x0 end
            local r0, r1 = math.max(p[3], top, origin), math.min(p[4], bot)
            if r1 > r0 then blit(bb, src, dx, r0, sx, r0 - origin, x1 - x0, r1 - r0) end
        end
    end
end

-- across(bb, src, tile, sx, x0, x1, y, sy, h): src columns [sx, sx+tile)
-- tiled over [x0, x1).
local function across(bb, src, tile, sx, x0, x1, y, sy, h)
    local x = x0
    while x < x1 do
        local n = math.min(tile, x1 - x)
        blit(bb, src, x, y, sx, sy, n, h)
        x = x + n
    end
end

-- top(bb, a, x, w, book_top): the halo above a spine at [x, x+w). It ends
-- one lip INTO the book: the page block leaves its top row unpainted between
-- the boards (the nick) for the shadow behind the head to show there.
function M.top(bb, a, x, w, book_top)
    local y = book_top + (a.lip or 0) - a.halo
    local sy, h = 0, a.halo
    if y < 0 then sy = -y; h = h + y; y = 0 end
    if h <= 0 or w <= 0 then return end
    across(bb, a.top, a.tile, 0, x, x + w, y, sy, h)
end

-- foot(bb, a, x0, x1, y, h, lcap, rcap): the contact line under a run
-- [x0, x1), rows [y, y+h), with end caps lcap / rcap px wide (0: none).
-- A strip SHORTER than the mask gets the mask stretched to it (once per
-- height), not cropped: cropped, the fade was cut off part way, a flat band
-- ending in a step on the plank.
local function feet(a, h)
    if h >= a.foot then return a.foot_l, a.foot_r end
    a.feet = a.feet or {}
    local f = a.feet[h]
    if not f then
        local ok, l, r = pcall(function()
            return scaled(a.foot_l, a.foot_l:getWidth(), h),
                   scaled(a.foot_r, a.foot_r:getWidth(), h)
        end)
        if not ok or not l then return nil end
        f = { l, r }
        a.feet[h] = f
    end
    return f[1], f[2]
end

function M.foot(bb, a, x0, x1, y, h, lcap, rcap)
    h = math.min(h, a.foot)
    if h <= 0 or x1 <= x0 then return end
    local fl, fr = feet(a, h)
    if not fl then return end
    lcap = math.min(lcap or a.cap, a.cap); rcap = math.min(rcap or a.cap, a.cap)
    if lcap > 0 then blit(bb, fl, x0 - lcap, y, a.cap - lcap, 0, lcap, h) end
    across(bb, fl, a.tile, a.cap, x0, x1, y, 0, h)
    if rcap > 0 then blit(bb, fr, x1, y, a.tile, 0, rcap, h) end
end

local DIRS  = { "right", "left" }
local PARTS = { { 0, 0, 0, 0 }, { 0, 0, 0, 0 } }

-- paintRow(bb, ox, oy, cols, opts): the whole recess of one row.
--   cols      recess_cols: { x, w, h, foot } left to right, row-local
--   opts      { stand_h, width, below, wall, night }: the floor row, the
--             row's width, the plank surface rows under the floor (inset),
--             how far above the floor the surface meets the wall
function M.paintRow(bb, ox, oy, cols, opts)
    -- Without the C blitter an alpha blit is per-pixel Lua: no shadow beats a
    -- paint measured in seconds (Wallpaper.shadeRect's rule). Done, not
    -- failed, so the banded painter does not try either.
    if type(bb.canUseCbb) == "function" and not bb:canUseCbb() then return true end
    local colour = type(bb.getType) == "function" and bb:getType() == Blitbuffer.TYPE_BBRGB32
    local a = M.get(opts.night, colour)
    if not a then return false end
    local stand_h, width = opts.stand_h, opts.width
    local below = math.max(0, opts.below or 0)
    local n = #cols
    for i = 1, n do
        local c = cols[i]
        local book_top = stand_h - math.min(c.h, stand_h)
        local floor = stand_h - (c.foot or 0)
        M.top(bb, a, ox + c.x, c.w, oy + book_top)
        -- Each side: the whole wedge in the gap before the next book; over
        -- that book, only what shows above it when it is shorter (under it
        -- the contact line is the shadow). Wedges from both sides of a gap
        -- overlap and multiply.
        local plank_end = oy + stand_h + below
        for _s = 1, 2 do
            local dir = DIRS[_s]
            -- not `and cols[i + 1] or cols[i - 1]`: with no book to the
            -- right that picks the one to the LEFT
            local nb
            if dir == "right" then nb = cols[i + 1] else nb = cols[i - 1] end
            local edge = (dir == "right") and (c.x + c.w) or c.x
            local room
            if nb then
                room = (dir == "right") and (nb.x - edge) or (edge - (nb.x + nb.w))
            else
                room = (dir == "right") and (width - edge) or edge
            end
            room = math.max(0, room)
            -- the visible parts, in two reused tables (a row has ~50 sides)
            local p1, np = PARTS[1], 1
            p1[1], p1[2], p1[3], p1[4] = 0, room, 0, plank_end
            if nb then
                local nb_top = stand_h - math.min(nb.h, stand_h)
                if nb_top > book_top then
                    local p2 = PARTS[2]
                    p2[1], p2[2], p2[3], p2[4] = room, room + nb.w, 0, oy + nb_top
                    np = 2
                end
            end
            M.side(bb, a, ox + edge, dir, oy + book_top, oy + floor, PARTS, opts.wall,
                   (not nb) and room or nil, np)
        end
    end
    -- contact line: under each run of touching books that stand at the same
    -- foot. Spines stand on the floor and their line covers the plank strip
    -- in front of them (below); a face-out stands pushed back by its foot,
    -- and its line runs from the cover's foot over that push, up to where
    -- the spines stand -- the band FaceOutFeet paints without the masks.
    local i = 1
    while i <= n do
        local c = cols[i]
        local foot = c.foot or 0
        local j = i
        while j < n and (cols[j + 1].foot or 0) == foot
                and cols[j + 1].x <= cols[j].x + cols[j].w do
            j = j + 1
        end
        local rows = (foot > 0) and foot or below
        if rows > 0 then
            local x0, x1 = c.x, cols[j].x + cols[j].w
            local lroom = (i > 1) and (x0 - (cols[i - 1].x + cols[i - 1].w)) or x0
            local rroom = (j < n) and (cols[j + 1].x - x1) or (width - x1)
            M.foot(bb, a, ox + x0, ox + x1, oy + stand_h - foot, rows,
                   math.max(0, lroom), math.max(0, rroom))
        end
        i = j + 1
    end
    return true
end

return M
