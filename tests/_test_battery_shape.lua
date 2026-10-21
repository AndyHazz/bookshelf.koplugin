-- tests/_test_battery_shape.lua
-- The battery card follows its cell: a battery standing upright in a square
-- or tall cell (1x1, 1x2, 2x2), lying on its side beside the figures in a
-- strip (3x1, 6x1), and the heading/figure/bar card in between (2x1) or with
-- no height to go by (start menu, picker).
package.path = "./?.lua;./?/init.lua;" .. package.path
local t   = dofile("tests/_helpers.lua").runner()
local src = io.open("micromodules/battery.lua"):read("*a")
local body = src:match("\nlocal function shapeOf%(width, avail_h%)\n(.-)\nend\n")

local function shape(w, h)
    assert(body, "could not find shapeOf in battery - renamed?")
    return load("local width, avail_h = ...\n" .. body, "shapeOf", "t", {})(w, h)
end

t.test("1x1, 1x2 and 2x2 stand the battery up", function()
    assert(shape(162, 175) == "upright", shape(162, 175))
    assert(shape(162, 387) == "upright")
    assert(shape(361, 387) == "upright")
end)
t.test("any cell wider than tall lays it on its side (2x1, 3x1, 3x2, 6x1)", function()
    assert(shape(361, 175) == "sideways")
    assert(shape(560, 175) == "sideways")
    assert(shape(560, 387) == "sideways", "3x2 truncated the card's \"remaining\"")
    assert(shape(1158, 175) == "sideways")
end)
t.test("no height (start menu, picker) keeps the card", function()
    assert(shape(361, nil) == "card")
end)

t.done()
