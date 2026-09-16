-- tests/_test_corner_keep.lua
-- A cover's rounded corners show what was BEHIND the cover, whatever that is.
--
-- WHAT NEEDS PINNING. RoundedCornerCard paints the cover square and then cuts
-- the corners by painting over them, and what it painted was a guess at the
-- background: the wallpaper's pixels, else the page ground colour, else
-- white. Inside the dark top panel the guess was the white page (the panel
-- is a scrim over it), and under a stack's front cover it was the page where
-- the pile's layer really is. Both showed as bright corners (maintainer, dark
-- theme with a white background). CornerKeep snapshots the four corner
-- squares before the cover is painted and puts the cut pixels back from
-- them, so the corner is exactly what was there: panel, pile, page or
-- picture, on screen or in the page-wipe's offscreen buffer alike.
--
-- Usage (from plugin root): lua tests/_test_corner_keep.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq
local src = io.open("lib/bookshelf_spine_widget.lua"):read("*a")

local function compile(code, env, name)
    if _G.setfenv then
        local f = assert(_G.loadstring(code, name)); _G.setfenv(f, env); return f
    end
    return assert(load(code, name, "t", env))
end
local block = src:match("\n(local CornerKeep = {}\n.-\nfunction CornerKeep:free%(%)\n.-\nend)\n")
assert(block, "CornerKeep is missing from bookshelf_spine_widget.lua")

-- A fake blitbuffer that records blits and knows its size and type.
local news = {}
local function fakeBB(w, h, typ)
    local b = { w = w, h = h, typ = typ or 8, blits = {}, freed = false }
    b.getWidth  = function() return b.w end
    b.getHeight = function() return b.h end
    b.getType   = function() return b.typ end
    b.blitFrom  = function(_s, src_bb, dx, dy, sx, sy, bw, bh)
        b.blits[#b.blits + 1] = { src = src_bb, dx = dx, dy = dy, sx = sx, sy = sy, w = bw, h = bh }
    end
    b.free = function() b.freed = true end
    return b
end
local env = { type = type, pcall = pcall, ipairs = ipairs, math = math, setmetatable = setmetatable,
              Blitbuffer = { new = function(w, h, typ) local b = fakeBB(w, h, typ); news[#news + 1] = b; return b end } }
local CornerKeep = compile(block .. "\nreturn CornerKeep", env, "CornerKeep")()

t.test("take() snapshots the four corner squares of the card, in the target's own type", function()
    news = {}
    local bb = fakeBB(1236, 1648, 4)
    local keep = CornerKeep.take(bb, 100, 200, 300, 450, 12)   -- x, y, w, h, radius
    assert(keep, "no keep")
    eq(#news, 4, "four squares")
    for _i, sq in ipairs(news) do eq(sq.w, 12); eq(sq.h, 12); eq(sq.typ, 4, "the target's type") end
    -- Each square copied its patch of the target: (dest 0,0) <- (src ox,oy) 12x12.
    local origins = {}
    for _i, sq in ipairs(news) do
        eq(#sq.blits, 1); local bl = sq.blits[1]
        eq(bl.src, bb); eq(bl.dx, 0); eq(bl.dy, 0); eq(bl.w, 12); eq(bl.h, 12)
        origins[bl.sx .. "," .. bl.sy] = true
    end
    for _i, o in ipairs{ "100,200", "388,200", "100,638", "388,638" } do
        assert(origins[o], "missing corner square at " .. o)
    end
end)

t.test("putRow() paints a cut row back from the square that holds it, with the right source offset", function()
    news = {}
    local bb = fakeBB(1236, 1648, 8)
    local keep = CornerKeep.take(bb, 100, 200, 300, 450, 12)
    -- TL corner, row 3 of the corner, 5 pixels cut from the card's left edge.
    eq(keep:putRow(bb, 100, 203, 5), true)
    local bl = bb.blits[#bb.blits]
    eq(bl.dx, 100); eq(bl.dy, 203); eq(bl.sx, 0); eq(bl.sy, 3); eq(bl.w, 5); eq(bl.h, 1)
    assert(bl.src.blits[1].sx == 100 and bl.src.blits[1].sy == 200, "put back from the TL square")
    -- TR corner: 4 pixels ending at the card's right edge, row 0.
    eq(keep:putRow(bb, 396, 200, 4), true)
    bl = bb.blits[#bb.blits]
    eq(bl.dx, 396); eq(bl.sx, 8, "396 - 388: offset inside the TR square"); eq(bl.sy, 0)
    -- BR corner: row 11 of the bottom band, 2 pixels.
    eq(keep:putRow(bb, 398, 649, 2), true)
    bl = bb.blits[#bb.blits]
    eq(bl.sx, 10); eq(bl.sy, 11)
    assert(bl.src.blits[1].sx == 388 and bl.src.blits[1].sy == 638, "put back from the BR square")
end)

t.test("a row that no square holds is refused, so the caller can fall back", function()
    news = {}
    local bb = fakeBB(1236, 1648, 8)
    local keep = CornerKeep.take(bb, 100, 200, 300, 450, 12)
    eq(keep:putRow(bb, 150, 300, 5), false, "the middle of the card is nobody's corner")
    eq(keep:putRow(bb, 100, 215, 3), false, "just below the TL square")
end)

t.test("free() releases the four squares; take() refuses a target it cannot snapshot", function()
    news = {}
    local bb = fakeBB(1236, 1648, 8)
    local keep = CornerKeep.take(bb, 100, 200, 300, 450, 12)
    keep:free()
    for _i, sq in ipairs(news) do assert(sq.freed, "a square was not freed") end
    eq(CornerKeep.take({}, 0, 0, 10, 10, 3), nil, "no blitFrom: nothing to keep")
    eq(CornerKeep.take(bb, 0, 0, 10, 10, 0), nil, "no radius: nothing to keep")
end)

t.test("RoundedCornerCard keeps its corners before painting the cover and puts them back instead of guessing", function()
    local body = src:match("\nfunction RoundedCornerCard:paintTo%(bb, x, y%)\n(.-)\nend\n")
    assert(body, "no RoundedCornerCard:paintTo")
    local take_at  = body:find("CornerKeep.take(bb, x, y, self.width, self.height, self.radius)", 1, true)
    local inner_at = body:find("self.inner:paintTo(bb", 1, true)
    assert(take_at and inner_at and take_at < inner_at, "the corners must be kept BEFORE the cover paints over them")
    assert(body:find("keep:putRow(bb, cx, cy, cw)", 1, true), "fill() does not put the kept pixels back")
    assert(body:find("keep:free()", 1, true), "the squares are not freed after the cut")
    -- An explicit bg_color (the selection ring behind a selected cover) still
    -- wins: that corner is meant to show the ring, not what was behind.
    assert(body:find('type(self.bg_color) == "nil"', 1, true), "bg_color no longer gates the keep")
end)

t.done()
