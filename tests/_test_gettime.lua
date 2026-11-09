-- tests/_test_gettime.lua
-- lib/bookshelf_gettime: the shared wall-clock. Two contracts: with LuaSocket
-- present it wraps socket.gettime (fractional seconds); without it the
-- fallback is os.time (integer WALL seconds - never os.clock, whose CPU-only
-- time freezes during idle waits and would break reader_park's idle
-- bookkeeping under fallback).
package.path = "./?.lua;./?/init.lua;" .. package.path

local t = dofile("tests/_helpers.lua").runner()

t.test("with LuaSocket present, wraps socket.gettime", function()
    package.loaded["socket"] = { gettime = function() return 1234.5 end }
    local gettime = dofile("lib/bookshelf_gettime.lua")
    assert(type(gettime) == "function", "module must return a function")
    assert(gettime() == 1234.5, "must delegate to socket.gettime")
end)

t.test("without LuaSocket, falls back to os.time (wall clock)", function()
    package.loaded["socket"] = nil
    package.preload["socket"] = function() error("no luasocket in harness") end
    local gettime = dofile("lib/bookshelf_gettime.lua")
    assert(gettime == os.time, "fallback must be os.time, not os.clock")
    package.preload["socket"] = nil
end)

t.test("socket without gettime also falls back", function()
    package.loaded["socket"] = { skip = function() end }  -- no gettime field
    local gettime = dofile("lib/bookshelf_gettime.lua")
    assert(gettime == os.time, "partial socket module must not be trusted")
    package.loaded["socket"] = nil
end)

-- ui/timeval is gone from KOReader (ui/time replaced it), so a module that
-- tried it first fell back to os.clock on every current device: CPU time,
-- which leaves out the waits a cover decode spends reading its data. The
-- spine shelf's turn summary reported a cold page's covers at 158 ms that
-- took 557 ms (PW5).
t.test("no module asks for the clock KOReader no longer has", function()
    local p = io.popen("ls lib/*.lua")
    for path in p:lines() do
        local f = io.open(path); local src = f:read("*a"); f:close()
        assert(not src:find("ui/timeval", 1, true), path .. " still reads ui/timeval")
    end
    p:close()
    local f = io.open("lib/bookshelf_spine_shelf.lua"); local src = f:read("*a"); f:close()
    assert(src:find('local _gettime = require("lib/bookshelf_gettime")', 1, true),
        "the spine shelf keeps a clock of its own")
end)

t.done()
