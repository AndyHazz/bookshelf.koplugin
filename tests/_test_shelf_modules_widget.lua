-- tests/_test_shelf_modules_widget.lua
-- The shelf's side of shelf modules: settings save to the shelf, the spine
-- list carries them (and its cache key notices a change), the cover fetch
-- puts the cursor back, the range counts books, removal tells the module.
package.path = "./?.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()
local w = io.open("lib/bookshelf_widget.lua"):read("*a")
local function fn(name)
    return w:match("\nfunction BookshelfWidget[:.]" .. name:gsub("[%.%:]", "%%%0") .. "%(.-\nend\n")
end

t.test("a module's settings save onto its shelf, its place kept and nothing transient", function()
    local body = w:match("\nfunction BookshelfWidget:_shelfModuleOwner%(tab_id%)\n(.-)\nend\n")
    assert(body, "_shelfModuleOwner not found")
    local saved
    local tabs = { { id = "s", shelf_modules = { { id = "m", module = "clock", after = 4, w = 2 } } } }
    local env = {
        pairs = pairs, ipairs = ipairs, type = type,
        require = function() return { load = function() return tabs end, save = function(x) saved = x end } end,
        UIManager = { setDirty = function() end },
    }
    local owner = load("local self, tab_id = ...\n" .. body, "own", "t", env)({ }, "s")
    owner.save({ id = "m", module = "clock", after = 0, w = 6, twelve_hour = true, _drawn = 1 })
    local m = saved[1].shelf_modules[1]
    assert(m.twelve_hour == true, "the setting was not saved")
    assert(m.after == 4 and m.w == 2, "a settings save moved the module")
    assert(m._drawn == nil, "a transient field was saved")
end)

t.test("a spine shelf's list carries its modules, and a change is a new list", function()
    local f = fn("_spineCachedFetch")
    assert(f and f:find("insertItems(items, mods)", 1, true), "modules not put in the list")
    assert(f:find('key = key .. "|m:"', 1, true), "the cache key ignores the modules")
end)

t.test("the cover fetch asks from the page's first item and puts the cursor back", function()
    local f = fn("_fetchWithShelfModules")
    assert(f and f:find("self._cursor = before + 1", 1, true) and f:find("self._cursor = saved", 1, true))
    assert(f:find("pcall(self._fetchChipItems", 1, true), "a failed fetch would leave the cursor moved")
end)

t.test("a spine shelf's range counts books", function()
    local f = fn("_pageCounterText")
    assert(f and f:find("spineWindow(mods, 1)", 1, true))
end)

t.test("a module the layout editor removes tells its module", function()
    local f = w:match("\nfunction BookshelfWidget:_shelfModuleHost%(%)\n(.-)\nend\n")
    assert(f and f:find("notifyRemoved(m)", 1, true))
    local menu = fn("_spineModuleMenu")
    assert(menu and menu:find("Modules.notifyRemoved(l[i])", 1, true))
end)

t.test("the editor's grid places come back as order", function()
    local f = fn("_shelfModulesFromEdit")
    assert(f and f:find("afterFromSlots(placed)", 1, true))
end)

t.done()
