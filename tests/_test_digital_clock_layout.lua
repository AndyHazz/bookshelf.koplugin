-- tests/_test_digital_clock_layout.lua
-- The digital clock in a wide cell (3x1, 6x1) puts the date beside the time,
-- weekday over day and month, instead of a small line under it; square and
-- tall cells, and callers with no height (start menu, picker), keep the
-- stacked layout.
package.path = "./?.lua;./?/init.lua;" .. package.path
local t   = dofile("tests/_helpers.lua").runner()
local src = io.open("micromodules/clock.lua"):read("*a")
local body = src:match("\nlocal function sideBySide%(width, avail_h%)\n(.-)\nend\n")

local function side(w, h)
    assert(body, "could not find sideBySide in clock - renamed?")
    return load("local width, avail_h = ...\n" .. body, "sideBySide", "t", {})(w, h)
end

t.test("a 3x1 cell puts the date beside the time", function()
    assert(side(560, 175) == true)
end)
t.test("a 2x2 or 2x1 cell keeps it underneath", function()
    assert(side(361, 387) == false)
    assert(side(361, 260) == false)
end)
t.test("no height keeps the stacked layout", function()
    assert(side(560, nil) == false)
end)

t.done()
