-- tests/_test_editor_outline_under.lua
-- What hangs out of a selected card (the Shelf module's heading, hooked over
-- its plank) stays in front of the layout editor's selection outline: the
-- outline ran through it (maintainer, PW5). Painted under the cards instead,
-- a bare module's ground covered the outline on a dark theme.
--
-- Usage (from plugin root): lua tests/_test_editor_outline_under.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()
local src = assert(io.open("lib/bookshelf_hero_modules.lua")):read("*a")

t.test("the outline goes over the cards, and the heading over the outline", function()
    -- Under the cards, a bare module's own ground covered it on a dark theme.
    local over = src:match("\n    function container%.over%(bb, x0, y0%)\n(.-)\n    end\nend\n")
    assert(over, "over moved")
    local ring = over:find("bb:paintBorder(", 1, true)
    local again = over:find("repaintScreenBadges(bb,", 1, true)
    assert(ring and again and ring < again, "the heading is not painted again after the outline")
    local ss = assert(io.open("lib/bookshelf_spine_shelf.lua")):read("*a")
    assert(ss:find("widget:paintDeferred(bb)", 1, true), "repaint does not redraw where it was")
end)

t.test("a heading hanging past the grid is kept clear of the fade", function()
    local ed = assert(io.open("lib/bookshelf_module_grid_editor.lua")):read("*a")
    local fa = ed:match("\nfunction Editor:_fadeAround%(bb%)\n(.-)\nend\n")
    assert(fa and fa:find("SpineShelf.screenBadgeRects(x0, y0, w, h)", 1, true), "the label's lower half fades")
    local ss = assert(io.open("lib/bookshelf_spine_shelf.lua")):read("*a")
    assert(ss:find("SpineShelf._screen_badges[s] = self", 1, true), "badges are not recorded where drawn")
    -- Behaviour: only rects touching the asked one.
    local body = ss:match("\n(function SpineShelf%.screenBadgeRects%(x, y, w, h%).-\nend)\n")
    local S = { _screen_badges = {} }
    assert(load(body, "r", "t", { SpineShelf = S, pairs = pairs }))()
    local a, b = { _rect = { x = 10, y = 95, w = 40, h = 20 } }, { _rect = { x = 300, y = 500, w = 40, h = 20 } }
    S._screen_badges[a], S._screen_badges[b] = true, true
    local got = S.screenBadgeRects(0, 0, 200, 100)
    assert(#got == 1 and got[1] == a._rect, #got)
end)

t.done()
