-- tests/_test_palette_null_tile.lua
-- The palette's word tile ("No background", "Transparent") is as wide as its
-- label, with room to spare: at the label's width plus the default padding
-- the outline of a picked tile met the first and last letters (PW5).
-- Usage (from plugin root): lua tests/_test_palette_null_tile.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq

local src = io.open("lib/bookshelf_color_palette.lua"):read("*a")
local body = assert(src:match("local function nullTileWidth%(label, side, image_path, fit%)\n(.-)\nend\n"),
    "nullTileWidth moved")
local env = {
    math = math,
    BFont = { getFace = function() return "face", false end },
    TextWidget = { new = function(_self, o) return { getSize = function() return { w = 100 } end, free = function() end } end },
    Space = { padding = { default = 5, small = 2, large = 10 } },
}
local code = "return function(label, side, image_path, fit)\n" .. body .. "\nend"
local fn
if setfenv then fn = assert(loadstring(code)); setfenv(fn, env) else fn = assert(load(code, "nullTileWidth", "t", env)) end
local nullTileWidth = fn()

t.test("a word tile leaves a large padding each side of its label", function()
    eq(nullTileWidth("No background", 60, nil, true), 100 + 2 * 10)
end)

t.test("a short word or a picture tile stays square", function()
    eq(nullTileWidth("No", 160, nil, true), 160)
    eq(nullTileWidth("No background", 60, "/wood.png", true), 60)
end)

t.done()
