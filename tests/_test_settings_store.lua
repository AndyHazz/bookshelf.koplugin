-- tests/_test_settings_store.lua
-- Pure-Lua tests for bookshelf_settings_store: read/save/delete, the nilOrTrue
-- / isTrue back-compat predicates, the generation counter, and the one-shot
-- migration of legacy bookshelf_* keys out of G_reader_settings.

package.path = "./?.lua;./?/init.lua;" .. package.path

-- In-memory backing for the plugin's LuaSettings file. Reassigned between
-- tests; the module's cached settings object captures `lua_store` as an
-- upvalue, so reassigning the slot repoints it.
local lua_store = {}
local flush_count = 0

package.loaded["datastorage"] = {
    getSettingsDir = function() return "/tmp/bookshelf-settings-test" end,
}
package.loaded["logger"] = {
    dbg = function() end, info = function() end,
    warn = function() end, err = function() end,
}
-- File "present at load" is read once per module load via lfs.attributes.
local file_present = false
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(_path, attr)
        if attr == "mode" then return file_present and "file" or nil end
        return nil
    end,
}
package.loaded["luasettings"] = {
    open = function(_self, _path)
        return {
            readSetting = function(_, k) return lua_store[k] end,
            saveSetting = function(_, k, v) lua_store[k] = v end,
            delSetting  = function(_, k) lua_store[k] = nil end,
            flush       = function() flush_count = flush_count + 1 end,
            isTrue      = function(_, k) return lua_store[k] == true end,
            nilOrTrue   = function(_, k)
                local v = lua_store[k]; return v == nil or v == true
            end,
        }
    end,
}

-- Global KOReader settings (migration source).
local greader = {}
_G.G_reader_settings = {
    readSetting = function(_, k) return greader[k] end,
    delSetting  = function(_, k) greader[k] = nil end,
}

local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()
local eq = helpers.eq

local function loadStore()
    package.loaded["lib/bookshelf_settings_store"] = nil
    return dofile("lib/bookshelf_settings_store.lua")
end

-- Most tests share one Store; migration tests reload it with fresh state.
lua_store = { migrated = true }   -- skip migration for the basic tests
local Store = loadStore()

t.test("read returns the default when a key is absent", function()
    eq(Store.read("nope", "fallback"), "fallback")
    eq(Store.read("nope"), nil)
end)

t.test("read returns the stored value when present", function()
    lua_store.active_chip = "series"
    eq(Store.read("active_chip", "recent"), "series")
end)

t.test("save persists the value and bumps the generation", function()
    local g0 = Store.generation()
    Store.save("chip_font_scale", 120)
    eq(lua_store.chip_font_scale, 120)
    eq(Store.read("chip_font_scale"), 120)
    assert(Store.generation() == g0 + 1, "generation did not advance on save")
end)

t.test("delete removes the value and bumps the generation", function()
    lua_store.dev_branch = "x"
    local g0 = Store.generation()
    Store.delete("dev_branch")
    eq(lua_store.dev_branch, nil)
    assert(Store.generation() == g0 + 1, "generation did not advance on delete")
end)

t.test("saveDeferred writes in memory and bumps generation without flushing", function()
    local g0 = Store.generation()
    local f0 = flush_count
    Store.saveDeferred("active_cursor", 9)
    eq(lua_store.active_cursor, 9)
    assert(Store.generation() == g0 + 1, "generation did not advance on saveDeferred")
    assert(flush_count == f0, "saveDeferred should not flush")
end)

t.test("nilOrTrue: nil and true are true; false and other values are false", function()
    lua_store.t_nil = nil
    lua_store.t_true = true
    lua_store.t_false = false
    lua_store.t_num = 1
    assert(Store.nilOrTrue("t_nil") == true,  "nil should be true")
    assert(Store.nilOrTrue("t_true") == true, "true should be true")
    assert(Store.nilOrTrue("t_false") == false, "false should be false")
    assert(Store.nilOrTrue("t_num") == false, "non-true value should be false")
end)

t.test("isTrue: only an exact true is true", function()
    lua_store.i_true = true
    lua_store.i_false = false
    lua_store.i_num = 1
    assert(Store.isTrue("i_true") == true, "true should be true")
    assert(Store.isTrue("i_false") == false, "false should be false")
    assert(Store.isTrue("i_missing") == false, "missing should be false")
    assert(Store.isTrue("i_num") == false, "non-true value should be false")
end)

t.test("path() returns the dedicated bookshelf settings file", function()
    eq(Store.path(), "/tmp/bookshelf-settings-test/bookshelf.lua")
end)

t.test("wasPresent reflects whether the file existed at load", function()
    file_present = false
    local s1 = loadStore()
    assert(s1.wasPresent() == false, "expected not-present")
    file_present = true
    local s2 = loadStore()
    assert(s2.wasPresent() == true, "expected present")
end)

t.test("migration copies legacy bookshelf_* keys out of G_reader_settings", function()
    -- Fresh state: legacy values in the global store, empty plugin file.
    greader = {
        bookshelf_active_chip   = "genres",
        bookshelf_check_updates = true,
        bookshelf_sort_series   = "name",   -- legacy per-chip sort key
        unrelated_key           = "keep",   -- non-bookshelf: must be left alone
    }
    lua_store = {}   -- no "migrated" flag -> migration runs
    local S = loadStore()
    -- Trigger the lazy open/migrate.
    eq(S.read("active_chip"), "genres")
    eq(S.read("check_updates"), true)
    eq(S.read("sort_series"), "name")
    -- Source keys removed from the global store; unrelated key untouched.
    eq(greader.bookshelf_active_chip, nil)
    eq(greader.bookshelf_check_updates, nil)
    eq(greader.bookshelf_sort_series, nil)
    eq(greader.unrelated_key, "keep")
    -- Migration flag set so it never repeats.
    eq(lua_store.migrated, true)
end)

t.test("migration is a no-op when the flag is already set", function()
    greader = { bookshelf_active_chip = "should_not_migrate" }
    lua_store = { migrated = true }
    local S = loadStore()
    S.read("anything")
    -- Already migrated: the legacy key is left in place, not consumed.
    eq(greader.bookshelf_active_chip, "should_not_migrate")
    eq(lua_store.active_chip, nil)
end)

t.test("expandedTapAction: resolves explicit values + legacy fallback", function()
    -- Unset + legacy double-tap off -> single-tap open.
    lua_store.expanded_tap_action = nil
    lua_store.tap_to_open_double  = nil
    eq(Store.expandedTapAction(), "open")
    -- Unset + legacy double-tap ON -> honour it (existing users keep behaviour).
    lua_store.tap_to_open_double = true
    eq(Store.expandedTapAction(), "open_double")
    -- An explicit value overrides the legacy toggle.
    lua_store.expanded_tap_action = "show_detail"
    eq(Store.expandedTapAction(), "show_detail")
    lua_store.expanded_tap_action = "open"
    eq(Store.expandedTapAction(), "open")
    lua_store.expanded_tap_action = "open_double"
    eq(Store.expandedTapAction(), "open_double")
    -- A bogus stored value is ignored, falling back to the legacy resolution.
    lua_store.tap_to_open_double  = nil
    lua_store.expanded_tap_action = "nonsense"
    eq(Store.expandedTapAction(), "open")
    lua_store.expanded_tap_action = nil
end)

t.done()
