-- tests/_test_fade_sites.lua
-- Where a faded book (on hold, or finished with "Fade finished books") is
-- made see-through. Three paint sites share lib/bookshelf_see_through.lua:
-- the cover card, the page block above a face-out cover on a spine shelf,
-- and a spine. Each must copy what is behind BEFORE it paints and mix it
-- back AFTER, or the book mixes with itself and nothing fades.
--
-- Source-order checks: these painters live inside two very large files and
-- draw through KOReader's widgets. The mixing itself is tested in
-- tests/_test_see_through.lua; the look is checked on the rig.

local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq

local function read(p) local f = assert(io.open(p)); local s = f:read("*a"); f:close(); return s end
local card_src  = read("lib/bookshelf_spine_widget.lua")
local shelf_src = read("lib/bookshelf_spine_shelf.lua")

local function body(src, name)
    return assert(src:match("\nfunction " .. name:gsub("[%.:]", "%%%0") .. "%(bb, x, y%)\n(.-)\nend\n"),
        name .. " not found")
end
local function at(s, needle, from)
    return assert(s:find(needle, from or 1, true), "missing: " .. needle)
end

t.test("the cover card copies behind before the cover and mixes after the border", function()
    local b = body(card_src, "RoundedCornerCard:paintTo")
    local take  = at(b, "SeeThrough.take(")
    local inner = at(b, "self.inner:paintTo(")
    local frame = at(b, "_paintColorSafeBorder(")
    local put   = at(b, "SeeThrough.put(")
    assert(take < inner, "copy before the cover paints")
    assert(put > frame, "mix after the corners and the border, so they fade too")
end)

t.test("the white wash is only the fallback for a target that cannot be read", function()
    local b = body(card_src, "RoundedCornerCard:paintTo")
    local wash = at(b, "lightenRect(")
    local put  = at(b, "SeeThrough.put(")
    -- One wash, and it sits behind "not see".
    eq(select(2, b:gsub("lightenRect%(", "")), 1)
    assert(b:sub(1, wash):find("if self.fade_by and self.fade_by > 0 and not see then", 1, true),
        "the wash runs only without a copy")
    assert(wash < put)
end)

t.test("one place says whether a cover is faded", function()
    assert(card_src:find("\nfunction SpineWidget:isFaded%(%)\n"), "SpineWidget:isFaded")
    local wrap = assert(card_src:match("\nfunction SpineWidget:_wrapCoverInCard%(.-%)\n(.-)\nend\n"))
    at(wrap, "self:isFaded()")
end)

t.test("the page block above a face-out fades with its cover", function()
    local b = body(shelf_src, "FaceOutTopBlock:paintTo")
    local take = at(b, "SeeThrough.take(")
    local pages = at(b, "bb:paintRectRGB32(")
    local put  = at(b, "SeeThrough.put(")
    assert(take < pages and put > pages)
    at(b, "self.cover:isFaded()")
    -- The block is told which cover it sits on.
    local build = assert(shelf_src:match("local block = depth > 0 and FaceOutTopBlock:new(%b{})"))
    at(build, "cover = cover")
end)

t.test("a faded book is faded spine out too", function()
    local b = body(shelf_src, "SpineBookSlot:paintTo")
    local take = at(b, "SeeThrough.take(")
    local blit = at(b, "bb:blitFrom(cached,")
    local put  = at(b, "SeeThrough.put(", blit)
    local fin  = at(b, "SpineShelf.finishSlot(bb, x, y, _render_after[key]")
    assert(take < blit, "copy before the spine")
    assert(put < fin, "mix before the slot's finishing strokes")
    at(b, "SpineShelf.spineFaded(self.book")
end)

t.test("all three use one strength", function()
    at(card_src, "CoverProgress.FADE_STRENGTH")
    eq(select(2, shelf_src:gsub("CoverProgress%.FADE_STRENGTH", "")) >= 2, true)
end)

t.done()
