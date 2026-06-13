-- Headless tests for lib/bookshelf_start_menu_model.lua
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

local Model = dofile("lib/bookshelf_start_menu_model.lua")
local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()

t.test("first load seeds defaults and sets seeded flag", function()
    kv = {}
    local items = Model.load()
    assert(#items == 7, "expected starter set, got " .. #items)
    assert(kv.start_menu_seeded == true, "seeded flag not set")
    assert(type(kv.start_menu_items) == "table", "items not persisted")
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

t.test("sanitize drops malformed entries", function()
    local s = Model.sanitize({
        { id = "a", type = "action", label = "ok", action = { history = true } },
        { id = "b", type = "action", label = "no action or internal" },
        { type = "action", label = "no id", action = { history = true } },
        "not a table",
        { id = "c", type = "module", module = "stats" },
        { id = "d", type = "bogus" },
    })
    assert(#s == 2, "expected 2 survivors, got " .. #s)
    assert(s[1].id == "a" and s[2].id == "c")
end)

t.test("sanitize strips nested folders (one-level rule)", function()
    local s = Model.sanitize({
        { id = "f", type = "folder", label = "Games", children = {
            { id = "x", type = "action", label = "Chess", action = { history = true } },
            { id = "g", type = "folder", label = "nested", children = {} },
        } },
    })
    assert(#s == 1 and #s[1].children == 1, "nested folder not stripped")
    assert(s[1].children[1].id == "x")
end)

t.test("nextId is monotonic and persisted", function()
    kv = {}
    local a, b = Model.nextId(), Model.nextId()
    assert(a ~= b, "ids must differ")
    assert(kv.start_menu_next_id == 3, "counter not persisted")
end)

t.test("sanitize does not mutate its input", function()
    local nested = { id = "g", type = "folder", label = "nested", children = {} }
    local folder = { id = "f", type = "folder", label = "Games", children = {
        { id = "x", type = "action", label = "Chess", action = { history = true } },
        nested,
    } }
    local input = { folder }
    local out, changed = Model.sanitize(input)
    -- Original folder still has the nested folder in its children.
    assert(#folder.children == 2, "input folder was mutated: children count changed")
    assert(folder.children[2].id == "g", "input folder was mutated: nested folder removed")
    -- Returned copy has the nested folder stripped.
    assert(#out == 1, "expected 1 entry in output")
    assert(#out[1].children == 1, "nested folder should be stripped from output copy")
    assert(out[1].children[1].id == "x", "action child missing from output copy")
    assert(changed, "expected changed=true when nested folder stripped")
end)

t.test("load persists sanitized result once", function()
    kv = {}
    kv.start_menu_seeded = true
    kv.start_menu_items = {
        { id = "bad", type = "action", label = "no action or internal" },
        { id = "good", type = "action", label = "ok", action = { history = true } },
    }
    local items = Model.load()
    -- Returned list has only the good entry.
    assert(#items == 1, "expected 1 item, got " .. #items)
    assert(items[1].id == "good", "wrong item returned")
    -- Persisted store now has only the good entry too.
    assert(type(kv.start_menu_items) == "table", "items not persisted")
    assert(#kv.start_menu_items == 1, "store not cleaned: has " .. #kv.start_menu_items)
    assert(kv.start_menu_items[1].id == "good", "wrong item in store")
    -- Second load sees clean data (no re-persist needed).
    local items2 = Model.sanitize(kv.start_menu_items)
    assert(#items2 == 1, "second load would not return clean data")
end)

t.test("sanitize strips a persisted _unresolved flag (self-heal)", function()
    local s, changed = Model.sanitize({
        { id = "a", type = "action", label = "A", _unresolved = true,
          action = { history = true } },
        { id = "f", type = "folder", label = "F", children = {
            { id = "x", type = "action", label = "X", _unresolved = true,
              action = { favorites = true } },
        } },
    })
    assert(#s == 2, "expected both entries kept, got " .. #s)
    assert(s[1]._unresolved == nil, "_unresolved not stripped from action")
    assert(s[1].id == "a" and s[1].label == "A" and s[1].action.history == true,
        "action entry fields lost in copy-on-strip")
    assert(s[2].children[1]._unresolved == nil,
        "_unresolved not stripped from folder child")
    assert(changed, "expected changed=true when stripping _unresolved")
end)

t.test("sanitize keeps plugin entries, drops ones missing key/method", function()
    local s, changed = Model.sanitize({
        { id = "p", type = "action", label = "Sokoban",
          plugin = { key = "sokoban", method = "__menu_callback" } },
        { id = "q", type = "action", label = "Broken", plugin = {} },
    })
    assert(#s == 1, "expected 1 survivor, got " .. #s)
    assert(s[1].id == "p", "wrong survivor: " .. tostring(s[1].id))
    assert(s[1].plugin.key == "sokoban" and s[1].plugin.method == "__menu_callback",
        "plugin table fields lost")
    assert(changed, "expected changed=true when dropping the keyless entry")
end)

t.test("action/folder entries without string label are dropped", function()
    local s = Model.sanitize({
        { id = "a", type = "action", action = { history = true } },
        { id = "b", type = "action", label = 42, action = { history = true } },
        { id = "c", type = "folder", children = {} },
        { id = "d", type = "folder", label = nil, children = {} },
        { id = "e", type = "action", label = "ok", action = { history = true } },
        { id = "f", type = "module", module = "stats" },
    })
    -- Only "e" (action with label) and "f" (module, no label needed) survive.
    assert(#s == 2, "expected 2 survivors, got " .. #s)
    assert(s[1].id == "e", "wrong first survivor: " .. tostring(s[1].id))
    assert(s[2].id == "f", "wrong second survivor: " .. tostring(s[2].id))
end)

local function fixture()
    return {
        { id = "a", type = "action", label = "A", action = { history = true } },
        { id = "f", type = "folder", label = "F", children = {
            { id = "x", type = "action", label = "X", action = { favorites = true } },
            { id = "y", type = "action", label = "Y", action = { history = true } },
        } },
        { id = "b", type = "action", label = "B", internal = "close" },
    }
end

t.test("findById locates top-level and nested entries", function()
    local items = fixture()
    local list, idx, entry, parent = Model.findById(items, "x")
    assert(entry and entry.id == "x" and idx == 1 and parent.id == "f")
    list, idx, entry, parent = Model.findById(items, "b")
    assert(entry and idx == 3 and parent == nil and list == items)
    assert(Model.findById(items, "zz") == nil)
end)

t.test("moveBy moves within its own list and clamps at edges", function()
    local items = fixture()
    assert(Model.moveBy(items, "b", -1))
    assert(items[2].id == "b" and items[3].id == "f")
    assert(not Model.moveBy(items, "a", -1), "clamp at top")
    assert(Model.moveBy(items, "x", 1))
    local f = items[3]
    assert(f.children[1].id == "y" and f.children[2].id == "x")
end)

t.test("removeById removes nested entries", function()
    local items = fixture()
    assert(Model.removeById(items, "y"))
    assert(#items[2].children == 1)
    assert(Model.removeById(items, "f"))
    assert(#items == 2 and items[2].id == "b")
    assert(not Model.removeById(items, "zz"))
end)

t.test("insertAfter splices after anchor; nil anchor appends to top level", function()
    local items = fixture()
    Model.insertAfter(items, "a", { id = "n", type = "action", label = "N", action = { history = true } })
    assert(items[2].id == "n")
    Model.insertAfter(items, "x", { id = "m", type = "action", label = "M", action = { history = true } })
    assert(items[3].children[2].id == "m")
    Model.insertAfter(items, nil, { id = "p", type = "action", label = "P", action = { history = true } })
    assert(items[#items].id == "p")
end)

t.test("moveToFolder and moveToTopLevel", function()
    local items = fixture()
    assert(Model.moveToFolder(items, "a", "f"))
    assert(#items == 2 and items[1].id == "f")
    local f = items[1]
    assert(f.children[#f.children].id == "a")
    assert(Model.moveToTopLevel(items, "x"))
    assert(items[#items].id == "x")
    assert(not Model.moveToFolder(items, "f", "f"), "folders cannot be moved into folders")
end)

local eq = helpers.eq

t.test("imageIconName extracts NAME from [icon=NAME] whole-value tokens", function()
    eq(Model.imageIconName("[icon=heart]"), "heart")
    eq(Model.imageIconName("[icon= my-icon ]"), "my-icon")  -- trims spaces
    assert(Model.imageIconName("\xEE\xA5\x8A") == nil, "plain glyph -> nil")
    assert(Model.imageIconName("%batt_icon") == nil, "dynamic %token -> nil")
    assert(Model.imageIconName("[icon=]") == nil, "empty name -> nil")
    assert(Model.imageIconName("a[icon=x]b") == nil, "not a whole-value token -> nil")
    assert(Model.imageIconName(nil) == nil, "nil -> nil")
end)

t.done()
