-- tests/_test_hardcover_preload.lua
-- Pure-Lua tests for Hardcover.preloadMetadata.
--
-- applyMetadata runs once per book while the light-meta map is built, and each
-- call used to ask the cache for one row, compiling a fresh SELECT each time.
-- The point of the preload is the QUERY COUNT, so that is what these assert on:
-- a timing test would be flaky, but "one statement instead of N" is exact.

package.path = "./?.lua;./?/init.lua;" .. package.path

local settings = {}
package.loaded["lib/bookshelf_settings_store"] = {
    read = function(key, default)
        local v = settings["bookshelf_" .. key]
        if v == nil then return default end
        return v
    end,
    save   = function(key, value) settings["bookshelf_" .. key] = value end,
    delete = function(key) settings["bookshelf_" .. key] = nil end,
    flush  = function() end,
    isTrue = function(key) return settings["bookshelf_" .. key] == true end,
    nilOrTrue = function(key)
        local v = settings["bookshelf_" .. key]
        return v == nil or v == true
    end,
}
package.loaded["datastorage"] = { getSettingsDir = function() return "/tmp/bookshelf-hc-preload" end }
package.loaded["logger"] = { dbg = function() end, info = function() end,
                             warn = function() end, err = function() end }
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(_p, a) if a == "mode" then return "file" end end,
}
package.loaded["luasettings"] = {
    open = function(_self, _path)
        return { readSetting = function() return {} end,
                 saveSetting = function() end, flush = function() end }
    end,
}
package.loaded["docsettings"] = {
    findCustomCoverFile = function() return nil end,
    getSidecarDir = function() return "/tmp/bookshelf-hc-preload" end,
}
-- Present and enabled: Hardcover.isAvailable() requires a query function.
package.loaded["hardcover/lib/hardcover_api"] = { query = function() return nil end }
package.loaded["rapidjson"] = { encode = function(v) return v end,
                                decode = function(s) return s end }

-- SQLite fake that COUNTS statements by shape.
local store, sql_count = {}, { single = 0, bulk = 0 }
package.loaded["lua-ljsqlite3/init"] = {
    open = function(_path)
        local db = {}
        function db:exec() end
        function db:close() end
        function db:prepare(sql)
            if sql:find("SELECT data FROM cache", 1, true) then
                sql_count.single = sql_count.single + 1
            elseif sql:find("SELECT ckey, data FROM cache", 1, true) then
                sql_count.bulk = sql_count.bulk + 1
            end
            local stmt = { sql = sql }
            function stmt:bind(...) self.args = {...}; self._rows = nil; self._i = 0; return self end
            function stmt:clearbind() self.args = nil; self._rows = nil; self._i = 0; return self end
            function stmt:reset() self._rows = nil; self._i = 0; return self end
            function stmt:close() end
            function stmt:step()
                local a, s = self.args or {}, self.sql
                if s:find("SELECT data FROM cache", 1, true) then
                    local v = store[a[1]] and store[a[1]][a[2]]
                    return v ~= nil and { v } or nil
                elseif s:find("SELECT ckey, data FROM cache", 1, true) then
                    if not self._rows then
                        self._rows = {}
                        for ckey, data in pairs(store[a[1]] or {}) do
                            self._rows[#self._rows + 1] = { ckey, data }
                        end
                        self._i = 0
                    end
                    self._i = self._i + 1
                    return self._rows[self._i]
                elseif s:find("INSERT OR REPLACE INTO cache", 1, true) then
                    store[a[1]] = store[a[1]] or {}
                    store[a[1]][a[2]] = a[3]
                end
                return nil
            end
            return stmt
        end
        return db
    end,
}

local Hardcover = require("lib/bookshelf_hardcover")
local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()

local BOOKS = 40

local function reset(enabled)
    Hardcover.invalidate()
    store, sql_count = {}, { single = 0, bulk = 0 }
    settings["bookshelf_hardcover_use_metadata"] = (enabled ~= false)
    store.enrich = {}
    for i = 1, BOOKS do
        store.enrich[tostring(i)] = { title = "Book " .. i }
    end
end

t.test("without a preload, each book costs its own query", function()
    reset()
    for i = 1, BOOKS do Hardcover.getCachedEnrichment(i) end
    -- Pins what the preload is for. If this ever stops being true the
    -- optimisation below is measuring nothing.
    assert(sql_count.single == BOOKS,
        "expected " .. BOOKS .. " single-row queries, got " .. sql_count.single)
end)

t.test("after a preload, the whole library costs one query", function()
    reset()
    Hardcover.preloadMetadata()
    for i = 1, BOOKS do
        assert(Hardcover.getCachedEnrichment(i), "book " .. i .. " went missing")
    end
    assert(sql_count.bulk == 1, "expected 1 bulk query, got " .. sql_count.bulk)
    assert(sql_count.single == 0,
        "a preloaded row still hit the DB " .. sql_count.single .. " time(s)")
end)

t.test("a book with no cached row costs no query either", function()
    reset()
    Hardcover.preloadMetadata()
    local before = sql_count.single
    -- The memo holds every row, so absence IS the answer. Without the bulk
    -- flag every unlinked book would still pay for a lookup that finds nothing.
    assert(Hardcover.getCachedEnrichment(9999) == nil, "invented a row")
    assert(sql_count.single == before, "an absent book queried the DB")
end)

t.test("a preload does not run twice", function()
    reset()
    Hardcover.preloadMetadata()
    Hardcover.preloadMetadata()
    assert(sql_count.bulk == 1, "preloaded twice: " .. sql_count.bulk)
end)

t.test("invalidate makes the next read go back to the database", function()
    reset()
    Hardcover.preloadMetadata()
    Hardcover.invalidate()
    -- Anything that invalidates the memo has to clear the "memo is complete"
    -- flag with it, or a book linked after the preload reads as unlinked for
    -- the rest of the session.
    store.enrich["7"] = { title = "Relinked" }
    local got = Hardcover.getCachedEnrichment(7)
    assert(got and got.title == "Relinked", "stale answer survived invalidate")
end)

t.test("a preload never overwrites what the session already knows", function()
    reset()
    local first = Hardcover.getCachedEnrichment(3)
    assert(first, "nothing seeded")
    -- A row this session already read is newer than whatever the bulk read
    -- returns, so the preload must leave it alone. (A row written DURING the
    -- session lands in the memo through _cachePut, and linking a book calls
    -- invalidate, which the test above covers.)
    store.enrich["3"] = { title = "Changed underneath" }
    Hardcover.preloadMetadata()
    local got = Hardcover.getCachedEnrichment(3)
    assert(got.title == first.title,
        "the preload clobbered a live memo entry with a stale read")
end)

t.test("the preload is inert when the metadata override is off", function()
    reset(false)
    Hardcover.preloadMetadata()
    assert(sql_count.bulk == 0, "read the cache with the override off")
end)

t.done()
