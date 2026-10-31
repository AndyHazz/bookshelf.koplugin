-- tests/_test_spine_module_width.lua
-- A shelf module on a spine shelf is w face-out widths wide (two thirds of
-- the row's height each). With nothing to stop it, a wide module on tall rows
-- came out wider than the row: 4 x 288px = 1152px on a 1146px row (the
-- rig's Home in spines, Silverfish's card put on it from its welcome screen).
-- It fitted no row, so it stood alone on the next and the page ended at it:
-- no spines at all, "1-1 of 250". A cover shelf caps a module at its row's
-- slots (ShelfModules.width); a spine shelf now caps it at the row's width.
-- Run from the plugin root: lua tests/_test_spine_module_width.lua
package.path = "./?.lua;" .. package.path
local t  = dofile("tests/_helpers.lua").runner()
local eq = dofile("tests/_helpers.lua").eq
local src = io.open("lib/bookshelf_spine_shelf.lua"):read("*a")

local body = src:match("\nfunction SpineShelf%.moduleWidth%(n, unit, gap, content_w%)\n(.-)\nend\n")
assert(body, "could not find SpineShelf.moduleWidth - renamed?")
local f = assert((loadstring or load)("local n, unit, gap, content_w = ...\n" .. body))
local function width(...) return f(...) end

t.test("w face-out widths and the gaps between", function()
    eq(width(2, 288, 0, 1146), 576)
    eq(width(3, 100, 10, 1146), 320)
    eq(width(1, 288, 0, 1146), 288)
end)

t.test("never wider than the row", function()
    eq(width(4, 288, 0, 1146), 1146)
    eq(width(9, 288, 12, 1146), 1146)
end)

t.test("no row width known: as wide as asked", function()
    eq(width(4, 288, 0, nil), 1152)
    eq(width(4, 288, 0, 0), 1152)
end)

t.test("the plan sizes its modules with it", function()
    assert(src:find("local w = SpineShelf.moduleWidth(n, unit, opts.gap, opts.content_w)", 1, true),
        "the spine plan sizes modules without the row's width")
end)

t.done()
