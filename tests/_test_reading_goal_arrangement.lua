-- tests/_test_reading_goal_arrangement.lua
-- Reading goal with more than one goal on: how many it shows at once, and
-- whether side by side. A wide cell shows two goals side by side; a tall
-- enough one stacks two; otherwise one at a time (tap cycles).
package.path = "./?.lua;./?/init.lua;" .. package.path
local t   = dofile("tests/_helpers.lua").runner()
local src = io.open("micromodules/reading_goal.lua"):read("*a")
local body = src:match("\nlocal function arrangement%(shape, n_active, block_h, avail_h%)\n(.-)\nend\n")

local function arr(...)
    assert(body, "could not find arrangement in reading_goal - renamed?")
    return load("local shape, n_active, block_h, avail_h = ...\n" .. body, "arr", "t", {})(...)
end

t.test("a wide cell shows two goals side by side", function()
    local per, side = arr("wide", 2, 200, 387)
    assert(per == 2 and side == true, tostring(per) .. " " .. tostring(side))
end)
t.test("a tall enough square cell stacks two", function()
    local per, side = arr("square", 2, 150, 387)
    assert(per == 2 and side == false)
end)
t.test("a short square cell shows one", function()
    local per = arr("square", 2, 300, 387)
    assert(per == 1)
end)
t.test("one goal on: one, whatever the shape", function()
    local per, side = arr("wide", 1, 100, 387)
    assert(per == 1 and not side)
end)
t.test("no height (start menu): one", function()
    assert(arr("wide", 2, 100, nil) == 1)
end)

t.done()
