-- Headless tests for lib/bookshelf_hero_modules_model.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

-- In-memory settings store stub
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

local Model = dofile("lib/bookshelf_hero_modules_model.lua")
local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()

t.test("first load seeds the default module(s) and the seeded flag", function()
    kv = {}
    local items = Model.load()
    -- New installs default to just the analogue clock (offline, fits any size);
    -- users add more from the picker.
    assert(#items == 1, "expected 1 default module, got " .. #items)
    assert(items[1].module == "analogue_clock", "default is not the analogue clock")
    assert(kv.hero_modules_seeded == true, "seeded flag not set")
    assert(type(kv.hero_module_items) == "table", "items not persisted")
    -- All defaults are module entries.
    for _i, it in ipairs(items) do
        assert(it.type == "module" and type(it.module) == "string",
            "default entry is not a module")
    end
end)

t.test("deleting everything does not reseed", function()
    kv = {}
    Model.load()
    Model.save({})
    local items = Model.load()
    assert(#items == 0, "reseeded after delete-all")
end)

t.test("DEFAULTS pass sanitize unchanged", function()
    local d = Model.DEFAULTS()
    local s, changed = Model.sanitize(d)
    assert(#s == #d, "sanitize dropped a default entry")
    assert(not changed, "sanitize reported changed on clean defaults")
end)

t.test("sanitize keeps only well-formed module entries", function()
    local s, changed = Model.sanitize({
        { id = "a", type = "module", module = "analogue_clock" },
        { id = "b", type = "action", label = "x", action = { history = true } }, -- no actions in hero
        { id = "c", type = "folder", label = "F", children = {} },               -- no folders in hero
        { type = "module", module = "no_id" },                                   -- missing id
        { id = "d", type = "module" },                                           -- missing module key
        "not a table",
        { id = "e", type = "module", module = "quote_of_day" },
    })
    assert(#s == 2, "expected 2 module survivors, got " .. #s)
    assert(s[1].id == "a" and s[2].id == "e", "wrong survivors")
    assert(changed, "expected changed=true when dropping non-module entries")
end)

t.test("sanitize does not mutate its input", function()
    local input = {
        { id = "a", type = "module", module = "analogue_clock" },
        { id = "b", type = "action", label = "x", action = { history = true } },
    }
    local out, changed = Model.sanitize(input)
    assert(#input == 2, "input list length changed")
    assert(input[2].type == "action", "input entry mutated")
    assert(#out == 1 and out[1].id == "a", "wrong survivor in output")
    assert(changed, "expected changed=true")
end)

t.test("nextId is monotonic and persisted", function()
    kv = {}
    local a, b = Model.nextId(), Model.nextId()
    assert(a ~= b, "ids must differ")
    assert(a == "hm1" and b == "hm2", "unexpected id format: " .. a .. ", " .. b)
    assert(kv.hero_module_next_id == 3, "counter not persisted")
end)

t.test("load persists sanitized result once", function()
    kv = {}
    kv.hero_modules_seeded = true
    kv.hero_module_items = {
        { id = "bad", type = "action", label = "x", action = { history = true } },
        { id = "good", type = "module", module = "reading_goal" },
    }
    local items = Model.load()
    assert(#items == 1 and items[1].id == "good", "expected only the module entry")
    assert(#kv.hero_module_items == 1, "store not cleaned")
    assert(kv.hero_module_items[1].id == "good", "wrong item in store")
end)

-- Reused list helpers (borrowed from the start-menu model) operate on the
-- hero list shape correctly.
local function fixture()
    return {
        { id = "a", type = "module", module = "analogue_clock" },
        { id = "b", type = "module", module = "quote_of_day" },
        { id = "c", type = "module", module = "random_unread" },
    }
end

t.test("moveBy reorders and clamps at edges", function()
    local items = fixture()
    assert(Model.moveBy(items, "c", -1))
    assert(items[2].id == "c" and items[3].id == "b", "moveBy up failed")
    assert(not Model.moveBy(items, "a", -1), "should clamp at top")
end)

t.test("removeById removes a module", function()
    local items = fixture()
    assert(Model.removeById(items, "b"))
    assert(#items == 2 and items[2].id == "c", "removeById failed")
    assert(not Model.removeById(items, "zz"), "removing absent id returns false")
end)

t.test("insertAfter splices after anchor; nil anchor appends", function()
    local items = fixture()
    Model.insertAfter(items, "a", { id = "n", type = "module", module = "clock" })
    assert(items[2].id == "n", "insertAfter anchor failed")
    Model.insertAfter(items, nil, { id = "z", type = "module", module = "weather" })
    assert(items[#items].id == "z", "append failed")
end)

t.test("sanitize/save/load preserve per-instance fields on a module entry", function()
    kv = {}
    kv.hero_modules_seeded = true
    kv.hero_module_items = {
        { id = "act1", type = "module", module = "action",
          label = "WiFi", icon = "[icon=wifi]",
          action = { toggle_wifi = true } },
    }
    local items = Model.load()
    assert(#items == 1, "entry dropped")
    local e = items[1]
    assert(e.module == "action" and e.label == "WiFi"
        and e.icon == "[icon=wifi]" and e.action and e.action.toggle_wifi == true,
        "per-instance fields not preserved through load/sanitize")
end)

t.done()
