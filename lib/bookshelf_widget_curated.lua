-- lib/bookshelf_widget_curated.lua
-- The shelf's side of hand-ordered shelves (issue 390): moving a book along
-- the shelf it stands on, taking it off, and standing an ornament beside it.
-- Installed onto BookshelfWidget (see the end of lib/bookshelf_widget.lua).
--
-- A hand-ordered shelf is a KOReader collection shown as a shelf (one
-- collection's shelf, or Favorites). Two things are kept in step:
--   the BOOKS and their order      the collection (lib/bookshelf_curated)
--   the PIECES standing among them tab.shelf_modules, each `after` so many
--                                  books (pinned ornaments, other modules)
-- Everything here works in SHELF ORDER, the order on screen, read from the
-- repository exactly as the shelf reads it: so a collection KOReader sorts
-- itself, a reversed shelf and a book whose file has gone all come out as
-- the reader sees them. A move writes that order, changed, back to the
-- collection. Arranging is offered only when the screen is the collection:
-- sorted by Collection order, with no filter.

local UIManager = require("ui/uimanager")
local Device    = require("device")
local Screen    = Device.screen
local _         = require("lib/bookshelf_i18n").gettext

return function(BookshelfWidget)

local function Curated()  return require("lib/bookshelf_curated") end
local function CuratedUI() return require("lib/bookshelf_curated_ui") end
local function TabModel() return require("lib/bookshelf_tab_model") end

-- _curatedList() -> collection name, tab when the shelf on screen can be
-- ordered by hand.
function BookshelfWidget:_curatedList()
    local tab = TabModel().getById(self.chip)
    local list = CuratedUI().listOf(tab)
    if not list then return nil end
    return list, tab
end

-- _curatedArrangeable() -> true, reversed | false, why ("sort" | "unordered"
-- | "boxes").
-- A filter does not stop it: a book the filter hides keeps its slot in the
-- collection when the order is written (writeOrder), as a file gone from the
-- device does, and the moves are among the books on screen (maintainer,
-- PW5: a Home shelf on a collection, hiding On hold books, gave the book
-- menu on a long-press, not Arrange).
function BookshelfWidget:_curatedArrangeable()
    local list, tab = self:_curatedList()
    if not list then return false, "kind" end
    local first = type(tab.sort_priority) == "table" and tab.sort_priority[1]
    if not (first and first.key == "collection_order") then return false, "sort" end
    -- A collection with no order of its own (KOReader sorts it, by title
    -- say): placing a book would write the order on screen as the
    -- collection's and switch that sorting off. Only when asked
    -- (_curatedStartOrder).
    if not Curated().ordered(list) then return false, "unordered" end
    -- A shelf that boxes its series stands a whole series as one thing, in
    -- every view: the pieces count boxes there, the collection counts books.
    if tab.series_boxes then return false, "boxes" end
    return true, first.reverse == true
end

-- The books in shelf order, as the shelf fetches them, and this book's
-- place among them.
-- Read once between changes: every change to a collection or to a shelf's
-- record moves the repository's cache epoch or the tab model's generation,
-- and a step asks for the order several times (the move, the page to show,
-- each button's state), each a record a book.
local _shown = {}
local function shelfOrder(tab, fp)
    local Repo = require("lib/bookshelf_book_repository")
    local TM = TabModel()
    local key
    if Repo.cacheEpoch and TM.generation then
        key = tostring(tab.id) .. "|" .. tostring(Repo.cacheEpoch()) .. "|" .. tostring(TM.generation())
    end
    local books
    if key and _shown.key == key then
        books = {}
        for i, f in ipairs(_shown.books) do books[i] = f end
    else
        books = {}
        local page = Repo.getBySource(tab.source, tab.filter, tab.sort_priority, 0, 100000, { light_only = true })
        for i, b in ipairs(page or {}) do books[i] = b.filepath end
        if key then
            local keep = {}
            for i, f in ipairs(books) do keep[i] = f end
            _shown = { key = key, books = keep }
        end
    end
    local at
    if fp then
        for i, f in ipairs(books) do if f == fp then at = i; break end end
    end
    return books, at
end

-- The shelf order, changed, written back as the collection's. The
-- collection may hold files the shelf does not show (gone from the device,
-- not a book): each keeps the slot it had, and the books shown are dealt
-- into the other slots in their new order. Left to the end, a move pushed
-- them to the back of KOReader's own view of the collection.
local function writeOrder(list, books, reversed)
    local n = #books
    local shown, seq = {}, {}
    for i = 1, n do
        local fp = reversed and books[n + 1 - i] or books[i]
        seq[i] = fp
        shown[fp] = true
    end
    local out, k = {}, 0
    for _i, fp in ipairs(Curated().books(list)) do
        if shown[fp] then
            k = k + 1
            out[#out + 1] = seq[k]
        else
            out[#out + 1] = fp
        end
    end
    -- Anything shown that the collection's own list did not name (it should
    -- not happen): after the rest, never dropped.
    for i = k + 1, n do out[#out + 1] = seq[i] end
    return Curated().setOrder(list, out)
end

-- After a move made here: every piece notes the book now on its left, so
-- the next reading of the pieces (CuratedUI.reconcilePieces) leaves the
-- move standing; with the old note it sent each piece back beside the book
-- it had stood by. In memory, on the shelf's own record: the next save of
-- it carries the note, and no write is spent on it here.
local function reanchor(self, books)
    local tab = TabModel().getById(self.chip)
    local mods = tab and tab.shelf_modules
    if type(mods) == "table" and #mods > 0 then CuratedUI().anchorPieces(mods, books) end
end

-- Are the shelf's pieces on screen? Not in list view, nor with Modules > On
-- the shelf off: the list stays on the shelf's record, and a step must not
-- hop a piece nobody can see.
local function piecesShown(self)
    if not self._activeShelfModules then return true end
    return self:_activeShelfModules() ~= nil
end

-- withMods(self, fn) -> fn(mods) on the shelf's own module list (raw, so it
-- stays right while Modules > On the shelf is off); saved when fn returns
-- true.
local function withMods(self, fn)
    local TM = TabModel()
    local tabs = TM.load()
    for _i, t in ipairs(tabs) do
        if t.id == self.chip then
            local mods = type(t.shelf_modules) == "table" and t.shelf_modules or nil
            if fn(mods, t) then TM.save(tabs) end
            return
        end
    end
end

-- _curatedStartOrder() -> true: the order on screen becomes the collection's
-- own, so its books can be placed by hand. For a collection KOReader was
-- sorting itself this switches that off: the reader asked.
function BookshelfWidget:_curatedStartOrder()
    local list, tab = self:_curatedList()
    local ok, why = self:_curatedArrangeable()
    if not list or ok or why ~= "unordered" then return false end
    local first = tab.sort_priority[1]
    return writeOrder(list, (shelfOrder(tab)), first.reverse == true)
end

-- _curatedPlace(fp) -> the book's place in shelf order, of how many.
function BookshelfWidget:_curatedPlace(fp)
    local list, tab = self:_curatedList()
    if not (list and self:_curatedArrangeable()) then return nil end
    local books, at = shelfOrder(tab, fp)
    return at, #books
end

-- _curatedCanStep(fp, dir) -> would a step do anything?
function BookshelfWidget:_curatedCanStep(fp, dir)
    local at, n = self:_curatedPlace(fp)
    if not at then return false end
    local tab = TabModel().getById(self.chip)
    return CuratedUI().step(n, piecesShown(self) and tab and tab.shelf_modules or nil, at, dir) ~= nil
end

-- _curatedStep(fp, dir) -> true when the book moved one place along the
-- shelf (1 right, -1 left): past the book beside it, or past the piece.
function BookshelfWidget:_curatedStep(fp, dir)
    local list, tab = self:_curatedList()
    local ok, reversed = self:_curatedArrangeable()
    if not (list and ok) then return false end
    local books, at = shelfOrder(tab, fp)
    if not at then return false end
    local UI, moved = CuratedUI(), false
    local shown = piecesShown(self)
    withMods(self, function(mods)
        if not shown then mods = nil end
        local st = UI.step(#books, mods, at, dir)
        if not st then return false end
        moved = true
        if st.kind == "piece" then return UI.applyStep(mods, st) end
        books[at], books[st.to] = books[st.to], books[at]
        writeOrder(list, books, reversed)
        return false
    end)
    if moved then reanchor(self, books) end
    return moved
end

-- _curatedToEdge(fp, dir) -> true when the book went to the shelf's start
-- (-1) or end (1). The pieces keep the books on their left.
function BookshelfWidget:_curatedToEdge(fp, dir)
    local list, tab = self:_curatedList()
    local ok, reversed = self:_curatedArrangeable()
    if not (list and ok) then return false end
    local books, at = shelfOrder(tab, fp)
    if not at then return false end
    local UI, to, moved = CuratedUI(), nil, false
    local shown = piecesShown(self)
    withMods(self, function(mods)
        if not shown then mods = nil end
        if UI.atEdge(mods, #books, at, dir) then return false end
        moved = true
        to = UI.toEdge(mods, #books, at, dir)
        return mods ~= nil
    end)
    if not moved then return false end
    if to ~= at then
        table.insert(books, to, table.remove(books, at))
        writeOrder(list, books, reversed)
    end
    reanchor(self, books)
    return true
end

-- _curatedMoveTo(fp, target) -> true when the book went straight to the
-- place another book holds (that one and the books between move up one):
-- one write however far, where a step a place was a wait a place.
function BookshelfWidget:_curatedMoveTo(fp, target)
    local list, tab = self:_curatedList()
    local ok, reversed = self:_curatedArrangeable()
    if not (list and ok) or fp == target then return false end
    local books, at = shelfOrder(tab, fp)
    local to
    for i, f in ipairs(books) do if f == target then to = i; break end end
    if not (at and to) then return false end
    local UI = CuratedUI()
    local shown = piecesShown(self)
    withMods(self, function(mods)
        if not (shown and mods) then return false end
        UI.shiftForRemove(mods, at)
        UI.shiftForInsert(mods, to)
        return true
    end)
    table.insert(books, to, table.remove(books, at))
    writeOrder(list, books, reversed)
    reanchor(self, books)
    return true
end

-- _curatedSwap(fp, other) -> true when the two books traded places (a
-- long-press on another book while arranging). No place changes hands but
-- theirs, so the pinned pieces stay where they stand.
function BookshelfWidget:_curatedSwap(fp, other)
    local list, tab = self:_curatedList()
    local ok, reversed = self:_curatedArrangeable()
    if not (list and ok) or fp == other then return false end
    local books, at = shelfOrder(tab, fp)
    local to
    for i, f in ipairs(books) do if f == other then to = i; break end end
    if not (at and to) then return false end
    books[at], books[to] = books[to], books[at]
    writeOrder(list, books, reversed)
    reanchor(self, books)
    return true
end

-- _shelfSwap(a, b) -> true when two things on the shelf traded places: a
-- book and a pinned piece, or two pieces ({ book = fp } / { piece = id }).
-- Long-press while arranging (maintainer: "the same with ornaments, between
-- ornaments and between ornaments and books"). A book only moves on a shelf
-- that can be arranged; two pieces trade places on any shelf showing them.
function BookshelfWidget:_shelfSwap(a, b)
    if not piecesShown(self) then return false end
    local SM = require("lib/bookshelf_shelf_modules")
    local list, tab = self:_curatedList()
    local books, reversed
    if a.book or b.book then
        local ok
        ok, reversed = self:_curatedArrangeable()
        if not (list and ok) then return false end
        books = shelfOrder(tab)
    elseif list then
        books = shelfOrder(tab)
    else
        -- Pieces alone: their places count books, and the books stay.
        books = {}
        local n = 0
        for _i, m in ipairs((tab or TabModel().getById(self.chip) or {}).shelf_modules or {}) do
            n = math.max(n, math.floor(tonumber(m.after) or 0))
        end
        for i = 1, n do books[i] = "\0" .. i end
    end
    local swapped
    withMods(self, function(mods, t)
        local nb, nm = SM.swapPlaces(books, mods or {}, a, b)
        if not nb then return false end
        t.shelf_modules = #nm > 0 and nm or nil
        swapped = nb
        return true
    end)
    if not swapped then return false end
    if a.book or b.book then writeOrder(list, swapped, reversed) end
    if list then reanchor(self, swapped) end
    return true
end

-- _curatedCanPage(fp, dir) -> is there a page before (-1) / after (1) the
-- one the book is on? An estimate from the page on screen, cheap enough to
-- light a button with; _curatedToPage works the place out.
function BookshelfWidget:_curatedCanPage(fp, dir)
    local at, n = self:_curatedPlace(fp)
    if not at then return false end
    local cursor = self._cursor or 1
    if self._isSpineMode and self:_isSpineMode() then
        if dir < 0 then return cursor > 1 end
        local c = self._spine_fetch_cache
        local total = (c and type(c.items) == "table" and #c.items) or self._total_items or n
        return cursor + (self._spine_shown or 0) <= total
    end
    -- Covers with pieces among them page by slots, not books.
    if self._activeShelfModules and self:_activeShelfModules() then return false end
    local view = math.max(1, self:_viewSize())
    local page = math.floor((at - 1) / view)
    if dir < 0 then return page >= 1 end
    return (page + 1) * view + 1 <= n
end

-- _curatedToPage(fp, dir) -> true when the book went FIRST on the page after
-- (1) or before (-1) the one it is on. On a spine shelf the pages are what
-- the shelf plans: the next page's start is taken from the shelf WITHOUT the
-- book where it is now (the pages before its new place are then exactly
-- those, so the break in front of it holds); the previous page's from the
-- shelf as it stands. Covers and lists page by a fixed count.
function BookshelfWidget:_curatedToPage(fp, dir)
    local list, tab = self:_curatedList()
    local ok, reversed = self:_curatedArrangeable()
    if not (list and ok) then return false end
    local books, at = shelfOrder(tab, fp)
    if not at then return false end
    local to, lead_from, without
    if self._isSpineMode and self:_isSpineMode() then
        local c = self._spine_fetch_cache
        local items = c and c.items
        if type(items) ~= "table" then return false end
        local mypos
        without = {}
        for i = 1, #items do
            local it = items[i]
            if type(it) == "table" and it.filepath == fp then mypos = i
            else without[#without + 1] = it end
        end
        if not mypos then return false end
        local start
        if dir > 0 then
            local firsts = self._spineFirstsOf and self:_spineFirstsOf(without)
            if type(firsts) ~= "table" then return false end
            local cursor = self._cursor or 1
            local here = cursor - ((mypos < cursor) and 1 or 0)
            for i = 1, #firsts do
                if firsts[i] > here then start = firsts[i]; break end
            end
        else
            local ok_f, firsts = pcall(self._spinePageFirsts, self, true)
            if not ok_f or type(firsts) ~= "table" then return false end
            local page_start = 1
            for i = 1, #firsts do if firsts[i] <= mypos then page_start = firsts[i] end end
            for i = 1, #firsts do if firsts[i] < page_start then start = firsts[i] end end
            -- A place before the book's own: the same with or without it.
        end
        if not start then return false end
        local before = 0
        for i = 1, start - 1 do
            local it = without[i]
            if not (type(it) == "table" and it.shelf_module) then before = before + 1 end
        end
        to, lead_from = before + 1, start
    else
        if self._activeShelfModules and self:_activeShelfModules() then return false end
        local view = math.max(1, self:_viewSize())
        local page = math.floor((at - 1) / view)
        if dir > 0 then
            to = (page + 1) * view + 1
            if to > #books then return false end
        else
            if page < 1 then return false end
            to = (page - 1) * view + 1
        end
    end
    if to == at then return false end
    local UI = CuratedUI()
    local shown = piecesShown(self)
    withMods(self, function(mods)
        if not (shown and mods) then return false end
        UI.shiftForRemove(mods, at)
        UI.shiftForInsert(mods, to)
        -- A piece standing at the page's start, between the book and the
        -- books before it: the book goes in front, to lead the page.
        if lead_from and without then
            local at_or_after = {}
            for i = lead_from, #without do
                local it = without[i]
                if type(it) == "table" and it.shelf_module then at_or_after[it.shelf_module.id] = true end
            end
            for _i, m in ipairs(mods) do
                if at_or_after[m.id] and (tonumber(m.after) or 0) == to - 1 then m.after = to end
            end
        end
        return true
    end)
    table.insert(books, to, table.remove(books, at))
    writeOrder(list, books, reversed)
    reanchor(self, books)
    return true
end

-- _curatedBookAt(pos) -> the path of the book drawn under a point on this
-- page, or nil.
function BookshelfWidget:_curatedBookAt(pos)
    if not (pos and self._shelfSlotRect) then return nil end
    -- In list view a book's slot is its cover thumbnail at the row's left;
    -- the row is the book (PW5: a tap on a title missed, and the tap went
    -- through to the list). The row is the cover's height, and the gap to
    -- the next row's cover belongs half to each.
    local list = self._viewMode and self:_viewMode() == "list"
    local slack = 0
    if list then
        local ok, Device = pcall(require, "device")
        slack = ok and Device.screen and Device.screen.scaleBySize
            and Device.screen:scaleBySize(8) or 8
    end
    for _i, item in ipairs(self._page_items or {}) do
        local fp = type(item) == "table" and item.filepath
        if fp then
            local r = self:_shelfSlotRect(fp)
            if r and r.x then
                if list then
                    if pos.y >= r.y - slack and pos.y < r.y + r.h + slack then return fp end
                elseif pos:intersectWith(r) then
                    return fp
                end
            end
        end
    end
    return nil
end

-- _shelfPieceAt(pos) -> the shelf module (a pinned ornament, say) drawn
-- under a point on this page, as the shelf's record has it, or nil. A spine
-- shelf notes each piece's cell as it draws it (_spine_module_cells, which
-- can outlive a piece: only one still on the shelf's record counts).
function BookshelfWidget:_shelfPieceAt(pos)
    local cells = self._spine_module_cells
    if not (pos and type(cells) == "table") then return nil end
    local ok, SM = pcall(require, "lib/bookshelf_shelf_modules")
    local mods = ok and SM and SM.list(TabModel().getById(self.chip)) or nil
    for _i, m in ipairs(mods or {}) do
        local cell = cells[m.id]
        local r = cell and cell.dimen
        if r and r.x and pos:intersectWith(r) then return m end
    end
    return nil
end

-- _curatedAtEdge(fp, dir) -> is the book already first (-1) / last (1)?
function BookshelfWidget:_curatedAtEdge(fp, dir)
    local at, n = self:_curatedPlace(fp)
    if not at then return true end
    local tab = TabModel().getById(self.chip)
    return CuratedUI().atEdge(piecesShown(self) and tab and tab.shelf_modules or nil, n, at, dir)
end

-- _curatedTakeOff(fp) -> true when the book came off this shelf.
function BookshelfWidget:_curatedTakeOff(fp)
    local list, tab = self:_curatedList()
    if not (list and Curated().has(list, fp)) then return false end
    -- Its place on screen, when the screen is the list: the pieces close up.
    local at = self:_curatedPlace(fp)
    if at then
        local UI = CuratedUI()
        withMods(self, function(mods)
            if not mods then return false end
            UI.shiftForRemove(mods, at)
            return true
        end)
    end
    local gone = Curated().remove(list, fp)
    if gone and at then reanchor(self, (shelfOrder(tab))) end
    -- Its turn (spine out) goes with it: added again, it faces out.
    if gone then
        withMods(self, function(_mods, t)
            local v = t.spine_face_out
            if type(v) == "table" and type(v.spine) == "table" and v.spine[fp] then
                v.spine[fp] = nil
                return true
            end
            return false
        end)
    end
    return gone
end

-- Face out or spine out, book by book: a spine shelf whose Face out is
-- "Choose for each book" (spine_face_out = { chosen = true, spine = { [path]
-- = true } }, read by SpineShelf.faceOutSpec). Every book faces out until it
-- is turned.
local function faceChoice(tab)
    local v = tab and tab.spine_face_out
    if type(v) == "table" and v.chosen == true and not v.all then return v end
    return nil
end

-- _curatedFaceChoice() -> is the choice on offer on this shelf, now?
function BookshelfWidget:_curatedFaceChoice()
    local list, tab = self:_curatedList()
    if not list then return false end
    if not (self._isSpineMode and self:_isSpineMode()) then return false end
    return faceChoice(tab) ~= nil
end

-- _curatedFacesOut(fp) -> does this book stand cover forward?
function BookshelfWidget:_curatedFacesOut(fp)
    local _list, tab = self:_curatedList()
    local v = faceChoice(tab)
    if not v then return false end
    return not (type(v.spine) == "table" and v.spine[fp])
end

-- _curatedSetFaceOut(fp, on) -> true when the book was turned (and saved).
function BookshelfWidget:_curatedSetFaceOut(fp, on)
    if not fp or not self:_curatedList() then return false end
    local changed = false
    withMods(self, function(_mods, t)
        local v = faceChoice(t)
        if not v then return false end
        local spine = type(v.spine) == "table" and v.spine or {}
        local is_out = not spine[fp]
        if is_out == (on and true or false) then return false end
        spine[fp] = (not on) and true or nil
        v.spine = spine
        changed = true
        return true
    end)
    return changed
end

-- _curatedStandPiece(fp, entry) -> the new module: an ornament pinned to the
-- right of this book.
function BookshelfWidget:_curatedStandPiece(fp, entry)
    if not (entry and entry.name) then return nil end
    local at = self:_curatedPlace(fp)
    if not at then return nil end
    local made
    withMods(self, function(mods, tab)
        mods = mods or {}
        tab.shelf_modules = mods
        local used = {}
        for _j, x in ipairs(mods) do used[x.id] = true end
        local k = 1
        while used["sm_" .. k] do k = k + 1 end
        made = { id = "sm_" .. k, type = "module", module = "ornament",
                 ornament = entry.name, tap = entry.tap, after = at, w = 1 }
        -- First of the pieces after this book: touching it.
        table.insert(mods, 1, made)
        return true
    end)
    if made then
        local _l, tab = self:_curatedList()
        reanchor(self, (shelfOrder(tab)))
    end
    return made
end

-- _curatedShow(fp): the shelf redrawn on the page that holds the book, with
-- the book picked out.
function BookshelfWidget:_curatedShow(fp)
    local at = self:_curatedPlace(fp)
    if at then
        local pos = at
        pcall(function()
            local SM = require("lib/bookshelf_shelf_modules")
            for _i, m in ipairs(SM.list(TabModel().getById(self.chip)) or {}) do
                if (tonumber(m.after) or 0) < at then pos = pos + 1 end
            end
        end)
        local cursor = self._cursor or 1
        if self._isSpineMode and self:_isSpineMode() then
            local shown = self._spine_shown or 0
            -- At the page's first or last place, or off it: a move there can
            -- shift where the pages break (books differ in width), so the
            -- page comes from the map of the shelf AS IT NOW STANDS, the
            -- list fetched again first (the map is kept with the list, and
            -- read from the old one it put a book stepped right off page 1
            -- second on page 2). Inside the page the start cannot move, and
            -- the map, which plans the whole shelf, is not built.
            if pos <= cursor or pos >= cursor + shown - 1 then
                local from = pos
                self._spine_keep_cursor = true
                if self._expireSpineFetch then self:_expireSpineFetch() end
                if self._spineCachedFetch then pcall(self._spineCachedFetch, self, 400) end
                self._spine_keep_cursor = nil
                local ok, firsts = pcall(self._spinePageFirsts, self, true)
                if ok and type(firsts) == "table" then
                    for i = 1, #firsts do if firsts[i] <= pos then from = firsts[i] end end
                end
                self._cursor = math.max(1, from)
            end
        elseif not (self._activeShelfModules and self:_activeShelfModules()) then
            -- A cover shelf with pieces on it pages by SLOTS, not books:
            -- left where it is rather than turned to a wrong page.
            local view = math.max(1, self:_viewSize())
            if at < cursor or at >= cursor + view then
                self._cursor = math.floor((at - 1) / view) * view + 1
            end
        end
        if self._syncPageFromCursor then pcall(self._syncPageFromCursor, self) end
    end
    self._tap_selected_fp = fp
    self:_curatedRedraw()
end

-- _curatedPieces() -> the shelf's module list, its pieces put back beside
-- their books (CuratedUI.reconcilePieces) when the collection changed since
-- they were last seen: a book added, removed or moved by something other
-- than these menus. Called as the shelf reads its modules. Nothing is
-- written here: the next save of the shelf's record carries it.
function BookshelfWidget:_curatedPieces(mods)
    local list, tab = self:_curatedList()
    mods = mods or (tab and tab.shelf_modules)
    if not (list and type(mods) == "table" and #mods > 0) then return mods end
    if not self:_curatedArrangeable() then return mods end
    local UI = CuratedUI()
    local books = shelfOrder(tab)
    UI.reconcilePieces(mods, books)
    -- A piece seen here for the first time notes the book on its left.
    for _i, m in ipairs(mods) do
        if m.anchor == nil then UI.anchorPieces({ m }, books) end
    end
    return mods
end

-- _curatedRedraw(): the shelf's rows again, and only them: the top panel and
-- the menu over it are as they were, so nothing else is rebuilt or flashed
-- (a whole rebuild per step was most of a step's 300 ms on a PW5).
function BookshelfWidget:_curatedRedraw()
    -- A spine shelf keeps its own list for 30 seconds, keyed on the shelf
    -- and its pieces: a book moved past a book changes neither.
    if self._expireSpineFetch then self:_expireSpineFetch() end
    -- And composed pages for page turns, under a key that knows nothing of
    -- which books are turned spine out: a turn was drawn from the picture
    -- before it.
    if self._pageCacheClear then self:_pageCacheClear() end
    -- The page was chosen for the book just moved (_curatedShow). A list
    -- that comes back in another order is otherwise taken for one that
    -- reordered itself, and the cursor put back on the old page's first
    -- book (_anchorSpineCursor): one place off, after a step over a page's
    -- end.
    self._spine_keep_cursor = true
    if self._swapShelvesInPlace then
        self:_swapShelvesInPlace()
    else
        self:_rebuild()
        UIManager:setDirty(self, "ui")
    end
    self._spine_keep_cursor = nil
end

-- _curatedUseShelfOrder(): sort this shelf by its collection's order.
function BookshelfWidget:_curatedUseShelfOrder()
    local TM = TabModel()
    local tabs = TM.load()
    for _i, t in ipairs(tabs) do
        if t.id == self.chip then
            local ok, Editor = pcall(require, "lib/bookshelf_chip_editor")
            t.sort_priority = (ok and Editor and Editor.sourceSortDefaults and Editor.sourceSortDefaults("collection"))
                or { { key = "collection_order", reverse = false }, { key = "last_opened", reverse = true } }
        end
    end
    TM.save(tabs)
    pcall(function() require("lib/bookshelf_book_repository").invalidateBookCache("shelf order") end)
end

-- _curatedArrangeShelf() -> the arrange menu, opened on the first book of
-- the page on screen (the shelf editor's Arrange button); nil when the page
-- shows no book of the collection.
function BookshelfWidget:_curatedArrangeShelf()
    local list = self:_curatedList()
    if not list then return nil end
    for _i, item in ipairs(self._page_items or {}) do
        if type(item) == "table" and item.filepath and Curated().has(list, item.filepath) then
            return self:_curatedMoveMenu(item)
        end
    end
    return nil
end

-- _holdBook(book): a long-press on a book on the shelf. On a hand-ordered
-- shelf that can be arranged (or only waits for "Place by hand"), Arrange,
-- which has a way to the book menu; anywhere else the book menu
-- (maintainer: the Arrange card in the book menu goes, a long-press on the
-- shelf opens Arrange).
function BookshelfWidget:_holdBook(book)
    local fp = book and book.filepath
    local list = fp and self:_curatedList()
    if list and Curated().has(list, fp) then
        local ok, why = self:_curatedArrangeable()
        if ok or why == "unordered" then return self:_curatedMoveMenu(book) end
    end
    return self:_showBookDetail(book, { active = "edit" })
end

-- _curatedMoveMenu(book): arranging a hand-ordered shelf, on the shelf.
-- Modeled on a pinned piece's menu (_spineModuleMenu): it opens clear of the
-- shelf and STAYS OPEN while books move. One book is picked up (lifted on
-- the shelf, named in the title). With it up:
--   the buttons            Start / Page / Left / Right / Page / End
--   a swipe on it          one place
--   a tap on another book  it goes to that book's place
--   a hold on another book that one is picked up instead
--   a swipe on the shelf   turns the page, the menu staying
-- A tap anywhere else closes it.
function BookshelfWidget:_curatedMoveMenu(book)
    local fp = book and book.filepath
    local list = self:_curatedList()
    if not (fp and list and Curated().has(list, fp)) then return end
    local bw = self
    local Session = require("lib/bookshelf_module_grid_session")
    local UI = CuratedUI()
    -- Right to left: the shelf's rows are mirrored, place 1 at the right.
    local mirrored = false
    pcall(function() mirrored = require("ui/bidi").mirroredUILayout() and true or false end)
    local d
    local title = book.title or _("Book")
    -- The book picked up now (a hold on another book picks that one up).
    local cur_book = book
    local function book_now() return cur_book end
    -- "Arrange: The Traveler": the menu named, then the book picked up. The
    -- title bar cuts a long one at its end.
    local function titleText() return require("ffi/util").template(_("Arrange: %1"), title) end
    local function close() if d then UIManager:close(d) end end
    local function after(moved)
        if not moved then return end
        bw:_curatedShow(fp)
        if d then d:refresh() end
    end
    local function step(dir) after(bw:_curatedStep(fp, dir)) end
    local function edge(dir) after(bw:_curatedToEdge(fp, dir)) end
    local function takeOff()
        close()
        local _l, tab = bw:_curatedList()
        local gone = bw:_curatedTakeOff(fp)
        bw._tap_selected_fp = nil
        if gone then
            bw:_curatedRedraw()
            -- It leaves at once, with no question asked: say what happened
            -- and where, so a slip is seen and can be put right.
            pcall(function()
                local T = require("ffi/util").template
                UIManager:show(require("ui/widget/notification"):new{
                    text = T(_("Removed from the %1 collection"),
                        (tab and tab.source and tab.source.id) or (tab and tab.label) or "") })
            end)
        end
    end
    -- The strip at the top: which collection the shelf is, and the two ways
    -- out of arranging (maintainer): the shelf's editor, and the book's menu
    -- for the book picked up (what a long-press opened before it opened
    -- this).
    local function strip()
        local T = require("ffi/util").template
        local _l, tab = bw:_curatedList()
        local name = (tab and tab.source and tab.source.id) or ""
        return { { type = "summary", text = T(_("This shelf uses the %1 collection."), name),
            -- Edit shelf, then "Edit" with a book at the right, as a pinned
            -- piece's Arrange menu has "Edit" with its cup: the same two
            -- buttons in both, the icon the one that changes (maintainer).
            actions = {
                { label = _("Edit shelf"), callback = function()
                    close()
                    local _l2, t2 = bw:_curatedList()
                    if t2 then
                        require("lib/bookshelf_chip_editor"):editTab(t2.id, { bw = bw, on_change = function(info) bw:_afterChipEdit(info) end })
                    end
                end },
                { icon = "\xEE\x9E\xBD", label = _("Edit"), callback = function()   -- book-open-variant
                    close()
                    bw:_showBookDetail(book_now(), { active = "edit" })
                end },
            } } }
    end
    local function standPiece()
        require("lib/bookshelf_ornament_browser").show(nil, {
            title = _("Choose an ornament"),
            pick = function(entry)
                if bw:_curatedStandPiece(fp, entry) then
                    bw:_curatedShow(fp)
                    if d then d:refresh() end
                end
            end,
        })
    end
    local function page()
        local ok, why = bw:_curatedArrangeable()
        local blocks = {}
        if ok then
            -- Left and Right are the screen's, in either reading direction.
            -- The same six a pinned ornament's menu has (_spineModuleMenu).
            local ICON = { first = UI.ICON_FIRST, page_prev = Session.PAGE_PREV, prev = Session.CHEV_LEFT,
                           next = Session.CHEV_RIGHT, page_next = Session.PAGE_NEXT, last = UI.ICON_LAST }
            local TEXT = { start = _("Start"), page_prev = _("Page"), left = _("Left"),
                           right = _("Right"), page_next = _("Page"), ["end"] = _("End") }
            -- One row the menu's whole width, as the ornament's: the shelf's
            -- start and end at its ends, a page and a place between them
            -- (fill: equal cells, icons alone where the labels do not fit).
            local chips = {}
            for _i, c in ipairs(UI.moveChips(mirrored)) do
                chips[#chips + 1] = { icon = ICON[c.icon], text = TEXT[c.key],
                    enabled = (c.step and bw:_curatedCanStep(fp, c.step))
                        or (c.edge and not bw:_curatedAtEdge(fp, c.edge))
                        or (c.page and bw:_curatedCanPage(fp, c.page)) or false,
                    callback = function()
                        if c.step then step(c.step)
                        elseif c.page then after(bw:_curatedToPage(fp, c.page))
                        else edge(c.edge) end
                    end }
            end
            blocks[#blocks + 1] = { type = "chips", fill = true, items = chips }
            if Device:isTouchDevice() then
                -- A tap on another book picks that one up (no need to say).
                blocks[#blocks + 1] = { type = "hint",
                    text = _("Long-press another book or ornament to swap their places.") }
            end
            local extras = {}
            -- Only where a piece would show: a spine shelf, with Modules > On
            -- the shelf on.
            local on_shelf = true
            pcall(function()
                local Store = require("lib/bookshelf_settings_store")
                if Store.microOnShelf then on_shelf = Store.microOnShelf() and true or false end
            end)
            -- Add ornament last (after the book's own actions, maintainer).
            local add_ornament
            if on_shelf and bw._isSpineMode and bw:_isSpineMode() then
                add_ornament = { icon = UI.ICON_ORNAMENT, text = _("Add ornament") .. "\xE2\x80\xA6",
                    callback = standPiece }
            end
            -- Cover forward or spine out, this book (a spine shelf whose
            -- Face out is "Choose for each book"). Lit while it faces out.
            if bw:_curatedFaceChoice() then
                local out = bw:_curatedFacesOut(fp)
                table.insert(extras, 1, { icon = UI.ICON_FACE, text = _("Face out"), on = out,
                    callback = function()
                        if bw:_curatedSetFaceOut(fp, not out) then
                            bw:_curatedShow(fp)
                            if d then d:refresh() end
                        end
                    end })
            end
            extras[#extras + 1] = { icon = UI.ICON_REMOVE, text = _("Remove from collection"), callback = takeOff }
            extras[#extras + 1] = add_ornament
            blocks[#blocks + 1] = { type = "chips", items = extras }
        else
            local text
            if why == "boxes" then
                text = _("This shelf boxes each series together, so its books cannot be placed one by one. Turn series boxes off in the shelf editor to move books by hand.")
            elseif why == "unordered" then
                text = _("This collection is not in an order of your own yet: KOReader may be sorting it. Placing books by hand starts from the order on screen, and turns KOReader's own sorting of this collection off.")
            else
                text = _("This shelf is sorted another way, so its books cannot be moved by hand.")
            end
            blocks[#blocks + 1] = { type = "summary", text = text }
            local items = {}
            if why == "unordered" then
                items[#items + 1] = { text = _("Place by hand"), callback = function()
                    if bw:_curatedStartOrder() then
                        bw:_curatedShow(fp)
                        if d then d:refresh() end
                    end
                end }
            end
            if why == "sort" then
                items[#items + 1] = { text = _("Sort by collection order"), callback = function()
                    bw:_curatedUseShelfOrder()
                    bw:_curatedShow(fp)
                    if d then d:refresh() end
                end }
            end
            items[#items + 1] = { icon = UI.ICON_REMOVE, text = _("Remove from collection"), callback = takeOff }
            blocks[#blocks + 1] = { type = "chips", items = items }
            return { strip = strip(), blocks = blocks }
        end
        return { strip = strip(), blocks = blocks }
    end
    bw._tap_selected_fp = fp
    bw:_curatedRedraw()
    d = require("lib/bookshelf_page_dialog").show{
        title = titleText,
        page = page,
        on_close = function()
            if bw._tap_selected_fp == fp then
                bw._tap_selected_fp = nil
                bw:_curatedRedraw()
            end
        end,
        anchor = function()
            local cw = d and d.frame and d.frame:getSize().w
            if not cw then return nil end
            if bw.hasTopPanel and bw:hasTopPanel() then
                return { x = math.floor((Screen:getWidth() - cw) / 2), y = 0, w = cw, h = Screen:scaleBySize(8) }
            end
            local r = bw._shelfSlotRect and bw:_shelfSlotRect(fp)
            if r and r.y and r.h then
                local gap = Screen:scaleBySize(16)
                return { x = math.floor((Screen:getWidth() - cw) / 2), y = r.y - gap, w = cw, h = r.h + 2 * gap }
            end
        end,
    }
    local function onSwipeBook(ges)
        local r = bw._shelfSlotRect and bw:_shelfSlotRect(fp)
        if not (r and r.x and ges and ges.pos and ges.pos:intersectWith(r)) then return false end
        local by = UI.swipeStep(ges.direction, mirrored)
        if not by then return false end
        step(by)
        return true
    end
    -- pickUp(other): that book is picked up instead, so a whole shelf can be
    -- arranged without leaving the menu.
    local function pickUp(other)
        for _i, item in ipairs(bw._page_items or {}) do
            if type(item) == "table" and item.filepath == other then
                title = item.title or title
                cur_book = item
            end
        end
        if cur_book.filepath ~= other then cur_book = { filepath = other, title = title } end
        fp = other
        bw._tap_selected_fp = fp
        bw:_curatedRedraw()
        d:refresh()
    end
    -- A tap on another book on the shelf: that one is picked up (maintainer:
    -- "tapping another book should switch to arranging the tapped book"). A
    -- tap on this book, or anywhere else off the menu, is the menu's own (it
    -- closes).
    local function onTapBook(ges)
        if not (ges and ges.pos) then return false end
        local frame = d.frame and d.frame.dimen
        if frame and ges.pos:intersectWith(frame) then return false end
        local target = bw:_curatedBookAt(ges.pos)
        if not target or target == fp or not Curated().has(list, target) then return false end
        pickUp(target)
        return true
    end
    -- A tap (or a hold) on a pinned piece: this menu gives way to the
    -- piece's own, which moves, adjusts and unpins it; a tap on a book from
    -- there comes back here (maintainer). The book is put down first.
    local function onTapPiece(ges)
        if not (ges and ges.pos and bw._shelfPieceAt and bw._spineModuleMenu) then return false end
        local frame = d.frame and d.frame.dimen
        if frame and ges.pos:intersectWith(frame) then return false end
        local piece = bw:_shelfPieceAt(ges.pos)
        if not piece then return false end
        d:_dismiss()
        bw:_spineModuleMenu(piece)
        return true
    end
    -- A hold on a pinned piece: the book and the piece trade places
    -- (maintainer), the book staying picked up.
    local function onHoldPiece(ges)
        if not (ges and ges.pos and bw._shelfPieceAt) or not bw:_curatedArrangeable() then return false end
        local frame = d.frame and d.frame.dimen
        if frame and ges.pos:intersectWith(frame) then return false end
        local piece = bw:_shelfPieceAt(ges.pos)
        if not piece then return false end
        after(bw:_shelfSwap({ book = fp }, { piece = piece.id }))
        return true
    end
    -- A hold on another book: the two trade places (maintainer: "Long press
    -- another book to swap position").
    local function onHoldBook(ges)
        if not (ges and ges.pos) or not bw:_curatedArrangeable() then return false end
        local frame = d.frame and d.frame.dimen
        if frame and ges.pos:intersectWith(frame) then return false end
        local other = bw:_curatedBookAt(ges.pos)
        if not other or other == fp or not Curated().has(list, other) then return false end
        after(bw:_curatedSwap(fp, other))
        return true
    end
    -- A swipe on the shelf, off the picked-up book: the page turns and the
    -- menu stays, so a book can be sent to a place on another page.
    local function onSwipeShelf(ges)
        if not (ges and ges.pos) then return false end
        local frame = d.frame and d.frame.dimen
        if frame and ges.pos:intersectWith(frame) then return false end
        local by = UI.swipeStep(ges.direction, mirrored)
        if not by then return false end
        if by == -1 then
            if bw._paginateNext then bw:_paginateNext() end
        elseif bw._paginatePrev then
            bw:_paginatePrev()
        end
        -- A page turn drops the shelf's own selection: the book is still up.
        bw._tap_selected_fp = fp
        for _i, item in ipairs(bw._page_items or {}) do
            if type(item) == "table" and item.filepath == fp then bw:_curatedRedraw(); break end
        end
        return true
    end
    local handle = d.handleEvent
    function d:handleEvent(event)
        local ev = event.handler == "onGesture" and event.args and event.args[1]
        if ev and ev.ges == "swipe" and (onSwipeBook(ev) or onSwipeShelf(ev)) then return true end
        if ev and ev.ges == "tap" and onTapPiece(ev) then return true end
        if ev and ev.ges == "tap" and onTapBook(ev) then return true end
        if ev and ev.ges == "hold" and onHoldPiece(ev) then return true end
        if ev and ev.ges == "hold" and onHoldBook(ev) then return true end
        return handle(self, event)
    end
    return d
end

end
