-- tests/_test_edit_fade.lua
-- The layout editor fades the modules that aren't selected toward their own
-- card: lighter on a light card, DARKER on a dark one. Lightening dark cards
-- (the dark theme) turned them flat mid-grey with pale text (PW5).
package.path = "./?.lua;./?/init.lua;" .. package.path
local t   = dofile("tests/_helpers.lua").runner()
local src = io.open("lib/bookshelf_hero_modules.lua"):read("*a")
local body = src:match("\nfunction HeroModules%._fade%(bb, x, y, w, h, card_bg%)\n(.-)\nend\n")

local function fade(card_bg)
    assert(body, "could not find HeroModules._fade - renamed?")
    local calls = {}
    local bb = {
        lightenRect = function(_s, ...) calls[#calls + 1] = "lighten" end,
        darkenRect  = function(_s, ...) calls[#calls + 1] = "darken" end,
    }
    load("local bb, x, y, w, h, card_bg = ...\n" .. body, "_fade", "t",
        { pcall = pcall, type = type })(bb, 0, 0, 10, 10, card_bg)
    return calls[1]
end

local function grey(v) return { getColor8 = function() return { a = v } end } end

t.test("a light card fades lighter", function()
    assert(fade(grey(0xEE)) == "lighten")
end)
t.test("a dark card fades darker", function()
    assert(fade(grey(0x22)) == "darken")
end)
t.test("no card colour: lighter, as before", function()
    assert(fade(nil) == "lighten")
end)

t.done()
