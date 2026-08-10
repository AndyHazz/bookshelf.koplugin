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

t.done()
