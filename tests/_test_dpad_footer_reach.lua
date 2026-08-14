-- tests/_test_dpad_footer_reach.lua
-- onBSFocusDown from the grid: where "down" lands when the shelf is not full.
--
-- The grid reserves a fixed number of rows, so a shelf holding fewer books
-- than slots has empty rows below the last book. Focus-down used to be
-- resolved geometrically -- "am I on the LAST row of the grid?" -- so on a
-- part-full shelf the cursor was never on that row, the move fell through to
-- _moveCursor(n_cols), and stepping into an empty slot did nothing at all: a
-- keyboard / d-pad user could not reach the footer (Reddit report).
--
-- Driven against the real method body, extracted by name from the source and
-- run under a stub `self` (the same trick _test_select_all_view uses) -- the
-- widget itself needs the whole KOReader tree to construct. A rename fails the
-- test rather than silently skipping it.
package.path = "./?.lua;./?/init.lua;" .. package.path

local t = dofile("tests/_helpers.lua").runner()

local src  = io.open("lib/bookshelf_widget.lua"):read("*a")
local body = src:match("\nfunction BookshelfWidget:onBSFocusDown%(%)\n(.-)\nend\n")
assert(body, "could not find BookshelfWidget:onBSFocusDown() - renamed?")

local function compile(code, env)
    if _G.setfenv then
        local f = assert(_G.loadstring(code, "onBSFocusDown"))
        _G.setfenv(f, env)
        return f
    end
    return assert(load(code, "onBSFocusDown", "t", env))
end

-- Stub shelf. `books` is how many books the page holds; the grid is
-- rows x cols slots, so anything past #books is an empty slot.
local function shelf(opts)
    local items = {}
    for i = 1, (opts.books or 0) do items[i] = { filepath = "/b/" .. i } end
    local self_tbl = {
        _focus_zone      = "grid",
        _cursor_idx      = opts.cursor,
        _page_items      = items,
        _total_pages     = opts.total_pages or 1,
        _drilldown_path  = {},
        _selection       = { isActive = function() return opts.selecting == true end },
        _nShelves        = function() return opts.rows or 2 end,
        _nCols           = function() return opts.cols or 4 end,
        _startMenuPosition = function() return opts.start_menu or "left" end,
        _swapShelvesInPlace = function(s) s._shelves_swapped = true end,
        _swapFooterInPlace  = function(s) s._footer_swapped = true end,
        _refreshBucket      = function(s) s._bucket_refreshed = true end,
        _moveCursor = function(s, delta)
            -- The old fallback. Reaching it at all now means the new
            -- occupied-slot resolution declined a move it should have made.
            s._fell_back_to_moveCursor = delta
            return true
        end,
    }
    local f = compile("local self = ... ; " .. body, { })
    f(self_tbl)
    return self_tbl
end

t.test("one row of books, two rows of slots: down reaches the footer", function()
    -- The report: 4 books in an 4x2 grid. Cursor on the only row.
    local s = shelf{ books = 4, cols = 4, rows = 2, cursor = 2, total_pages = 1 }
    assert(s._focus_zone == "footer",
        "expected focus in the footer, got " .. tostring(s._focus_zone))
    assert(s._fell_back_to_moveCursor == nil,
        "should not have gone through _moveCursor at all")
end)

t.test("empty row below, multiple pages: lands on the next-page button", function()
    local s = shelf{ books = 4, cols = 4, rows = 2, cursor = 1, total_pages = 3 }
    assert(s._focus_zone == "footer")
    assert(s._footer_cursor_btn == "next",
        "got " .. tostring(s._footer_cursor_btn))
end)

t.test("single page: lands on the start-menu slot instead", function()
    local s = shelf{ books = 4, cols = 4, rows = 2, cursor = 1, total_pages = 1 }
    assert(s._footer_cursor_btn == "menu",
        "got " .. tostring(s._footer_cursor_btn))
end)

t.test("single page with the start menu off: focus stays in the grid", function()
    local s = shelf{ books = 4, cols = 4, rows = 2, cursor = 1,
                     total_pages = 1, start_menu = "off" }
    assert(s._focus_zone == "grid", "nothing in the footer is focusable")
    assert(s._cursor_idx == 1, "cursor should not have moved")
end)

t.test("selection active: the bucket overlay still comes before the footer", function()
    local s = shelf{ books = 4, cols = 4, rows = 2, cursor = 1, selecting = true }
    assert(s._focus_zone == "selection_overlay",
        "got " .. tostring(s._focus_zone))
end)

t.test("a book directly below: plain step down, no zone change", function()
    local s = shelf{ books = 8, cols = 4, rows = 2, cursor = 2 }
    assert(s._focus_zone == "grid")
    assert(s._cursor_idx == 6, "expected 2 + 4 = 6, got " .. tostring(s._cursor_idx))
end)

t.test("ragged tail: down lands on the last book of the short row", function()
    -- 6 books in a 4x2 grid -- the second row holds slots 5 and 6 only.
    -- From slot 4 the cell below (8) is empty, but row 2 is not: the nearest
    -- book in the direction travelled is 6, not the footer.
    local s = shelf{ books = 6, cols = 4, rows = 2, cursor = 4 }
    assert(s._focus_zone == "grid",
        "row below has books, so focus stays in the grid")
    assert(s._cursor_idx == 6, "expected slot 6, got " .. tostring(s._cursor_idx))
end)

t.test("bottom row of a full grid still goes to the footer", function()
    local s = shelf{ books = 8, cols = 4, rows = 2, cursor = 7, total_pages = 2 }
    assert(s._focus_zone == "footer")
    assert(s._footer_cursor_btn == "next")
end)

t.test("empty shelf: down still reaches the footer", function()
    local s = shelf{ books = 0, cols = 4, rows = 2, cursor = 1, total_pages = 1 }
    assert(s._focus_zone == "footer",
        "got " .. tostring(s._focus_zone))
end)

t.done()
