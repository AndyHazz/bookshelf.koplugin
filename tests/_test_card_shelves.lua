-- tests/_test_card_shelves.lua
-- Card shelves (5.6, maintainer): a Shelf card can have a shelf of its own,
-- made from the card's settings and edited in the normal shelf editor (source,
-- filters, sort, style, and a plank of its own), which never shows on the
-- main screen: not in the chip bar, the Shelves list, swiping, the editor's
-- move arrows or the main screen's own checks. Removing the card removes it.
package.path = "./?.lua;./?/init.lua;" .. package.path
package.loaded["logger"] = { dbg = function() end, info = function() end,
                              warn = function() end, err = function() end }
local stored = {}
package.loaded["lib/bookshelf_settings_store"] = {
    read   = function(key, default) local v = stored[key]; if v == nil then return default end; return v end,
    save   = function(key, value) stored[key] = value end,
    saveDeferred = function(key, value) stored[key] = value end,
    delete = function(key) stored[key] = nil end,
    flush  = function() end,
    isTrue = function(key) return stored[key] == true end,
    nilOrTrue = function(key) return stored[key] == nil or stored[key] == true end,
}
_G.G_reader_settings = setmetatable({}, { __index = function() return function() end end })
local TabModel = dofile("lib/bookshelf_tab_model.lua")
local t = dofile("tests/_helpers.lua").runner()
local function src(p) return io.open(p):read("*a") end

local function seed()
    stored = {}
    TabModel.save({
        { id = "all", label = "Home", source = { kind = "library" }, enabled = true },
        { id = "custom_1", label = "Card", source = { kind = "recent" }, enabled = true, card_only = true },
        { id = "recent", label = "Recent", source = { kind = "recent" }, enabled = true },
    })
end

t.test("a card shelf is never one of the main screen's shelves", function()
    seed()
    local ids = {}
    for _i, tab in ipairs(TabModel.getActive()) do ids[#ids + 1] = tab.id end
    assert(table.concat(ids, ",") == "all,recent", table.concat(ids, ","))
    assert(TabModel.isCardOnly(TabModel.getById("custom_1")))
    assert(not TabModel.isCardOnly(TabModel.getById("all")))
end)

t.test("newCardShelf makes a pending, card-only shelf with a free id", function()
    seed()
    local tabs = TabModel.load()
    local nt = TabModel.newCardShelf(tabs)
    assert(nt.card_only == true and nt.pending == true and nt.id == "custom_2", nt.id)
    assert(nt.source and nt.source.kind == "none")
end)

t.test("the Shelves list in Settings leaves card shelves out", function()
    local f = src("lib/bookshelf_settings.lua"):match("\nfunction Settings:_tabsMenuItems%(.-\nend\n")
    assert(f and f:find("isCardOnly", 1, true), "Settings lists card shelves")
end)

t.test("the editor's move arrows step over card shelves", function()
    local ed = src("lib/bookshelf_chip_editor.lua")
    local n = 0
    for _ in ed:gmatch("isCardOnly") do n = n + 1 end
    assert(n >= 2, "the arrows' neighbour walks do not skip card shelves")
end)

t.test("the main screen's own checks leave card shelves out", function()
    assert(src("lib/bookshelf_ornament_deck.lua"):find("isCardOnly", 1, true), "ornament deck")
    local w = src("lib/bookshelf_widget.lua")
    local cap = w:match("\nfunction BookshelfWidget:_anyShelfShowsCaptions%(.-\nend\n")
    assert(cap and cap:find("isCardOnly", 1, true), "captions check")
end)

t.test("the card: its picker, its own shelf, and removal", function()
    local card = src("micromodules/shelf.lua")
    local rows = card:match("\nlocal function shelfRows%(.-\nend\n")
    assert(rows and rows:find("isCardOnly", 1, true), "the picker offers other cards' shelves")
    assert(card:find("New shelf for this card", 1, true), "no way to make one")
    assert(card:find("on_remove", 1, true), "removing the card leaves its shelf behind")
end)

t.test("removing a card tells its module", function()
    assert(src("lib/bookshelf_module_grid_session.lua"):find("Modules.notifyRemoved(it)", 1, true), "the layout editor")
    assert(src("lib/bookshelf_start_menu_edit.lua"):find("Modules.notifyRemoved(gone)", 1, true), "the long-press menu")
    local m = src("lib/bookshelf_start_menu_modules.lua"):match("\nfunction M%.notifyRemoved%(entry%)\n(.-)\nend\n")
    assert(m and m:find("on_remove", 1, true), "notifyRemoved does not reach the module")
end)

t.test("Shelf style offers a plank for card shelves only", function()
    local ed = src("lib/bookshelf_chip_editor.lua")
    assert(ed:find("draft.card_only", 1, true) and ed:find("Plank: %1", 1, true), "no Plank row")
end)

t.done()
