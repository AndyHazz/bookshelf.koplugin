-- tests/_test_cursor_fetched_window.lua
-- A clamped cursor must not render the page fetched before the clamp -- the
-- root cause behind issue #369, found by the maintainer through ZOOM.
--
-- Usage (from plugin root): lua tests/_test_cursor_fetched_window.lua
--
-- THE ORDER INSIDE _rebuild. A window-fetched source (Home, a folder or group
-- drill, a series, search, OPDS) fetches just the visible page, at
-- offset = cursor - 1. Only THEN is the cursor clamped against the total that
-- fetch reported. For a whole-list source that ordering is harmless, because
-- the page is sliced out of the list after the clamp. For a windowed one the
-- page has already been cut, and it was rendered as fetched.
--
-- So whenever the page GROWS past the end of a short list, the clamp moves the
-- cursor while the screen keeps the old window. The maintainer's repro: a
-- seven-book series at three columns, paged to book 4, then zoomed out to four
-- columns and two rows. Eight fit on a page, the clamp takes the cursor to 1,
-- the footer says "page 1 of 1" -- and the screen shows books 4-7, with no
-- page left to reach 1-3 from.
--
-- Expanding the shelf is the same thing through another door; the clamp added
-- to _setExpanded for #369 only worked because it ran BEFORE the fetch, on that
-- one path. Zoom, and anything else that grows the page, went straight past it.
--
-- _rebuild is far too large to run here, so the decision is a small method
-- (_clampFetchedWindow) exercised for real, and _rebuild's use of it is pinned
-- in the source.

package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local src = io.open("lib/bookshelf_widget.lua"):read("a")

local Shelf = {}
for _i, name in ipairs({ "_maxCursor", "_clampCursor", "_clampFetchedWindow" }) do
    local args, code = src:match("\nfunction BookshelfWidget:" .. name
                                 .. "%((.-)%)\n(.-)\nend\n")
    assert(code, "BookshelfWidget:" .. name .. " is gone or was renamed")
    Shelf[name] = assert(load("return function(self" ..
        (args ~= "" and ", " .. args or "") .. ")\n" .. code .. "\nend"))()
end

-- A shelf that has just fetched a page at `cursor` and now knows the total.
local function shelf(view, cursor)
    local s = {
        _cursor      = cursor,
        _viewSize    = function() return view end,
        _isSpineMode = function() return false end,
    }
    for k, fn in pairs(Shelf) do s[k] = fn end
    return s
end

t.test("zooming out on a short series asks for the page again", function()
    -- The maintainer's case: 7 books, the page now holds 8, fetched at book 4.
    local s = shelf(8, 4)
    eq(s:_clampFetchedWindow(7, true), true,
        "the window fetched at book 4 would be rendered under a page-1 cursor")
    eq(s._cursor, 1, "the cursor was not clamped to the only legal page start")
end)

t.test("a cursor that is still a legal start keeps its window", function()
    -- The rule swiping up relies on: 100 books, page of 12, at book 9. Nothing
    -- moves, so nothing is fetched twice.
    local s = shelf(12, 9)
    eq(s:_clampFetchedWindow(100, true), false, "a legal cursor forced a refetch")
    eq(s._cursor, 9, "the reader's row moved")
end)

t.test("a whole-list source never needs a second fetch", function()
    -- It slices the page AFTER the clamp, so the clamped cursor is already the
    -- one the screen uses. A refetch there would be a whole second rebuild for
    -- nothing.
    local s = shelf(8, 4)
    eq(s:_clampFetchedWindow(7, false), false, "a sliced source asked to refetch")
    eq(s._cursor, 1, "the cursor still has to be clamped")
end)

t.test("an empty result clamps without asking for another fetch", function()
    -- A total of zero is the size of the whole list, not of the window, so a
    -- second fetch at book 1 would come back just as empty. It would also put
    -- an extra rebuild on the empty-chip path, which has its own open issue
    -- (#423) and is no place for a behaviour change nobody asked for.
    local s = shelf(8, 4)
    eq(s:_clampFetchedWindow(0, true), false,
        "an empty chip was sent round the rebuild a second time")
    eq(s._cursor, 1, "the cursor still has to be clamped")
end)

-- ── _rebuild's side of it ──────────────────────────────────────────────────

local function rebuildSnippet()
    local at = src:find("self:_clampFetchedWindow(total", 1, true)
    assert(at, "_rebuild no longer asks _clampFetchedWindow about its page")
    return src:sub(at - 200, at + 900)
end

t.test("_rebuild fetches the page again when the clamp moved it", function()
    local s = rebuildSnippet()
    local set   = s:find("self._cursor_clamp_retry = true", 1, true)
    local again = s:find("self:_rebuild()", set or 1, true)
    assert(set and again,
        "a moved cursor still renders the window fetched before the clamp")
end)

t.test("the second pass cannot serve the stale window from the draft cache", function()
    -- A pinch is a draft regrid, and the draft cache holds the page cut at the
    -- OLD offset. Retrying without dropping it would render the same window.
    local s = rebuildSnippet()
    assert(s:find("self._draft_items_cache = nil", 1, true),
        "the retry can be served the very window it is retrying to replace")
end)

t.test("the second pass happens at most once", function()
    -- The same guard the label-strip retry above it uses: a total that changes
    -- between the two fetches must not turn this into a loop.
    local s = rebuildSnippet()
    assert(s:find("not self._cursor_clamp_retry", 1, true),
        "nothing stops the refetch from repeating")
    assert(s:find("self._cursor_clamp_retry = nil", 1, true),
        "the guard is never cleared, so the NEXT rebuild could not retry")
end)

-- ── The page-turn fast path has the same order ─────────────────────────────
--
-- _swapShelvesInPlace fetches, clamps and renders exactly as _rebuild does,
-- so fixing one and not the other is the same mistake as patching expand and
-- not zoom. It already falls back to a full rebuild for a change of shape it
-- cannot swap in place (the empty state); a moved window is another.

t.test("the page-turn fast path falls back to a rebuild when the clamp moved it", function()
    local body = src:match("\nfunction BookshelfWidget:_swapShelvesInPlace%(%)\n(.-)\nend\n")
    assert(body, "_swapShelvesInPlace moved or was renamed")
    local at = body:find("self:_clampFetchedWindow(total", 1, true)
    assert(at, "the page swap renders a window fetched before its clamp")
    local after = body:sub(at, at + 400)
    assert(after:find("self:_rebuild()", 1, true),
        "a moved window is swapped in place instead of being fetched again")
    assert(not body:find("\n    self:_clampCursor(total)\n", 1, true),
        "the swap still clamps without asking whether its window moved")
end)

t.done()
