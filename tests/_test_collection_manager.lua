-- tests/_test_collection_manager.lua
-- The collection editor (book menu > Tags > Collections Edit, the bulk
-- menu's Collections…, Manage collections) is the shelf editor's picker
-- widget, LibraryModal, so it has the same search row (issue 488: many
-- collections meant a lot of paging) and toggles in place.
-- Run from the plugin root: lua tests/_test_collection_manager.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local t  = dofile("tests/_helpers.lua").runner()
local eq = dofile("tests/_helpers.lua").eq

package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }
package.loaded["device"] = { screen = { getWidth = function() return 600 end,
                                        getHeight = function() return 800 end } }
local shown, closed = {}, {}
package.loaded["ui/uimanager"] = {
    show  = function(_self, w) shown[#shown + 1] = w end,
    close = function(_self, w)
        closed[#closed + 1] = w
        if w and w._on_close then w:_on_close() end
    end,
    setDirty = function() end,
}
local function widgetStub()
    return { new = function(_self, o) return o end }
end
package.loaded["ui/widget/buttondialog"] = widgetStub()
package.loaded["ui/widget/confirmbox"]   = widgetStub()
package.loaded["ui/widget/inputdialog"]  = { new = function(_self, o)
    function o.onShowKeyboard() end
    function o:getInputText() return self._typed end
    return o
end }

-- The modal: records its config; refresh counts the in-place redraws.
local modal
package.loaded["lib/bookshelf_library_modal"] = {
    new = function(_self, o)
        modal = o
        o.page, o.refreshes = 1, 0
        function o:refresh() self.refreshes = self.refreshes + 1 end
        -- UIManager:close runs the modal's on_closed, as LibraryModal does.
        function o:_on_close() if self.config.on_closed then self.config.on_closed() end end
        return o
    end,
}
-- The cell: what each collection is drawn as.
package.loaded["lib/bookshelf_picker_cell"] = {
    render = function(item, _dimen, o)
        return { label = item.label, subtitle = item.subtitle, count = item.count,
                 selected = o.selected, tint = o.tint }
    end,
}

-- Collections, in KOReader's order (not A to Z).
local RC = { default_collection_name = "favorites" }
local function reset()
    RC.coll = { favorites = { ["/b/fav.epub"] = true }, ["Zoology"] = {}, ["Book club 2024"] = {},
                ["Book club 2025"] = { ["/b/one.epub"] = true }, ["Alpha"] = {} }
    RC.coll_settings = { favorites = { order = 1 }, ["Zoology"] = { order = 2 },
        ["Book club 2024"] = { order = 3 }, ["Book club 2025"] = { order = 4 }, ["Alpha"] = { order = 5 } }
    RC.written, RC.saved = 0, nil
    shown, closed, modal = {}, {}, nil
end
function RC:_read() end
function RC:write() self.written = self.written + 1 end
function RC:getCollectionsWithFile(fp)
    local out = {}
    for name, c in pairs(self.coll) do if c[fp] then out[name] = true end end
    return out
end
function RC:isFileInCollection(fp, name) return self.coll[name] and self.coll[name][fp] == true end
function RC:addRemoveItemMultiple(fp, target) self.saved = { fp = fp, target = target } end
function RC:addCollection(name) self.coll[name] = {}; self.coll_settings[name] = { order = 99 } end
package.loaded["readcollection"] = RC

local CM = dofile("lib/bookshelf_collection_manager.lua")

local function names()
    local out = {}
    for i = 1, modal.config.item_count() do out[#out + 1] = modal.config.item_at(i) end
    return table.concat(out, ",")
end
local function cell(name) return modal.config.cell_renderer(name, {}) end

t.test("the editor is the picker's widget, with its search row", function()
    reset()
    CM.show{ book = { filepath = "/b/one.epub" } }
    assert(modal, "not shown in a LibraryModal")
    assert(not modal.config.no_search and modal.config.on_search_submit, "no search row")
    eq(modal.config.grid_cols, 2)
end)

t.test("collections are in KOReader's order, without Favorites", function()
    reset()
    CM.show{}
    eq(names(), "Zoology,Book club 2024,Book club 2025,Alpha")
end)

t.test("searching shows only the collections whose name matches, any case", function()
    reset()
    CM.show{}
    modal.config.on_search_submit("CLUB")
    eq(names(), "Book club 2024,Book club 2025")
    eq(modal.page, 1)
    modal.config.on_search_submit(nil)
    eq(names(), "Zoology,Book club 2024,Book club 2025,Alpha")
end)

t.test("book mode: a tap toggles in place, and Save writes the draft", function()
    reset()
    CM.show{ book = { filepath = "/b/one.epub" } }
    eq(cell("Book club 2025").selected, true, "the book's collection isn't shown selected")
    local before = modal.refreshes
    modal.config.on_cell_tap("Zoology")
    eq(#closed, 0, "the tap closed the dialog")
    assert(modal.refreshes > before, "the tap didn't redraw in place")
    eq(cell("Zoology").selected, true)
    eq(RC.written, 0, "a tap wrote before Save")
    modal.config.footer_rows[2][2].on_tap()          -- Save
    assert(RC.saved and RC.saved.target["Zoology"] and RC.saved.target["Book club 2025"])
    eq(RC.written, 1)
end)

t.test("book mode: a toggle survives a search that hides it", function()
    reset()
    CM.show{ book = { filepath = "/b/one.epub" } }
    modal.config.on_cell_tap("Zoology")
    modal.config.on_search_submit("club")
    modal.config.footer_rows[2][2].on_tap()
    assert(RC.saved.target["Zoology"], "the hidden toggle was lost")
end)

t.test("book mode: Save keeps the book's Favorites", function()
    reset()
    CM.show{ book = { filepath = "/b/fav.epub" } }
    modal.config.footer_rows[2][2].on_tap()
    assert(RC.saved.target.favorites, "Save un-favourited the book")
end)

t.test("bulk: a tap cycles add to all > remove from all > no change", function()
    reset()
    local diff
    CM.show{ bulk = true, paths = { "/b/one.epub", "/b/two.epub" }, on_save = function(d) diff = d end }
    eq(cell("Book club 2025").subtitle, "Mixed")
    modal.config.on_cell_tap("Alpha")
    eq(cell("Alpha").subtitle, "Add to all +"); eq(cell("Alpha").selected, true)
    modal.config.on_cell_tap("Alpha")
    eq(cell("Alpha").tint, true)
    modal.config.on_cell_tap("Alpha")
    eq(cell("Alpha").subtitle, nil)
    modal.config.on_cell_tap("Zoology")
    modal.config.footer_rows[2][2].on_tap()
    assert(diff and diff.add and diff.add.Zoology and diff.remove == nil)
    eq(RC.written, 0, "bulk wrote collections itself")
end)

t.test("manage mode: a tap opens the collection's Edit menu", function()
    reset()
    CM.show{}
    modal.config.on_cell_tap("Alpha")
    assert(shown[#shown].title and shown[#shown].title:find("Alpha", 1, true), "no Edit menu for the tap")
    assert(modal.config.cell_long_tap, "no long-press Edit menu")
end)

t.test("a new collection clears the search and is ticked in book mode", function()
    reset()
    CM.show{ book = { filepath = "/b/one.epub" } }
    modal.config.on_search_submit("club")
    modal.config.footer_rows[1][1].on_tap()          -- + New collection
    local dlg = shown[#shown]
    dlg._typed = "Gothic"
    dlg.buttons[1][2].callback()                     -- Create
    assert(names():find("Gothic", 1, true), "the new collection isn't in view")
    eq(cell("Gothic").selected, true)
end)

t.test("on_close runs once, however the dialog closes", function()
    reset()
    local n = 0
    CM.show{ book = { filepath = "/b/one.epub" }, on_close = function() n = n + 1 end }
    modal.config.footer_rows[2][1].on_tap()          -- Cancel
    eq(n, 1)
end)

t.done()
