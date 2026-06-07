-- tests/_helpers.lua
-- Shared helpers for Bookshelf's pure-Lua test suites (run by tests/run.sh
-- under a standalone `lua`, NOT KOReader). Not a test suite itself -- the
-- runner globs `_test_*.lua`, so this `_helpers.lua` name is skipped.
--
-- Usage:
--   local helpers = dofile("tests/_helpers.lua")
--   local hccache = helpers.install_hardcover_cache_fake()  -- BEFORE requiring
--                                                           -- lib/bookshelf_hardcover
--   hccache.seed("enrich", "123:456", { description = "..." })
--   local rows = hccache.kind("rating")   -- read back what the code stored
--   hccache.clear()                        -- between tests

local M = {}

-- Tiny test runner shared by newer suites, matching the run.sh contract
-- (prints "PASS n  FAIL n"; exits non-zero on any failure).
--   local t = require-or-dofile("tests/_helpers.lua").runner()
--   t.test("name", function() assert(...) end)
--   t.done()
function M.runner()
    local pass, fail = 0, 0
    return {
        test = function(name, fn)
            local ok, err = pcall(fn)
            if ok then
                pass = pass + 1
            else
                fail = fail + 1
                io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n")
            end
        end,
        done = function()
            io.stdout:write(("PASS %d  FAIL %d\n"):format(pass, fail))
            if fail > 0 then os.exit(1) end
        end,
    }
end

-- Assert deep value/sequence equality (scalars + flat arrays); returns got so
-- it can be chained. Good enough for the small structures these suites check.
function M.eq(got, want, msg)
    local function same(a, b)
        if type(a) ~= type(b) then return false end
        if type(a) ~= "table" then return a == b end
        for k, v in pairs(a) do if not same(v, b[k]) then return false end end
        for k, v in pairs(b) do if not same(v, a[k]) then return false end end
        return true
    end
    if not same(got, want) then
        error((msg or "values differ") .. "\n  got:  " .. tostring(got)
            .. "\n  want: " .. tostring(want), 2)
    end
    return got
end

-- In-memory backend for the SQLite-backed Hardcover cache.
--
-- Since v2.4.2 the enrichment / ratings / reviews caches live in an SQLite
-- table  cache(kind, ckey, data)  (rapidjson blobs) opened via lua-ljsqlite3.
-- Neither library exists under a standalone interpreter, so without a fake the
-- cache disables itself and every read returns nil. This installs:
--   * a `rapidjson` stub whose encode/decode are identity (the fake DB stores
--     Lua values directly), and
--   * a `lua-ljsqlite3/init` stub implementing exactly the statements the
--     module issues, backed by a plain Lua table.
-- The module's real _cacheGet/_cachePut/_cacheReadKind/etc. then run unchanged,
-- so the tests exercise the live cache code paths.
--
-- Must be called BEFORE the first require/dofile of lib/bookshelf_hardcover
-- (require caches the module, and the stubs must be in package.loaded first).
-- Returns { seed(kind,ckey,value), kind(kind)->table, clear() }.
function M.install_hardcover_cache_fake()
    local store = {}   -- store[kind][ckey] = value

    -- _cacheDb() reads DataStorage:getSettingsDir() for the DB path (which the
    -- fake ignores). Provide a default only if the suite hasn't already stubbed
    -- datastorage -- some suites assert a specific settings path elsewhere.
    if not package.loaded["datastorage"] then
        package.loaded["datastorage"] = {
            getSettingsDir = function() return "/tmp/bookshelf-test" end,
        }
    end

    package.loaded["rapidjson"] = {
        encode = function(v) return v end,
        decode = function(s) return s end,
    }

    package.loaded["lua-ljsqlite3/init"] = {
        open = function(_path)
            local db = {}
            function db:exec() end          -- PRAGMA / CREATE TABLE: no-op
            function db:close() end
            function db:prepare(sql)
                local stmt = { sql = sql }
                function stmt:bind(...)
                    self.args = { ... }; self._rows = nil; self._i = 0; return self
                end
                function stmt:clearbind()
                    self.args = nil; self._rows = nil; self._i = 0; return self
                end
                function stmt:reset() self._rows = nil; self._i = 0; return self end
                function stmt:close() end
                function stmt:step()
                    local a = self.args or {}
                    local s = self.sql
                    if s:find("SELECT data FROM cache", 1, true) then
                        local v = store[a[1]] and store[a[1]][a[2]]
                        return v ~= nil and { v } or nil
                    elseif s:find("INSERT OR REPLACE INTO cache", 1, true) then
                        store[a[1]] = store[a[1]] or {}
                        store[a[1]][a[2]] = a[3]
                        return nil
                    elseif s:find("DELETE FROM cache", 1, true) then
                        store[a[1]] = nil
                        return nil
                    elseif s:find("SELECT COUNT(*) FROM cache", 1, true) then
                        local n = 0
                        if store[a[1]] then
                            for _ in pairs(store[a[1]]) do n = n + 1 end
                        end
                        return { n }
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
                    end
                    return nil
                end
                return stmt
            end
            return db
        end,
    }

    return {
        seed  = function(kind, ckey, value)
            store[kind] = store[kind] or {}
            store[kind][ckey] = value
        end,
        kind  = function(kind) return store[kind] or {} end,
        clear = function() for k in pairs(store) do store[k] = nil end end,
    }
end

return M
