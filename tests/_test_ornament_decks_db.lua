-- tests/_test_ornament_decks_db.lua
-- The ornament decks in SQLite, driven against REAL SQLite (as the book facts
-- store's test is: a fake would only assert my own assumptions back at me).
-- Each shelf's deck is its own rows; a database with none takes the settings
-- store's once, and the store's copy goes.
--
-- Needs KOReader's tree for ljsqlite3; skips cleanly under a plain interpreter:
--   /usr/lib/koreader/luajit tests/_test_ornament_decks_db.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

local KO = os.getenv("KOREADER_DIR") or "/usr/lib/koreader"
local f = io.open(KO .. "/common/lua-ljsqlite3/init.lua", "r")
if not f then print("SKIP: no KOReader tree at " .. KO .. "; needs real sqlite"); os.exit(0) end
f:close()
package.path  = KO .. "/frontend/?.lua;" .. KO .. "/common/?.lua;"
             .. KO .. "/common/?/init.lua;" .. KO .. "/?.lua;" .. package.path
package.cpath = KO .. "/common/?.so;" .. KO .. "/libs/?.so;" .. KO .. "/?.so;" .. package.cpath
if not pcall(require, "ffi/loadlib") then print("SKIP: ffi/loadlib unavailable"); os.exit(0) end
if not pcall(require, "lua-ljsqlite3/init") then print("SKIP: ljsqlite3 will not load here"); os.exit(0) end

package.loaded["logger"] = { dbg = function() end, info = function() end,
                             warn = function() end, err = function() end }
local TMPDIR = os.getenv("TMPDIR") or "/tmp"
local DIR = TMPDIR .. "/bookshelf_decks_db_test"
package.loaded["datastorage"] = { getSettingsDir = function() return DIR end }
-- The settings store the decks move in from: a table, with delete.
local store = {}
package.loaded["lib/bookshelf_settings_store"] = {
    read = function(k) return store[k] end,
    delete = function(k) store[k] = nil end,
}
local DB = require("lib/bookshelf_ornament_decks_db")

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1 else
        fail = fail + 1
        io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n")
    end
end
local function fresh()
    DB.close()
    os.execute("rm -rf '" .. DIR .. "' && mkdir -p '" .. DIR .. "/bookshelf'")
end
local function reopen() DB.close() end

test("a shelf's deck survives a reopen, in order", function()
    fresh()
    store = {}
    DB.put("all", { "c.png", "a.png", "b.png" })
    reopen()
    local d = DB.get("all")
    assert(d and table.concat(d, ",") == "c.png,a.png,b.png", d and table.concat(d, ","))
end)

test("changing one shelf leaves the others", function()
    fresh()
    store = {}
    DB.put("all", { "a", "b" })
    DB.put("recent", { "x", "y", "z" })
    DB.put("all", { "b", "a" })
    reopen()
    assert(table.concat(DB.get("all"), ",") == "b,a")
    assert(table.concat(DB.get("recent"), ",") == "x,y,z")
end)

test("a dropped shelf's deck goes", function()
    fresh()
    store = {}
    DB.put("all", { "a" })
    DB.put("gone", { "b" })
    DB.drop("gone")
    reopen()
    assert(DB.get("gone") == nil)
    assert(DB.get("all")[1] == "a")
end)

test("a new database takes the settings store's decks, once, and the old key goes", function()
    fresh()
    store = { ornament_decks = { all = { "p1", "p2" }, _ = { "q" } } }
    assert(table.concat(DB.get("all"), ",") == "p1,p2", "not moved in")
    assert(DB.get("_")[1] == "q")
    assert(store.ornament_decks == nil, "the settings copy stayed")
    -- A later store value is not taken over decks already here.
    store = { ornament_decks = { all = { "stale" } } }
    reopen()
    assert(DB.get("all")[1] == "p1", "moved in again over the database's own")
end)

io.write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
