-- tests/_test_widget_curated.lua
-- lib/bookshelf_widget_curated: the shelf's side of Curated shelves (issue
-- 390). A book moves along the shelf it stands on, among the pinned pieces;
-- it comes off; an ornament is stood beside it. The methods are installed on
-- a bare table here, with the real list module and the real step rules
-- behind them, and the tab model in memory.
package.path = "./?.lua;./?/init.lua;" .. package.path

local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq

package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }
package.loaded["ffi/util"] = { template = function(s, a) return (s:gsub("%%1", tostring(a))) end }
package.loaded["ui/uimanager"] = { setDirty = function() end, close = function() end, show = function() end }
package.loaded["device"] = { screen = { getWidth = function() return 600 end, scaleBySize = function(_s, n) return n end } }
package.loaded["readcollection"] = { default_collection_name = "favorites" }

-- The collection, in memory, with lib/bookshelf_curated's contract; and the
-- repository handing the shelf its books as the shelf's sort says.
local coll, orders
local epoch, fetches, unordered = 0, 0, false
package.loaded["lib/bookshelf_curated"] = {
    exists = function(name) return name == "mine" or name == "favorites" end,
    has = function(_n, fp) for _i, f in ipairs(coll) do if f == fp then return true end end return false end,
    remove = function(_n, fp)
        for i, f in ipairs(coll) do if f == fp then table.remove(coll, i); return true end end
        return false
    end,
    setOrder = function(_n, fps) coll = fps; orders = orders + 1; epoch = epoch + 1; unordered = false; return true end,
    books = function()
        local out = {}
        for i, f in ipairs(coll) do out[i] = f end
        return out
    end,
    ordered = function() return not unordered end,
}
package.loaded["lib/bookshelf_book_repository"] = {
    cacheEpoch = function() return epoch end,
    getBySource = function(_source, _filter, sort)
        fetches = fetches + 1
        local out = {}
        local rev = sort and sort[1] and sort[1].reverse
        for i = 1, #coll do
            local fp = rev and coll[#coll + 1 - i] or coll[i]
            -- A file the shelf does not show (gone from the device, not a book).
            -- A book the shelf's filter hides ("hid..."), with a filter on.
            if not fp:find("^gone") and not (filter_on and fp:find("^hid")) then
                out[#out + 1] = { filepath = fp }
            end
        end
        return out, #out
    end,
    invalidateBookCache = function() end,
}
package.loaded["lib/bookshelf_chip_editor"] = {
    sourceSortDefaults = function() return { { key = "collection_order", reverse = false } } end,
}

local tabs, saves
package.loaded["lib/bookshelf_tab_model"] = {
    load = function() return tabs end,
    save = function(tb) tabs = tb; saves = saves + 1 end,
    getById = function(id) for _i, x in ipairs(tabs) do if x.id == id then return x end end end,
    generation = function() return saves end,
    isCardOnly = function() return false end,
}
local filter_on = false
package.loaded["lib/bookshelf_filter"] = { isActive = function() return filter_on end }
-- The real module (it is plain list work): the swaps run through it.
package.loaded["lib/bookshelf_shelf_modules"] = dofile("lib/bookshelf_shelf_modules.lua")

local BW = {}
dofile("lib/bookshelf_widget_curated.lua")(BW)

local function shelf(opts)
    opts = opts or {}
    saves, orders, fetches = 0, 0, 0
    epoch = epoch + 1
    unordered = opts.unordered == true
    filter_on = opts.filter == true
    coll = {}
    for i, n in ipairs(opts.books or { "A", "B", "C", "D" }) do coll[i] = n end
    tabs = {
        { id = "home", label = "Home", source = { kind = "all" } },
        { id = "mine", label = "Mine", source = { kind = "collection", id = "mine" }, filter = {},
          sort_priority = opts.sort or { { key = "collection_order", reverse = opts.reversed == true } },
          shelf_modules = opts.mods },
        { id = "tag", label = "A tag", source = { kind = "collection", id = "space-opera" },
          sort_priority = { { key = "collection_order" } } },
    }
    local self = setmetatable({ chip = opts.chip or "mine", rebuilt = 0 }, { __index = BW })
    self._rebuild = function(s) s.rebuilt = s.rebuilt + 1 end
    self._swapShelvesInPlace = function(s) s.swapped = (s.swapped or 0) + 1 end
    self._viewSize = function() return 3 end
    self._expireSpineFetch = function(s) s.expired = (s.expired or 0) + 1 end
    self._isSpineMode = function() return opts.spines ~= false end
    self._viewMode = function() return opts.view or "spines" end
    self._activeShelfModules = function()
        if opts.pieces_hidden then return nil end
        return tabs[2].shelf_modules
    end
    tabs[2].series_boxes = opts.boxes
    return self
end
-- The shelf as it would stand: books by name, pieces by id.
local function look(self)
    local tab = tabs[2]
    local books = {}
    for i = 1, #coll do books[i] = tab.sort_priority[1].reverse and coll[#coll + 1 - i] or coll[i] end
    local by = {}
    for _i, m in ipairs(tab.shelf_modules or {}) do by[m.after] = by[m.after] or {}; table.insert(by[m.after], m.id) end
    local out = {}
    for _i, id in ipairs(by[0] or {}) do out[#out + 1] = id end
    for i, b in ipairs(books) do
        out[#out + 1] = b
        for _j, id in ipairs(by[i] or {}) do out[#out + 1] = id end
    end
    return table.concat(out, " ")
end
local function has(fp) for _i, f in ipairs(coll) do if f == fp then return true end end return false end

t.test("only a shelf with a collection behind it can be ordered by hand", function()
    local self = shelf({ chip = "home" })
    eq(self:_curatedList(), nil)
    eq((self:_curatedArrangeable()), false)
    eq(self:_curatedStep("A", 1), false)
    self = shelf({ chip = "tag" })       -- a pinned tag: kind "collection", no collection
    eq(self:_curatedList(), nil)
end)

t.test("a move writes the whole shelf's order to the collection, once", function()
    local self = shelf()
    self:_curatedStep("B", 1)
    eq(orders, 1)
    eq(table.concat(coll, " "), "A C B D")
end)

t.test("a step swaps the book with the one beside it", function()
    local self = shelf()
    eq(self:_curatedStep("B", 1), true)
    eq(look(self), "A C B D")
    eq(self:_curatedStep("B", -1), true)
    eq(look(self), "A B C D")
end)

t.test("a step at the shelf's end does nothing", function()
    local self = shelf()
    eq(self:_curatedStep("D", 1), false)
    eq(self:_curatedStep("A", -1), false)
    eq(self:_curatedCanStep("D", 1), false)
    eq(self:_curatedCanStep("D", -1), true)
    eq(look(self), "A B C D")
end)

t.test("a step past a pinned piece moves the piece, saved on the shelf's record", function()
    local self = shelf({ mods = { { id = "x", after = 2 } } })
    eq(look(self), "A B x C D")
    eq(self:_curatedStep("B", 1), true)
    eq(look(self), "A x B C D")
    eq(saves, 1)
    eq(self:_curatedStep("B", 1), true)
    eq(look(self), "A x C B D")
end)

t.test("on a reversed shelf right is still right on screen", function()
    local self = shelf({ reversed = true })
    eq(look(self), "D C B A")
    eq(self:_curatedStep("C", 1), true)
    eq(look(self), "D B C A")
    eq(table.concat(coll, " "), "A C B D", "the collection's own order is the reverse of the screen's")
    eq(self:_curatedToEdge("A", -1), true)
    eq(look(self), "A D B C")
end)

t.test("to the start and to the end, the pieces keeping their left-hand books", function()
    local self = shelf({ mods = { { id = "x", after = 1 } } })
    eq(look(self), "A x B C D")
    eq(self:_curatedToEdge("C", -1), true)
    eq(look(self), "C A x B D")
    eq(self:_curatedToEdge("C", 1), true)
    eq(look(self), "A x B D C")
    eq(self:_curatedToEdge("C", 1), false, "already there")
    -- A piece standing first: the first BOOK can still go to the start.
    self = shelf({ mods = { { id = "w", after = 0 } } })
    eq(look(self), "w A B C D")
    eq(self:_curatedAtEdge("A", -1), false)
    eq(self:_curatedToEdge("A", -1), true)
    eq(look(self), "A w B C D")
    eq(orders, 0, "the books did not move: the collection is not rewritten")
    eq(self:_curatedAtEdge("A", -1), true)
end)

t.test("taking a book off closes the pieces up behind it", function()
    local self = shelf({ mods = { { id = "x", after = 2 } } })
    eq(self:_curatedTakeOff("B"), true)
    eq(look(self), "A x C D")
    eq(has("B"), false)
    eq(self:_curatedTakeOff("B"), false)
end)

t.test("an ornament stands to the right of the book, touching it", function()
    local self = shelf({ mods = { { id = "sm_1", after = 2 } } })
    local m = self:_curatedStandPiece("B", { name = "Cats/Lucky Cat", tap = "zoom" })
    assert(m, "nothing made")
    eq(m.module, "ornament"); eq(m.ornament, "Cats/Lucky Cat"); eq(m.after, 2); eq(m.id, "sm_2")
    eq(look(self), "A B sm_2 sm_1 C D")
end)

t.test("an ornament on a shelf with no pieces yet makes the list", function()
    local self = shelf()
    assert(self:_curatedStandPiece("A", { name = "p" }))
    eq(look(self), "A sm_1 B C D")
end)

t.test("a shelf sorted another way cannot be arranged by hand, and says why", function()
    local self = shelf({ sort = { { key = "title" } } })
    local ok, why = self:_curatedArrangeable()
    eq(ok, false); eq(why, "sort")
    eq(self:_curatedStep("A", 1), false)
    eq(self:_curatedPlace("A"), nil)
    self:_curatedUseShelfOrder()
    eq((self:_curatedArrangeable()), true)
end)

-- Maintainer, PW5: a Home shelf on a collection, filtered to hide On hold
-- books, opened the book menu on a long-press, not Arrange. A book the
-- filter hides keeps its slot in the collection (writeOrder), as a file gone
-- from the device does, so a filter is no reason to stop.
t.test("one with a filter can be arranged; a book it hides keeps its place", function()
    local self = shelf({ filter = true, books = { "A", "hid1", "B", "C" } })
    eq((self:_curatedArrangeable()), true)
    eq(self:_curatedStep("B", 1), true)
    eq(table.concat(coll, " "), "A hid1 C B")
    eq(self:_curatedTakeOff("A"), true)
end)

t.test("a collection KOReader sorts itself is not rearranged without being asked", function()
    -- The first move used to write the order on screen as the collection's
    -- and switch KOReader's own sorting of it off, with no word.
    local self = shelf({ unordered = true })
    local ok, why = self:_curatedArrangeable()
    eq(ok, false); eq(why, "unordered")
    eq(self:_curatedStep("A", 1), false)
    eq(orders, 0, "the collection was rewritten unasked")
    -- Asked: the order on screen becomes the collection's, and moves work.
    eq(self:_curatedStartOrder(), true)
    eq(orders, 1)
    eq(table.concat(coll, " "), "A B C D")
    eq((self:_curatedArrangeable()), true)
    eq(self:_curatedStep("A", 1), true)
end)

t.test("the shelf's order is read once between changes, however often it is asked", function()
    -- A step asked for it five times, each building a record a book.
    local self = shelf()
    fetches = 0
    self:_curatedPlace("A"); self:_curatedPlace("B"); self:_curatedCanStep("A", 1); self:_curatedAtEdge("D", 1)
    eq(fetches, 1)
    self:_curatedStep("A", 1)
    self:_curatedPlace("A"); self:_curatedCanStep("A", 1)
    eq(fetches, 2, "once more after the change, and no more")
    eq(look(self), "B A C D")
end)

t.test("a book can be sent straight to another book's place", function()
    -- Tap where it should go: stepping a book twenty places is twenty waits.
    local self = shelf({ books = { "A", "B", "C", "D", "E" } })
    eq(self:_curatedMoveTo("A", "D"), true)
    eq(look(self), "B C D A E")
    eq(orders, 1, "one write, however far it went")
    eq(self:_curatedMoveTo("E", "B"), true)
    eq(look(self), "E B C D A")
    eq(self:_curatedMoveTo("E", "E"), false)
    eq(self:_curatedMoveTo("E", "nope"), false)
    eq(self:_curatedMoveTo("nope", "E"), false)
end)

t.test("sent to another place, the pieces keep the books on their left", function()
    local self = shelf({ books = { "A", "B", "C", "D" }, mods = { { id = "x", after = 2 } } })
    eq(look(self), "A B x C D")
    eq(self:_curatedMoveTo("D", "A"), true)
    eq(look(self), "D A B x C")
    eq(self:_curatedMoveTo("D", "C"), true)
    eq(look(self), "A B x C D")
end)

t.test("on a reversed shelf it lands where it was sent on screen", function()
    local self = shelf({ books = { "A", "B", "C", "D" }, reversed = true })
    eq(look(self), "D C B A")
    eq(self:_curatedMoveTo("D", "A"), true)
    eq(look(self), "C B A D")
end)

t.test("a move expires the spine shelf's own list, or the old order is redrawn", function()
    local self = shelf()
    self:_curatedStep("A", 1); self:_curatedShow("A")
    assert((self.expired or 0) >= 1, "the 30 second list cache was left to serve the old order")
end)

t.test("pieces that are not on screen do not swallow a step", function()
    -- List view, or Modules > On the shelf off: the list is still on the
    -- shelf's record, and a step used to hop a piece nobody could see.
    local self = shelf({ mods = { { id = "x", after = 1 } }, pieces_hidden = true })
    eq(self:_curatedStep("A", 1), true)
    eq(table.concat(coll, " "), "B A C D", "the book did not move")
end)

t.test("a book the shelf does not show keeps its place in the collection", function()
    -- A file gone from the device stays in the collection; a move used to
    -- push it to the end of KOReader's own view of it.
    local self = shelf({ books = { "A", "gone1", "B", "C" } })
    eq(self:_curatedStep("C", -1), true)
    eq(table.concat(coll, " "), "A gone1 C B")
    self = shelf({ books = { "A", "gone1", "B", "C" }, reversed = true })
    eq(self:_curatedStep("C", 1), true)       -- screen: C B A > B C A
    eq(table.concat(coll, " "), "A gone1 C B")
end)

t.test("a shelf that boxes series cannot be placed book by book, in any view", function()
    local self = shelf({ boxes = "spines" })
    local ok, why = self:_curatedArrangeable()
    eq(ok, false); eq(why, "boxes")
    self = shelf({ boxes = true, spines = false })     -- covers and lists box too
    ok, why = self:_curatedArrangeable()
    eq(ok, false); eq(why, "boxes")
end)

t.test("a move made here stands: the pieces do not snap back to their old books", function()
    -- X Y [p] C, X stepped right: Y X [p] C. Reading the pieces again used
    -- to send p back beside Y (Y [p] X C): one press passed a book AND a piece.
    local self = shelf({ books = { "X", "Y", "C" }, mods = { { id = "p", after = 2 } } })
    self:_curatedPieces()
    eq(self:_curatedStep("X", 1), true)
    self:_curatedPieces()
    eq(look(self), "Y X p C")
    -- Right then left is a round trip.
    eq(self:_curatedStep("X", -1), true)
    self:_curatedPieces()
    eq(look(self), "X Y p C")
    -- To the start, and sent to a place, stand too.
    self = shelf({ books = { "A", "B", "C" }, mods = { { id = "p", after = 2 } } })
    self:_curatedPieces()
    eq(self:_curatedToEdge("B", -1), true)
    self:_curatedPieces()
    eq(look(self), "B A p C")
    eq(self:_curatedMoveTo("C", "B"), true)
    self:_curatedPieces()
    eq(look(self), "C B A p")
end)

t.test("pieces follow their books when the collection changed somewhere else", function()
    local self = shelf({ mods = { { id = "x", after = 2 } } })     -- A B [x] C D
    self:_curatedPieces()                                           -- first shown: anchored to B
    table.insert(coll, 1, "N"); epoch = epoch + 1                   -- KOReader's own view added N first
    local mods = self:_curatedPieces()
    eq(mods[1].after, 3, "the piece slid to between A and B")
    eq(look(self), "N A B x C D")
end)

t.test("showing a book turns to its page and picks it out", function()
    local self = shelf({ books = { "A", "B", "C", "D", "E", "F", "G" }, spines = false })
    self._cursor = 1
    self:_curatedShow("E")          -- view of 3: page two starts at 4
    eq(self._cursor, 4)
    eq(self._tap_selected_fp, "E")
    eq(self.swapped, 1, "the rows were not redrawn")
    eq(self.rebuilt, 0, "the whole shelf was rebuilt for one book's move")
    self:_curatedShow("F")          -- same page: stays
    eq(self._cursor, 4)
    self:_curatedShow("A")
    eq(self._cursor, 1)
end)

-- ── Face out or spine out, book by book ───────────────────────────────────

t.test("a spine shelf set to Choose for each book offers the choice; others do not", function()
    local self = shelf()
    tabs[2].spine_face_out = { chosen = true }
    eq(self:_curatedFaceChoice(), true)
    tabs[2].spine_face_out = { favorites = true }
    eq(self:_curatedFaceChoice(), false, "a shelf facing out by reasons")
    tabs[2].spine_face_out = nil
    eq(self:_curatedFaceChoice(), false)
    self = shelf({ spines = false })
    tabs[2].spine_face_out = { chosen = true }
    eq(self:_curatedFaceChoice(), false, "covers or a list: nothing to turn")
    self = shelf({ chip = "home" })
    eq(self:_curatedFaceChoice(), false)
end)

t.test("every book faces out until it is turned; turning it is saved on the shelf", function()
    local self = shelf()
    tabs[2].spine_face_out = { chosen = true }
    eq(self:_curatedFacesOut("B"), true)
    eq(self:_curatedSetFaceOut("B", false), true)
    eq(saves, 1)
    eq(self:_curatedFacesOut("B"), false)
    eq(self:_curatedFacesOut("A"), true)
    eq(tabs[2].spine_face_out.spine.B, true)
    eq(self:_curatedSetFaceOut("B", false), false, "already spine out")
    eq(saves, 1, "nothing changed, nothing saved")
    eq(self:_curatedSetFaceOut("B", true), true)
    eq(self:_curatedFacesOut("B"), true)
    eq(tabs[2].spine_face_out.spine.B, nil, "a table that only grows")
    eq(orders, 0, "the collection's order was written for a turn")
end)

t.test("a shelf not set to choose is left alone by a turn", function()
    local self = shelf()
    tabs[2].spine_face_out = { favorites = true }
    eq(self:_curatedSetFaceOut("B", false), false)
    eq(saves, 0)
    eq(tabs[2].spine_face_out.spine, nil)
end)

t.test("a book taken off the shelf takes its turn with it", function()
    local self = shelf()
    tabs[2].spine_face_out = { chosen = true }
    self:_curatedSetFaceOut("B", false)
    self:_curatedTakeOff("B")
    eq(tabs[2].spine_face_out.spine.B, nil, "added again later it would come back spine out")
end)

t.test("a redraw drops the composed pages kept for page turns", function()
    -- Maintainer, on the PW5: Face out turned a book once and then seemed
    -- dead. The page cache's key knows nothing of which books are turned, so
    -- the shelf was handed the picture from before the press.
    local self = shelf()
    local cleared = 0
    self._pageCacheClear = function() cleared = cleared + 1 end
    self:_curatedRedraw()
    eq(cleared, 1)
    eq(self.swapped, 1)
end)

-- ── Arranging: books and pinned pieces, one way of working ────────────────

t.test("the piece drawn under a point is found, by the shelf's own record of it", function()
    local self = shelf({ mods = { { id = "sm_1", module = "ornament", ornament = "cactus.png", after = 1 },
                                  { id = "sm_2", module = "ornament", ornament = "fern.png", after = 3 } } })
    local function rect(x) return { x = x, y = 500, w = 100, h = 300 } end
    self._spine_module_cells = { sm_1 = { dimen = rect(200) }, sm_2 = { dimen = rect(700) },
                                 sm_gone = { dimen = rect(400) } }   -- unpinned since: no record
    local function at(x)
        return { x = x, y = 600, intersectWith = function(p, r)
            return p.x >= r.x and p.x < r.x + r.w and p.y >= r.y and p.y < r.y + r.h end }
    end
    eq(self:_shelfPieceAt(at(250)).id, "sm_1")
    eq(self:_shelfPieceAt(at(750)).ornament, "fern.png")
    eq(self:_shelfPieceAt(at(450)), nil, "a piece that is no longer on the shelf")
    eq(self:_shelfPieceAt(at(50)), nil)
    self._spine_module_cells = nil
    eq(self:_shelfPieceAt(at(250)), nil, "covers or a list: no pieces drawn this way")
end)

local WSRC = io.open("lib/bookshelf_widget_curated.lua"):read("*a")
local MSRC = io.open("lib/bookshelf_widget.lua"):read("*a")

t.test("arranging a book: a tap on a pinned piece opens that piece's menu", function()
    local menu = WSRC:match("\nfunction BookshelfWidget:_curatedMoveMenu%(book%)\n(.-)\nend\n")
    assert(menu, "_curatedMoveMenu moved")
    local tap = menu:match("local function onTapPiece%(ges%)(.-)\n    end\n")
    assert(tap, "a tap on a piece closes the menu and nothing more (maintainer)")
    assert(tap:find("bw:_shelfPieceAt(ges.pos)", 1, true))
    assert(tap:find("d:_dismiss()", 1, true), "the book stays lifted under the piece's menu")
    assert(tap:find("bw:_spineModuleMenu(piece)", 1, true))
    -- Ahead of "a tap on another book": a piece is not a place to put one.
    local a, b = menu:find('ev.ges == "tap" and onTapPiece(ev)', 1, true), menu:find('ev.ges == "tap" and onTapBook(ev)', 1, true)
    assert(a and b and a < b, "the piece's tap is not tried first")
    -- A long-press on a piece swaps the two now (maintainer); see below.
    assert(menu:find('ev.ges == "hold" and onHoldPiece(ev)', 1, true), "a long-press on a piece does nothing")
end)

t.test("a piece's menu: a tap on a book of a hand-ordered shelf picks that book up", function()
    local menu = MSRC:match("\nfunction BookshelfWidget:_spineModuleMenu%(entry%)\n(.-)\nend\n")
    assert(menu, "_spineModuleMenu moved")
    local tap = menu:match("local function onTapOther%(ges%)(.-)\n    end\n")
    assert(tap, "from a piece's menu there is no way to a book but closing it")
    assert(tap:find("bw:_shelfPieceAt(ges.pos)", 1, true), "nor to another piece")
    assert(tap:find("bw:_curatedMoveMenu(", 1, true))
    assert(tap:find("bw:_curatedList()", 1, true), "offered on a shelf whose books cannot be arranged")
    -- A tap switches; a hold swaps now (onHoldOther).
    assert(menu:find('ev.ges == "tap" and onTapOther(ev)', 1, true))
end)

t.test("the two menus are laid out alike: move first, then what else it can do", function()
    local menu = MSRC:match("\nfunction BookshelfWidget:_spineModuleMenu%(entry%)\n(.-)\nend\n")
    local page = menu:match("local function page%(%)(.-)\n    end\n    d = require")
    assert(page, "the piece menu's page moved")
    local move = page:find('{ type = "chips", fill = true, items = {', 1, true)
    local acts = page:find('blocks[#blocks + 1] = { type = "chips", items = bar }', 1, true)
    assert(move and acts and move < acts, "the piece's actions lead its menu; the book's follow the move buttons")
    -- No heading over the buttons in either (maintainer): the title names the menu.
    assert(not menu:find('_("Move it', 1, true))
    assert(not WSRC:find('_("Move it', 1, true))
    assert(not page:find('strip[#strip + 1] = { type = "chips", items = bar }', 1, true))
end)

t.test("Add ornament wears the ornaments' own icon, the coffee cup", function()
    -- Maintainer: a flower pot stood there; everywhere else ornaments are
    -- the cup (bookshelf_ornaments.COLLECTION_ICON).
    local menu = WSRC:match("\nfunction BookshelfWidget:_curatedMoveMenu%(book%)\n(.-)\nend\n")
    -- Maintainer: "'Ornament beside it..' could just be 'Add ornament...'"
    local line = menu:match('[^\n]*_%("Add ornament"%)[^\n]*')
    assert(line and line:find("icon = UI.ICON_ORNAMENT", 1, true), line)
    assert(not WSRC:find("E949", 1, true), "the flower is still used")
    local ui = io.open("lib/bookshelf_curated_ui.lua"):read("*a")
    assert(ui:find('UI.ICON_ORNAMENT = "\\u{F0F4}"', 1, true), "not the cup")
    local orn = io.open("lib/bookshelf_ornaments.lua"):read("*a")
    assert(orn:find('COLLECTION_ICON = "\\u{F0F4}"', 1, true) or orn:find("COLLECTION_ICON", 1, true),
        "the ornaments' icon moved: keep the two the same")
end)

-- ── A book stepped across a page boundary ─────────────────────────────────
-- Maintainer, on the PW5: a book at the end of page 1, stepped right, came up
-- SECOND on page 2; stepped back left it was on neither page shown. The rig
-- traced it: _curatedShow put the page start on the book (10), then the
-- shelf's refetch "anchored" the cursor to where the OLD page-2 first book
-- now stood (9), as it does for a list that reordered itself.

local function spineShelf(books, cursor, shown, firsts)
    local self = shelf({ books = books })
    local calls = {}
    self._cursor, self._spine_shown = cursor, shown
    self._expireSpineFetch = function() calls[#calls + 1] = "expire" end
    self._spineCachedFetch = function() calls[#calls + 1] = "fetch" end
    self._spinePageFirsts = function(_s, build)
        calls[#calls + 1] = build and "map" or "peek"
        return firsts
    end
    self._syncPageFromCursor = function() end
    self._swapShelvesInPlace = function(s)
        s.swapped = (s.swapped or 0) + 1
        s.kept_during_swap = s._spine_keep_cursor
    end
    return self, calls
end
local NINE = { "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N" }

t.test("stepped off the page's end, the book leads the next page", function()
    -- Page 1 shows nine; the book is now 10th, the first of page 2.
    local self, calls = spineShelf(NINE, 1, 9, { 1, 10 })
    self:_curatedShow("J")
    eq(self._cursor, 10)
    -- The map is of the NEW order: the list is fetched again before it is asked.
    local seq = table.concat(calls, " ")
    local e, f, m = seq:find("expire", 1, true), seq:find("fetch", 1, true), seq:find("map", 1, true)
    assert(e and f and m and e < f and f < m, "page starts read from the list before the move: " .. seq)
end)

t.test("stepped back over the page's start, the view follows to the page before", function()
    local self = spineShelf(NINE, 10, 5, { 1, 10 })
    self:_curatedShow("I")      -- 9th: the last of page 1
    eq(self._cursor, 1)
end)

t.test("the page breaks moved with the book: the page starts where the new map says", function()
    -- The book is the page's first (10th) but page 1 now holds ten: page 2
    -- starts at 11, and the book is the last of page 1.
    local self = spineShelf(NINE, 10, 5, { 1, 11 })
    self:_curatedShow("J")
    eq(self._cursor, 1)
end)

t.test("a move inside the page builds no page map", function()
    -- The map plans the whole shelf: not for a step that leaves the page be.
    local self, calls = spineShelf(NINE, 1, 9, { 1, 10 })
    self:_curatedShow("D")
    eq(self._cursor, 1)
    assert(not table.concat(calls, " "):find("map", 1, true), "the whole shelf planned for a mid-page step")
end)

t.test("the page chosen for a moved book is not re-anchored by the refetch", function()
    local self = spineShelf(NINE, 1, 9, { 1, 10 })
    self:_curatedShow("J")
    eq(self.kept_during_swap, true, "the shelf's refetch may move the cursor back")
    eq(self._spine_keep_cursor, nil, "left set: a later refetch that should anchor would not")
    local fetch = MSRC:match("\nfunction BookshelfWidget:_spineCachedFetch%(n%)\n(.-)\nend\n")
    assert(fetch, "_spineCachedFetch moved")
    assert(fetch:find("if not self._spine_keep_cursor then\n            self:_anchorSpineCursor(c.items, items)", 1, true),
        "the anchor runs whatever was asked")
end)

-- ── A book to the next or the previous page ───────────────────────────────

-- The shelf's list as the spine fetch keeps it: books in shelf order, a
-- piece standing after so many of them.
local function cacheList(self, books, mods)
    local out = {}
    for i = 0, #books do
        for _j, m in ipairs(mods or {}) do
            if (m.after or 0) == i then out[#out + 1] = { shelf_module = m } end
        end
        if i < #books then out[#out + 1] = { filepath = books[i + 1] } end
    end
    self._spine_fetch_cache = { items = out }
end
local function order() return table.concat(coll, " ") end

t.test("next page: the book goes first on the page after, by the breaks without it here", function()
    local self = spineShelf(NINE, 1, 9, { 1, 10 })
    cacheList(self, NINE)
    local planned
    self._spineFirstsOf = function(_s, items) planned = #items; return { 1, 10 } end
    eq(self:_curatedToPage("D", 1), true)
    eq(planned, 13, "the breaks were worked out with the book still on this page")
    eq(order(), "A B C E F G H I J D K L M N")
    eq(orders, 1, "one write")
end)

t.test("previous page: first on the page before", function()
    local self = spineShelf(NINE, 10, 5, { 1, 10 })
    cacheList(self, NINE)
    eq(self:_curatedToPage("L", -1), true)
    eq(order(), "L A B C D E F G H I J K M N")
end)

t.test("no page that way: nothing moves, nothing is written", function()
    local self = spineShelf(NINE, 1, 9, { 1, 10 })
    cacheList(self, NINE)
    self._spineFirstsOf = function() return { 1 } end
    eq(self:_curatedToPage("D", 1), false)
    eq(self:_curatedToPage("D", -1), false, "already on the first page")
    eq(orders, 0)
    eq(self:_curatedCanPage("D", -1), false)
end)

t.test("next page: a piece standing first on that page lets the book lead", function()
    -- A piece after the 8th book left: it opens page 2 (position 9 of the
    -- list without the book). The book goes in front of it.
    local mods = { { id = "sm_1", module = "ornament", ornament = "c.png", after = 9 } }
    local self = shelf({ books = NINE, mods = mods })
    self._cursor, self._spine_shown = 1, 9
    self._expireSpineFetch, self._spineCachedFetch = function() end, function() end
    self._spinePageFirsts = function() return { 1, 9 } end
    self._syncPageFromCursor = function() end
    cacheList(self, NINE, mods)
    self._spineFirstsOf = function() return { 1, 9 } end
    eq(self:_curatedToPage("D", 1), true)
    eq(order(), "A B C E F G H I D J K L M N")
    eq(tabs[2].shelf_modules[1].after, 9, "the piece is in front of the book: it leads the page")
end)

t.test("covers and lists page by a fixed count", function()
    local self = shelf({ books = { "A", "B", "C", "D", "E", "F", "G" }, spines = false, pieces_hidden = true })
    self._cursor = 1
    eq(self:_curatedToPage("B", 1), true)        -- three a page: first of page 2 is place 4
    eq(order(), "A C D B E F G")
    eq(self:_curatedToPage("E", -1), true)       -- E is 5th, on page 2: first of page 1
    eq(order(), "E A C D B F G")
    eq(self:_curatedToPage("G", 1), false, "the last page")
    eq(self:_curatedCanPage("E", -1), false); eq(self:_curatedCanPage("E", 1), true)
end)

t.test("the Arrange menu's buttons do one of three things each", function()
    local menu = WSRC:match("\nfunction BookshelfWidget:_curatedMoveMenu%(book%)\n(.-)\nend\n")
    assert(menu:find("bw:_curatedToPage(fp, c.page)", 1, true), "the Page buttons do nothing")
    assert(menu:find("bw:_curatedCanPage(fp, c.page)", 1, true), "a Page button lit with no page to go to")
    -- One row, Start and End at its ends (maintainer): the menu's whole
    -- width in equal cells, so End no longer wraps alone.
    assert(menu:find('blocks[#blocks + 1] = { type = "chips", fill = true, items = chips }', 1, true))
    assert(not menu:find("c.edge and ends", 1, true), "Start and End on a row of their own")
end)

t.test("the Arrange menu is titled for itself and the book picked up", function()
    local menu = WSRC:match("\nfunction BookshelfWidget:_curatedMoveMenu%(book%)\n(.-)\nend\n")
    assert(menu:find('template(_("Arrange: %1"), title)', 1, true), "the book's title alone")
    assert(menu:find("title = titleText,", 1, true), "a title fixed at opening: a hold picks up another book")
end)

-- Maintainer: "remove [the Arrange card] and have long press on a collection
-- shelf open the nudge position window, with a button in there to open the
-- edit book menu".
t.test("a long-press on a shelf that can be arranged opens Arrange; elsewhere the book menu", function()
    local opened
    local function wire(self)
        self._curatedMoveMenu = function(_s, b) opened = "arrange:" .. b.filepath end
        self._showBookDetail = function(_s, b, o) opened = "book:" .. b.filepath .. ":" .. tostring(o and o.active) end
        return self
    end
    wire(shelf()):_holdBook({ filepath = "B" })
    eq(opened, "arrange:B")
    -- Waiting only for "Place by hand": Arrange, which offers it.
    wire(shelf({ unordered = true })):_holdBook({ filepath = "B" })
    eq(opened, "arrange:B")
    -- Filtered: Arrange too.
    wire(shelf({ filter = true })):_holdBook({ filepath = "B" })
    eq(opened, "arrange:B")
    -- Nothing to nudge: the book menu, as before.
    for _i, o in ipairs({ { sort = { { key = "title" } } }, { boxes = true }, { chip = "home" } }) do
        opened = nil
        wire(shelf(o)):_holdBook({ filepath = "B" })
        eq(opened, "book:B:edit")
    end
    -- A book that is not on this shelf's collection (a pinned tag shelf).
    opened = nil
    wire(shelf()):_holdBook({ filepath = "Z" })
    eq(opened, "book:Z:edit")
end)

-- Maintainer, PW5: "tapping another book should switch to arranging the
-- tapped book ... 'Long press another book to swap position' is perhaps
-- all we need to say ... Instead of 'Take off shelf' say 'Remove from
-- collection'. Add a strip at the top of the menu with 'This shelf uses the
-- [collection] collection'. Edit shelf and Edit book ... in that strip."
t.test("a long-press swaps a book and a piece, or two pieces", function()
    local self = shelf({ mods = { { id = "cup", after = 1 }, { id = "pot", after = 3 } } })
    eq(self:_shelfSwap({ book = "C" }, { piece = "cup" }), true)
    eq(look(self), "A C B cup pot D")
    eq(table.concat(coll, " "), "A C B D", "the collection's order")
    self = shelf({ mods = { { id = "cup", after = 1 }, { id = "pot", after = 3 } } })
    eq(self:_shelfSwap({ piece = "cup" }, { piece = "pot" }), true)
    eq(look(self), "A pot B C cup D")
    eq(orders, 0, "two pieces trading places rewrote the collection")
    eq(shelf({ sort = { { key = "title" } }, mods = { { id = "cup", after = 1 } } })
        :_shelfSwap({ book = "C" }, { piece = "cup" }), false, "a book moved on a shelf sorted another way")
end)

t.test("a long-press swaps two books, the pieces staying where they stand", function()
    local self = shelf({ mods = { { id = "cup", after = 1 } } })
    eq(self:_curatedSwap("A", "C"), true)
    eq(look(self), "C cup B A D")
    eq(orders, 1)
    eq(self:_curatedSwap("A", "A"), false)
    eq(shelf({ sort = { { key = "title" } } }):_curatedSwap("A", "C"), false, "swapped on a shelf sorted another way")
    -- Reversed on screen: the two still trade places.
    self = shelf({ reversed = true })
    eq(self:_curatedSwap("B", "D"), true)
    eq(table.concat(coll, " "), "A D C B")
end)

t.test("in list view a tap anywhere on a book's row finds the book, not only its cover", function()
    local self = shelf({ view = "list" })
    self._page_items = { { filepath = "A" }, { filepath = "B" } }
    local rows = { A = { x = 45, y = 600, w = 100, h = 150 }, B = { x = 45, y = 767, w = 100, h = 150 } }
    self._shelfSlotRect = function(_s, fp) return rows[fp] end
    eq(self:_curatedBookAt({ x = 900, y = 800 }), "B", "the row's text did not count")
    eq(self:_curatedBookAt({ x = 900, y = 640 }), "A")
    eq(self:_curatedBookAt({ x = 900, y = 2000 }), nil)
end)

t.test("the Arrange menu: a tap picks a book up, a hold swaps, one line says so", function()
    local menu = WSRC:match("\nfunction BookshelfWidget:_curatedMoveMenu%(book%)\n(.-)\nend\n")
    local tap = menu:match("local function onTapBook%(ges%)(.-)\n    end\n")
    assert(tap and tap:find("pickUp(target)", 1, true), "a tap does not pick the book up")
    local hold = menu:match("local function onHoldBook%(ges%)(.-)\n    end\n")
    assert(hold and hold:find("bw:_curatedSwap(fp, other)", 1, true), "a hold does not swap")
    -- A hold on a pinned piece swaps the book with it (maintainer), ahead
    -- of the tap's switch to the piece's menu.
    local hp = menu:match("local function onHoldPiece%(ges%)(.-)\n    end\n")
    assert(hp and hp:find("bw:_shelfSwap({ book = fp }, { piece = piece.id })", 1, true), "a hold on a piece does not swap")
    assert(menu:find('ev.ges == "hold" and onHoldPiece(ev)', 1, true)
        and not menu:find('ev.ges == "hold" and onTapPiece(ev)', 1, true), "a hold on a piece still opens its menu")
    assert(menu:find('_("Long-press another book or ornament to swap their places.")', 1, true), "the one line")
    assert(not menu:find("Or tap another book", 1, true), "the old instructions are still there")
    assert(not menu:find("Tap a pinned ornament", 1, true), "the ornament line is still there")
    -- Maintainer: Add ornament last, so it does not split two book actions.
    local rm, add = menu:find('text = _("Remove from collection"), callback = takeOff }', 1, true),
        menu:find("extras[#extras + 1] = add_ornament", 1, true)
    assert(rm and add and rm < add, "Add ornament comes before Remove from collection")
    assert(menu:find('_("Remove from collection")', 1, true) and not menu:find('_("Take off shelf")', 1, true))
end)

t.test("the Arrange menu: a strip naming the collection, with Edit shelf and Edit book", function()
    local menu = WSRC:match("\nfunction BookshelfWidget:_curatedMoveMenu%(book%)\n(.-)\nend\n")
    assert(menu:find('T(_("This shelf uses the %1 collection."), name)', 1, true), "no strip")
    -- "Edit" with a book, as the ornament menu's "Edit" has the cup: the
    -- same short button in both (maintainer).
    assert(menu:find('label = _("Edit shelf")', 1, true)
        and menu:find('{ icon = "\\xEE\\x9E\\xBD", label = _("Edit"), callback = function()', 1, true),
        "no Edit shelf / Edit (book) in the strip")
    -- Edit shelf at the right in both Arrange menus, so it stays put
    -- (maintainer: less paint shift).
    -- Since: Edit shelf first, the "Edit" with its icon at the right
    -- (maintainer).
    assert(menu:find('label = _("Edit shelf")', 1, true) < menu:find('label = _("Edit"),', 1, true),
        "the Edit with its icon is not the right-hand button")
    assert(not menu:find('_("Book menu")', 1, true), "Book menu is still a chip")
    local _a, n = menu:gsub("strip = strip%(%)", "")
    eq(n, 2, "the strip is not on both pages")
end)

-- Maintainer, PW5: Home changed to another collection from the editor kept
-- showing the old one until a swipe down. Edit shelf in both Arrange menus
-- opened the editor with an on_change that did nothing, so the shelf never
-- dropped its list or rebuilt.
t.test("Edit shelf from either Arrange menu rebuilds the shelf after an edit", function()
    for _i, f in ipairs({ "lib/bookshelf_widget_curated.lua", "lib/bookshelf_widget.lua" }) do
        local src = io.open(f):read("*a")
        for call in src:gmatch('chip_editor"%):editTab%(.-%)\n') do
            assert(not call:find("on_change = function() end", 1, true), f .. ": an editor whose changes the shelf never hears")
        end
    end
    local cur = io.open("lib/bookshelf_widget_curated.lua"):read("*a")
    assert(cur:find("on_change = function(info) bw:_afterChipEdit(info) end", 1, true), "the book's Arrange menu")
    local w = io.open("lib/bookshelf_widget.lua"):read("*a")
    local es = w:match("local function editShelf%(%)(.-)\n    end\n")
    assert(es and es:find("on_change = function(info) bw:_afterChipEdit(info) end", 1, true), "the piece's Arrange menu")
end)

t.done()
