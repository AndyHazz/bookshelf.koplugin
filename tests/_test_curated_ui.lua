-- tests/_test_curated_ui.lua
-- lib/bookshelf_curated_ui: what a reader does with hand-ordered shelves
-- (issue 390): put books on one from a book's menu and make a new one on the
-- way. A hand-ordered shelf is a KOReader collection shown as a shelf. The
-- parts with decisions in them are tested here; the windows are rendered on
-- the rig.
package.path = "./?.lua;./?/init.lua;" .. package.path

local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq

package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }
package.loaded["ffi/util"] = { template = function(s, ...)
    local a = { ... }
    return (s:gsub("%%(%d)", function(i) return tostring(a[tonumber(i)]) end))
end }

-- Collections in memory, with lib/bookshelf_curated's contract.
local lists
local Curated = {
    create = function(name)
        if type(name) ~= "string" or name == "" or name == "favorites" then return nil end
        lists[name] = lists[name] or {}
        return name
    end,
    exists = function(id) return lists[id] ~= nil end,
    has = function(id, fp) for _i, f in ipairs(lists[id] or {}) do if f == fp then return true end end return false end,
    add = function(id, fp)
        if not lists[id] then return false end
        for _i, f in ipairs(lists[id]) do if f == fp then return false end end
        table.insert(lists[id], fp); return true
    end,
    remove = function(id, fp)
        for i, f in ipairs(lists[id] or {}) do if f == fp then table.remove(lists[id], i); return true end end
        return false
    end,
    books = function(id) return lists[id] or {} end,
    count = function(id) return #(lists[id] or {}) end,
}
Curated.addMany = function(id, fps)
    local n = 0
    for _i, fp in ipairs(fps) do if Curated.add(id, fp) then n = n + 1 end end
    return n
end
Curated.removeMany = function(id, fps)
    local n = 0
    for _i, fp in ipairs(fps) do if Curated.remove(id, fp) then n = n + 1 end end
    return n
end
package.loaded["lib/bookshelf_curated"] = Curated
package.loaded["readcollection"] = { default_collection_name = "favorites" }

local tabs, saves
package.loaded["lib/bookshelf_tab_model"] = {
    load = function() return tabs end,
    save = function(tb) tabs = tb; saves = saves + 1 end,
    newTab = function(tb, label)
        return { id = "custom_" .. (#tb + 1), label = label, source = { kind = "none" },
                 filter = {}, sort_priority = { { key = "title" } }, enabled = true, pending = true }
    end,
    insertAfter = function(tb, anchor, new)
        for i, x in ipairs(tb) do if x.id == anchor then table.insert(tb, i + 1, new); return end end
        tb[#tb + 1] = new
    end,
    isCardOnly = function(x) return x.card_only == true end,
}
package.loaded["lib/bookshelf_chip_editor"] = {
    sourceSortDefaults = function(kind)
        return kind == "collection" and { { key = "collection_order", reverse = false },
                                          { key = "last_opened", reverse = true } } or nil
    end,
}

local UI = require("lib/bookshelf_curated_ui")

local function reset()
    lists, saves = { ["Best of 2026"] = { "/b/a" }, TBR = {}, favorites = { "/b/f" } }, 0
    tabs = {
        { id = "all", label = "Home", source = { kind = "all" }, enabled = true },
        { id = "custom_1", label = "Best of 2026", source = { kind = "collection", id = "Best of 2026" }, enabled = true },
        { id = "custom_2", label = "To read", source = { kind = "collection", id = "TBR" }, enabled = true },
        { id = "custom_3", label = "Card", source = { kind = "collection", id = "TBR" }, enabled = true, card_only = true },
        { id = "custom_4", label = "Half made", source = { kind = "collection", id = "TBR" }, pending = true },
        { id = "custom_5", label = "A pinned tag", source = { kind = "collection", id = "space-opera" }, enabled = true },
        { id = "custom_6", label = "To read again", source = { kind = "collection", id = "TBR" }, enabled = true },
        { id = "favorites", label = "Favorites", source = { kind = "favorites" }, enabled = true },
    }
end

t.test("shelves lists each collection's shelf once, in shelf order", function()
    reset()
    local s = UI.shelves()
    eq(#s, 2)
    eq(s[1].label, "Best of 2026"); eq(s[1].list, "Best of 2026"); eq(s[1].id, "custom_1")
    eq(s[2].label, "To read"); eq(s[2].list, "TBR")
end)

t.test("a pinned tag is not a shelf to put books on: no collection is behind it", function()
    reset()
    eq(UI.listOf(tabs[6]), nil)
end)

t.test("the Favorites shelf is not one to place by hand, nor in the chooser", function()
    -- It is not sorted by its collection's order, so a move would write an
    -- order nothing shows; and the book menu has its own card for it.
    reset()
    eq(UI.listOf(tabs[8]), nil)
    for _i, s in ipairs(UI.shelves()) do assert(s.list ~= "favorites") end
    eq(UI.listOf(tabs[1]), nil)
end)

t.test("state says how much of a set of books is on a shelf", function()
    reset()
    eq(UI.state("Best of 2026", { "/b/a" }), "all")
    eq(UI.state("Best of 2026", { "/b/a", "/b/b" }), "some")
    eq(UI.state("Best of 2026", { "/b/b" }), "none")
    eq(UI.state("Best of 2026", {}), "none")
end)

t.test("toggle adds books that are missing, and takes them off when all are on", function()
    reset()
    eq(UI.toggle("TBR", { "/b/x", "/b/y" }), 2)
    eq(table.concat(lists.TBR, " "), "/b/x /b/y")
    eq(UI.toggle("TBR", { "/b/x", "/b/y", "/b/z" }), 1, "some on: the rest are added")
    eq(UI.toggle("TBR", { "/b/x", "/b/y" }), 2, "all on: taken off")
    eq(table.concat(lists.TBR, " "), "/b/z")
end)

t.test("a new shelf is a saved shelf on a new collection, beside the one on screen, in spines", function()
    reset()
    local tab = UI.newShelf("Beach reads", "custom_1")
    assert(tab, "no shelf made")
    eq(tab.label, "Beach reads")
    eq(tab.source.kind, "collection"); eq(tab.source.id, "Beach reads")
    eq(Curated.exists("Beach reads"), true)
    eq(tab.pending, nil, "left pending: start-up would remove it")
    eq(tab.sort_priority[1].key, "collection_order")
    eq(tab.view_mode, "spines")
    -- Maintainer: "New collection shelves should have ornaments set to none
    -- by default, as the primary way to arrange is by placing pinned
    -- ornament modules."
    eq(tab.ornament_frequency, 0, "dealt ornaments on a new collection shelf")
    eq(tabs[3], tab, "not placed after the shelf on screen")
    eq(saves, 1)
end)

t.test("a new shelf looks like the shelf the book was added from", function()
    -- Maintainer: a first shelf made from a covers shelf opened as one lone
    -- spine.
    reset()
    eq(UI.newShelf("From covers", "custom_1", "covers").view_mode, "covers")
    eq(UI.newShelf("From a list", "custom_1", "list").view_mode, "list")
    eq(UI.newShelf("From spines", "custom_1", "spines").view_mode, "spines")
    -- Auto is a rule about drill levels, not a look to copy; nor is nonsense.
    eq(UI.newShelf("From auto", "custom_1", "auto").view_mode, "spines")
    eq(UI.newShelf("From junk", "custom_1", 7).view_mode, "spines")
end)

t.test("a new shelf lets the reader choose face out or spine out for each book", function()
    -- Whatever view it opens in: switched to spines later, it is ready.
    reset()
    local tab = UI.newShelf("Chosen", "custom_1", "covers")
    eq(type(tab.spine_face_out), "table")
    eq(tab.spine_face_out.chosen, true)
end)

t.test("a new shelf named for a collection that exists shows that collection", function()
    reset()
    local tab = UI.newShelf("  Best of 2026 ", nil)
    eq(tab.source.id, "Best of 2026")
    eq(table.concat(lists["Best of 2026"], " "), "/b/a", "the collection was emptied or replaced")
end)

t.test("a new shelf with no name gets one that is free", function()
    reset()
    eq(UI.newShelf("   ", nil).label, "My shelf")
    eq(UI.newShelf(nil, nil).label, "My shelf 2")
end)

t.test("a name that cannot be a collection makes no shelf", function()
    reset()
    eq(UI.newShelf("favorites", nil), nil)
    eq(saves, 0)
end)

t.test("the chooser's page shows each shelf, lit when the book is on it", function()
    reset()
    local model = UI._page({ "/b/a" }, function() end, function() end)
    local opts = {}
    for _i, b in ipairs(model.blocks) do if b.type == "option" then opts[#opts + 1] = b end end
    -- Each card says what a tap will do: a lit one takes the book OFF, under
    -- a window titled "Add to shelf" (a first-time reader lost a book to it).
    eq(opts[1].text, "Best of 2026"); eq(opts[1].on, true)
    eq(opts[1].desc, "This book is on it. Tap to take it off.")
    eq(opts[2].text, "To read"); eq(opts[2].on, false); eq(opts[2].desc, "Empty. Tap to add.")
    lists.TBR = { "/b/x", "/b/y" }
    model = UI._page({ "/b/a" }, function() end, function() end)
    eq(model.blocks[2].desc, "2 books. Tap to add.")
    lists.TBR = { "/b/x" }
    model = UI._page({ "/b/a", "/b/x" }, function() end, function() end)
    eq(model.blocks[1].desc, "Some of these books are on it. Tap to add the rest.")
    lists.TBR = { "/b/a", "/b/x" }
    model = UI._page({ "/b/a", "/b/x" }, function() end, function() end)
    eq(model.blocks[2].desc, "These books are on it. Tap to take them off.")
    assert(opts[#opts].text:find("New shelf", 1, true), "no way to make a new shelf from here")
end)

t.test("a tap on a shelf in the chooser changes the collection and reports it", function()
    reset()
    local changed = 0
    local model = UI._page({ "/b/q" }, function() changed = changed + 1 end, function() end)
    model.blocks[1].callback()
    eq(Curated.has("Best of 2026", "/b/q"), true)
    eq(changed, 1)
end)

t.test("the tap says which shelf, how many books and which way they went", function()
    reset()
    local got
    local function note(label, n, removed) got = { label, n, removed } end
    UI._page({ "/b/q", "/b/r" }, note, function() end).blocks[1].callback()
    eq(got[1], "Best of 2026"); eq(got[2], 2); eq(got[3], false)
    -- All on it now: the same tap takes them off.
    UI._page({ "/b/q", "/b/r" }, note, function() end).blocks[1].callback()
    eq(got[2], 2); eq(got[3], true)
    eq(Curated.has("Best of 2026", "/b/q"), false)
end)

t.test("what the reader is told once the chooser has closed", function()
    -- Maintainer, bulk-adding on the PW5: "the add books menu does nothing
    -- when I tapped the TBR collection". It had added them, lit the card and
    -- stayed open.
    eq(UI.doneText("TBR", 1, false), "Added to TBR")
    eq(UI.doneText("TBR", 13, false), "13 books added to TBR")
    eq(UI.doneText("TBR", 1, true), "Taken off TBR")
    eq(UI.doneText("TBR", 13, true), "13 books taken off TBR")
end)

t.test("picking a shelf closes the chooser and says what happened", function()
    reset()
    local shown, closed, page_fn, on_close = {}, 0, nil, nil
    -- As lib/bookshelf_page_dialog: on_close runs from its own _dismiss, NOT
    -- from UIManager:close (the rig: the chooser went, the shelf behind was
    -- never told).
    local dialog = { refresh = function() end }
    function dialog:_dismiss() closed = closed + 1; on_close() end
    package.loaded["lib/bookshelf_page_dialog"] = { show = function(o)
        page_fn, on_close = o.page, o.on_close
        return dialog
    end }
    package.loaded["ui/uimanager"] = {
        show = function(_s, w) shown[#shown + 1] = w end,
        close = function() closed = closed + 1 end,
    }
    package.loaded["ui/widget/notification"] = { new = function(_s, o) return o end }
    local done
    UI.pick{ paths = { "/b/q", "/b/r" }, on_done = function(changed) done = changed end }
    page_fn().blocks[1].callback()
    eq(closed, 1, "the chooser stayed open: the tap read as doing nothing")
    eq(done, true)
    eq(shown[1] and shown[1].text, "2 books added to Best of 2026")
end)

t.test("with no shelf of the reader's own yet the chooser says what one is", function()
    reset()
    tabs = { tabs[1] }
    local model = UI._page({ "/b/a" }, function() end, function() end)
    local text = {}
    for _i, b in ipairs(model.blocks) do text[#text + 1] = (b.text or "") .. " " .. (b.desc or "") end
    text = table.concat(text, "\n")
    assert(text:find("in the order you place them", 1, true), text)
    assert(text:find("KOReader collection", 1, true), text)
    assert(text:find("New shelf", 1, true), text)
end)

-- ── Moving a book along its shelf, among pinned pieces ────────────────────
-- A pinned ornament (or any module on the shelf) sits `after` so many books.
-- A step moves the book past the ONE thing beside it, a book or a piece.

local function mods(...)
    local out = {}
    for _i, spec in ipairs({ ... }) do out[#out + 1] = { id = spec[1], after = spec[2] } end
    return out
end
local function show(n, ms, order)
    -- The shelf as a string: books by letter, pieces by id.
    local out = {}
    local by = {}
    for _i, m in ipairs(ms) do by[m.after] = by[m.after] or {}; table.insert(by[m.after], m.id) end
    for _i, id in ipairs(by[0] or {}) do out[#out + 1] = id end
    for i = 1, n do
        out[#out + 1] = order[i]
        for _j, id in ipairs(by[i] or {}) do out[#out + 1] = id end
    end
    return table.concat(out, " ")
end

t.test("a step with a book beside it swaps the two books", function()
    local st = UI.step(3, mods(), 2, 1)
    eq(st.kind, "book"); eq(st.to, 3)
    st = UI.step(3, mods(), 2, -1)
    eq(st.kind, "book"); eq(st.to, 1)
end)

t.test("a step at the end of the shelf goes nowhere", function()
    eq(UI.step(3, mods(), 3, 1), nil)
    eq(UI.step(3, mods(), 1, -1), nil)
    eq(UI.step(0, mods(), 1, 1), nil)
end)

t.test("a step right with a piece beside it hops the piece, not the next book", function()
    -- A [x] B  >  [x] A B
    local ms = mods({ "x", 1 })
    local st = UI.step(2, ms, 1, 1)
    eq(st.kind, "piece")
    UI.applyStep(ms, st)
    eq(show(2, ms, { "A", "B" }), "x A B")
end)

t.test("a step left with a piece beside it hops the piece", function()
    -- A [x] B  >  A B [x]
    local ms = mods({ "x", 1 })
    local st = UI.step(2, ms, 2, -1)
    eq(st.kind, "piece")
    UI.applyStep(ms, st)
    eq(show(2, ms, { "A", "B" }), "A B x")
end)

t.test("with two pieces between, a step hops the nearer one only", function()
    -- A [x] [y] B: A steps right > [x] A [y] B
    local ms = mods({ "x", 1 }, { "y", 1 })
    UI.applyStep(ms, UI.step(2, ms, 1, 1))
    eq(show(2, ms, { "A", "B" }), "x A y B")
    -- A [x] [y] B: B steps left > A [x] B [y]
    ms = mods({ "x", 1 }, { "y", 1 })
    UI.applyStep(ms, UI.step(2, ms, 2, -1))
    eq(show(2, ms, { "A", "B" }), "A x B y")
end)

t.test("a hopped piece lands next to the book among pieces already there", function()
    -- [w] A [x] B: A steps right > [w] [x] A B   (x lands after w, beside A)
    local ms = mods({ "w", 0 }, { "x", 1 })
    UI.applyStep(ms, UI.step(2, ms, 1, 1))
    eq(show(2, ms, { "A", "B" }), "w x A B")
    -- A [x] B [w]: B steps left > A B [x] [w]   (x lands before w, beside B)
    ms = mods({ "x", 1 }, { "w", 2 })
    UI.applyStep(ms, UI.step(2, ms, 2, -1))
    eq(show(2, ms, { "A", "B" }), "A B x w")
end)

t.test("a piece keeps the book on its left when a book leaves the shelf", function()
    -- A B [x] C, B removed > A [x] C
    local ms = mods({ "x", 2 })
    UI.shiftForRemove(ms, 2)
    eq(show(2, ms, { "A", "C" }), "A x C")
    -- [w] A B [x], A removed > [w] B [x]
    ms = mods({ "w", 0 }, { "x", 2 })
    UI.shiftForRemove(ms, 1)
    eq(show(1, ms, { "B" }), "w B x")
end)

t.test("a piece keeps its neighbors when a book is put in ahead of it", function()
    -- A [x] B, N put first > N A [x] B
    local ms = mods({ "x", 1 })
    UI.shiftForInsert(ms, 1)
    eq(show(3, ms, { "N", "A", "B" }), "N A x B")
    -- put last: nothing moves
    ms = mods({ "x", 1 })
    UI.shiftForInsert(ms, 3)
    eq(show(3, ms, { "A", "B", "N" }), "A x B N")
end)

t.test("to the start puts the book before everything, pieces included", function()
    -- [w] A [x] B C: C to the start > C [w] A [x] B
    local ms = mods({ "w", 0 }, { "x", 1 })
    eq(UI.toEdge(ms, 3, 3, -1), 1)
    eq(show(3, ms, { "C", "A", "B" }), "C w A x B")
    -- [w] A B: A is the first BOOK but not the first thing > A [w] B
    ms = mods({ "w", 0 })
    eq(UI.atEdge(ms, 2, 1, -1), false, "a piece still stands before it")
    eq(UI.toEdge(ms, 2, 1, -1), 1)
    eq(show(2, ms, { "A", "B" }), "A w B")
    eq(UI.atEdge(ms, 2, 1, -1), true)
end)

t.test("to the end puts the book after everything", function()
    -- A B [x] C [y]: A to the end > B [x] C [y] A
    local ms = mods({ "x", 2 }, { "y", 3 })
    eq(UI.toEdge(ms, 3, 1, 1), 3)
    eq(show(3, ms, { "B", "C", "A" }), "B x C y A")
    eq(UI.atEdge(ms, 3, 3, 1), true)
    eq(UI.atEdge(ms, 3, 2, 1), false)
end)

t.test("a book alone at an edge with no pieces is at the edge", function()
    eq(UI.atEdge(nil, 3, 1, -1), true); eq(UI.atEdge(nil, 3, 3, 1), true)
    eq(UI.atEdge(nil, 3, 2, -1), false)
    eq(UI.toEdge(nil, 3, 2, 1), 3)
end)

-- ── The move buttons, left to right and right to left ─────────────────────
-- In a right-to-left language KOReader mirrors the shelf: place 1 is at the
-- right. "Right" has to move the book towards the right of the SCREEN.

t.test("left to right: Start, Page, Left, Right, Page, End", function()
    -- Maintainer: books had Start and End, pinned ornaments had the page
    -- buttons; both have both.
    local c = UI.moveChips(false)
    local keys = {}
    for i, x in ipairs(c) do keys[i] = x.key end
    eq(table.concat(keys, " "), "start page_prev left right page_next end")
    eq(c[3].step, -1); eq(c[4].step, 1)
    eq(c[1].edge, -1); eq(c[6].edge, 1)
    eq(c[2].page, -1); eq(c[5].page, 1)
    eq(c[1].icon, "first"); eq(c[2].icon, "page_prev"); eq(c[3].icon, "prev")
    eq(c[4].icon, "next"); eq(c[5].icon, "page_next"); eq(c[6].icon, "last")
    -- One job a button.
    for _i, x in ipairs(c) do
        local n = (x.step and 1 or 0) + (x.edge and 1 or 0) + (x.page and 1 or 0)
        eq(n, 1, x.key)
    end
    eq(UI.swipeStep("east", false), 1); eq(UI.swipeStep("west", false), -1)
    eq(UI.swipeStep("north", false), nil)
end)

t.test("right to left: Right moves a place BACK, which is right on the screen", function()
    local c = UI.moveChips(true)
    local by, keys = {}, {}
    for i, x in ipairs(c) do by[x.key] = x; keys[i] = x.key end
    eq(by.right.step, -1); eq(by.left.step, 1)
    eq(by.start.edge, -1, "Start is still place 1, which is at the right there")
    eq(by.page_prev.page, -1, "the page before is still the page before")
    -- The row is mirrored as it is laid out, so the list is given back to
    -- front for Left to come out on the left: on screen End, Page, Left,
    -- Right, Page, Start.
    eq(table.concat(keys, " "), "start page_prev right left page_next end")
    -- The glyphs point the way the book goes on the screen.
    eq(by.left.icon, "prev"); eq(by.right.icon, "next")
    eq(by.start.icon, "last"); eq(by["end"].icon, "first")
    eq(by.page_prev.icon, "page_next"); eq(by.page_next.icon, "page_prev")
    eq(UI.swipeStep("east", true), -1); eq(UI.swipeStep("west", true), 1)
end)

t.test("a name is found for a shelf nobody named", function()
    reset()
    eq(UI.freeName(), "My shelf")
    lists["My shelf"] = {}
    eq(UI.freeName(), "My shelf 2")
end)

-- ── Pieces stay beside their book ───────────────────────────────────────────
-- `after` is a count, so a book added, removed or moved anywhere else (the
-- chooser, KOReader's own collection view, a deleted file, a second shelf on
-- the collection) slid every piece along. Each piece remembers the book on
-- its left; the count is put right from that when the shelf is next shown.

t.test("a piece remembers the book on its left", function()
    local ms = mods({ "w", 0 }, { "x", 2 })
    UI.anchorPieces(ms, { "A", "B", "C" })
    eq(ms[1].anchor, false, "leading the shelf: no book on its left")
    eq(ms[2].anchor, "B"); eq(ms[2].anchor_at, 2)
end)

t.test("a book added ahead of a piece elsewhere: the piece stays beside its book", function()
    local ms = mods({ "x", 1 })
    UI.anchorPieces(ms, { "A", "B" })
    eq(UI.reconcilePieces(ms, { "N", "A", "B" }), true)
    eq(show(3, ms, { "N", "A", "B" }), "N A x B")
    eq(UI.reconcilePieces(ms, { "N", "A", "B" }), false, "settled: nothing more to change")
end)

t.test("a book removed elsewhere, and the books reordered elsewhere", function()
    local ms = mods({ "x", 2 })
    UI.anchorPieces(ms, { "A", "B", "C" })
    UI.reconcilePieces(ms, { "B", "C" })
    eq(show(2, ms, { "B", "C" }), "B x C")
    UI.reconcilePieces(ms, { "C", "B" })
    eq(show(2, ms, { "C", "B" }), "C B x")
end)

t.test("a leading piece keeps leading", function()
    local ms = mods({ "w", 0 })
    UI.anchorPieces(ms, { "A" })
    UI.reconcilePieces(ms, { "N", "A" })
    eq(show(2, ms, { "N", "A" }), "w N A")
end)

t.test("the book a piece stood beside has gone: the piece closes up to the one before", function()
    -- A B [x] C, B taken off somewhere else > A [x] C (not A C [x])
    local ms = mods({ "x", 2 })
    UI.anchorPieces(ms, { "A", "B", "C" })
    UI.reconcilePieces(ms, { "A", "C" })
    eq(show(2, ms, { "A", "C" }), "A x C")
    eq(ms[1].anchor, "A", "and takes the book now on its left")
    -- The first book gone: the piece leads.
    ms = mods({ "x", 1 })
    UI.anchorPieces(ms, { "A", "B" })
    UI.reconcilePieces(ms, { "B" })
    eq(show(1, ms, { "B" }), "x B")
    -- Fewer books than its count: it stands at the end.
    ms = mods({ "x", 5 })
    UI.anchorPieces(ms, { "A", "B", "C", "D", "E" })
    UI.reconcilePieces(ms, { "A" })
    eq(ms[1].after, 1)
end)

t.test("a piece moved by its own menu is believed, not snapped back", function()
    -- The pinned piece's menu changes `after` and knows nothing of anchors.
    local ms = mods({ "x", 1 })
    UI.anchorPieces(ms, { "A", "B", "C" })
    ms[1].after = 2
    eq(UI.reconcilePieces(ms, { "A", "B", "C" }), true)
    eq(ms[1].after, 2); eq(ms[1].anchor, "B"); eq(ms[1].anchor_at, 2)
end)

t.test("a piece never anchored is left alone until it is", function()
    local ms = mods({ "x", 1 })
    eq(UI.reconcilePieces(ms, { "N", "A" }), false)
    eq(ms[1].after, 1); eq(ms[1].anchor, nil)
    eq(UI.reconcilePieces(nil, { "A" }), false)
end)

t.test("no pieces on the shelf: every step is a book swap, and the shifts are safe", function()
    eq(UI.step(2, nil, 1, 1).kind, "book")
    UI.shiftForRemove(nil, 1); UI.shiftForInsert(nil, 1)
end)

t.done()
