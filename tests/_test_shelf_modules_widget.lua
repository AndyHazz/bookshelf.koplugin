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
    -- gap_base too: the row layout starts each entry's gap from it, so a
    -- raised gap_before alone was undone (the book after a module touched it).
    assert(ins:find("nxt.gap_base = face_gap", 1, true), "the gap after a module is lost in the row layout")
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
    assert(f:find("SpineWidget.cardBackdrop(card_w, card_h, selected, bare)", 1, true), "no cover backdrop")
    assert(not f:find("FrameContainer", 1, true), "still framed square")
    local sw = io.open("lib/bookshelf_spine_widget.lua"):read("*a")
    assert(sw:find("function SpineWidget.cardBackdrop(card_w, card_h, selected, bare)", 1, true), "no backdrop helper")
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

-- The layout editor fades everything but the modules it can move, so it is
-- plain that taps on books and page swipes are off while it is up.
t.test("the layout editor fades all but the editable modules", function()
    local ed = io.open("lib/bookshelf_module_grid_editor.lua"):read("*a")
    local f = ed:match("\nfunction Editor:_fadeAround%(bb%)\n(.-)\nend\n")
    assert(f, "no fade")
    assert(f:find("b.page == self.session.page", 1, true), "keeps modules on other pages")
    -- In a copy of the screen, written back (a blend on a Kindle's
    -- framebuffer was ~650 ms on a PW5).
    assert(f:find("fade(c, 0, 0, W, H, Editor.FADE)", 1, true), "does not fade the screen, in a copy")
    assert(f:find("c:blitFrom(k.copy, k.x, k.y, 0, 0, k.w, k.h)", 1, true), "does not put the modules back")
    assert(f:find("bb:blitFrom(c, 0, 0, 0, 0, W, H)", 1, true) and f:find("self:_fadeFromCache(bb, cache_key, kx, ky, kw, kh)", 1, true),
        "the faded copy never reaches the screen")
    -- The top panel and full screen keep their whole grid, so the empty
    -- cells' dashed outlines stay clear; a cover shelf keeps only its
    -- modules (its grid is the books' slots).
    assert(f:find('if d and d.x and info.surface ~= "shelf" then', 1, true), "the empty cells are faded out")
    -- On a dark theme the fade goes towards black, as a module's own fade
    -- does (lightening it washed the dark screen to flat grey). Night mode
    -- paints cards pre-inverted, light, so it still lightens there.
    assert(f:find("local fade = Editor._fadeDark() and c.darkenRect or c.lightenRect", 1, true), "fades towards white on a dark theme")
    local dark = ed:match("\nfunction Editor%._fadeDark%(%)\n(.-)\nend\n")
    -- The theme, not the cards: a light shelf may have dark cards. Darkened
    -- paint shows dark only on a frame that doesn't invert, so it is the
    -- palette's own flip (the shelf wants dark, the frame doesn't invert).
    assert(dark and dark:find("local want_dark, inverting = CP.theme()", 1, true)
           and dark:find("return want_dark ~= inverting", 1, true), "doesn't follow the theme")
    local paint = ed:match("\nfunction Editor:paintTo%(bb, x, y%)\n(.-)\nend\n")
    local fade_at = paint and paint:find("self._fadeAround", 1, true)
    local footer_at = paint and paint:find("footer:paintTo", 1, true)
    assert(fade_at and footer_at and fade_at < footer_at, "the fade must come before the edit bar and toolbar")
end)

-- A spine module's page buttons: from the page ON SCREEN (a restored cursor
-- needn't sit on the page map's boundaries), the module goes first on the
-- next or previous page, and the shelf shows it there.
t.test("spine page moves land the module first on the next or previous page", function()
    local body = fn("_spineModulePageMove")
    assert(body, "no _spineModulePageMove")
    local src = body:gsub("^\nfunction BookshelfWidget:_spineModulePageMove%(id, dir%)", "return function(self, id, dir)")
    local move = assert(load(src, "move", "t", setmetatable({}, { __index = _G })))()
    local function shelf(cursor, next_item, mods)
        return {
            _cursor = cursor, _spine_next_item = next_item, _total_items = 100,
            _activeShelfModules = function() return mods end,
            _spinePageFirsts = function() return { 1, 7, 13, 19 } end,
        }
    end
    -- One module after 5 books: position 6. On screen: items 6..10 (cursor 6,
    -- the next page starts at item 11), off the page map's own boundaries.
    local mods = { { id = "m", after = 5, w = 2 } }
    local after, from = move(shelf(6, 6, mods), "m", 1)
    assert(after == 9 and from == 10, "next: after " .. tostring(after) .. " from " .. tostring(from))
    after, from = move(shelf(6, 6, mods), "m", -1)
    assert(after == 0 and from == 1, "previous: after " .. tostring(after) .. " from " .. tostring(from))
    assert(move(shelf(1, 6, { { id = "m", after = 0, w = 2 } }), "m", -1) == nil, "a previous page before the first")
    assert(move(shelf(96, 6, mods), "m", 1) == nil, "a next page past the end")
end)

-- The spine module menu: centred by an x worked out from its own width (a
-- missing x crashed KOReader v2026.03, which reads anchor.x at once; a Geom
-- would fill in x = 0) and clear of the module by a gap.
t.test("the spine module menu is centred and clear of the module", function()
    local m = fn("_spineModuleMenu")
    local a = m and m:match("anchor = function%(%)(.-)\n        end,")
    assert(a, "no anchor")
    a = a:gsub("%-%-[^\n]*", "")
    assert(not a:find("Geom:new", 1, true), "a Geom pins the menu to the left")
    assert(a:find("y = r.y - gap", 1, true) and a:find("h = r.h + 2 * gap", 1, true), "no gap round the module")
    assert(a:find("x = math.floor((Screen:getWidth() - cw) / 2)", 1, true), "not centred by its own x")
end)

-- The spine module menu stays open and updates in place (closing and
-- reopening it per tap flashed the whole screen), takes swipes on the module,
-- and the shelf's refresh after a change is the rows-only swap.
t.test("the spine module menu updates in place and takes swipes", function()
    local m = fn("_spineModuleMenu")
    assert(m, "no menu")
    assert(not m:find("bw:_spineModuleMenu(entry)", 1, true), "it still reopens itself")
    assert(m:find("d:getButtonById(key)", 1, true) and m:find("btn:enable()", 1, true), "buttons not updated in place")
    assert(m:find("d.ges_events.SwipeModule", 1, true) and m:find('ges.direction == "east"', 1, true), "no swipe on the module")
    local owner = fn("_shelfModuleOwner")
    local r = owner and owner:match("function owner.refresh%(%)(.-)\n    end")
    assert(r and r:find("bw:_swapShelvesInPlace()", 1, true), "no in-place swap")
    assert(not r:find("if not (bw._swapShelvesInPlace and bw:_swapShelvesInPlace())", 1, true), "still rebuilds after the swap")
end)

t.test("a bare module on a cover shelf stands on no cover shadow", function()
    -- An ornament drawn on a cover shelf sat on a cover's card shadow
    -- (maintainer, PW5). A bare module has no card: no backdrop, except the
    -- selection ring while the layout editor has it picked.
    local w = io.open("lib/bookshelf_widget.lua"):read("*a")
    local body = w:match("\nfunction BookshelfWidget:_moduleRow%(row, heads%)\n(.-)\nend\n")
    assert(body, "no _moduleRow")
    assert(body:find("local bare = def and def.bare", 1, true), "bare modules not told apart")
    assert(body:find("if SpineWidget.cardBackdrop and (selected or not bare) then", 1, true),
        "a bare module still gets the cover shadow")
    -- Picked, it gets the ring alone: the ring is a fill a card covers, and
    -- with no card the whole fill showed (rig).
    assert(body:find("SpineWidget.cardBackdrop(card_w, card_h, selected, bare)", 1, true))
    local sw = io.open("lib/bookshelf_spine_widget.lua"):read("*a")
    local bd = sw:match("\nfunction SpineWidget%.cardBackdrop%(card_w, card_h, selected, bare%)\n(.-)\nend\n")
    assert(bd and bd:find("ring_only = bare or nil", 1, true), "a bare module's ring is filled")
end)

t.done()
