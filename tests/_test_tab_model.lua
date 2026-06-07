-- tests/_test_tab_model.lua
-- Pure-Lua unit tests for bookshelf_tab_model.lua.
-- Run from the plugin root: `lua tests/_test_tab_model.lua`

-- After the lib/ reorg, require("lib/...") needs the plugin root on
-- package.path so the slash-style require resolves.
package.path = "./?.lua;./?/init.lua;" .. package.path

package.loaded["logger"] = { dbg = function() end, info = function() end,
                              warn = function() end, err = function() end }

local stored = {}
_G.G_reader_settings = setmetatable({}, {
    __index = function(_, k)
        if k == "readSetting" then return function(_, key) return stored[key] end end
        if k == "saveSetting" then return function(_, key, val) stored[key] = val end end
        if k == "delSetting"  then return function(_, key) stored[key] = nil end end
        if k == "flush"       then return function() end end
        return nil
    end,
})

-- Stub BookshelfSettings so tab_model can require it without pulling in
-- LuaSettings / DataStorage (KOReader-only). Uses the same `stored` table
-- as the G_reader_settings stub so tests don't need to know which store
-- a setting lands in.
package.loaded["lib/bookshelf_settings_store"] = {
    read   = function(key, default) local v = stored[key]; if v == nil then return default end; return v end,
    save   = function(key, value)   stored[key] = value end,
    delete = function(key)          stored[key] = nil end,
    flush  = function() end,
    isTrue = function(key)          return stored[key] == true end,
    nilOrTrue = function(key)       return stored[key] == nil or stored[key] == true end,
}

local TabModel = dofile("lib/bookshelf_tab_model.lua")

local pass, fail = 0, 0
local function test(name, fn)
    stored = {}
    local ok, err = pcall(fn)
    if ok then pass = pass + 1
    else fail = fail + 1; io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n") end
end

test("defaults: produces all built-in tabs in expected order", function()
    local tabs = TabModel.DEFAULTS()
    local ids = {} for _, t in ipairs(tabs) do ids[#ids + 1] = t.id end
    local expected = { "all", "recent", "latest", "series", "authors",
                       "genres", "tags", "languages", "favorites" }
    assert(#tabs == #expected, "got " .. #tabs .. " tabs, expected " .. #expected)
    for i, id in ipairs(expected) do
        assert(ids[i] == id, "position " .. i .. ": expected " .. id .. " got " .. tostring(ids[i]))
    end
end)

test("defaults: fresh install enables Home/Recent/Series/Favourites only", function()
    -- v2.0.1: trimmed default chip set so new users see a focused
    -- starting bar instead of all 8 chips at once. Latest/Authors/
    -- Genres/Tags exist but are disabled; user can opt them on via
    -- the Bookshelf chips menu.
    local enabled_by_default = {}
    for _, t in ipairs(TabModel.DEFAULTS()) do
        if t.enabled then enabled_by_default[t.id] = true end
    end
    local expected = { all = true, recent = true, series = true, favorites = true }
    for id in pairs(expected) do
        assert(enabled_by_default[id],
               "expected " .. id .. " to be enabled in fresh-install defaults")
    end
    for id in pairs(enabled_by_default) do
        assert(expected[id],
               "did not expect " .. id .. " enabled in fresh-install defaults")
    end
end)

test("load: returns defaults when nothing saved", function()
    local tabs = TabModel.load()
    assert(#tabs > 0)
    assert(tabs[1].id == "all")
end)

test("load: migrates legacy bookshelf_chips_disabled to enabled=false", function()
    stored["chips_disabled"] = { genres = true, tags = true }
    local tabs = TabModel.load()
    for _, t in ipairs(tabs) do
        if t.id == "genres" or t.id == "tags" then
            assert(t.enabled == false, t.id .. " should be disabled by migration")
        else
            assert(t.enabled == true, t.id .. " should remain enabled")
        end
    end
    -- After migration the legacy setting should be cleared
    assert(stored["chips_disabled"] == nil,
           "legacy setting should be cleared after migration")
    -- The new schema should be persisted
    assert(stored["tabs"] ~= nil, "new schema should be saved on migration")
end)

test("load: round-trips a saved schema", function()
    local custom = {
        { id = "all", label = "Home", icon = nil, source = { kind = "all" },
          filter = {}, sort_priority = { { key = "title", reverse = false } },
          enabled = true },
    }
    stored["tabs"] = custom
    local loaded = TabModel.load()
    assert(#loaded == 1)
    assert(loaded[1].label == "Home")
    assert(loaded[1].sort_priority[1].key == "title")
end)

test("save: persists tabs and flushes", function()
    local tabs = { { id = "all", label = "Home", source = { kind = "all" },
                     filter = {}, sort_priority = {}, enabled = true } }
    TabModel.save(tabs)
    assert(stored["tabs"] ~= nil)
    assert(#stored["tabs"] == 1)
    assert(stored["tabs"][1].label == "Home")
end)

test("getById: returns the matching tab", function()
    local t = TabModel.getById("favorites")
    assert(t ~= nil)
    assert(t.id == "favorites")
end)

test("getActive: returns only enabled tabs in order", function()
    stored["tabs"] = {
        { id = "all", enabled = true,  source = { kind = "all" } },
        { id = "recent", enabled = false, source = { kind = "recent" } },
        { id = "latest", enabled = true, source = { kind = "latest" } },
    }
    local active = TabModel.getActive()
    assert(#active == 2)
    assert(active[1].id == "all")
    assert(active[2].id == "latest")
end)

io.write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
