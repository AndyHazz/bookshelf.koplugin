-- tests/_test_cursor_follows_book.lua
-- Paging the shelf to keep a chosen book on screen across a view-size change
-- (BookshelfWidget:_setCursorToShow) -- issue #369.
--
-- Usage (from plugin root): lua tests/_test_cursor_follows_book.lua
--
-- THE BUG. This runs immediately after a collapse or expand -- that is what it
-- is for, and its own comment says to call it after toggling. But it clamped
-- with _clampCursor() and no total, which makes _maxCursor fall back to
-- self._total_pages: the page count for the view size we just LEFT.
--
-- Collapsing shrinks the view, so the real page count GROWS while the stale
-- one stays small, and the clamp drags the cursor backwards. The worst case is
-- a folder whose books all fit on ONE expanded page: _total_pages is 1, max
-- cursor comes out as 1, and tapping a book on the second collapsed page sent
-- the shelf to page 1 -- which is exactly what the reporter described, right
-- down to "a book that would be on page 2, or any page higher, in hero view".
--
-- bookshelf_widget.lua is 19k lines and needs the whole KOReader stack, so the
-- method is extracted by name and run against a plain table carrying only the
-- fields it touches. _maxCursor and _clampCursor are extracted with it, so the
-- interaction between the three is what is under test rather than a stub of it.

package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local Shelf = {}
do
    local src = io.open("lib/bookshelf_widget.lua"):read("a")
    for _i, name in ipairs({ "_setCursorToShow", "_maxCursor", "_clampCursor",
                             "_syncPageFromCursor", "_setExpanded",
                             "onSwipeShelvesUp", "onBookshelfToggleHero",
                             "_setSpineCursor", "_spineSkip",
                             "_noteSpineRows" }) do
        local body = src:match("\nfunction BookshelfWidget:" .. name
                               .. "%((.-)%)\n(.-)\nend\n")
        local args, code = src:match("\nfunction BookshelfWidget:" .. name
                                     .. "%((.-)%)\n(.-)\nend\n")
        assert(code, "BookshelfWidget:" .. name .. " is gone or was renamed")
        Shelf[name] = assert(load("return function(self" ..
            (args ~= "" and ", " .. args or "") .. ")\n" .. code .. "\nend"))()
    end
end

-- A shelf mid-collapse: the view size is already the NEW one, _total_pages is
-- still the old view's, which is the whole trap.
local function shelf(view, total_items, stale_total_pages)
    local s = {
        _cursor = 1,
        _total_items = total_items,
        _total_pages = stale_total_pages,
        _viewSize = function() return view end,
        -- The cursor stack asks the mode before doing view-size arithmetic
        -- (spine pages hold a variable count); these tests pin the fixed-view
        -- behaviour, so the stub answers covers.
        _isSpineMode = function() return false end,
    }
    for k, fn in pairs(Shelf) do s[k] = fn end
    return s
end

t.test("a book on the second collapsed page is followed, not abandoned", function()
    -- The reporter's case. 18 books: one expanded page of 20, two collapsed
    -- pages of 12. Tapping book 15 must land on the page holding it.
    local s = shelf(12, 18, 1)
    s:_setCursorToShow(15)
    eq(s._cursor, 13, "the shelf went back to page 1 instead of following")
    -- Only the CURSOR is asserted here. _syncPageFromCursor clamps its label
    -- against the same stale _total_pages, so page reads 1 at this instant --
    -- harmless, because the _rebuild that always follows recomputes both from
    -- the new view size. The cursor is what that rebuild slices with, so it is
    -- the output that has to be right.
end)

t.test("a stale page count cannot drag the cursor backwards", function()
    -- Same shape, further out: 30 books, expanded page count of 2, collapsed
    -- view of 12 means three real pages.
    local s = shelf(12, 30, 2)
    s:_setCursorToShow(25)
    eq(s._cursor, 25, "clamped against the page count of the view we left")
end)

t.test("a book on the first page still lands on the first page", function()
    local s = shelf(12, 18, 1)
    s:_setCursorToShow(3)
    eq(s._cursor, 1)
end)

t.test("the cursor is page-ALIGNED, not set to the book", function()
    -- The shelf pages in whole views; landing mid-page would leave the row
    -- boundaries out of step with the chevrons.
    local s = shelf(12, 100, 9)
    s:_setCursorToShow(14)
    eq(s._cursor, 13)
end)

t.test("a genuinely out-of-range index is still clamped", function()
    -- The clamp still has to do its job -- this is not about removing it.
    local s = shelf(12, 18, 1)
    s:_setCursorToShow(999)
    assert(s._cursor <= 13, "cursor ran past the end: " .. s._cursor)
end)

t.test("no total yet falls back to the old behaviour rather than erroring", function()
    -- Before the first fetch there is nothing to clamp against; _maxCursor's
    -- page-count path is the only answer available.
    local s = shelf(12, nil, 3)
    s:_setCursorToShow(14)
    assert(type(s._cursor) == "number" and s._cursor >= 1)
end)

t.test("a nil index is a no-op", function()
    -- _globalIndexOfFilepath answers nil when the book is not on the page.
    local s = shelf(12, 18, 1)
    s._cursor = 7
    s:_setCursorToShow(nil)
    eq(s._cursor, 7, "a book we could not locate moved the shelf anyway")
end)

-- ── The other half of #369: EXPANDING ────────────────────────────────────
--
-- The reporter's second case, and the one still open after the collapse fix
-- above shipped. Swiping up deliberately leaves the cursor where it was, so
-- the row the reader was looking at stays put and the books above it are a
-- swipe back away. Nothing re-checked that the cursor was still a legal page
-- start at the BIGGER view size, though. On a short folder it is not: six
-- books, a collapsed page of four, and the expanded page holds the lot -- so
-- there is no page to swipe back to, and the two books the collapsed page
-- ended on were all the reader could reach.
--
-- The globals below are what the extracted bodies reference as upvalues in
-- the real module.
_G.UIManager          = { setDirty = function() end }
_G.logger             = { dbg = function() end }
_G._gettime           = function() return 0 end
_G.BookshelfSettings  = { saved = {},
                          save  = function(k, v) _G.BookshelfSettings.saved[k] = v end,
                          flush = function() end }

-- A shelf about to expand: _viewSize answers the size for the CURRENT state,
-- the way the real one does, so the swipe sees the new size the moment the
-- flag flips.
local function expanding(collapsed_view, expanded_view, total_items, cursor)
    local s = {
        _expanded    = false,
        _cursor      = cursor,
        _total_items = total_items,
        _total_pages = math.max(1, math.ceil(total_items / collapsed_view)),
        _isSpineMode = function() return false end,
        _viewSize    = function(self_)
            return self_._expanded and expanded_view or collapsed_view
        end,
        _markOpdsNav    = function() end,
        _clearDpadFocus = function() end,
        _rebuild        = function(self_) self_._rebuilt = true end,
    }
    for k, fn in pairs(Shelf) do s[k] = fn end
    return s
end

t.test("expanding a short folder does not strand the books above the cursor", function()
    -- Six books, collapsed pages of four, so page 2 starts at book 5. The
    -- expanded page holds eight: book 5 is no longer a legal page start.
    local s = expanding(4, 8, 6, 5)
    s:onSwipeShelvesUp()
    eq(s._cursor, 1, "books 1-4 are unreachable on the expanded shelf")
end)

t.test("expanding a long shelf still leaves the top row on the top row", function()
    -- Why this is a clamp and not a re-alignment: the maintainer's ruling is
    -- that swiping up keeps the reader's row. 100 books, collapsed page of
    -- four at book 9, expanded page of twelve. Book 9 is a legal start -- 91
    -- books sit below it -- so nothing moves.
    local s = expanding(4, 12, 100, 9)
    s:onSwipeShelvesUp()
    eq(s._cursor, 9, "the expanded shelf jumped away from the reader's row")
end)

t.test("expanding when already expanded is still a no-op", function()
    local s = expanding(4, 8, 6, 5)
    s._expanded = true
    eq(s:onSwipeShelvesUp(), false, "a second swipe up rebuilt the shelf")
    assert(not s._rebuilt, "a second swipe up rebuilt the shelf")
end)

t.test("the toggle-hero action expands the same way a swipe does", function()
    -- onBookshelfToggleHero is the Dispatcher-bound "show/hide hero". It set
    -- the flag by hand, so it skipped everything _setExpanded does: the
    -- stranding clamp, the OPDS nav arming, and saving the state the file's
    -- own comment says only deliberate show/hide-hero actions write.
    _G.BookshelfSettings.saved = {}
    local s = expanding(4, 8, 6, 5)
    s:onBookshelfToggleHero()
    assert(s._expanded == true, "the action did not expand")
    eq(s._cursor, 1, "the action stranded the books above the cursor")
    eq(_G.BookshelfSettings.saved.home_expanded, true,
        "the action did not persist the state it changed")
end)

-- ── Spine shelves: pages of no fixed size ──────────────────────────────────
--
-- Found on the maintainer's PW5 while testing the fix above: page 2 of a
-- 243-book spine shelf shows books 35-79. Select one in the middle of the top
-- row, swipe up (35-114, the row kept, as designed), swipe down -- and the
-- shelf goes back to 1-34, with the book they chose on neither.
--
-- _setCursorToShow worked the page out as floor((idx-1)/view)*view+1, which
-- assumes every page holds `view` books. A spine page holds however many
-- spines fit, so on a spine shelf that is not a page start at all.
--
-- The first fix asked the page map. That was exact but PLANS EVERY BOOK ON THE
-- SHELF, and the maintainer felt the first collapse on the PW5 and asked about
-- libraries of 7,000 books. Their idea replaced it: the expanded render has
-- already laid out every row, so it knows the book each one starts with. The
-- collapse groups those rows into collapsed pages from the top and lands on
-- the chunk holding the chosen book. Nothing is planned; a page is named by
-- its first book, so any row start is a page start.

-- A shelf just collapsed from the expanded render at `cursor`: `rows` is what
-- that render noted (via _noteSpineRows), `n` the collapsed row count.
local function spineShelf(rows, cursor, n)
    local s = {
        _cursor      = cursor,
        chip         = "all",
        _total_items = 243,
        _spine_hist  = { { c = 1, s = 0 } },
        _spine_rows  = rows,
        _viewSize    = function() return 80 end,   -- a capacity ESTIMATE
        _nShelves    = function() return n or 2 end,
        _isSpineMode = function() return true end,
        _spinePageFirsts = function(self_) self_._built_map = true end,
        _spinePageIndexForCursor = function() return nil end,
    }
    for k, fn in pairs(Shelf) do s[k] = fn end
    return s
end

-- The maintainer's shelf, expanded at book 35: four rows starting at 35, 55,
-- 80 and 97. Collapsed to two rows, that is 35-79 and then 80-114.
local function rowsAt(cursor, starts, fps)
    local anchors = {}
    for i, c in ipairs(starts) do anchors[i] = { c = c, s = 0 } end
    return { anchors = anchors, row_of = fps or {}, c = cursor, s = 0, chip = "all" }
end
local ROWS = { 35, 55, 80, 97 }

t.test("collapsing a spine shelf returns to the page the reader came from", function()
    -- The reported case: a book in the top row of 35-79.
    local s = spineShelf(rowsAt(35, ROWS, { ["/b45"] = 1 }), 35)
    s:_setCursorToShow(45, "/b45")
    eq(s._cursor, 35, "the shelf left the page the chosen book is on")
    eq(#s._spine_hist, 1, "the way back from here was rewritten for nothing")
end)

t.test("a book in the second row of that page stays on it too", function()
    local s = spineShelf(rowsAt(35, ROWS, { ["/b60"] = 2 }), 35)
    s:_setCursorToShow(60, "/b60")
    eq(s._cursor, 35)
end)

t.test("a book further down the expanded shelf lands on its own page", function()
    -- Row 3 is the first row of the second collapsed page.
    local s = spineShelf(rowsAt(35, ROWS, { ["/b100"] = 4 }), 35)
    s:_setCursorToShow(100, "/b100")
    eq(s._cursor, 80, "rows 3-4 are the page after 35-79")
end)

t.test("back from there retraces the page the reader came from", function()
    local s = spineShelf(rowsAt(35, ROWS, { ["/b100"] = 4 }), 35)
    s:_setCursorToShow(100, "/b100")
    local top = s._spine_hist[#s._spine_hist]
    eq(top.c, 35, "a back-step would not return to 35-79")
    eq(#s._spine_hist, 2, "the older history was lost")
end)

t.test("every page above the landing one goes on the history, in order", function()
    -- Six rows expanded, two collapsed: landing on the third chunk (row 5)
    -- must be able to step back through rows 3 and 1.
    local s = spineShelf(rowsAt(35, { 35, 55, 80, 97, 115, 131 }, { ["/b120"] = 5 }), 35)
    s:_setCursorToShow(120, "/b120")
    eq(s._cursor, 115)
    eq(s._spine_hist[#s._spine_hist].c, 80)
    eq(s._spine_hist[#s._spine_hist - 1].c, 35)
end)

t.test("the row a BOOK is on beats the row its item starts on", function()
    -- A flattened series is ONE item spanning several rows, so its item index
    -- is where it starts, not where the chosen spine is. Item 55 starts row 2
    -- and runs through row 3; the book chosen is in row 2.
    local rows = rowsAt(35, { 35, 55, 55, 97 }, { ["/member"] = 2 })
    local s = spineShelf(rows, 35)
    s:_setCursorToShow(55, "/member")
    eq(s._cursor, 35, "the spine's own row was ignored for its item's")
end)

t.test("without a filepath the item index still finds a row", function()
    local s = spineShelf(rowsAt(35, ROWS), 35)
    s:_setCursorToShow(100)
    eq(s._cursor, 80)
end)

t.test("rows noted for another page are not trusted", function()
    -- The view-mode cycle calls this on its way INTO spines, when the rows on
    -- record are from some earlier spine render. Nothing moves.
    local s = spineShelf(rowsAt(115, ROWS, { ["/b100"] = 4 }), 35)
    s:_setCursorToShow(100, "/b100")
    eq(s._cursor, 35)
end)

t.test("rows noted for another shelf are not trusted", function()
    local rows = rowsAt(35, ROWS, { ["/b100"] = 4 })
    rows.chip = "series"
    local s = spineShelf(rows, 35)
    s:_setCursorToShow(100, "/b100")
    eq(s._cursor, 35)
end)

t.test("with no rows noted the cursor stays put rather than jumping to page 1", function()
    local s = spineShelf(nil, 35)
    s:_setCursorToShow(45, "/b45")
    eq(s._cursor, 35, "no rows, and the shelf still jumped")
end)

t.test("nothing plans the whole shelf to do it", function()
    -- The cost this replaced: the page map plans every book, which the
    -- maintainer felt on the PW5's first collapse.
    local s = spineShelf(rowsAt(35, ROWS, { ["/b100"] = 4 }), 35)
    s:_setCursorToShow(100, "/b100")
    eq(s._built_map, nil, "the collapse still builds the whole-shelf page map")
end)

-- ── _noteSpineRows: what the render records ────────────────────────────────

local function noted(plan, cursor, skip)
    local s = spineShelf(nil, cursor)
    s.chip = "all"
    if skip then s._spine_skip, s._spine_skip_for = skip, cursor end
    s:_noteSpineRows(plan)
    return s._spine_rows
end

-- A plan's shape: entries carry item_idx (relative to the slice from the
-- cursor) and the book; rows name their first and last entry.
local function planOf(items_per_row)
    local entries, rows, i = {}, {}, 0
    for _r, row in ipairs(items_per_row) do
        local first = i + 1
        for _k, e in ipairs(row) do
            i = i + 1
            entries[i] = { item_idx = e[1], book = { filepath = e[2] } }
        end
        rows[#rows + 1] = { first = first, last = i }
    end
    return { entries = entries, rows = rows }
end

t.test("each row's anchor is the item it starts with, in shelf terms", function()
    local r = noted(planOf({ { { 1, "/a" }, { 2, "/b" } }, { { 3, "/c" } } }), 35)
    eq(r.anchors[1].c, 35); eq(r.anchors[1].s, 0)
    eq(r.anchors[2].c, 37); eq(r.anchors[2].s, 0)
    eq(r.c, 35, "the page the rows belong to was not recorded")
end)

t.test("a row that starts inside an item records how far in", function()
    -- Item 2 is a group of three spines, two on row 1 and one on row 2, so a
    -- page starting at row 2 must start two spines into it.
    local r = noted(planOf({ { { 1, "/a" }, { 2, "/s1" }, { 2, "/s2" } },
                             { { 2, "/s3" }, { 3, "/c" } } }), 35)
    eq(r.anchors[2].c, 36)
    eq(r.anchors[2].s, 2, "the row would start the group again from its first spine")
end)

t.test("the page's own offset carries into a row still inside its first item", function()
    -- The page itself began three spines into item 1 (a resumed group), and
    -- row 2 is still in it: five spines of it are behind row 2.
    local r = noted(planOf({ { { 1, "/g4" }, { 1, "/g5" } }, { { 1, "/g6" } } }), 35, 3)
    eq(r.anchors[1].s, 3)
    eq(r.anchors[2].s, 5)
end)

t.test("every book on the page is mapped to its row", function()
    local r = noted(planOf({ { { 1, "/a" }, { 2, "/b" } }, { { 3, "/c" } } }), 35)
    eq(r.row_of["/a"], 1); eq(r.row_of["/b"], 1); eq(r.row_of["/c"], 2)
end)

t.done()
