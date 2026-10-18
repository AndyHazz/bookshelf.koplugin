-- tests/_test_module_cache.lua
-- The micro-module caches (fitted card sizes, Shelf size tally, Reading goal
-- figures) live in their own small file and are written in ONE coalesced
-- flush, never through Store.save, which rewrites the whole settings file on
-- every call: on a PW5 that cost ~275ms inside a full-screen open.
-- Run from the plugin root: lua tests/_test_module_cache.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()

local scheduled = {}
package.loaded["ui/uimanager"] = {
    scheduleIn = function(_, _s, fn) scheduled[#scheduled + 1] = fn end,
    unschedule = function(_, fn)
        for i = #scheduled, 1, -1 do if scheduled[i] == fn then table.remove(scheduled, i) end end
    end,
}
local Cache = dofile("lib/bookshelf_module_cache.lua")

local data, flushes = {}, 0
Cache._setStore{
    read = function(k) return data[k] end,
    saveDeferred = function(k, v) data[k] = v end,
    flush = function() flushes = flushes + 1 end,
}

t.test("saves change memory only, then one flush follows", function()
    Cache.save("a", 1); Cache.save("b", 2); Cache.save("a", 3)
    assert(flushes == 0, "a save wrote the file straight away")
    assert(#scheduled == 1, "the flushes were not coalesced: " .. #scheduled)
    assert(Cache.read("a") == 3 and Cache.read("b") == 2)
    table.remove(scheduled, 1)()
    assert(flushes == 1)
end)

t.test("a save after the flush schedules another", function()
    Cache.save("c", 4)
    assert(#scheduled == 1)
    table.remove(scheduled, 1)()
    assert(flushes == 2)
end)

t.test("flush() writes now and drops the pending one", function()
    Cache.save("d", 5)
    Cache.flush()
    assert(flushes == 3 and #scheduled == 0)
end)

t.test("none of the three caches goes through the settings file", function()
    for _, f in ipairs({ "lib/bookshelf_hero_modules.lua", "micromodules/shelf_size.lua",
                         "micromodules/reading_goal.lua" }) do
        local src = io.open(f):read("*a")
        for _, key in ipairs({ "FIT_MEMO_KEY", "SAVED_KEY" }) do
            assert(not src:find("BookshelfSettings%.save%(" .. key)
               and not src:find("Store%.save%(" .. key)
               and not src:find("store%(%)%.save%(" .. key),
               f .. " still saves " .. key .. " to the settings file")
        end
    end
end)

t.done()
