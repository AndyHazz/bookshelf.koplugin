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
    -- This paint's overhangs, copied before the outline and put back after:
    -- not every heading remembered, or a hidden one came back.
    local saved = over:find("HeroModules._copyOverhangs(bb,", 1, true)
    local ring = over:find("bb:paintBorder(", 1, true)
    local back = over:find("bb:blitFrom(k.copy, k.x, k.y, 0, 0, k.w, k.h)", 1, true)
    assert(saved and ring and back and saved < ring and ring < back,
        "the heading is not kept in front of the outline")
end)

t.test("a heading hanging past the grid is kept clear of the fade", function()
    local ed = assert(io.open("lib/bookshelf_module_grid_editor.lua")):read("*a")
    local fa = ed:match("\nfunction Editor:_fadeAround%(bb%)\n(.-)\nend\n")
    -- What the grid's modules drew past it in its latest paint, off the
    -- screen and back over the fade; never in the stored fade, where a
    -- heading hidden since stayed painted (maintainer, PW5).
    assert(fa and fa:find("overs = Editor._overhangCopies(bb, x0, y0, w, h)", 1, true), "the label's lower half fades")
    assert(fa:find("Editor._putBack(bb, overs)", 1, true))
    local ss = assert(io.open("lib/bookshelf_spine_shelf.lua")):read("*a")
    assert(ss:find("SpineShelf._screen_badges[s] = self", 1, true), "badges are not recorded where drawn")
    -- Behaviour: only badges drawn since, touching the asked rect.
    local body = ss:match("\n(function SpineShelf%.badgeRectsSince%(seq, x, y, w, h%).-\nend)\n")
    local S = { _screen_badges = {} }
    assert(load(body, "r", "t", { SpineShelf = S, pairs = pairs }))()
    local a = { _rect = { x = 10, y = 95, w = 40, h = 20 }, _seq = 5 }
    local b = { _rect = { x = 300, y = 500, w = 40, h = 20 }, _seq = 6 }
    local old = { _rect = { x = 20, y = 95, w = 40, h = 20 }, _seq = 2 }
    S._screen_badges[a], S._screen_badges[b], S._screen_badges[old] = true, true, true
    local got = S.badgeRectsSince(3, 0, 0, 200, 100)
    assert(#got == 1 and got[1] == a._rect, "an earlier paint's badge kept: " .. #got)
    local hm = assert(io.open("lib/bookshelf_hero_modules.lua")):read("*a")
    local under = hm:match("\n    function container%.under%(bb, x0, y0%)\n(.-)\n    end\n")
    assert(under:find("HeroModules._frame_overhangs = {}", 1, true), "the list outlives the grid's paint")
end)

t.test("the outline shows on a dark theme: white where black would not", function()
    -- Black disappeared on a dark panel or wallpaper; borderless modules
    -- (the Shelf module) then showed no selection at all (maintainer, PW5).
    -- Night mode flips black to white itself, so only an unflipped dark
    -- theme paints it white: Editor._fadeDark's test.
    local over = src:match("\n    function container%.over%(bb, x0, y0%)\n(.-)\n    end\nend\n")
    assert(over:find("thick, HeroModules._outlineColor(), Space.px(4) + thick)", 1, true), "always black")
    local f = src:match("\nfunction HeroModules%._outlineColor%(%)\n(.-)\nend\n")
    assert(f and f:find("want_dark ~= inverting", 1, true), "not the theme's test")
end)

t.done()
