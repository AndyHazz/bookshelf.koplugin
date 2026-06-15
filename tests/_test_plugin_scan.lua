-- Headless tests for lib/bookshelf_plugin_scan.lua
-- Focus: submenu-plugin launching (M.SUBMENU) plus the existing callback /
-- duplicate-prevention behaviour it must not regress.
package.path = "./?.lua;./?/init.lua;" .. package.path

-- plugin_scan reaches the live FM via package.loaded; build a fake instance
-- that mirrors FileManager's dual registration (array entries + named fields
-- pointing at the SAME module tables, so the reverse key map resolves).
local function module(name, build_entry)
    local mod = { name = name }
    function mod:addToMainMenu(items) items[name] = build_entry() end
    return mod
end

-- submenu-only (the Frotz shape): top entry has sub_item_table_func, no callback
local frotz = module("frotz", function()
    return {
        text = "Interactive Fiction",
        sub_item_table_func = function()
            return { { text = "Open game", callback = function() end } }
        end,
    }
end)
-- callback AND submenu: callback must win (priority / no duplicate entry)
local both = module("both", function()
    return {
        text = "Both",
        callback = function() end,
        sub_item_table = { { text = "x", callback = function() end } },
    }
end)
-- static sub_item_table only
local stat = module("stat", function()
    return { text = "Static", sub_item_table = { { text = "y", callback = function() end } } }
end)
-- callback only (the sokoban / casual-chess shape that already worked)
local cbonly = module("cbonly", function()
    return { text = "Game", callback = function() end }
end)
-- submenu field present but resolves to nil at launch (unresolvable)
local bad = module("bad", function()
    return { text = "Bad", sub_item_table_func = function() return nil end }
end)

local function installFM()
    local fm = {}
    local mods = { frotz, both, stat, cbonly, bad }
    for i, m in ipairs(mods) do fm[i] = m; fm[m.name] = m end
    package.loaded["apps/filemanager/filemanager"] = { instance = fm }
end

-- capture MenuHost.show calls (resolve's SUBMENU launcher hosts the submenu)
local shown = {}
package.loaded["lib/bookshelf_menu_host"] = {
    show = function(opts) shown[#shown + 1] = opts; return {} end,
}

installFM()

local Scan = dofile("lib/bookshelf_plugin_scan.lua")
local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()

local function methodFor(results, key)
    for _i, p in ipairs(results) do if p.key == key then return p.method end end
    return nil
end

t.test("M.SUBMENU sentinel is defined and distinct from the callback one", function()
    assert(Scan.SUBMENU == "__menu_submenu", "SUBMENU sentinel value")
    assert(Scan.SUBMENU ~= Scan.SENTINEL, "must differ from callback sentinel")
end)

t.test("scan() detects a submenu-only plugin via SUBMENU", function()
    local r = Scan.scan()
    assert(methodFor(r, "frotz") == Scan.SUBMENU, "frotz should resolve to SUBMENU")
    assert(methodFor(r, "stat") == Scan.SUBMENU, "static sub_item_table -> SUBMENU")
end)

t.test("callback wins over submenu (no duplicate / priority guard)", function()
    local r = Scan.scan()
    assert(methodFor(r, "both") == Scan.SENTINEL,
        "an entry with a callback AND a submenu must resolve to the callback")
    assert(methodFor(r, "cbonly") == Scan.SENTINEL,
        "callback-only plugins keep their existing detection")
    -- each plugin appears at most once
    local r2, seen = Scan.scan(), {}
    for _i, p in ipairs(r2) do
        assert(not seen[p.key], "duplicate scan entry for " .. p.key)
        seen[p.key] = true
    end
end)

t.test("scan() title comes from the menu entry text", function()
    local r = Scan.scan()
    for _i, p in ipairs(r) do
        if p.key == "frotz" then
            assert(p.title == "Interactive Fiction", "title from entry.text")
        end
    end
end)

t.test("exists() greys SUBMENU when module/addToMainMenu present or gone", function()
    assert(Scan.exists("frotz", Scan.SUBMENU) == true, "present module")
    assert(Scan.exists("nope", Scan.SUBMENU) == false, "absent module")
end)

t.test("resolve() SUBMENU returns a launcher that hosts the submenu", function()
    shown = {}
    local launch = Scan.resolve("frotz", Scan.SUBMENU)
    assert(type(launch) == "function", "resolve should return a launcher")
    launch()
    assert(#shown == 1, "launcher should host exactly one menu")
    assert(shown[1].title == "Interactive Fiction", "host title")
    assert(type(shown[1].item_table) == "table" and #shown[1].item_table == 1,
        "host item_table is the resolved submenu")
end)

t.test("resolve() SUBMENU returns nil when the submenu resolves to non-table", function()
    local launch = Scan.resolve("bad", Scan.SUBMENU)
    assert(launch == nil, "unresolvable submenu -> nil launcher")
end)

t.test("existing callback launching still resolves (no regression)", function()
    local launch = Scan.resolve("cbonly", Scan.SENTINEL)
    assert(type(launch) == "function", "callback sentinel still resolves")
end)

t.test("scan() detects a plugin whose menu key differs from its field key (#140)", function()
    -- KOReader copies _meta.lua's `name` onto the module and registers it
    -- under that, mangling the module's own name to "filemanager"..key. But
    -- addToMainMenu keys the entry off the plugin's lower-case name, so it
    -- matches neither the field key nor the mangled module name. The QuickRSS
    -- shape: field key "QuickRSS", module name "filemanagerQuickRSS", entry
    -- under "quickrss". The single entry is unambiguously the plugin's.
    local mod = { name = "filemanagerQuickRSS" }
    function mod:addToMainMenu(items)
        items.quickrss = { text = "QuickRSS", callback = function() end }
    end
    local fm = { mod }
    fm.QuickRSS = mod
    package.loaded["apps/filemanager/filemanager"] = { instance = fm }

    local r = Scan.scan()
    assert(methodFor(r, "QuickRSS") == Scan.SENTINEL,
        "single-entry plugin with a mismatched menu key must be detected")
    assert(type(Scan.resolve("QuickRSS", Scan.SENTINEL)) == "function",
        "resolve must re-find the single entry at launch time")
    installFM()  -- restore the shared fixture for any later tests
end)

t.test("scan() lifts a leading PUA icon glyph out of the title (#140)", function()
    -- Plugin prefixes its menu text with its own NerdFont glyph + spaces
    -- (the QuickRSS / Updates Manager pattern). U+F09E = "\xEF\x82\x9E".
    local glyphed = module("glyphed", function()
        return { text = "\xEF\x82\x9E  Feeds", callback = function() end }
    end)
    local plain = module("plain", function()
        return { text = "Plain Name", callback = function() end }
    end)
    local fm = {}
    for i, m in ipairs({ glyphed, plain }) do fm[i] = m; fm[m.name] = m end
    package.loaded["apps/filemanager/filemanager"] = { instance = fm }

    local r = Scan.scan()
    local function find(k) for _i, p in ipairs(r) do if p.key == k then return p end end end
    local g = find("glyphed")
    assert(g and g.icon == "\xEF\x82\x9E", "leading PUA glyph must become the icon")
    assert(g.title == "Feeds", "title must have the glyph + spaces stripped")
    local p = find("plain")
    assert(p and p.icon == nil, "a plain title must yield no icon")
    assert(p.title == "Plain Name", "a plain title must be left intact")
    installFM()
end)

t.done()
