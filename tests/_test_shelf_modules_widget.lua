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

-- Opening the editor on a layout that narrowed a module (3 columns: a
-- 3-wide module beside a book is drawn 2 wide) and saving without touching
-- it must keep the width it was given, not the narrowed one.
t.test("the editor keeps a module's width unless it was changed", function()
    local f = w:match("\nfunction BookshelfWidget:_shelfModuleHost%(%)\n(.-)\nend\n")
    assert(f and f:find("shown_w", 1, true), "the save does not know what width the editor opened with")
    local g = w:match("\nfunction BookshelfWidget:_shelfModuleGridInfo%(%)\n(.-)\nend\n")
    assert(g and g:find("self._shelf_module_shown_w", 1, true), "the grid info does not remember it")
end)

-- On a spine shelf a module stands like a face-out cover: a face-out's gap
-- either side, pushed back, its drawn height recorded for the shadow, and
-- the whole stand (it never lifts).
t.test("spine modules stand like face-out covers", function()
    local ss = io.open("lib/bookshelf_spine_shelf.lua"):read("*a")
    local ins = ss:match("if module_flats then\n        %-%- Back at their places(.-)\n    end\n")
    assert(ins, "module re-insertion not found")
    assert(ins:find("gap_before = face_gap", 1, true), "no face-out gap before a module")
    assert(ins:find("nxt.gap_before = face_gap", 1, true), "no face-out gap after a module")
    local tile = ss:match("\nfunction SpineShelf%._moduleTile%(e, stand_h, opts, push%)\n(.-)\nend\n")
    assert(tile, "_moduleTile does not take the push")
    assert(tile:find("e._drawn_h = cell_h", 1, true), "the shadow does not follow the drawn module")
    assert(not tile:find("0.08", 1, true), "still leaves lift headroom")
    assert(ss:find("foot = ((e.face_out or e.shelf_module) and inset or 0)", 1, true),
           "the shadow's foot is not pushed back with the module")
end)

-- A card-less module (a Shelf module, an ornament) is see-through: the
-- shelf's shading must carry on behind it, not stop round a blank box.
t.test("card-less modules leave the shelf shading alone", function()
    local ss = io.open("lib/bookshelf_spine_shelf.lua"):read("*a")
    assert(ss:find("elseif e.shelf_module and SpineShelf._bareModule(e.shelf_module) then", 1, true),
           "a bare module still blanks the shading behind it")
end)

-- On a cover shelf a module's card is a cover's card: the slots less the
-- shadow's room, a cover's height, standing on the covers' shadow or their
-- selection ring (a square frame round it left white wedges in the corners).
t.test("a cover-shelf module is sized and framed like a cover", function()
    local f = fn("_moduleRow")
    assert(f, "_moduleRow not found")
    assert(f:find("local card_h = math.max(1, (row.cover_h or sh) - off)", 1, true), "not a cover's height")
    assert(f:find("h.span * sw + (h.span - 1) * gap - off", 1, true), "not a cover's width")
    assert(f:find("SpineWidget.cardBackdrop(card_w, card_h, selected)", 1, true), "no cover backdrop")
    assert(not f:find("FrameContainer", 1, true), "still framed square")
    local sw = io.open("lib/bookshelf_spine_widget.lua"):read("*a")
    assert(sw:find("function SpineWidget.cardBackdrop(card_w, card_h, selected)", 1, true), "no backdrop helper")
end)

-- The editor's page buttons on a shelf: every shelf page is there to move
-- to, and the shelf follows the module to its new page; Shorter and Taller
-- are left out (one row tall), Narrower and Wider stay.
t.test("the shelf editor moves modules page by page, and the shelf follows", function()
    local h = fn("_shelfModuleHost")
    assert(h and h:find("host.shelf = true", 1, true), "the editor is not told it is on a shelf")
    assert(h:find("function host.max_pages()", 1, true), "no shelf page count for the editor")
    assert(h:find("bw._cursor = (edit.page - 1) * bw:_viewSize() + 1", 1, true), "the shelf does not follow the editor's page")
    local ed = io.open("lib/bookshelf_module_grid_editor.lua"):read("*a")
    assert(ed:find('if on_shelf and axis == "h" then return nil end', 1, true), "Shorter/Taller shown on a shelf")
    assert(not ed:find("if on_shelf and not can then return nil end", 1, true), "Narrower hidden at its limit")
    assert(ed:find("pageButton(Session.PAGE_PREV, -1)", 1, true) and ed:find("pageButton(Session.PAGE_NEXT, 1)", 1, true), "no page buttons")
    -- On a shelf: Narrower over Wider, two rows of four.
    local shelf_rows = ed:match("if on_shelf then(.-)\n        else")
    assert(shelf_rows, "no shelf layout")
    local r1 = shelf_rows:match("compact%((.-)compact%(")
    assert(r1 and r1:find("Narrower", 1, true) and not r1:find("Wider", 1, true), "Narrower and Wider share a row")
end)

t.done()
