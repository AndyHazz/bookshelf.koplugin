-- tests/_test_slice.lua
-- Work that cannot stop by itself, run in steps: Slice runs a function in a
-- coroutine, and Slice.check() -- called by the code inside at points where
-- stopping is safe (before a cover decode) -- gives the step back once its
-- time is up. Outside a slice, check() does nothing.
package.path = "./?.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq
local Slice = require("lib/bookshelf_slice")

t.test("the work pauses at a check once the step's time is up, and resumes there", function()
    local done = {}
    local job = Slice.start(function()
        for i = 1, 5 do done[#done + 1] = i; Slice.check() end
    end)
    local budget = 2
    local over = function() budget = budget - 1; return budget < 0 end
    local finished, ok = Slice.step(job, over)
    eq(ok, true); eq(finished, false)
    eq(#done, 3, "it did not stop at the first check after its time was up")
    budget = 100
    finished, ok = Slice.step(job, over)
    eq(finished, true); eq(ok, true); eq(#done, 5)
end)

t.test("an error inside ends the job and is handed back", function()
    local job = Slice.start(function() error("boom") end)
    local finished, ok, err = Slice.step(job, function() return false end)
    eq(finished, true); eq(ok, false)
    assert(tostring(err):find("boom"), tostring(err))
end)

t.test("a check outside a slice, or in another coroutine, never pauses", function()
    Slice.check()
    local co = coroutine.create(function() Slice.check(); return "ran" end)
    local _ok, v = coroutine.resume(co)
    eq(v, "ran")
end)

t.test("a pause through pcall works (the build runs inside one)", function()
    local job = Slice.start(function()
        local ok = pcall(function() Slice.check(); Slice.check() end)
        assert(ok)
    end)
    local finished = Slice.step(job, function() return true end)
    eq(finished, false)
    finished = Slice.step(job, function() return false end)
    eq(finished, true)
end)

t.done()
