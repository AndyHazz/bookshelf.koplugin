-- tests/_test_position_store.lua
-- The shelf's place has a file of its own.
--
-- Which shelf, which page, the drill and the ornament deal of that page are
-- saved after every bout of paging. In the main settings file each of those
-- saves rewrote all of it (48 KB on a PW5, written twice with its backup),
-- for a few numbers. They live in settings/bookshelf/position.lua, and the
-- paging save flushes only that, plus the main file when a deferred main key
-- is waiting (a pinch's columns ride the same save).
package.path = "./?.lua;./?/init.lua;" .. package.path

local MAIN = "/tmp/bs-pos-test/bookshelf/settings.lua"
local files, flushes = {}, {}
package.loaded["datastorage"] = {
    getDataDir = function() return "/tmp/bs-pos-test-data" end,
    getSettingsDir = function() return "/tmp/bs-pos-test" end,
}
package.loaded["logger"] = { dbg = function() end, info = function() end, warn = function() end, err = function() end }
package.loaded["libs/libkoreader-lfs"] = { attributes = function() return nil end }
package.loaded["luasettings"] = {
    open = function(_self, path)
        files[path] = files[path] or {}
        local data = files[path]
        return {
            readSetting = function(_, k) return data[k] end,
            saveSetting = function(_, k, v) data[k] = v end,
            delSetting  = function(_, k) data[k] = nil end,
            flush       = function() flushes[path] = (flushes[path] or 0) + 1 end,
        }
    end,
}
_G.G_reader_settings = { readSetting = function() end, delSetting = function() end, flush = function() end }
files[MAIN] = { migrated = true, reader_keys_moved = true, aux_data_relocated_v2 = true,
                active_chip = "series", active_cursor = 41 }   -- an upgrade: still in the main file

local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq
package.loaded["lib/bookshelf_settings_store"] = nil
local Store = dofile("lib/bookshelf_settings_store.lua")
local POS
for p in pairs(files) do if p ~= MAIN then POS = p end end

local function posPath()
    for p in pairs(files) do if p:find("position.lua", 1, true) then return p end end
end

t.test("an upgrade keeps its place: read from the main file until the first save", function()
    eq(Store.read("active_chip"), "series")
    eq(Store.read("active_cursor"), 41)
end)

t.test("the place is saved to its own file, not the main one", function()
    for _i, k in ipairs({ "active_chip", "active_cursor", "active_page", "drill_path", "orn_resume" }) do
        Store.saveDeferred(k, k == "drill_path" and {} or 7)
    end
    local P = assert(posPath(), "no position file")
    eq(files[P].active_cursor, 7)
    eq(Store.read("active_cursor"), 7, "the new place does not win over the old one")
    eq(files[MAIN].active_cursor, nil, "the old copy stays in the main file, to be read back")
end)

t.test("a paging save writes the small file only", function()
    Store.flushPending()   -- the upgrade's one removal from the main file
    flushes = {}
    Store.saveDeferred("active_cursor", 9)
    Store.flushPending()
    eq(flushes[posPath()], 1)
    eq(flushes[MAIN], nil, "the whole main file was rewritten for the page number")
end)

t.test("a deferred main key waiting goes with it, once", function()
    flushes = {}
    Store.saveDeferred("bookshelf_columns", 5)
    Store.flushPending()
    eq(flushes[MAIN], 1, "a pinch's columns were lost")
    Store.flushPending()
    eq(flushes[MAIN], 1, "written again with nothing waiting")
end)

t.test("a full flush writes both, as before", function()
    flushes = {}
    Store.flush()
    eq(flushes[MAIN], 1); eq(flushes[posPath()], 1)
end)

t.test("clearing a key does not bring back an older place from the main file", function()
    files[MAIN].drill_path = { { kind = "series", label = "old" } }
    Store.saveDeferred("drill_path", nil)
    eq(Store.read("drill_path"), nil, "the drill an earlier version saved came back")
    files[MAIN].active_page = 12
    Store.delete("active_page")
    eq(Store.read("active_page"), nil)
end)

t.test("the shelf's paging save uses it", function()
    local W = io.open("lib/bookshelf_widget.lua"):read("*a")
    local body = assert(W:match("\nfunction BookshelfWidget:_flushNavStateNow%(%)\n(.-)\nend\n"))
    assert(body:find("BookshelfSettings.flushPending()", 1, true), "the paging save rewrites the main file")
end)

t.done()
