-- tests/_test_last_books_fit.lua
-- Recently read's "Fit" count: as many covers as the cell holds at full
-- height (2:3 covers, a gap between, room for the status marks above and
-- below), so a 1x1 shows one readable cover and a 6x1 a full row rather than
-- three of whatever size the width allowed.
package.path = "./?.lua;./?/init.lua;" .. package.path
local t   = dofile("tests/_helpers.lua").runner()
local src = io.open("micromodules/last_books.lua"):read("*a")
local body = src:match("\nlocal function fitCount%(width, height, gap, overhang%)\n(.-)\nend\n")

local function fit(w, h, gap, m)
    assert(body, "could not find fitCount in last_books - renamed?")
    local f = load("local width, height, gap, overhang = ...\n" .. body, "fitCount", "t",
        { math = math })
    return f(w, h, gap, m)
end

t.test("a 1x1 cell holds one cover", function()
    assert(fit(160, 175, 10, 8) == 1, tostring(fit(160, 175, 10, 8)))
end)

t.test("a 6x1 strip holds a row of them", function()
    -- covers 159 tall -> 106 wide; (1160 + 10) / 116 = 10
    assert(fit(1160, 175, 10, 8) == 10, tostring(fit(1160, 175, 10, 8)))
end)

t.test("a 3x2 cell holds as many big covers as fit across", function()
    -- covers 371 tall -> 247 wide; (560 + 10) / 257 = 2
    assert(fit(560, 387, 10, 8) == 2, tostring(fit(560, 387, 10, 8)))
end)

t.test("never fewer than one, never more than twelve", function()
    assert(fit(20, 400, 10, 8) == 1)
    assert(fit(5000, 60, 10, 8) == 12)
end)

t.done()
