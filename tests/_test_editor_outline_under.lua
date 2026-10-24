-- tests/_test_editor_outline_under.lua
-- The layout editor's selection outline is painted under the modules: it lies
-- just outside the selected card, and what hangs out of a card (the Shelf
-- module's heading, hooked over its plank) stays in front of it. Painted
-- over them, the outline ran through that heading (maintainer, PW5).
--
-- Usage (from plugin root): lua tests/_test_editor_outline_under.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()
local src = assert(io.open("lib/bookshelf_hero_modules.lua")):read("*a")

t.test("the outline is in the layer under the cells, the dimming over them", function()
    local under = src:match("\n    function container%.under%(bb, x0, y0%)\n(.-)\n    end\n    function container%.over")
    local over = src:match("\n    function container%.over%(bb, x0, y0%)\n(.-)\n    end\n")
    assert(under and over, "layers moved")
    assert(under:find("bb:paintBorder(", 1, true), "the outline is not under the cells")
    assert(not over:find("paintBorder", 1, true), "the outline is still over the cells")
    assert(over:find("HeroModules._fade(", 1, true), "the other modules are no longer dimmed")
end)

t.test("a heading hanging past the grid is kept clear of the fade", function()
    local ed = assert(io.open("lib/bookshelf_module_grid_editor.lua")):read("*a")
    local fa = ed:match("\nfunction Editor:_fadeAround%(bb%)\n(.-)\nend\n")
    assert(fa and fa:find("SpineShelf.screenBadgeRects(x0, y0, w, h)", 1, true), "the label's lower half fades")
    local ss = assert(io.open("lib/bookshelf_spine_shelf.lua")):read("*a")
    assert(ss:find("SpineShelf._screen_badges[s] = true", 1, true), "badges are not recorded where drawn")
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
