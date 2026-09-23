-- tests/_test_module_border_color.lua
-- The micro-module card's hairline can be recoloured (issue 424).
--
-- Usage (from plugin root): lua tests/_test_module_border_color.lua
--
-- The hairline arrived with the v5.1.0 wallpaper work, so a card reads over a
-- picture; on a plain page some readers found it darker than before. It is a
-- row in the accent colours now, beside the card's background. Unset, nothing
-- changes: the card keeps the theme's own ink.

package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local src = io.open("lib/bookshelf_hero_modules.lua"):read("*a")
local body = src:match("\nlocal function _cardBorderInk%(%)\n(.-)\nend\n")
assert(body, "_cardBorderInk moved")

local function ink(resolved, primary)
    local env = {
        pcall = pcall, type = type,
        require = function(name)
            assert(name == "lib/bookshelf_cover_progress")
            return { resolvedColors = function() return resolved end }
        end,
        Modules = { COLOR_PRIMARY = primary },
        Blitbuffer = { COLOR_BLACK = "black" },
    }
    return assert(load("return function()\n" .. body .. "\nend", "ink", "t", env))()()
end

t.test("unset, the card keeps the theme's ink", function()
    eq(ink({}, "primary"), "primary")
end)

t.test("the reader's pick wins", function()
    eq(ink({ module_border = "grey" }, "primary"), "grey")
end)

t.test("with no theme ink either, black", function()
    eq(ink({}, nil), "black")
end)

t.test("the palette reads the key with no default, for day and night", function()
    local cp = io.open("lib/bookshelf_cover_progress.lua"):read("*a")
    assert(cp:find('_readModeColor("module_border", nil)', 1, true))
    assert(cp:find("module_border     = module_border_raw and _paint(module_border_raw) or nil", 1, true))
end)

t.test("Reset to default colors clears it", function()
    local st = io.open("lib/bookshelf_settings.lua"):read("*a")
    assert(st:find('"module_border"', 1, true), "the reset list misses the new key")
    assert(st:find('pickColor("module_border", "module_border"', 1, true))
end)

t.done()
