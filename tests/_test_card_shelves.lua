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
    assert(card:find("Create new shelf", 1, true), "no way to make one")
    assert(card:find("Use existing shelf", 1, true), "no way to pick one")
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

-- Settings: rows nudge in place (a reopen flashes the screen), the heading's
-- two controls share a row, and small covers drop their badges.
t.test("the Shelf module's settings nudge rows in place", function()
    local card = src("micromodules/shelf.lua")
    local dlg = card:match("\nlocal function showSettings%(ctx%)\n(.-)\nend\n")
    assert(dlg, "showSettings not found")
    assert(dlg:find('id = "rows"', 1, true) and dlg:find("getButtonById", 1, true), "rows are not rewritten in place")
    assert(not dlg:find("showSettings(ctx)", 1, true), "the dialog still reopens itself")
    assert(dlg:find("Heading text[^\n]-\n.-id = \"heading\""), "heading controls are not on one row")
end)

t.test("small covers on a Shelf module drop their badges", function()
    local card = src("micromodules/shelf.lua")
    assert(card:find("no_badges = ", 1, true), "the module never asks")
    local row = src("lib/bookshelf_shelf_row.lua")
    assert(row:find("show_progress = not opts.no_badges", 1, true), "ShelfRow ignores no_badges")
    assert(row:find("suppress_favorite_badge = opts.no_badges", 1, true), "the favourite corner stays")
end)

-- The default card is warm paper, and a colour card stays coloured inside:
-- fill() would collapse it to its grey.
t.test("module cards are paper, and keep their colour inside", function()
    assert(src("lib/bookshelf_cover_progress.lua"):find('DEFAULT_MODULE_BG = { hex = "#F3EDE0" }', 1, true),
           "the default card is not paper")
    local clip = src("lib/bookshelf_clip_container.lua")
    assert(clip:find("paintRectRGB32", 1, true), "a colour card is flattened to grey inside")
end)

-- A cover's height follows its slot's width: one cover across a wide module
-- stood taller than its row and pushed the heading out over the next module.
t.test("a Shelf module's cover rows fit their height", function()
    local body = src("micromodules/shelf.lua"):match("\nlocal function coverBody%(.-\nend\n")
    assert(body and body:find("local row_w = math.min(w, n * math.floor((row_h - 2 * m) * 2 / 3)", 1, true),
           "slots are not capped by the row's height")
    assert(body:find("width = row_w", 1, true), "the row still takes the full width")
end)

-- On spines the heading hangs on the plank, as a section's label does, and
-- the module's planks cut their bevels back to what is behind them.
t.test("a spine Shelf module labels its plank and keeps its corners", function()
    local card = src("micromodules/shelf.lua")
    assert(card:find("plank_label = (r == 1) and label or nil", 1, true), "no label on the plank")
    assert(card:find("keep_ground = true", 1, true), "the planks still cut to white")
    local ss = src("lib/bookshelf_spine_shelf.lua")
    assert(ss:find("if opts.plank_label and opts.plank_label ~= \"\" and #badge_spans == 0", 1, true),
           "rowWidget ignores plank_label")
    assert(ss:find("keep_ground = opts.keep_ground", 1, true), "rowWidget does not pass keep_ground")
    assert(ss:find("bb:blitFrom(keep_l, cx, cy", 1, true), "the bevel is not cut back to what was there")
end)

t.done()
