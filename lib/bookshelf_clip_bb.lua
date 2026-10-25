--[[--
A stand-in for a blitbuffer that clips every drawing call to a few rects.

KOReader repaints a whole widget for any setDirty, and scopes only the
panel refresh: lifting one book on the shelf painted every plank, ornament,
shadow and cover again (a full shelf paint measured 150 ms on a PW5, the
same paint clipped to one book 51-72 ms). Painted through this, the widget
tree runs its paintTo with its real coordinates (so every dimen it records,
and every tap target, is right) while each blit, fill and text run outside
the rects costs nothing and one that crosses a rect is cut to the part
inside it.

  local ClipBB = require("lib/bookshelf_clip_bb")
  widget:paintTo(ClipBB.new(Screen.bb, { rect, rect2 }), x, y)

Methods that draw are wrapped; anything else (getWidth, getType, a
viewport, the data pointer...) goes to the real buffer. A drawing method
not wrapped here draws unclipped: correct, only not cheaper.

READING THE TARGET BACK. A painter that copies what is already on the
target (a corner cut keeping what was behind it) must hand the REAL buffer
to a real blitbuffer's method: ClipBB.real(bb). This one's own blits
unwrap a clipped source themselves.
]]

local M = {}

local Clip = {}

local function real(bb)
    if type(bb) == "table" and rawget(bb, "_is_clip") then return rawget(bb, "_bb") end
    return bb
end
M.real = real

-- cut(c, x, y, w, h) -> the part of (x, y, w, h) inside rect c as x, y, w,
-- h, and the offsets into it (dx, dy); nil when nothing is.
local function cut(c, x, y, w, h)
    local x0, y0 = math.max(x, c.x), math.max(y, c.y)
    local x1, y1 = math.min(x + w, c.x + c.w), math.min(y + h, c.y + c.h)
    if x1 <= x0 or y1 <= y0 then return nil end
    return x0, y0, x1 - x0, y1 - y0, x0 - x, y0 - y
end

-- Source-to-destination blits: (source, dest_x, dest_y, offs_x, offs_y, w, h, ...).
local BLITS = { "blitFrom", "alphablitFrom", "pmulalphablitFrom", "ditherblitFrom",
                "ditheralphablitFrom", "ditherpmulalphablitFrom", "colorblitFrom",
                "colorblitFromRGB32", "invertblitFrom", "addblitFrom" }
for _i, name in ipairs(BLITS) do
    Clip[name] = function(self, src, dx, dy, ox, oy, w, h, ...)
        src = real(src)
        ox, oy = ox or 0, oy or 0
        if not w then w, h = src:getWidth() - ox, src:getHeight() - oy end
        if not (dx and dy and w and h) then return end
        local bb = self._bb
        local f = bb[name]
        for _r, c in ipairs(self._rects) do
            local x, y, cw, ch, sx, sy = cut(c, dx, dy, w, h)
            if x then f(bb, src, x, y, ox + sx, oy + sy, cw, ch, ...) end
        end
    end
end

-- Rect fills: (x, y, w, h, ...).
local RECTS = { "paintRect", "paintRectRGB32", "invertRect", "lightenRect", "darkenRect",
                "dimRect", "blendRectRGB32" }
for _i, name in ipairs(RECTS) do
    Clip[name] = function(self, x, y, w, h, ...)
        if not (x and y and w and h) then return end
        local bb = self._bb
        local f = bb[name]
        for _r, c in ipairs(self._rects) do
            local cx, cy, cw, ch = cut(c, x, y, w, h)
            if cx then f(bb, cx, cy, cw, ch, ...) end
        end
    end
end
function Clip:fill(colour)
    for _r, c in ipairs(self._rects) do self._bb:paintRect(c.x, c.y, c.w, c.h, colour) end
end

-- Shapes the buffer draws itself (a border, a rounded rect): one wholly
-- inside a rect is drawn as it is; one crossing a rect's edge is drawn into a
-- small real buffer holding what is on screen there, and only the part inside
-- the rect is copied back. Drawing it whole painted a neighbour's background
-- over that neighbour's text, which lay outside the rect and was skipped
-- (the chip next to a restyled chip came out blank). A real buffer, not a
-- viewport: a viewport keeps its parent's stride and a fast-path fill smears
-- across it.
local function shape(self, name, x, y, w, h, ...)
    if not (x and y and w and h) then return end
    local bb = self._bb
    for _r, c in ipairs(self._rects) do
        local ix, iy, iw, ih = cut(c, x, y, w, h)
        if ix then
            if ix == x and iy == y and iw == w and ih == h then
                bb[name](bb, x, y, w, h, ...)
            else
                local Blitbuffer = require("ffi/blitbuffer")
                local tmp = Blitbuffer.new(iw, ih, bb:getType())
                tmp:blitFrom(bb, 0, 0, ix, iy, iw, ih)
                local ok = pcall(tmp[name], tmp, x - ix, y - iy, w, h, ...)
                if ok then bb:blitFrom(tmp, ix, iy, 0, 0, iw, ih) end
                tmp:free()
            end
        end
    end
end
for _i, name in ipairs({ "paintBorder", "paintRoundedRect", "paintBorderRGB32",
                         "paintInnerBorder", "paintRoundedCorner" }) do
    Clip[name] = function(self, x, y, w, h, ...) return shape(self, name, x, y, w, h, ...) end
end

-- Single pixels: inside a rect or not at all.
for _i, name in ipairs({ "setPixel", "setPixelClamped" }) do
    Clip[name] = function(self, x, y, ...)
        for _r, c in ipairs(self._rects) do
            if x >= c.x and y >= c.y and x < c.x + c.w and y < c.y + c.h then
                local bb = self._bb
                return bb[name](bb, x, y, ...)
            end
        end
    end
end

local mt = {
    __index = function(self, k)
        local f = Clip[k]
        if f then return f end
        local bb = rawget(self, "_bb")
        local v = bb[k]
        if type(v) == "function" then
            return function(_s, ...) return v(bb, ...) end
        end
        return v
    end,
}

--- new(bb, rects) -> a clipped stand-in for bb; rects a list of
--- { x, y, w, h } in bb's own coordinates.
-- disjoint(rects) -> the rects with any that overlap merged into their
-- bounding box: a blending fill (lighten, dim, a tint) cut once per rect
-- would otherwise be applied twice where two rects overlap.
local function disjoint(rects)
    local list = {}
    for i, r in ipairs(rects) do list[i] = { x = r.x, y = r.y, w = r.w, h = r.h } end
    local merged = true
    while merged do
        merged = false
        for i = 1, #list do
            for j = i + 1, #list do
                local a, b = list[i], list[j]
                if a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h then
                    local x0, y0 = math.min(a.x, b.x), math.min(a.y, b.y)
                    local x1 = math.max(a.x + a.w, b.x + b.w)
                    local y1 = math.max(a.y + a.h, b.y + b.h)
                    list[i] = { x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
                    table.remove(list, j)
                    merged = true
                    break
                end
            end
            if merged then break end
        end
    end
    return list
end

function M.new(bb, rects)
    local list = disjoint(rects)
    return setmetatable({ _bb = real(bb), _rects = list, _is_clip = true }, mt)
end

return M
