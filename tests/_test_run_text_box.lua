-- tests/_test_run_text_box.lua
-- A wrapping text block in which some runs (the rating stars) take a colour
-- of their own.
--
-- KOReader's text box lays the text out and draws it in one ink into its own
-- bitmap, and keeps a record of where each character's glyph landed. This
-- widget lifts the pixels of each run out of that bitmap into a small bitmap
-- of its own, and paints the main bitmap in the ink and each lifted piece in
-- the run's colour. Wrapping, truncation and the ellipsis stay KOReader's.
--
-- Usage (from plugin root): lua tests/_test_run_text_box.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local WHITE, BLACK, INK, GOLD = { name = "white" }, { name = "black" }, { name = "ink" }, { name = "gold" }
local made = {}   -- every bitmap Blitbuffer.new handed out
local function fakeBB(w, h)
    local bb = { w = w, h = h, inverts = 0, freed = 0, blits = {}, rects = {} }
    bb.getWidth   = function() return bb.w end
    bb.getHeight  = function() return bb.h end
    bb.invertRect = function() bb.inverts = bb.inverts + 1 end
    bb.free       = function() bb.freed = bb.freed + 1 end
    bb.blitFrom   = function(_s, src, dx, dy, sx, sy, ww, hh)
        bb.blits[#bb.blits + 1] = { src = src, dx = dx, dy = dy, sx = sx, sy = sy, w = ww, h = hh } end
    bb.paintRect  = function(_s, x, y, ww, hh, c)
        bb.rects[#bb.rects + 1] = { x = x, y = y, w = ww, h = hh, c = c } end
    return bb
end
package.loaded["ffi/blitbuffer"] = {
    COLOR_WHITE = WHITE, COLOR_BLACK = BLACK, TYPE_BB8 = "bb8",
    new = function(w, h, kind) local bb = fakeBB(w, h); bb.kind = kind; made[#made + 1] = bb; return bb end,
}

-- The base: init lays out and renders, as TextBoxWidget's does. The layout is
-- two lines of 10px-wide glyphs, 20px tall: characters 1-4, then 5-8.
local Base = {}
Base.__index = Base
function Base:extend(spec)
    spec = spec or {}
    spec.__index = spec
    return setmetatable(spec, { __index = self })
end
function Base:new(o)
    o = o or {}
    setmetatable(o, { __index = self })
    if o.init then o:init() end
    return o
end
local with_glyph_record = true
local function layout()
    local lines = {}
    for li = 1, 2 do
        local g = {}
        for i = 1, 4 do
            g[i] = { text_index = (li - 1) * 4 + i, x0 = (i - 1) * 10, x1 = i * 10 }
        end
        lines[li] = with_glyph_record and { xglyphs = g } or {}
    end
    return lines
end
function Base:init()
    self.line_height_px = 20
    self.vertical_string_list = layout()
    self.dimen = { w = 40, h = 40 }
    self:_renderText(1, 2)
end
function Base:_renderText(_first, _last)
    if self._bb then self._bb:free() end
    self._bb = fakeBB(40, 44)
end
function Base:paintTo() end
function Base:free() if self._bb then self._bb:free(); self._bb = nil end end
package.loaded["ui/widget/textboxwidget"] = Base

package.loaded["lib/bookshelf_color"] = {
    blendInk = function(bb, mask, x, y, w, h, ink)
        bb.calls[#bb.calls + 1] = { mask = mask, x = x, y = y, w = w, h = h, ink = ink }
    end,
}
package.loaded["lib/bookshelf_colour_runs"] = dofile("lib/bookshelf_colour_runs.lua")
package.loaded["lib/bookshelf_transparent_text"] = dofile("lib/bookshelf_transparent_text.lua")
local RT = dofile("lib/bookshelf_run_text_box.lua")

local function build(runs)
    made = {}
    return RT:new{ text = "12345678", width = 40, fgcolor = INK, runs = runs }
end

t.test("a run's pixels are lifted out of the block's bitmap", function()
    local w = build({ { s = 2, e = 3, colour = GOLD } })
    eq(#made, 1, "one lifted bitmap for a run on one line")
    local piece = made[1]
    eq(piece.w, 20); eq(piece.h, 20); eq(piece.kind, "bb8")
    eq(#piece.blits, 1)
    eq(piece.blits[1].src, w._bb, "copied from the block's own bitmap")
    eq(piece.blits[1].sx, 10); eq(piece.blits[1].sy, 0)
    eq(piece.inverts, 1, "kept as a mask, ready to blend")
    eq(#w._bb.rects, 1, "and wiped from the block's bitmap")
    eq(w._bb.rects[1].x, 10); eq(w._bb.rects[1].y, 0)
    eq(w._bb.rects[1].w, 20); eq(w._bb.rects[1].h, 20); eq(w._bb.rects[1].c, WHITE)
end)

t.test("a run broken across two lines is lifted as two pieces", function()
    local w = build({ { s = 4, e = 5, colour = GOLD } })
    eq(#made, 2)
    eq(made[1].blits[1].sx, 30); eq(made[1].blits[1].sy, 0)
    eq(made[2].blits[1].sx, 0);  eq(made[2].blits[1].sy, 20)
    eq(#w._bb.rects, 2)
end)

t.test("paint: the block in its ink, each lifted piece in the run's colour, in place", function()
    local w = build({ { s = 6, e = 7, colour = GOLD } })
    local target = { calls = {} }
    w:paintTo(target, 100, 200)
    eq(#target.calls, 2)
    eq(target.calls[1].mask, w._bb); eq(target.calls[1].ink, INK)
    eq(target.calls[1].x, 100); eq(target.calls[1].y, 200)
    eq(target.calls[2].mask, made[1]); eq(target.calls[2].ink, GOLD)
    eq(target.calls[2].x, 110); eq(target.calls[2].y, 220)
    eq(target.calls[2].w, 20); eq(target.calls[2].h, 20)
end)

t.test("no runs: nothing is lifted and the block paints as before", function()
    local w = build(nil)
    eq(#made, 0)
    eq(#w._bb.rects, 0)
    local target = { calls = {} }
    w:paintTo(target, 0, 0)
    eq(#target.calls, 1); eq(target.calls[1].ink, INK)
end)

t.test("no glyph record (advanced text shaping off): the stars stay in the ink", function()
    with_glyph_record = false
    local w = build({ { s = 2, e = 3, colour = GOLD } })
    with_glyph_record = true
    eq(#made, 0)
    eq(#w._bb.rects, 0, "nothing was wiped, so nothing is lost")
end)

t.test("a run past the bitmap's edge is clipped to it, never read outside", function()
    local w = build({ { s = 5, e = 8, colour = GOLD } })
    w._bb.h = 30            -- a block capped at a height that cuts line two
    made = {}
    w.vertical_string_list = layout()
    -- Re-lift against the shorter bitmap.
    w:_liftRuns(1, 2)
    eq(#made, 1)
    eq(made[1].h, 10, "only the part of the line inside the bitmap")
end)

t.test("rendering again frees the pieces of the render before", function()
    local w = build({ { s = 2, e = 3, colour = GOLD } })
    local old = made[1]
    w:_renderText(1, 2)
    eq(old.freed, 1)
    eq(#made, 2, "and lifts afresh from the new bitmap")
end)

t.test("free releases the lifted pieces with the block", function()
    local w = build({ { s = 2, e = 3, colour = GOLD } })
    local piece = made[1]
    w:free()
    eq(piece.freed, 1)
end)

t.done()
