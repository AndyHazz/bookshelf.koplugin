-- tests/_test_spine_same_size.lua
-- A spine shelf's Book sizes: Varied (each book's own height and thickness)
-- or Same (every book the default shape and thickness).
--
-- Usage (from plugin root): lua tests/_test_spine_same_size.lua
--
-- The choice is one helper, SpineShelf.bookShape, that the planner asks for
-- the shape it sizes a book from. Extracted and run here; the planner,
-- the widget and the editor are checked by source.

package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local ss = io.open("lib/bookshelf_spine_shelf.lua"):read("*a")
local wd = io.open("lib/bookshelf_widget.lua"):read("*a")
local ed = io.open("lib/bookshelf_chip_editor.lua"):read("*a")

local body = ss:match("\nfunction SpineShelf%.bookShape%(look, pages, same_size%)\n(.-)\nend\n")
assert(body, "SpineShelf.bookShape(look, pages, same_size) is missing")
local SpineLayout = { DEFAULT_ASPECT = 1.5 }
local bookShape = assert(load("return function(look, pages, same_size)\n" .. body .. "\nend",
    "bookShape", "t", { SpineLayout = SpineLayout, pairs = pairs }))()

t.test("Varied keeps the book's own shape and page count", function()
    local look = { r = 1, g = 2, b = 3, aspect = 1.7 }
    local a, l, p = bookShape(look, 640, nil)
    eq(a, 1.7); eq(p, 640)
    assert(l == look, "a Varied book's look should be the cached one")
end)

t.test("Same gives every book the default shape and thickness", function()
    local look = { r = 1, g = 2, b = 3, aspect = 1.7, sampled = true }
    local a, l, p = bookShape(look, 640, true)
    eq(a, 1.5)
    eq(p, nil, "the width should come from the default page count")
    eq(l.aspect, 1.5, "the painter's top edge reads the look's aspect")
    eq(l.r, 1); eq(l.sampled, true)
    eq(look.aspect, 1.7, "the cached look is shared with other views and must not change")
end)

t.test("a book with no known shape is the default either way", function()
    local a = bookShape({ aspect = nil }, nil, true)
    eq(a, 1.5)
end)

t.test("the planner sizes height, width and face-outs from bookShape", function()
    assert(ss:find("SpineShelf%.bookShape%(look,%s*SpineShelf%.thicknessPages%(thick%), opts%.same_size%)"),
        "plan() should ask bookShape for the shape")
    -- No sizing call may read the raw count or aspect after that.
    local plan = ss:match("\nfunction SpineShelf%.plan%(items, opts%)\n(.-)\nend\n")
    assert(plan, "plan moved")
    assert(not plan:find("spineWidthDp%(%s*SpineShelf%.thicknessPages"),
        "a spine width still reads the book's own page count")
end)

t.test("the shelf passes its Book sizes to both plan passes", function()
    local base = wd:match("\nfunction BookshelfWidget:_spinePlanBase%(.-%)\n(.-)\nend\n")
    assert(base and base:find("same_size%s*=%s*self:_spineSameSize%(%)"),
        "_spinePlanBase should carry same_size")
    assert(wd:find("\nfunction BookshelfWidget:_spineSameSize%(%)"), "_spineSameSize is missing")
end)

t.test("the editor offers Book sizes beside Thickness", function()
    assert(ed:find('label = _%("Book sizes"%)'), "no Book sizes control")
    assert(ed:find("draft%.spine_same_size"), "the control does not store spine_same_size")
end)

t.done()
