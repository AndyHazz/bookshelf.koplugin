-- lib/bookshelf_curated_ui.lua
-- What a reader does with hand-ordered shelves (issue 390), away from the
-- shelf itself: put books on one from a book's menu (pick) and make a new
-- one on the way (newShelf). Also the rules for a book moving among the
-- pieces that stand on its shelf (step, applyStep, shiftFor*).
--
-- A hand-ordered shelf is a KOReader collection shown as a shelf: a tab
-- record whose source is { kind = "collection", id = <name> } with a
-- collection really behind it (a pinned tag is kind "collection" too, with
-- none). lib/bookshelf_curated changes its books. Moving one book along the
-- shelf it stands on is the shelf's own business (BookshelfWidget).

local _ = require("lib/bookshelf_i18n").gettext
local T = require("ffi/util").template

local UI = {}

UI.ICON_ADD    = "\u{ECDA}"   -- book-plus
UI.ICON_REMOVE = "\u{ECD8}"   -- book-minus
UI.ICON_SHELF  = "\u{E7BA}"   -- book-multiple
UI.ICON_FACE   = "\u{E7B9}"   -- book: cover forward
-- The shelf's very start and end, for a book's and a pinned piece's menus;
-- the double chevrons beside them are a page (module_grid_session).
UI.ICON_FIRST  = "\u{ECFF}"   -- page-first
UI.ICON_LAST   = "\u{ED00}"   -- page-last
-- The ornaments' own icon everywhere else (bookshelf_ornaments.COLLECTION_ICON).
UI.ICON_ORNAMENT = "\u{F0F4}"   -- coffee
UI.ICON_NEW    = "\u{EB11}"   -- playlist-plus

local function Curated() return require("lib/bookshelf_curated") end
local function TabModel() return require("lib/bookshelf_tab_model") end

-- listOf(tab) -> the collection behind a shelf, when its books can be
-- placed by hand: one collection's shelf.
function UI.listOf(tab)
    local src = type(tab) == "table" and tab.source
    if type(src) ~= "table" then return nil end
    -- Not the Favorites shelf: the repository does not sort it by the
    -- collection's order, so a move there wrote an order no shelf showed.
    local name = src.kind == "collection" and src.id or nil
    if name and Curated().exists(name) then return name end
    return nil
end

-- shelves() -> { { id, label, list }, ... }: the shelves a book can be put
-- on, in shelf order: each one collection's shelf. Favorites is left out
-- (the book menu has its own card for it), as are a module's own shelf and
-- one still being made. Two shelves on one collection are listed once.
function UI.shelves()
    local out, seen = {}, {}
    for _i, tab in ipairs(TabModel().load() or {}) do
        local src = tab.source
        if type(src) == "table" and src.kind == "collection" and not tab.pending
                and not TabModel().isCardOnly(tab) then
            local name = UI.listOf(tab)
            if name and not seen[name] then
                seen[name] = true
                out[#out + 1] = { id = tab.id, label = tab.label or name, list = name }
            end
        end
    end
    return out
end

-- state(list, paths) -> "all" | "some" | "none" of these books are on it.
function UI.state(list, paths)
    local on = 0
    for _i, fp in ipairs(paths) do if Curated().has(list, fp) then on = on + 1 end end
    if on == 0 then return "none" end
    return on == #paths and "all" or "some"
end

-- toggle(list, paths) -> how many books changed: every one of them goes on,
-- unless all are on already, when they come off.
function UI.toggle(list, paths)
    local C = Curated()
    if UI.state(list, paths) == "all" then return C.removeMany(list, paths) end
    return C.addMany(list, paths)
end

-- freeName() -> a name for a shelf nobody named: "My shelf", or the first
-- "My shelf N" no collection has.
function UI.freeName()
    local label = _("My shelf")
    local n = 2
    while Curated().exists(label) do label = T(_("My shelf %1"), n); n = n + 1 end
    return label
end

-- newShelf(label, after_id, view_mode) -> the new shelf's record, saved: a
-- shelf on a collection of that name (made if there is none; an existing one
-- is shown as it is), after the shelf `after_id` (else last). view_mode: the
-- look of the shelf the book was added from ("covers" | "list" | "spines"),
-- which the new one takes; else spines, where the order reads as a shelf
-- and ornaments stand among the books. As spines, each book faces out or
-- stands spine out as the reader chooses (Arrange). nil when the name
-- cannot be a collection's.
function UI.newShelf(label, after_id, view_mode)
    local TM = TabModel()
    local tabs = TM.load()
    label = type(label) == "string" and label:gsub("^%s+", ""):gsub("%s+$", "") or ""
    if label == "" then label = UI.freeName() end
    local name = Curated().create(label)
    if not name then return nil end
    local tab = TM.newTab(tabs, label)
    tab.pending = nil
    tab.source = { kind = "collection", id = name }
    local ok, Editor = pcall(require, "lib/bookshelf_chip_editor")
    tab.sort_priority = (ok and Editor and Editor.sourceSortDefaults and Editor.sourceSortDefaults("collection"))
        or { { key = "collection_order", reverse = false }, { key = "last_opened", reverse = true } }
    tab.view_mode = (view_mode == "covers" or view_mode == "list") and view_mode or "spines"
    tab.spine_face_out = { chosen = true }
    -- No dealt ornaments: a hand-ordered shelf is arranged by pinning
    -- pieces where they belong (maintainer).
    tab.ornament_frequency = 0
    TM.insertAfter(tabs, after_id, tab)
    TM.save(tabs)
    return tab
end

-- doneText(label, n, removed) -> what the reader is told once a tap in the
-- chooser has put `n` books on the shelf `label` (or taken them off).
function UI.doneText(label, n, removed)
    if removed then
        if n == 1 then return T(_("Taken off %1"), label) end
        return T(_("%1 books taken off %2"), n, label)
    end
    if n == 1 then return T(_("Added to %1"), label) end
    return T(_("%1 books added to %2"), n, label)
end

-- _page(paths, on_change, on_new) -> the chooser's page: one card a shelf,
-- on when every book is on it; then a way to make a shelf. on_change(label,
-- n, removed) after a tap changed a list: which shelf, how many books, and
-- whether they came off; on_new() asks for a new shelf.
function UI._page(paths, on_change, on_new)
    local blocks = {}
    local shelves = UI.shelves()
    for _i, s in ipairs(shelves) do
        local st = UI.state(s.list, paths)
        local n = Curated().count(s.list)
        -- What a tap will do, on every card: a lit one takes the book OFF,
        -- under a window titled "Add to shelf".
        local desc
        if st == "all" then
            desc = #paths == 1 and _("This book is on it. Tap to take it off.")
                or _("These books are on it. Tap to take them off.")
        elseif st == "some" then desc = _("Some of these books are on it. Tap to add the rest.")
        elseif n == 0 then desc = _("Empty. Tap to add.")
        elseif n == 1 then desc = _("1 book. Tap to add.")
        else desc = T(_("%1 books. Tap to add."), n) end
        blocks[#blocks + 1] = { type = "option", text = s.label, icon = UI.ICON_SHELF, desc = desc,
            on = st == "all",
            callback = function()
                local n = UI.toggle(s.list, paths)
                if n > 0 then on_change(s.label, n, st == "all") end
            end }
    end
    if #shelves == 0 then
        blocks[#blocks + 1] = { type = "heading", text = _("No shelves of your own yet") }
    end
    blocks[#blocks + 1] = { type = "option", text = _("New shelf") .. "\xE2\x80\xA6", icon = UI.ICON_NEW,
        desc = #shelves == 0
            and _("A shelf of books you pick, in the order you place them: a home shelf, a to-be-read pile. Kept as a KOReader collection.")
            or nil,
        callback = on_new }
    return { blocks = blocks }
end

-- pick{ paths, after_id, view_mode, on_done }: the chooser, for one book or
-- many. A tap on a shelf does it, closes the chooser and says what was done
-- (it stayed open with the card lit, which read as the tap doing nothing:
-- maintainer); on_done(changed) as it closes. view_mode: the look on screen,
-- for a shelf made here (newShelf).
function UI.pick(opts)
    local paths = opts.paths or {}
    if #paths == 0 then return end
    local UIManager = require("ui/uimanager")
    local changed = false
    local dialog
    local function finish(label, n, removed)
        changed = true
        -- Its own dismiss: that is what runs on_close (on_done).
        if dialog then dialog:_dismiss() end
        pcall(function()
            UIManager:show(require("ui/widget/notification"):new{
                text = UI.doneText(label, n, removed == true) })
        end)
    end
    local onChange = finish
    local function askName()
        local InputDialog = require("ui/widget/inputdialog")
        local Screen = require("device").screen
        local input
        local function make()
            local name = input:getInputText()
            UIManager:close(input)
            local tab = UI.newShelf(name, opts.after_id, opts.view_mode)
            if not tab then
                UIManager:show(require("ui/widget/infomessage"):new{
                    text = _("That name cannot be used for a shelf of your own."), timeout = 3 })
                return
            end
            -- An existing collection of that name may hold some already.
            Curated().addMany(tab.source.id, paths)
            opts.made_shelf = true
            finish(tab.label, #paths, false)
        end
        input = InputDialog:new{
            title = _("Shelf name"),
            input = "",
            input_hint = _("My shelf"),
            allow_newline = false,
            text_height = Screen:scaleBySize(40),
            buttons = { {
                { text = _("Cancel"), id = "close", callback = function() UIManager:close(input) end },
                { text = _("Create"), is_enter_default = true, callback = make },
            } },
        }
        UIManager:show(input)
        input:onShowKeyboard()
    end
    dialog = require("lib/bookshelf_page_dialog").show{
        title = #paths == 1 and _("Add to shelf") or T(_("Add %1 books to shelf"), #paths),
        page = function() return UI._page(paths, onChange, askName) end,
        on_close = function()
            if opts.on_done then opts.on_done(changed, opts.made_shelf == true) end
        end,
    }
    return dialog
end

-- ── A book among the pieces on its shelf ────────────────────────────────────
-- Pinned ornaments and other shelf modules sit `after` so many books (tab
-- .shelf_modules; ties keep list order). The books' order is the list's. The
-- two together are the shelf, so a step along it moves a book past the ONE
-- thing beside it, whichever kind that is.

-- step(n_books, mods, idx, dir) -> what one step of book `idx` (its place
-- among the books) does, dir 1 right / -1 left, or nil at the shelf's end:
--   { kind = "book", to = <place> }                 swap with the next book
--   { kind = "piece", id, after, first = bool }     the piece hops over it
function UI.step(n_books, mods, idx, dir)
    if not (n_books and idx) or n_books < 1 or idx < 1 or idx > n_books then return nil end
    local beside = (dir == 1) and idx or (idx - 1)
    local piece
    for _i, m in ipairs(mods or {}) do
        if (tonumber(m.after) or 0) == beside then
            -- Right: the first of them is the one touching the book. Left:
            -- the last.
            if dir == 1 then piece = piece or m else piece = m end
        end
    end
    if piece then
        if dir == 1 then return { kind = "piece", id = piece.id, after = idx - 1, first = false } end
        return { kind = "piece", id = piece.id, after = idx, first = true }
    end
    local to = idx + dir
    if to < 1 or to > n_books then return nil end
    return { kind = "book", to = to }
end

-- applyStep(mods, st): a "piece" step, on the module list itself. The piece
-- lands touching the book: last of the pieces before it, or first of those
-- after it.
function UI.applyStep(mods, st)
    if not (mods and st and st.kind == "piece") then return false end
    for i, m in ipairs(mods) do
        if m.id == st.id then
            table.remove(mods, i)
            m.after = st.after
            if st.first then table.insert(mods, 1, m) else mods[#mods + 1] = m end
            return true
        end
    end
    return false
end

-- atEdge(mods, n_books, idx, dir) -> is the book already the very first (-1)
-- or last (1) thing on the shelf, pieces included?
function UI.atEdge(mods, n_books, idx, dir)
    if dir == 1 then
        if idx ~= n_books then return false end
        for _i, m in ipairs(mods or {}) do
            if (tonumber(m.after) or 0) >= n_books then return false end
        end
        return true
    end
    if idx ~= 1 then return false end
    for _i, m in ipairs(mods or {}) do
        if (tonumber(m.after) or 0) <= 0 then return false end
    end
    return true
end

-- toEdge(mods, n_books, idx, dir) -> the book's new place: the very start
-- (-1) or end (1) of the shelf, ahead of or after every piece too. Changes
-- the module list; the caller moves the book among the books.
function UI.toEdge(mods, n_books, idx, dir)
    local to = (dir == 1) and n_books or 1
    if mods then
        if idx ~= to then
            UI.shiftForRemove(mods, idx)
            UI.shiftForInsert(mods, to)
        end
        -- The pieces still outside it come inside, keeping their order.
        local hop, rest = {}, {}
        for _i, m in ipairs(mods) do
            local a = tonumber(m.after) or 0
            if (dir == 1 and a >= n_books) or (dir ~= 1 and a <= 0) then hop[#hop + 1] = m
            else rest[#rest + 1] = m end
        end
        if #hop > 0 then
            for _i, m in ipairs(hop) do m.after = (dir == 1) and (n_books - 1) or 1 end
            for k = #mods, 1, -1 do mods[k] = nil end
            if dir == 1 then
                for _i, m in ipairs(rest) do mods[#mods + 1] = m end
                for _i, m in ipairs(hop) do mods[#mods + 1] = m end
            else
                for _i, m in ipairs(hop) do mods[#mods + 1] = m end
                for _i, m in ipairs(rest) do mods[#mods + 1] = m end
            end
        end
    end
    return to
end

-- ── The move buttons, in either reading direction ───────────────────────────
-- In a right-to-left language KOReader mirrors the shelf's rows, so place 1
-- is at the right: "Right" has to move the book towards the right of the
-- SCREEN, a place back. Start and End stay the shelf's start and end.

-- moveChips(mirrored) -> the six buttons in the order to hand the row:
-- { key, step = place change | nil, edge = -1 | 1 | nil, page = -1 | 1 | nil,
-- icon }: one job each. Start and End are the shelf's; the two Page buttons
-- put it first on the page before or after (a pinned ornament's menu has the
-- same six: maintainer). icon is "first" | "page_prev" | "prev" | "next" |
-- "page_next" | "last": the glyph pointing the way the book goes on screen.
-- The row is mirrored as it is laid out, so right to left the list comes
-- back to front, for Left to stand on the left.
function UI.moveChips(mirrored)
    if mirrored then
        return {
            { key = "start",     edge = -1, icon = "last" },
            { key = "page_prev", page = -1, icon = "page_next" },
            { key = "right",     step = -1, icon = "next" },
            { key = "left",      step = 1,  icon = "prev" },
            { key = "page_next", page = 1,  icon = "page_prev" },
            { key = "end",       edge = 1,  icon = "first" },
        }
    end
    return {
        { key = "start",     edge = -1, icon = "first" },
        { key = "page_prev", page = -1, icon = "page_prev" },
        { key = "left",      step = -1, icon = "prev" },
        { key = "right",     step = 1,  icon = "next" },
        { key = "page_next", page = 1,  icon = "page_next" },
        { key = "end",       edge = 1,  icon = "last" },
    }
end

-- swipeStep(direction, mirrored) -> the place change of a swipe on the book.
function UI.swipeStep(direction, mirrored)
    local d = direction == "east" and 1 or direction == "west" and -1 or nil
    if d and mirrored then d = -d end
    return d
end

-- ── Pieces stay beside their book ───────────────────────────────────────────
-- `after` is a count of books, so a book added, removed or moved anywhere
-- else (the chooser, KOReader's own collection view, a deleted file, a
-- second shelf on the collection) slid every piece along by one. Each piece
-- also remembers the book on its left (`anchor`: its path, or false for a
-- piece leading the shelf) and the count it had when it noted that
-- (`anchor_at`). When the shelf is next shown the count is put right from
-- the book. A count that no longer matches `anchor_at` was changed by
-- someone who knows nothing of anchors (the piece's own menu): it is
-- believed, and the piece takes the book now on its left.

local function anchorOne(m, shown)
    local a = math.max(0, math.min(#shown, math.floor(tonumber(m.after) or 0)))
    local anchor = a > 0 and shown[a] or false
    local changed = m.anchor ~= anchor or m.anchor_at ~= a or m.after ~= a
    m.after, m.anchor, m.anchor_at = a, anchor, a
    return changed
end

-- anchorPieces(mods, shown) -> true when anything was noted: every piece
-- takes the book on its left, from its count and the books as shown.
function UI.anchorPieces(mods, shown)
    local changed = false
    for _i, m in ipairs(mods or {}) do
        if anchorOne(m, shown) then changed = true end
    end
    return changed
end

-- reconcilePieces(mods, shown) -> true when a count was put right. A piece
-- never anchored is left alone.
function UI.reconcilePieces(mods, shown)
    if not mods then return false end
    local at = {}
    for i, fp in ipairs(shown) do at[fp] = i end
    local changed = false
    for _i, m in ipairs(mods) do
        if m.anchor ~= nil then
            local idx = m.anchor and at[m.anchor] or nil
            if (tonumber(m.after) or 0) ~= m.anchor_at then
                -- Moved by something else since: its count is the truth.
                if anchorOne(m, shown) then changed = true end
            elseif m.anchor == false then
                if m.after ~= 0 then m.after, m.anchor_at = 0, 0; changed = true end
            elseif idx then
                if idx ~= m.after then m.after, m.anchor_at = idx, idx; changed = true end
            else
                -- Its book has gone from the shelf: it closes up to the
                -- book before that one.
                m.after = math.max(0, (tonumber(m.anchor_at) or 0) - 1)
                anchorOne(m, shown)
                changed = true
            end
        end
    end
    return changed
end

-- A book left the shelf from place k, or one went in at place k: every piece
-- keeps the book on its left.
function UI.shiftForRemove(mods, k)
    for _i, m in ipairs(mods or {}) do
        local a = tonumber(m.after) or 0
        if a >= k then m.after = a - 1 end
    end
end
function UI.shiftForInsert(mods, k)
    for _i, m in ipairs(mods or {}) do
        local a = tonumber(m.after) or 0
        if a >= k then m.after = a + 1 end
    end
end

return UI
