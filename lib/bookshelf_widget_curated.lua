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

-- _curatedArrangeable() -> true, reversed | false, why ("sort" | "filter").
function BookshelfWidget:_curatedArrangeable()
    local list, tab = self:_curatedList()
    if not list then return false, "kind" end
    local first = type(tab.sort_priority) == "table" and tab.sort_priority[1]
    if not (first and first.key == "collection_order") then return false, "sort" end
    local ok, Filter = pcall(require, "lib/bookshelf_filter")
    if ok and Filter and tab.filter and Filter.isActive(tab.filter) then return false, "filter" end
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

-- _curatedBookAt(pos) -> the path of the book drawn under a point on this
-- page, or nil.
function BookshelfWidget:_curatedBookAt(pos)
    if not (pos and self._shelfSlotRect) then return nil end
    for _i, item in ipairs(self._page_items or {}) do
        local fp = type(item) == "table" and item.filepath
        if fp then
            local r = self:_shelfSlotRect(fp)
            if r and r.x and pos:intersectWith(r) then return fp end
        end
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
    return gone
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
            if pos < cursor or pos >= cursor + shown then
                local from = pos
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
    if self._swapShelvesInPlace then
        self:_swapShelvesInPlace()
    else
        self:_rebuild()
        UIManager:setDirty(self, "ui")
    end
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

-- _curatedMoveMenu(book): arranging a hand-ordered shelf, on the shelf.
-- Modeled on a pinned piece's menu (_spineModuleMenu): it opens clear of the
-- shelf and STAYS OPEN while books move. One book is picked up (lifted on
-- the shelf, named in the title). With it up:
--   the buttons            Start / Left / Right / End
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
                    text = T(_("Taken off %1"), (tab and tab.label) or _("the shelf")) })
            end)
        end
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
            local at, n = bw:_curatedPlace(fp)
            blocks[#blocks + 1] = { type = "heading",
                text = (at and n) and string.format(_("Move it \xC2\xB7 %d of %d"), at, n) or _("Move it") }
            -- Left and Right are the screen's, in either reading direction.
            local ICON = { first = Session.PAGE_PREV, prev = Session.CHEV_LEFT,
                           next = Session.CHEV_RIGHT, last = Session.PAGE_NEXT }
            local TEXT = { start = _("Start"), left = _("Left"), right = _("Right"), ["end"] = _("End") }
            local chips = {}
            for _i, c in ipairs(UI.moveChips(mirrored)) do
                chips[#chips + 1] = { icon = ICON[c.icon], text = TEXT[c.key],
                    enabled = (c.step and bw:_curatedCanStep(fp, c.step))
                        or (c.edge and not bw:_curatedAtEdge(fp, c.edge)) or false,
                    callback = function()
                        if c.step then step(c.step) else edge(c.edge) end
                    end }
            end
            blocks[#blocks + 1] = { type = "chips", items = chips }
            if Device:isTouchDevice() then
                blocks[#blocks + 1] = { type = "hint",
                    text = _("Or tap another book to put this one in its place. Long-press another book to pick that one up. Swipe the shelf to turn the page.") }
            end
            local extras = {}
            -- Only where a piece would show: a spine shelf, with Modules > On
            -- the shelf on.
            local on_shelf = true
            pcall(function()
                local Store = require("lib/bookshelf_settings_store")
                if Store.microOnShelf then on_shelf = Store.microOnShelf() and true or false end
            end)
            if on_shelf and bw._isSpineMode and bw:_isSpineMode() then
                extras[#extras + 1] = { icon = "\u{E949}", text = _("Ornament beside it") .. "\xE2\x80\xA6",
                    callback = standPiece }
            end
            extras[#extras + 1] = { icon = UI.ICON_REMOVE, text = _("Take off shelf"), callback = takeOff }
            blocks[#blocks + 1] = { type = "chips", items = extras }
        else
            local text
            if why == "filter" then
                text = _("This shelf has a filter, so some of its books are out of sight. Clear the filter in the shelf editor to move books by hand.")
            elseif why == "boxes" then
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
            items[#items + 1] = { icon = UI.ICON_REMOVE, text = _("Take off shelf"), callback = takeOff }
            blocks[#blocks + 1] = { type = "chips", items = items }
        end
        return { blocks = blocks }
    end
    bw._tap_selected_fp = fp
    bw:_curatedRedraw()
    d = require("lib/bookshelf_page_dialog").show{
        title = function() return title end,
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
    -- A tap on another book on the shelf: this one goes to its place. A tap
    -- on this book, or anywhere else off the menu, is the menu's own (it
    -- closes).
    local function onTapBook(ges)
        if not (ges and ges.pos) or not bw:_curatedArrangeable() then return false end
        local frame = d.frame and d.frame.dimen
        if frame and ges.pos:intersectWith(frame) then return false end
        local target = bw:_curatedBookAt(ges.pos)
        if not target or target == fp then return false end
        after(bw:_curatedMoveTo(fp, target))
        return true
    end
    -- A hold on another book: that one is picked up instead, so a whole
    -- shelf can be arranged without leaving the menu.
    local function onHoldBook(ges)
        if not (ges and ges.pos) then return false end
        local frame = d.frame and d.frame.dimen
        if frame and ges.pos:intersectWith(frame) then return false end
        local other = bw:_curatedBookAt(ges.pos)
        if not other or other == fp or not Curated().has(list, other) then return false end
        for _i, item in ipairs(bw._page_items or {}) do
            if type(item) == "table" and item.filepath == other then title = item.title or title end
        end
        fp = other
        bw._tap_selected_fp = fp
        bw:_curatedRedraw()
        d:refresh()
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
        if ev and ev.ges == "tap" and onTapBook(ev) then return true end
        if ev and ev.ges == "hold" and onHoldBook(ev) then return true end
        return handle(self, event)
    end
    return d
end

end
