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
            if not fp:find("^gone") then out[#out + 1] = { filepath = fp } end
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
package.loaded["lib/bookshelf_shelf_modules"] = {
    list = function(tab) return tab and tab.shelf_modules end,
}

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

t.test("nor one with a filter: the books on screen are not the whole list", function()
    local self = shelf({ filter = true })
    local ok, why = self:_curatedArrangeable()
    eq(ok, false); eq(why, "filter")
    eq(self:_curatedStep("A", 1), false)
    -- It can still come off.
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

t.done()
