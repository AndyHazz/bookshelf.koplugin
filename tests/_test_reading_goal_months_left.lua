-- tests/_test_reading_goal_months_left.lua
-- The yearly goal's "N months left" line: in November it read "1 months
-- left", and in December "0 months left".
package.path = "./?.lua;./?/init.lua;" .. package.path
local t   = dofile("tests/_helpers.lua").runner()
local eq  = dofile("tests/_helpers.lua").eq
local src = io.open("micromodules/reading_goal.lua"):read("*a")
local body = src:match("\nlocal function monthsLeftText%(month%)\n(.-)\nend\n")

local function text(month)
    assert(body, "could not find monthsLeftText in reading_goal - renamed?")
    local env = { _ = function(s) return s end,
                  T = function(s, a) return (s:gsub("%%1", tostring(a))) end }
    return load("local month = ...\n" .. body, "left", "t", env)(month)
end

t.test("several months to go", function()
    eq(text(1), "11 months left"); eq(text(10), "2 months left")
end)
t.test("November: one month, not '1 months'", function()
    eq(text(11), "1 month left")
end)
t.test("December: the last month, not '0 months left'", function()
    eq(text(12), "Last month")
end)
t.test("the yearly goal uses it", function()
    assert(src:find("or monthsLeftText(t.month)", 1, true), "the yearly goal words its own line")
end)

t.done()
