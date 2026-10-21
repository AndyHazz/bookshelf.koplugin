-- Headless tests for Grid.snapLegacy: turning the old row-packed layout (pixel
-- sizes in reading order) into grid boxes on upgrade.
package.path = "./?.lua;./?/init.lua;" .. package.path

local Grid = dofile("lib/bookshelf_module_grid.lua")
local t = dofile("tests/_helpers.lua").runner()

local D = { cols = 4, rows = 5, cell_w = 100, cell_h = 100, gap = 10 }

local function find(bs, id)
    for _i, b in ipairs(bs) do if b.id == id then return b end end
end

-- Legacy entries: { id, page, row = old row index on that page, px_w, px_h }.
-- The old packer gave every row on a page the same height, and filled each
-- row's width exactly, so snapping shares each old row out across the grid's
-- columns by width and gives each old row an equal share of the grid's rows.

t.test("a full-width card snaps to all columns", function()
    local out = Grid.snapLegacy({ { id = "q", page = 1, row = 1, px_w = 430, px_h = 100 } }, D)
    assert(out[1].w == 4, "w " .. out[1].w)
end)

t.test("half-width cards pair on one row", function()
    local out = Grid.snapLegacy({
        { id = "a", page = 1, row = 1, px_w = 205, px_h = 100 },
        { id = "b", page = 1, row = 1, px_w = 205, px_h = 100 },
    }, D)
    local a, b = find(out, "a"), find(out, "b")
    assert(a.w == 2 and b.w == 2, "widths " .. a.w .. "," .. b.w)
    assert(a.row == 1 and b.row == 1 and a.col == 1 and b.col == 3,
        string.format("a c%d r%d, b c%d r%d", a.col, a.row, b.col, b.row))
end)

t.test("a row's widths share out the columns without overflowing", function()
    local out = Grid.snapLegacy({
        { id = "a", page = 1, row = 1, px_w = 300, px_h = 100 },
        { id = "b", page = 1, row = 1, px_w = 300, px_h = 100 },
        { id = "c", page = 1, row = 1, px_w = 300, px_h = 100 },
    }, D)
    local sum = 0
    for _i, b in ipairs(out) do sum = sum + b.w; assert(b.row == 1, b.id .. " wrapped") end
    assert(sum <= 4, "sum " .. sum)
end)

t.test("two old rows split the grid's rows between them", function()
    local out = Grid.snapLegacy({
        { id = "clock", page = 1, row = 1, px_w = 210, px_h = 700 },
        { id = "quote", page = 1, row = 1, px_w = 210, px_h = 700 },
        { id = "rand",  page = 1, row = 2, px_w = 210, px_h = 700 },
        { id = "goal",  page = 1, row = 2, px_w = 210, px_h = 700 },
    }, D)
    for _i, b in ipairs(out) do
        assert(b.page == 1, b.id .. " spilled to page " .. b.page)
    end
    -- 5 grid rows over 2 old rows: 3 and 2.
    assert(find(out, "clock").h == 3 and find(out, "rand").h == 2,
        "heights " .. find(out, "clock").h .. "/" .. find(out, "rand").h)
    assert(find(out, "rand").row == 4, "row 2 should start under row 1")
end)

t.test("a single old row fills the grid's height", function()
    local out = Grid.snapLegacy({ { id = "c", page = 1, row = 1, px_w = 210, px_h = 205 } }, D)
    assert(out[1].h == 5, "h " .. out[1].h)
end)

t.test("pages keep their order", function()
    local out = Grid.snapLegacy({
        { id = "a", page = 1, row = 1, px_w = 100, px_h = 100 },
        { id = "b", page = 3, row = 1, px_w = 100, px_h = 100 },
    }, D)
    assert(find(out, "a").page == 1 and find(out, "b").page >= 3)
end)

t.test("nothing is lost when an old page had more rows than the grid", function()
    local legacy = {}
    for i = 1, 25 do
        legacy[i] = { id = "m" .. i, page = 1, row = math.floor((i - 1) / 4) + 1, px_w = 100, px_h = 100 }
    end
    local out = Grid.snapLegacy(legacy, D)
    assert(#out == 25, "#out " .. #out)
    assert(#Grid.pages(out) == 2, "pages " .. #Grid.pages(out))
end)

t.test("tiny cards never snap below one cell", function()
    local out = Grid.snapLegacy({
        { id = "s", page = 1, row = 1, px_w = 3, px_h = 2 },
        { id = "t", page = 1, row = 1, px_w = 900, px_h = 2 },
    }, D)
    assert(find(out, "s").w >= 1 and find(out, "s").h >= 1)
end)

t.test("old rows share out ALL the grid's rows, not just a whole multiple", function()
    -- The PW5's real full-screen layout: four old rows onto a 6x7 grid.
    local D7 = { cols = 6, rows = 7, cell_w = 160, cell_h = 160, gap = 30 }
    local legacy = {
        { id = "clock", page = 1, row = 1, px_w = 300, px_h = 300 },
        { id = "stats", page = 1, row = 1, px_w = 600, px_h = 300 },
        { id = "quote", page = 1, row = 2, px_w = 900, px_h = 300 },
        { id = "batt",  page = 1, row = 3, px_w = 450, px_h = 300 },
        { id = "otd",   page = 1, row = 3, px_w = 450, px_h = 300 },
        { id = "shelf", page = 1, row = 4, px_w = 450, px_h = 300 },
        { id = "goal",  page = 1, row = 4, px_w = 450, px_h = 300 },
    }
    local out = Grid.snapLegacy(legacy, D7)
    local bottom = 0
    for _i, b in ipairs(out) do
        assert(b.page == 1, b.id .. " spilled")
        bottom = math.max(bottom, b.row + b.h - 1)
    end
    assert(bottom == 7, "layout ends at row " .. bottom .. " of 7")
    assert(find(out, "clock").h == 2 and find(out, "shelf").h == 1,
        "heights " .. find(out, "clock").h .. "/" .. find(out, "shelf").h)
end)

t.done()
