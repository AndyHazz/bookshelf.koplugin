-- tests/_test_dpad_spine_rows.lua
-- The D-pad on a spine shelf reaches every book on the page, row by row.
--
-- The grid arms of the D-pad handlers worked in cover-grid terms: a page of
-- _nShelves() * _nCols() slots (8 on a 4x2 shelf), rows _nCols() apart. A spine
-- page holds far more books than that, in rows of varying length, so Right
-- from the 8th spine turned the page and Down jumped by 4 books: only the first
-- few books on each shelf could be reached (Reddit report; reproduced on the rig
-- with a keys-only device on a 29-spine page). The render already records which
-- row each book on the page is on (_noteSpineRows); the handlers now use it.
--
-- Driven against the real method bodies, extracted by name from the source.
package.path = "./?.lua;./?/init.lua;" .. package.path

local h  = dofile("tests/_helpers.lua")
local t  = h.runner()
local eq = h.eq

local src = io.open("lib/bookshelf_widget.lua"):read("*a")
local function extract(sig)
    local pat = "\nfunction BookshelfWidget[:%.]" .. sig:gsub("[%(%)%.]", "%%%0") .. "\n(.-)\nend\n"
    local body = src:match(pat)
    assert(body, "could not find BookshelfWidget " .. sig .. " - renamed?")
    return body
end

local function compile(code, env, name)
    if _G.setfenv then
        local f = assert(_G.loadstring(code, name))
        _G.setfenv(f, env)
        return f
    end
    return assert(load(code, name, "t", env))
end

local env = { ipairs = ipairs, type = type, math = math,
    -- No modules or pieces on these pages (_test_dpad_shelf_modules has them).
    BookshelfWidget = { _keyStep = function() return nil end,
                        _slotLand = function(_items, idx) return idx end } }
local itemRows = compile("local self = ... ; " .. extract("_spineItemRows()"), env, "rows")
local rowStep  = compile("local rows, n, cur, dir = ... ; " .. extract("_spineRowStep(rows, n, cur, dir)"), env, "step")
local moveCur  = compile("local self, delta = ... ; " .. extract("_moveCursor(delta)"), env, "move")
local down     = compile("local self = ... ; " .. extract("onBSFocusDown()"), env, "down")
local up       = compile("local self = ... ; " .. extract("onBSFocusUp()"), env, "up")

-- A spine page: rows of the given lengths, then `extra` books past the page
-- (a spine page's items run on to the end of the chip; only the noted rows
-- are on screen).
local function shelf(row_lens, opts)
    opts = opts or {}
    local items, row_of = {}, {}
    for r, len in ipairs(row_lens) do
        for _i = 1, len do
            local fp = "/b/" .. (#items + 1)
            items[#items + 1] = { filepath = fp }
            row_of[fp] = r
        end
    end
    for _i = 1, (opts.extra or 10) do items[#items + 1] = { filepath = "/b/" .. (#items + 1) } end
    local s = {
        chip = "c", _cursor = 1, _focus_zone = "grid", _cursor_idx = opts.cur or 1,
        _page_items = items, _drilldown_path = {}, _chip_bar_hidden = true,
        _spine_rows = { row_of = row_of, chip = "c", c = 1, s = 0, anchors = {} },
        _selection = { isActive = function() return false end },
        _isSpineMode = function() return opts.covers ~= true end,
        _spineSkip = function() return 0 end,
        _nShelves = function() return 2 end,
        _nCols = function() return 4 end,
        _total_pages = 3, page = 1,
        _startMenuPosition = function() return "left" end,
        _heroIsMicroGrid = function() return false end,
        _pageForwardPossible = function() return true end,
        _pageBackPossible = function() return false end,
        _markOpdsNav = function() end,
        _advanceCursor = function(s_, d) s_.advanced = d end,
        _syncPageFromCursor = function() end,
        _swapShelvesInPlace = function(s_) s_.swaps = (s_.swaps or 0) + 1 end,
        _swapFooterInPlace = function(s_) s_.footer_swapped = true end,
        _swapHeroInPlace = function() end,
        _expanded = true,
        _keyOrnAfters = function() return nil end,
        _keyOrnIndex = function() return nil end,
    }
    s._spineItemRows = function(self_) return itemRows(self_) end
    s._spineRowStep = function(...) return rowStep(...) end
    s._moveCursor = function(self_, d) return moveCur(self_, d) end
    return s
end

t.test("rows come from the noted spine layout, only the books on the page", function()
    local s = shelf({ 12, 9 }, { extra = 20 })
    local rows, n = itemRows(s)
    eq(n, 21, "21 books on the page")
    eq(rows[1], 1, "first book on row 1"); eq(rows[12], 1, "12th on row 1")
    eq(rows[13], 2, "13th on row 2"); eq(rows[22], nil, "22nd is past the page")
end)

t.test("noted rows for another page are not trusted", function()
    local s = shelf({ 12, 9 })
    s._cursor = 30
    eq(itemRows(s), nil, "stale rows: nil")
end)

t.test("Right walks past the 8th spine instead of turning the page", function()
    local s = shelf({ 12, 9 }, { cur = 8 })
    moveCur(s, 1)
    eq(s._cursor_idx, 9, "9th book")
    eq(s.advanced, nil, "no page turn")
end)

t.test("Right turns the page only after the page's last book", function()
    local s = shelf({ 12, 9 }, { cur = 21 })
    moveCur(s, 1)
    eq(s.advanced, 1, "page turned")
    eq(s._cursor_idx, 1, "first book of the next page")
end)

t.test("Down goes to the next shelf, same place along it", function()
    local s = shelf({ 12, 9 }, { cur = 3 })
    down(s)
    eq(s._cursor_idx, 15, "3rd book of row 2 (13 + 2)")
end)

t.test("Down from a long row's tail lands on the shorter row's last book", function()
    local s = shelf({ 12, 9 }, { cur = 12 })
    down(s)
    eq(s._cursor_idx, 21, "row 2 ends at 21")
end)

t.test("Down from the bottom shelf goes to the footer", function()
    local s = shelf({ 12, 9 }, { cur = 15 })
    down(s)
    eq(s._focus_zone, "footer", "footer")
end)

t.test("Up goes to the shelf above", function()
    local s = shelf({ 12, 9 }, { cur = 18 })
    up(s)
    eq(s._cursor_idx, 6, "6th book of row 1 (18 is the 6th of row 2)")
    eq(s._focus_zone, "grid", "still on the shelves")
end)

t.test("Up from the 5th book of the top shelf leaves the shelves", function()
    -- Cover-grid arithmetic called this row 2 (5 > n_cols) and stayed.
    local s = shelf({ 12, 9 }, { cur = 5 })
    s._expanded = false
    s._hero_mode = "book"
    up(s)
    eq(s._focus_zone, "hero", "left for the hero")
end)

t.test("cover shelves keep the grid arithmetic", function()
    local s = shelf({ 12, 9 }, { cur = 8, covers = true })
    moveCur(s, 1)
    eq(s.advanced, 1, "8 slots: page turns after the 8th")
end)

t.done()
