-- tests/_test_hero_preview_cycle.lua
-- _previewNeighbourBook: the hero's left/right swipe steps one book along the
-- visible page and wraps at its ends (#325).
--
-- The bug it pins: _fetchChipItems returns TWO shapes. Window-fetched sources
-- (Home, folder/group drills, search, OPDS) hand back only the visible page,
-- indexed 1..view, with a total as the second return; everything else hands
-- back the whole list, which the caller slices with the absolute cursor.
-- Testing a page-local list against the absolute cursor put every item "out
-- of view", so the anchor was thrown away and every swipe landed on the
-- page's first or last book instead of stepping.
--
-- Driven against the real method body, extracted by name and run under a stub
-- `self` (as _test_select_all_view does).
package.path = "./?.lua;./?/init.lua;" .. package.path

local t = dofile("tests/_helpers.lua").runner()

local src  = io.open("lib/bookshelf_widget.lua"):read("*a")
local body = src:match("\nfunction BookshelfWidget:_previewNeighbourBook%(direction%)\n(.-)\nend\n")
assert(body, "could not find BookshelfWidget:_previewNeighbourBook() - renamed?")

local function compile(code, env)
    if _G.setfenv then
        local f = assert(_G.loadstring(code, "_previewNeighbourBook"))
        _G.setfenv(f, env)
        return f
    end
    return assert(load(code, "_previewNeighbourBook", "t", env))
end

local function book(name) return { filepath = "/b/" .. name .. ".epub", title = name } end
local function folder(name) return { kind = "folder", path = "/f/" .. name } end

-- Run one swipe. opts:
--   items       - what _fetchChipItems returns
--   total       - its second return; non-nil marks a page-window fetch
--   view        - slots on screen
--   cursor      - absolute cursor (only meaningful for whole-list sources)
--   preview     - the currently previewed record, if any
-- Returns the filepath _previewBook was handed, or nil if it wasn't called.
local function swipe(direction, opts)
    local picked
    local self_tbl = {
        _preview_book = opts.preview,
        _cursor       = opts.cursor,
        _viewSize     = function() return opts.view or 8 end,
        _fetchChipItems = function(_self, n)
            assert(n == 400, "expected the 400-item ceiling, got " .. tostring(n))
            return opts.items, opts.total
        end,
        _previewBook = function(_self, b) picked = b.filepath end,
    }
    local f = compile("local self, direction = ... ; " .. body,
                      { math = math, ipairs = ipairs })
    f(self_tbl, direction)
    return picked
end

-- ── Window-fetched page (Home, folder drills, OPDS): list IS the page ──
local PAGE = {}
for i = 1, 8 do PAGE[i] = book(i) end

t.test("steps to the next book on the page", function()
    local got = swipe(1, { items = PAGE, total = 40, preview = PAGE[3] })
    assert(got == "/b/4.epub", "got " .. tostring(got))
end)

t.test("steps to the previous book on the page", function()
    local got = swipe(-1, { items = PAGE, total = 40, preview = PAGE[3] })
    assert(got == "/b/2.epub", "got " .. tostring(got))
end)

t.test("wraps forward off the last book to the first", function()
    local got = swipe(1, { items = PAGE, total = 40, preview = PAGE[8] })
    assert(got == "/b/1.epub", "got " .. tostring(got))
end)

t.test("wraps backward off the first book to the last", function()
    local got = swipe(-1, { items = PAGE, total = 40, preview = PAGE[1] })
    assert(got == "/b/8.epub", "got " .. tostring(got))
end)

t.test("nothing previewed yet: forward starts on the first book", function()
    local got = swipe(1, { items = PAGE, total = 40 })
    assert(got == "/b/1.epub", "got " .. tostring(got))
end)

t.test("nothing previewed yet: backward starts on the last book", function()
    local got = swipe(-1, { items = PAGE, total = 40 })
    assert(got == "/b/8.epub", "got " .. tostring(got))
end)

t.test("a preview from another page re-anchors instead of stepping blind", function()
    local got = swipe(1, { items = PAGE, total = 40, preview = book("elsewhere") })
    assert(got == "/b/1.epub", "got " .. tostring(got))
end)

t.test("folder tiles are skipped, only books are previewable", function()
    local mixed = { folder("a"), book("x"), folder("b"), book("y") }
    local got = swipe(1, { items = mixed, total = 40, preview = mixed[2] })
    assert(got == "/b/y.epub", "got " .. tostring(got))
end)

t.test("a page with one book does not re-trigger itself", function()
    local one = { book("only") }
    local got = swipe(1, { items = one, total = 40, preview = one[1] })
    assert(got == nil, "should have left the preview alone, got " .. tostring(got))
end)

t.test("a page of folder tiles only is a no-op", function()
    local got = swipe(1, { items = { folder("a"), folder("b") }, total = 40 })
    assert(got == nil, "got " .. tostring(got))
end)

-- ── Whole-list source (favorites / recent / predicate chips): the cursor
-- picks the window out of the full list ──
local ALL = {}
for i = 1, 20 do ALL[i] = book(i) end

t.test("whole-list source on page 2 steps within that page", function()
    local got = swipe(1, { items = ALL, view = 8, cursor = 9, preview = ALL[11] })
    assert(got == "/b/12.epub", "got " .. tostring(got))
end)

t.test("whole-list source wraps inside the visible page, not into page 3", function()
    -- Cursor 9, view 8 -> the page is books 9..16. Forward off 16 wraps to 9.
    local got = swipe(1, { items = ALL, view = 8, cursor = 9, preview = ALL[16] })
    assert(got == "/b/9.epub", "got " .. tostring(got))
end)

t.test("whole-list source ignores a preview from a page you have left", function()
    local got = swipe(1, { items = ALL, view = 8, cursor = 9, preview = ALL[2] })
    assert(got == "/b/9.epub", "got " .. tostring(got))
end)

t.test("short last page does not read past the end of the list", function()
    -- Cursor 17, view 8, 20 books -> the page holds 17..20 only.
    local got = swipe(1, { items = ALL, view = 8, cursor = 17, preview = ALL[20] })
    assert(got == "/b/17.epub", "got " .. tostring(got))
end)

t.done()
