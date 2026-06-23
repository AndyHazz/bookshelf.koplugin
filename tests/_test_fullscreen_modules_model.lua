-- Headless tests for lib/bookshelf_fullscreen_modules_model.lua
-- The full-screen module list is a SEPARATE store from the hero list, seeded
-- from a copy of the hero list (minus page) on first load.
package.path = "./?.lua;./?/init.lua;" .. package.path

local kv = {}
package.loaded["lib/bookshelf_settings_store"] = {
    read   = function(key, default) if kv[key] == nil then return default end return kv[key] end,
    save   = function(key, value) kv[key] = value end,
    delete = function(key) kv[key] = nil end,
    flush  = function() end,
    isTrue = function(key) return kv[key] == true end,
}
package.loaded["logger"] = {
    dbg = function() end, info = function() end,
    warn = function() end, err = function() end,
}
package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }

local FSModel   = dofile("lib/bookshelf_fullscreen_modules_model.lua")
local HeroModel = dofile("lib/bookshelf_hero_modules_model.lua")
local helpers   = dofile("tests/_helpers.lua")
local t = helpers.runner()

t.test("seeds from an EMPTY hero list -> the clock default", function()
    kv = {}
    -- Hero list itself seeds to the clock default on its own first load.
    local items = FSModel.load()
    assert(#items == 1, "expected 1 seeded module, got " .. #items)
    assert(items[1].module == "analogue_clock", "default is not the clock")
    assert(kv.fullscreen_modules_seeded == true, "seeded flag not set")
    assert(type(kv.fullscreen_module_items) == "table", "items not persisted")
end)

t.test("seeds from a COPY of the hero list, dropping page, keeping config", function()
    kv = {}
    -- A hero list incl. an action card with per-instance config + a paged entry.
    kv.hero_module_items = {
        { id = "hm_a", type = "module", module = "action",
          action = "toggle_night_mode", label = "Night", icon = "[icon=moon]" },
        { id = "hm_b", type = "module", module = "weather", page = 2 },
    }
    kv.hero_modules_seeded = true
    local items = FSModel.load()
    assert(#items == 2, "expected 2 seeded modules, got " .. #items)
    assert(items[2].page == nil, "page field should be stripped on the full-screen list")
    -- Per-instance config (action/label/icon) MUST survive the seed -- else the
    -- action card renders blank and tapping does nothing.
    assert(items[1].action == "toggle_night_mode", "action field lost on seed")
    assert(items[1].label == "Night", "label lost on seed")
    assert(items[1].icon == "[icon=moon]", "icon lost on seed")
    -- Independent: neither the list nor the entry tables are shared with hero.
    assert(kv.fullscreen_module_items ~= kv.hero_module_items, "lists share a table")
    assert(items[1] ~= kv.hero_module_items[1], "entry tables shared with hero")
end)

t.test("sanitize keeps per-instance config (only page is dropped)", function()
    local s, changed = FSModel.sanitize({
        { id = "x", type = "module", module = "action",
          action = "toggle_wifi", label = "Wi-Fi", icon = "[icon=wifi]", page = 2 },
    })
    assert(#s == 1, "well-formed entry dropped")
    assert(s[1].page == nil, "page not stripped")
    assert(s[1].action == "toggle_wifi" and s[1].label == "Wi-Fi"
        and s[1].icon == "[icon=wifi]", "per-instance config dropped by sanitize")
    assert(changed == true, "sanitize should report changed when stripping page")
end)

t.test("editing the full-screen list does NOT touch the hero list", function()
    kv = {}
    kv.hero_module_items   = { { id = "hm_a", type = "module", module = "clock" } }
    kv.hero_modules_seeded = true
    FSModel.load()
    -- Add a module to the full-screen list only.
    local fs = FSModel.load()
    fs[#fs + 1] = { id = FSModel.nextId(), type = "module", module = "trivia" }
    FSModel.save(fs)
    -- Hero list unchanged.
    local hero = HeroModel.load()
    assert(#hero == 1 and hero[1].module == "clock", "hero list was mutated")
    -- Full-screen list has the addition.
    local out = FSModel.load()
    assert(#out == 2 and out[2].module == "trivia", "full-screen add not persisted")
end)

t.test("sanitize drops a stray page field + reports changed", function()
    local s, changed = FSModel.sanitize({
        { id = "x", type = "module", module = "clock", page = 3 },
    })
    assert(#s == 1, "well-formed entry dropped")
    assert(s[1].page == nil, "page not stripped")
    assert(changed == true, "sanitize should report changed when stripping page")
end)

t.test("deleting everything does not reseed", function()
    kv = {}
    FSModel.load()
    FSModel.save({})
    local items = FSModel.load()
    assert(#items == 0, "reseeded after delete-all")
end)

t.test("nextId is namespaced + monotonic", function()
    kv = {}
    local a = FSModel.nextId()
    local b = FSModel.nextId()
    assert(a:match("^fsm%d+$"), "nextId not fsm-prefixed: " .. tostring(a))
    assert(a ~= b, "nextId not unique")
end)

t.done()
