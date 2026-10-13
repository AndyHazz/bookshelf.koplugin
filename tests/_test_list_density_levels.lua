-- tests/_test_list_density_levels.lua
-- An Auto shelf listing on BOTH levels has list columns and rows per level
-- (5.4.4). ViewMode.listLevelsSplit / densityKeys decide which key a level
-- reads; the widget's real _chipListValue, _autoLevel and _setChipDensity are
-- extracted and run under stubs, as _test_list_view_gesture.lua does, so the
-- shelf is proven to ask the right question rather than the resolver alone.
--
-- Usage (from plugin root): lua tests/_test_list_density_levels.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t, eq = helpers.runner(), helpers.eq

local ViewMode = require("lib/bookshelf_view_mode")
local L, C, S = ViewMode.LIST, ViewMode.COVERS, ViewMode.SPINES

local function autoTab(l1, l2, extra)
    local tab = { id = "authors", view_mode = ViewMode.AUTO, view_level1 = l1, view_level2 = l2 }
    for k, v in pairs(extra or {}) do tab[k] = v end
    return tab
end

t.test("split only for Auto with List on both levels", function()
    eq(ViewMode.listLevelsSplit(autoTab(L, L)), true)
    eq(ViewMode.listLevelsSplit(autoTab(L, nil)), true, "Level 2 defaults to List")
    eq(ViewMode.listLevelsSplit(autoTab(nil, nil)), false, "Level 1 defaults to Covers")
    eq(ViewMode.listLevelsSplit(autoTab(L, C)), false)
    eq(ViewMode.listLevelsSplit(autoTab(S, L)), false)
    eq(ViewMode.listLevelsSplit({ view_mode = L }), false, "a List pin has one set")
    eq(ViewMode.listLevelsSplit(nil), false)
end)

t.test("densityKeys: Level 2 of a split shelf reads its own, then Level 1's", function()
    local tab = autoTab(L, L)
    eq({ ViewMode.densityKeys(tab, "list_rows", 2) }, { "list_rows_l2", "list_rows" })
    eq({ ViewMode.densityKeys(tab, "list_columns", 2) }, { "list_columns_l2", "list_columns" })
    eq({ ViewMode.densityKeys(tab, "list_rows", 1) }, { "list_rows" })
    eq({ ViewMode.densityKeys(autoTab(C, L), "list_rows", 2) }, { "list_rows" })
    eq({ ViewMode.densityKeys(tab, "spine_rows", 2) }, { "spine_rows" }, "list keys only")
end)

t.test("the expanded zoom has its own Level 2 key and never borrows Level 1's", function()
    eq({ ViewMode.densityKeys(autoTab(L, L), "list_rows_expanded", 2) }, { "list_rows_expanded_l2" })
end)

-- ── the widget ──────────────────────────────────────────────────────────────

local src = io.open("lib/bookshelf_widget.lua"):read("*a")
local function compile(code, env, name)
    if _G.setfenv then
        local f = assert(_G.loadstring(code, name)); _G.setfenv(f, env); return f
    end
    return assert(load(code, name, "t", env))
end
local function method(name, args, env)
    local body = src:match("\nfunction BookshelfWidget:" .. name .. "%(" .. args .. "%)\n(.-)\nend\n")
    assert(body, "could not find BookshelfWidget:" .. name .. " - renamed?")
    return compile("return function(self" .. (args ~= "" and (", " .. args) or "") .. ")\n"
        .. body .. "\nend", env, name)()
end

local tabs, global, saved
local env = {
    ViewMode = ViewMode, type = type, ipairs = ipairs,
    require = function(m)
        if m == "lib/bookshelf_tab_model" then
            return {
                getById = function(id) for _i, tb in ipairs(tabs) do if tb.id == id then return tb end end end,
                load = function() return tabs end,
                saveDeferred = function() saved = saved + 1 end,
            }
        end
        error("unexpected require " .. m)
    end,
    BookshelfSettings = {
        read = function(k) return global[k] end,
        saveDeferred = function(k, v) global[k] = v end,
    },
}
local chipListValue = method("_chipListValue", "key", env)
local autoLevel = method("_autoLevel", "", env)
local setDensity = method("_setChipDensity", "key, n", env)

local function shelf(drilled)
    local w = { chip = "authors" }
    w._isDrilledIn = function() return drilled end
    w._chipViewMode = function()
        local tb = env.require("lib/bookshelf_tab_model").getById(w.chip)
        return ViewMode.chipOverride(tb and tb.view_mode)
    end
    w._autoLevel = autoLevel
    w._chipListValue = chipListValue
    w._setChipDensity = setDensity
    return w
end

local function reset(tab)
    tabs, global, saved = { tab }, { list_rows = 4 }, 0
end

t.test("Level 2 shows its own numbers; Level 1 keeps its own", function()
    reset(autoTab(L, L, { list_rows = 6, list_columns = 2, list_rows_l2 = 9, list_columns_l2 = 1 }))
    eq(shelf(false):_chipListValue("list_rows"), 6)
    eq(shelf(false):_chipListValue("list_columns"), 2)
    eq(shelf(true):_chipListValue("list_rows"), 9)
    eq(shelf(true):_chipListValue("list_columns"), 1)
end)

t.test("unset, Level 2 follows Level 1, then the library default", function()
    reset(autoTab(L, L, { list_rows = 6 }))
    eq(shelf(true):_chipListValue("list_rows"), 6)
    reset(autoTab(L, L))
    eq(shelf(true):_chipListValue("list_rows"), 4)
end)

t.test("one level a list: one set, whatever the level", function()
    reset(autoTab(C, L, { list_rows = 6, list_rows_l2 = 9 }))
    eq(shelf(true):_chipListValue("list_rows"), 6)
end)

t.test("a pinch on Level 2 writes Level 2's number and leaves Level 1's", function()
    reset(autoTab(L, L, { list_rows = 6 }))
    shelf(true):_setChipDensity("list_rows", 8)
    eq(tabs[1].list_rows_l2, 8); eq(tabs[1].list_rows, 6); eq(saved, 1)
    shelf(false):_setChipDensity("list_rows", 3)
    eq(tabs[1].list_rows, 3); eq(tabs[1].list_rows_l2, 8)
end)

t.test("clearing Level 2's zoom does not hand it Level 1's", function()
    reset(autoTab(L, L, { list_rows_expanded = 10, list_rows_expanded_l2 = 7 }))
    shelf(true):_setChipDensity("list_rows_expanded", nil)
    eq(tabs[1].list_rows_expanded_l2, nil); eq(tabs[1].list_rows_expanded, 10)
    eq(shelf(true):_chipListValue("list_rows_expanded"), nil)
end)

t.test("a search inside an Auto shelf is not Level 2", function()
    reset(autoTab(L, L, { list_rows = 6, list_rows_l2 = 9 }))
    local w = shelf(true)
    w._chipViewMode = function() return nil end   -- search: no chip style
    eq(w:_chipListValue("list_rows"), 6)
end)

-- ── the dialog ──────────────────────────────────────────────────────────────

t.test("Shelf style offers a headed set per level only when both levels list", function()
    local ed = io.open("lib/bookshelf_chip_editor.lua"):read("*a")
    local block = ed:match("        if show_list then\n(.-)\n        end\n\n        if show_spines then")
    assert(block, "could not find the show_list block in Shelf style")
    assert(block:find('local split = ViewMode.listLevelsSplit(draft)', 1, true))
    assert(block:find('header(_("Level 1"))', 1, true) and block:find('header(_("Level 2"))', 1, true))
    assert(block:find('listRows(ViewMode.LEVEL2_SUFFIX, true)', 1, true))
    -- an unset Level 2 number shows the Level 1 number it follows
    assert(ed:find('if v == nil and inherit_key then v = draft[inherit_key] end', 1, true))
end)

t.done()
