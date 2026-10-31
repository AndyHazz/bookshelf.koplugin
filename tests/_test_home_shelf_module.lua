-- tests/_test_home_shelf_module.lua
-- A plugin with a module pack can offer, from something its reader chose
-- (Silverfish's welcome screen: "Card on home"), to put its module on the
-- reader's home shelf, the way it puts a card on Simple UI's home screen
-- (maintainer). Kit.setOnHomeShelf(key, on) / Kit.onHomeShelf(key), over
-- ShelfModules.homeShelf / onHome / setOnHome here.
--   - the home shelf is the first shelf on the chip strip that holds books:
--     not a hidden one, a sub-shelf, a card's own shelf or a shelf of shelves;
--   - on goes in first on that shelf, at the module's starting width, once;
--   - off takes every copy of it off that shelf and hands them back (for
--     the module's on_remove), touching no other module.
-- Run from the plugin root: lua tests/_test_home_shelf_module.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local t  = dofile("tests/_helpers.lua").runner()
local eq = dofile("tests/_helpers.lua").eq

package.loaded["lib/bookshelf_tab_model"] = {
    isShelves = function(tab) return type(tab.source) == "table" and tab.source.kind == "shelves" end,
}
local SM = dofile("lib/bookshelf_shelf_modules.lua")

local function shelves()
    return {
        { id = "off",    enabled = false, source = { kind = "all" } },
        { id = "parent", source = { kind = "shelves" } },
        { id = "child",  parent = "parent", source = { kind = "all" } },
        { id = "card",   card_only = true, source = { kind = "all" } },
        { id = "all",    source = { kind = "all" },
          shelf_modules = { { id = "sm_1", type = "module", module = "clock", after = 0, w = 2 } } },
        { id = "recent", source = { kind = "recent" } },
    }
end

t.test("home is the first shown shelf that holds books", function()
    eq(SM.homeShelf(shelves()).id, "all")
    eq(SM.homeShelf({ { id = "s", source = { kind = "shelves" } } }), nil)
    eq(SM.homeShelf({}), nil)
end)

t.test("on: first on the home shelf, at its starting width, once", function()
    local tabs = shelves()
    assert(not SM.onHome("pet", tabs))
    local changed, tab = SM.setOnHome("pet", true, tabs, 4)
    assert(changed and tab.id == "all")
    local mods = tab.shelf_modules
    eq(#mods, 2)
    local first = SM.ordered(mods)[1]
    eq(first.module, "pet"); eq(first.after, 0); eq(first.w, 4); eq(first.type, "module")
    assert(first.id and first.id ~= "sm_1", "its id is taken: " .. tostring(first.id))
    assert(SM.onHome("pet", tabs))
    changed = SM.setOnHome("pet", true, tabs, 4)
    assert(not changed); eq(#tab.shelf_modules, 2)
end)

t.test("on, on a shelf with no modules yet", function()
    local tabs = { { id = "home", source = { kind = "all" } } }
    assert(SM.setOnHome("pet", true, tabs, 3))
    eq(#tabs[1].shelf_modules, 1); eq(tabs[1].shelf_modules[1].id, "sm_1")
end)

t.test("off: every copy off the home shelf, nothing else", function()
    local tabs = shelves()
    SM.setOnHome("pet", true, tabs, 4)
    table.insert(tabs[5].shelf_modules, { id = "sm_9", type = "module", module = "pet", after = 7, w = 2 })
    local changed, tab, removed = SM.setOnHome("pet", false, tabs)
    assert(changed and tab.id == "all")
    eq(#removed, 2)
    eq(#tab.shelf_modules, 1); eq(tab.shelf_modules[1].module, "clock")
    assert(not SM.onHome("pet", tabs))
    changed = SM.setOnHome("pet", false, tabs)
    assert(not changed)
end)

t.test("no home shelf: nothing to do, no error", function()
    local tabs = { { id = "s", source = { kind = "shelves" } } }
    assert(not SM.onHome("pet", tabs))
    assert(not SM.setOnHome("pet", true, tabs, 4))
end)

-- The public names a plugin calls: they save, tell an open shelf, refuse a
-- module Bookshelf doesn't know, and hand removed copies to on_remove.
t.test("Kit.setOnHomeShelf saves, tells the shelf, and Kit.onHomeShelf reads it", function()
    local stored, saves, events, removed_seen = shelves(), 0, {}, {}
    local TM = package.loaded["lib/bookshelf_tab_model"]
    TM.load = function() return stored end
    TM.save = function(tabs) stored = tabs; saves = saves + 1 end
    package.loaded["lib/bookshelf_fonts"] = {}
    package.loaded["lib/bookshelf_start_menu_modules"] = {
        get = function(k) if k == "pet" then return { key = "pet", start_w = 4 } end end,
        notifyRemoved = function(m) removed_seen[#removed_seen + 1] = m.id end,
    }
    package.loaded["lib/bookshelf_shelf_modules"] = SM
    package.loaded["ui/uimanager"] = { broadcastEvent = function(_s, ev) events[#events + 1] = ev end }
    package.loaded["ui/event"] = { new = function(_s, name, arg) return { name = name, arg = arg } end }
    local Kit = dofile("lib/bookshelf_module_kit.lua")

    assert(not Kit.onHomeShelf("pet"))
    assert(Kit.setOnHomeShelf("pet", true))
    assert(Kit.onHomeShelf("pet"))
    eq(saves, 1); eq(#events, 1)
    eq(events[1].name, "BookshelfShelfModulesChanged"); eq(events[1].arg, "all")
    eq(SM.ordered(SM.homeShelf(stored).shelf_modules)[1].w, 4)
    assert(Kit.setOnHomeShelf("pet", true)); eq(saves, 1, "an unchanged shelf was saved again")
    assert(Kit.setOnHomeShelf("pet", false))
    assert(not Kit.onHomeShelf("pet"))
    eq(saves, 2); eq(#events, 2); eq(#removed_seen, 1)
    assert(not Kit.setOnHomeShelf("nosuch", true), "a module Bookshelf doesn't know went on the shelf")
    stored = { { id = "s", source = { kind = "shelves" } } }
    assert(not Kit.setOnHomeShelf("pet", true), "no home shelf, but it said done")
end)

-- The open shelf: rebuilds when it is the shelf that changed; covered by the
-- plugin's own screen, no refresh (the screen's close repaints it).
t.test("the shelf on screen rebuilds; another shelf, or a closed one, does nothing", function()
    local src = io.open("lib/bookshelf_widget.lua"):read("*a")
    local body = src:match("\nfunction BookshelfWidget:onBookshelfShelfModulesChanged%(tab_id%)\n(.-)\nend\n")
    assert(body, "could not find onBookshelfShelfModulesChanged - renamed?")
    local function run(bw, top)
        local seen = { rebuilds = 0, dirty = 0, invalidated = 0 }
        bw._rebuild = function() seen.rebuilds = seen.rebuilds + 1 end
        local env = setmetatable({
            UIManager = { getTopmostVisibleWidget = function() return top or bw end,
                          setDirty = function() seen.dirty = seen.dirty + 1 end },
            require = function(name)
                if name == "lib/bookshelf_underlay" then
                    return { invalidate = function() seen.invalidated = seen.invalidated + 1 end }
                end
                return require(name)
            end,
        }, { __index = _G })
        local f = (loadstring or load)("local self, tab_id = ...\n" .. body, "h", "t", env)
        if setfenv then setfenv(f, env) end
        f(bw, "all")
        return seen
    end
    local s = run({ chip = "all" })
    assert(s.rebuilds == 1 and s.dirty == 1 and s.invalidated == 0)
    s = run({ chip = "all" }, {})
    assert(s.rebuilds == 1 and s.dirty == 0 and s.invalidated == 1, "a covered shelf refreshed")
    s = run({ chip = "recent" })
    assert(s.rebuilds == 0 and s.dirty == 0)
    s = run({ chip = "all", _closed = true })
    assert(s.rebuilds == 0 and s.dirty == 0)
end)

t.done()
