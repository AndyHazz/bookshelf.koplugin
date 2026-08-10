-- tests/_test_bim_db.lua
-- lib/bookshelf_bim_db.open: the canonical BIM (bookinfo_cache.sqlite3)
-- opener shared by file_ops and stale_sweep. Every dependency is resolved
-- per call and pcall-guarded, so each failure mode maps to a distinct
-- loggable reason - walked here in dependency order, installing one stub
-- per step.
package.path = "./?.lua;./?/init.lua;" .. package.path

local t = dofile("tests/_helpers.lua").runner()
local BimDb = dofile("lib/bookshelf_bim_db.lua")

local db_present = false
local open_should_fail = false

t.test("no datastorage -> nil, 'no-datastorage'", function()
    package.preload["datastorage"] = function() error("not in harness") end
    local db, why = BimDb.open()
    assert(db == nil and why == "no-datastorage", tostring(why))
    package.preload["datastorage"] = nil
    package.loaded["datastorage"] = {
        getSettingsDir = function() return "/settings" end,
    }
end)

t.test("no lfs -> nil, 'no-lfs'", function()
    package.preload["libs/libkoreader-lfs"] = function() error("not in harness") end
    local db, why = BimDb.open()
    assert(db == nil and why == "no-lfs", tostring(why))
    package.preload["libs/libkoreader-lfs"] = nil
    package.loaded["libs/libkoreader-lfs"] = {
        attributes = function(p, what)
            assert(p == "/settings/bookinfo_cache.sqlite3",
                "must probe the BIM path, got " .. tostring(p))
            return db_present and "file" or nil
        end,
    }
end)

t.test("db file absent -> nil, 'no-db' (normal on first run)", function()
    db_present = false
    local db, why = BimDb.open()
    assert(db == nil and why == "no-db", tostring(why))
end)

t.test("sqlite binding absent -> nil, 'no-sqlite'", function()
    db_present = true
    package.preload["lua-ljsqlite3/init"] = function() error("not in harness") end
    local db, why = BimDb.open()
    assert(db == nil and why == "no-sqlite", tostring(why))
    package.preload["lua-ljsqlite3/init"] = nil
    package.loaded["lua-ljsqlite3/init"] = {
        open = function(path)
            if open_should_fail then error("locked") end
            return { path = path, is_conn = true }
        end,
    }
end)

t.test("open raising -> nil, 'open-failed'", function()
    open_should_fail = true
    local db, why = BimDb.open()
    assert(db == nil and why == "open-failed", tostring(why))
end)

t.test("all present -> live connection on the BIM path", function()
    open_should_fail = false
    local db, why = BimDb.open()
    assert(db and db.is_conn, tostring(why))
    assert(db.path == "/settings/bookinfo_cache.sqlite3")
end)

t.done()
