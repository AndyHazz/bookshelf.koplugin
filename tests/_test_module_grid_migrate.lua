-- Headless tests for Grid.snapLegacy: turning the old row-packed layout (pixel
-- sizes in reading order) into grid boxes on upgrade.
package.path = "./?.lua;./?/init.lua;" .. package.path

local Grid = dofile("lib/bookshelf_module_grid.lua")
local t = dofile("tests/_helpers.lua").runner()

local D = { cols = 4, rows = 5, cell_w = 100, cell_h = 100, gap = 10 }

local function find(bs, id)
    for _i, b in ipairs(bs) do if b.id == id then return b end end
end

t.test("a full-width card snaps to all columns", function()
    local out = Grid.snapLegacy({ { id = "q", page = 1, px_w = 4 * 100 + 3 * 10, px_h = 100 } }, D)
    assert(out[1].w == 4 and out[1].h == 1, out[1].w .. "x" .. out[1].h)
end)

t.test("half-width cards pair on one row", function()
    local out = Grid.snapLegacy({
        { id = "a", page = 1, px_w = 205, px_h = 100 },
        { id = "b", page = 1, px_w = 205, px_h = 100 },
    }, D)
    local a, b = find(out, "a"), find(out, "b")
    assert(a.w == 2 and b.w == 2, "widths " .. a.w .. "," .. b.w)
    assert(a.row == 1 and b.row == 1 and a.col == 1 and b.col == 3,
        string.format("a c%d r%d, b c%d r%d", a.col, a.row, b.col, b.row))
end)

t.test("a tall card snaps to two rows", function()
    local out = Grid.snapLegacy({ { id = "c", page = 1, px_w = 210, px_h = 205 } }, D)
    assert(out[1].h == 2, "h " .. out[1].h)
end)

t.test("pages keep their order", function()
    local out = Grid.snapLegacy({
        { id = "a", page = 1, px_w = 100, px_h = 100 },
        { id = "b", page = 3, px_w = 100, px_h = 100 },
    }, D)
    assert(find(out, "a").page == 1 and find(out, "b").page >= 3)
end)

t.test("nothing is lost when sizes no longer fit", function()
    local legacy = {}
    for i = 1, 25 do legacy[i] = { id = "m" .. i, page = 1, px_w = 100, px_h = 100 } end
    local out = Grid.snapLegacy(legacy, D)
    assert(#out == 25, "#out " .. #out)
    assert(#Grid.pages(out) == 2, "pages " .. #Grid.pages(out))
end)

t.test("tiny cards never snap below one cell", function()
    local out = Grid.snapLegacy({ { id = "s", page = 1, px_w = 3, px_h = 2 } }, D)
    assert(out[1].w == 1 and out[1].h == 1)
end)

t.done()
