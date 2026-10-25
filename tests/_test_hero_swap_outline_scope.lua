-- tests/_test_hero_swap_outline_scope.lua
-- The layout editor's selection outline is drawn round the selected card,
-- past its edge, so on the panel's bottom row it hangs below the panel band.
-- The panel's in-place swap repaints just its band (a clipped paint), and
-- while editing that band must take the outline in, or its bottom edge is
-- left off until the next full paint (maintainer, PW5: the minute tick).
--
-- Usage (from plugin root): lua tests/_test_hero_swap_outline_scope.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local t  = dofile("tests/_helpers.lua").runner()
local eq = dofile("tests/_helpers.lua").eq

local src = io.open("lib/bookshelf_widget.lua"):read("*a")
local body = src:match("\n(function BookshelfWidget:_swapMicroHeroInPlace%(.-\nend)\n")
assert(body, "_swapMicroHeroInPlace moved")

local function swap(editing)
    local scope
    local UM = { setDirty = function(_s, _w, how)
        if type(how) == "function" then local _m; _m, scope = how() end
    end, nextTick = function() end }
    local env = setmetatable({
        BookshelfWidget = {}, UIManager = UM,
        Geom = { new = function(_s, o) return o end },
        require = function(name)
            if name == "lib/bookshelf_hero_modules" then return { outlineOutset = function() return 4 end } end
            return require(name)
        end,
    }, { __index = _G })
    assert(load(body, "swap", "t", env))()
    local bw = setmetatable({
        _hero_mode = "micro", width = 1000, _hero_parent = { {} },
        _hero_dims = { PAD = 20, hero_h = 400, content_w = 960 },
        _buildMicroHero = function() return {} end,
        _module_edit = editing and {} or nil,
    }, { __index = env.BookshelfWidget })
    assert(bw:_swapMicroHeroInPlace())
    return scope
end

t.test("while editing, the swap repaints the outline below the panel too", function()
    eq(swap(true).h, 20 + 400 + 4)
end)

t.test("out of the editor, it repaints the panel band alone", function()
    eq(swap(false).h, 20 + 400)
end)

t.test("the outline is drawn the width the scope allows for", function()
    local hm = io.open("lib/bookshelf_hero_modules.lua"):read("*a")
    assert(hm:find("local thick = HeroModules.outlineOutset()", 1, true), "the outline's width is its own number again")
end)

t.done()
