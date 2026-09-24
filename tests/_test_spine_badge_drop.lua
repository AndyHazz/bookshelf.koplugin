-- tests/_test_spine_badge_drop.lua
-- How far a spine row's section badge hangs below its plank.
--
-- The badge is painted at by = y + h - plankFace(h) - 2 with height
-- text_h + 2 * pad_y, so it overhangs the row by text_h + 2*pad_y - face - 2.
-- The layout has to keep at least that much below the last row or the badge
-- sits on the footer panel. Extracted by name; the face and the text metrics
-- are stubbed, the arithmetic is the thing under test.
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq
local src = io.open("lib/bookshelf_spine_shelf.lua"):read("*a")
local function compile(code, env, name)
    if _G.setfenv then local f = assert(_G.loadstring(code, name)); _G.setfenv(f, env); return f end
    return assert(load(code, name, "t", env))
end
local body = src:match("\nfunction SpineShelf%.badgeDrop%(row_h%)\n(.-)\nend\n")
assert(body, "SpineShelf.badgeDrop is missing")
local text_h = 27
local env = {
    math = math, type = type, pcall = pcall, tostring = tostring, tonumber = tonumber, require = function(name)
        if name == "lib/bookshelf_settings_store" then return { read = function() return 100 end } end
        error("unexpected require " .. name)
    end,
    Screen = { scaleBySize = function(_s, px) return px * 2 end },
    Space  = { px = function(px) return px * 2 end },
    BFont  = { getFace = function() return {} end, getUIFontFace = function() return "cfont" end },
    TextWidget = { new = function(_s, o) return { getSize = function() return { w = 10, h = text_h } end, free = function() end } end },
    SpineShelf = { plankFace = function(h) return 12 end },
}
local badgeDrop = compile("return function(row_h)\n" .. body .. "\nend", env, "badgeDrop")()

t.test("the drop is the badge's height past the plank face, less the 2px it starts above the face bottom", function()
    -- text 27 + 2 * pad_y (2dp = 4px) = 35; face 12; minus 2 -> 21
    eq(badgeDrop(200), 21)
end)

t.test("a badge that ends inside the face hangs nothing", function()
    -- A smaller label scale, so the memo (keyed on the face size) probes anew.
    env.require = function(name)
        if name == "lib/bookshelf_settings_store" then return { read = function() return 60 end } end
    end
    text_h = 5   -- 5 + 4 = 9 < face 12 + 2
    eq(badgeDrop(200), 0)
    text_h = 27
end)

t.test("the section label font scale grows the drop", function()
    env.require = function(name)
        if name == "lib/bookshelf_settings_store" then return { read = function() return 150 end } end
    end
    text_h = 40
    eq(badgeDrop(200), 40 + 8 - 12 - 2)   -- pad_y is 2dp = 4px here, on both sides
end)

t.done()
