-- tests/_test_active_chip_colors.lua
-- The currently-reading button looks the same drilled in as it does at the top.
--
-- WHAT NEEDS PINNING. A selected chip normally renders by INVERTING its own
-- rect. On a manually dark shelf there is nothing to invert -- the fill is
-- cleared under a wallpaper -- so the chips layout asks for an explicit pair
-- instead: the bar's own colour as ink on the theme's ink as fill.
--
-- The breadcrumb layout asked only for the READER's custom chip colours, and
-- had no theme fallback beneath it. With none set, on a dark shelf, the
-- currently-reading button and its roof pointer fell back to inverting: a
-- black cell with a white glyph, where the same button one level up is a white
-- cell with a dark glyph. Reported from a drilled-in shelf (Genres > Time
-- Travel) on a PW5.
--
-- One helper answers for both layouts now, so they cannot drift again.
--
-- Usage (from plugin root): lua tests/_test_active_chip_colors.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local src = io.open("lib/bookshelf_chip_bar.lua"):read("*a")
local body = src:match("\nlocal function _activeChipColors%(%)\n(.-)\nend\n")
assert(body, "_activeChipColors moved or was renamed")

-- custom: what the reader chose (nil for "nothing chosen").
-- flips:  is the shelf themed dark?
local function run(custom_fill, custom_ink, flips)
    local env = {
        type = type, pcall = pcall, require = function(name)
            if name == "lib/bookshelf_cover_progress" then
                return { resolvedColors = function()
                    return { chrome_bg = "THEME_BG" }
                end }
            end
            error("unexpected require " .. tostring(name))
        end,
        _selectedChipColors = function() return custom_fill, custom_ink end,
        _chipThemeFlips     = function() return flips end,
        _chipInk            = function() return "THEME_INK" end,
    }
    local fn = assert(load("return function()\n" .. body .. "\nend",
        "_activeChipColors", "t", env))()
    return fn()
end

t.test("the reader's own colours win", function()
    local fill, ink = run("USER_FILL", "USER_INK", true)
    eq(fill, "USER_FILL"); eq(ink, "USER_INK")
end)

t.test("dark shelf, nothing chosen: the theme's pair, so it paints for real", function()
    local fill, ink = run(nil, nil, true)
    eq(fill, "THEME_INK", "the fill is the theme's ink -- the inversion done for real")
    eq(ink, "THEME_BG", "and the glyph takes the bar's own colour")
end)

t.test("light shelf, nothing chosen: no pair, the chip inverts itself", function()
    local fill, ink = run(nil, nil, false)
    eq(fill, nil, "a light shelf has an opaque ground to invert, so leave it alone")
    eq(ink, nil)
end)

t.test("both layouts ask the one helper", function()
    -- The bug was two answers to one question: chips mode had the theme
    -- fallback, breadcrumb mode did not.
    -- call sites only: not the doc comment, not the definition
    local calls = 0
    for line in src:gmatch("[^\n]+") do
        if line:find("_activeChipColors()", 1, true)
                and not line:match("^%s*%-%-")
                and not line:match("^local function") then
            calls = calls + 1
        end
    end
    eq(calls, 2, "one call per layout, found " .. calls)
    -- the breadcrumb block runs from its comment to the _actionButton call
    -- that ends it (the pointer itself now lives inside that builder)
    local crumb = src:match("(Pull the currently%-reading chip from the chips list.-_actionButton{)")
    assert(crumb, "the breadcrumb currently-reading block moved")
    assert(crumb:find("_activeChipColors", 1, true),
        "the breadcrumb button must take the same pair as the chips-mode one")
    assert(not crumb:find("_selectedChipColors", 1, true),
        "it must not ask for the reader's custom pair alone -- that was the bug")
end)

t.done()
