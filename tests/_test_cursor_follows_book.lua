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
                             "onSwipeShelvesUp", "onBookshelfToggleHero" }) do
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

t.done()
