-- Headless tests for lib/bookshelf_module_grid.lua: placement, the
-- launcher-style collision rule, flow, overflow and the store round-trip.
package.path = "./?.lua;./?/init.lua;" .. package.path

local Grid = dofile("lib/bookshelf_module_grid.lua")
local t = dofile("tests/_helpers.lua").runner()

local D = { cols = 4, rows = 5, cell_w = 100, cell_h = 100, gap = 10 }

-- The mockup layout:  clock clock goal  goal
--                     clock clock streak .
--                     rings rings rings rings  (x2 rows)
--                     quote quote quote  .
local function L() return {
    { id = "clock",  page = 1, col = 1, row = 1, w = 2, h = 2 },
    { id = "goal",   page = 1, col = 3, row = 1, w = 2, h = 1 },
    { id = "streak", page = 1, col = 3, row = 2, w = 1, h = 1 },
    { id = "rings",  page = 1, col = 1, row = 3, w = 4, h = 2 },
    { id = "quote",  page = 1, col = 1, row = 5, w = 3, h = 1 },
} end

-- Same, with one-row rings so there is room left to grow into (frame 3).
local function L2() return {
    { id = "clock",  page = 1, col = 1, row = 1, w = 2, h = 2 },
    { id = "goal",   page = 1, col = 3, row = 1, w = 2, h = 1 },
    { id = "streak", page = 1, col = 3, row = 2, w = 1, h = 1 },
    { id = "rings",  page = 1, col = 1, row = 3, w = 4, h = 1 },
    { id = "quote",  page = 1, col = 1, row = 4, w = 3, h = 1 },
} end

local function find(bs, id)
    for _i, b in ipairs(bs) do if b.id == id then return b end end
end

local function at(b, page, col, row, w, h)
    return b.page == page and b.col == col and b.row == row
        and (w == nil or b.w == w) and (h == nil or b.h == h)
end

local function show(b)
    return b and string.format("%s p%d c%d r%d %dx%d", b.id, b.page, b.col, b.row, b.w, b.h)
        or "nil"
end

local function same(a, b)
    return a.page == b.page and a.col == b.col and a.row == b.row
        and a.w == b.w and a.h == b.h
end

local function noOverlaps(bs)
    for i = 1, #bs do
        for j = i + 1, #bs do
            if Grid.overlaps(bs[i], bs[j]) then
                return false, show(bs[i]) .. " overlaps " .. show(bs[j])
            end
        end
    end
    return true
end

local function fullPage(page)
    local out = {}
    for r = 1, 5 do
        for c = 1, 4 do
            out[#out + 1] = { id = "p" .. page .. "c" .. c .. "r" .. r,
                page = page, col = c, row = r, w = 1, h = 1 }
        end
    end
    return out
end

t.test("move down onto a smaller neighbour swaps", function()
    local out = assert(Grid.move(L(), "goal", 0, 1, D))
    assert(at(find(out, "goal"), 1, 3, 2, 2, 1), show(find(out, "goal")))
    assert(at(find(out, "streak"), 1, 3, 1, 1, 1), show(find(out, "streak")))
    for _i, id in ipairs({ "clock", "rings", "quote" }) do
        assert(same(find(out, id), find(L(), id)), id .. " moved")
    end
end)

t.test("untouched modules never move", function()
    local out = assert(Grid.resize(L2(), "clock", "w", 1, D))
    assert(find(out, "clock").w == 3, show(find(out, "clock")))
    assert(same(find(out, "rings"), find(L2(), "rings")), "rings moved")
    assert(same(find(out, "quote"), find(L2(), "quote")), "quote moved")
end)

t.test("growing into a neighbour relocates only what collides", function()
    local out = assert(Grid.resize(L2(), "clock", "w", 1, D))
    assert(noOverlaps(out))
    assert(find(out, "goal").page == 1 and find(out, "streak").page == 1)
    -- Streak's nearest free cell is right beside where it was.
    assert(at(find(out, "streak"), 1, 4, 2), show(find(out, "streak")))
end)

t.test("growing with no free space anywhere refuses", function()
    local out, why = Grid.resize(L(), "clock", "w", 1, D)
    assert(out == nil and why == "no_room", "expected no_room")
end)

t.test("no room refuses and changes nothing", function()
    local full = fullPage(1)
    local before = find(full, "p1c1r1")
    local out, why = Grid.resize(full, "p1c1r1", "w", 1, D)
    assert(out == nil and why == "no_room")
    assert(same(find(full, "p1c1r1"), before), "input mutated")
end)

t.test("wider at the right edge grows left", function()
    local bs = { { id = "a", page = 1, col = 4, row = 1, w = 1, h = 1 } }
    local out = assert(Grid.resize(bs, "a", "w", 1, D))
    assert(at(out[1], 1, 3, 1, 2, 1), show(out[1]))
end)

t.test("narrower shrinks from the side wider grows", function()
    local bs = { { id = "a", page = 1, col = 3, row = 1, w = 2, h = 1 } }
    local out = assert(Grid.resize(bs, "a", "w", -1, D))
    assert(at(out[1], 1, 4, 1, 1, 1), show(out[1]))
    bs = { { id = "a", page = 1, col = 1, row = 1, w = 2, h = 1 } }
    out = assert(Grid.resize(bs, "a", "w", -1, D))
    assert(at(out[1], 1, 1, 1, 1, 1), show(out[1]))
end)

t.test("taller at the bottom edge grows up", function()
    local bs = { { id = "a", page = 1, col = 1, row = 5, w = 1, h = 1 } }
    local out = assert(Grid.resize(bs, "a", "h", 1, D))
    assert(at(out[1], 1, 1, 4, 1, 2), show(out[1]))
end)

t.test("shrink respects min_w", function()
    local out, why = Grid.resize(L(), "clock", "w", -1, D, 2, 1)
    assert(out == nil and why == "no_room", "min_w 2 should refuse")
    out = assert(Grid.resize(L(), "clock", "w", -1, D, 1, 1))
    assert(find(out, "clock").w == 1)
end)

t.test("min_w larger than the grid clamps instead of looping", function()
    local bs = { { id = "q", page = 1, col = 1, row = 1, w = 3, h = 1 } }
    local out = Grid.resize(bs, "q", "w", 1, D, 6, 1)
    assert(out and find(out, "q").w <= 4, "expected a clamped grow")
    local out2, why = Grid.resize(out, "q", "w", 1, D, 6, 1)
    assert(out2 == nil and why == "no_room", "growing past the grid must refuse")
end)

t.test("moveTo an empty cell", function()
    local out = assert(Grid.moveTo(L(), "streak", 4, 2, D))
    assert(at(find(out, "streak"), 1, 4, 2))
    for _i, id in ipairs({ "clock", "goal", "rings", "quote" }) do
        assert(same(find(out, id), find(L(), id)), id .. " moved")
    end
end)

t.test("move off the grid refuses", function()
    local out, why = Grid.move(L(), "clock", -1, 0, D)
    assert(out == nil and why == "no_room")
end)

t.test("toPage places at the first free spot", function()
    local out = assert(Grid.toPage(L(), "quote", 2, D))
    assert(at(find(out, "quote"), 2, 1, 1, 3, 1), show(find(out, "quote")))
end)

t.test("toPage onto a full page refuses", function()
    local bs = fullPage(2)
    bs[#bs + 1] = { id = "x", page = 1, col = 1, row = 1, w = 1, h = 1 }
    local out, why = Grid.toPage(bs, "x", 2, D)
    assert(out == nil and why == "no_room")
end)

t.test("flow never drops a box and runs past four pages", function()
    local bs = {}
    for i = 1, 30 do bs[i] = { id = "b" .. i, page = 1, col = 1, row = 1, w = 2, h = 2 } end
    local out = Grid.flow(bs, D, 1)
    assert(#out == 30, "#out " .. #out)
    assert(#Grid.pages(out) == 8, "pages " .. #Grid.pages(out))
    assert(noOverlaps(out))
end)

t.test("flow clamps oversized boxes to the grid", function()
    local out = Grid.flow({ { id = "big", page = 1, col = 1, row = 1, w = 9, h = 9 } }, D, 1)
    assert(at(out[1], 1, 1, 1, 4, 5), show(out[1]))
end)

t.test("resolve re-places overflow onto later pages", function()
    local D4 = { cols = 4, rows = 4, cell_w = 100, cell_h = 100, gap = 10 }
    local out, moved = Grid.resolve(L(), D4)
    assert(find(out, "quote").page == 2, show(find(out, "quote")))
    assert(#moved == 1 and moved[1] == "quote", "moved " .. table.concat(moved, ","))
    assert(same(find(out, "clock"), find(L(), "clock")))
end)

t.test("resolve leaves a fitting layout alone", function()
    local out, moved = Grid.resolve(L(), D)
    assert(#moved == 0)
    for _i, b in ipairs(L()) do assert(same(find(out, b.id), b), b.id) end
end)

t.test("pages lists only non-empty pages plus the kept one", function()
    local bs = {
        { id = "a", page = 1, col = 1, row = 1, w = 1, h = 1 },
        { id = "b", page = 3, col = 1, row = 1, w = 1, h = 1 },
    }
    local p = Grid.pages(bs, 2)
    assert(#p == 3 and p[1] == 1 and p[2] == 2 and p[3] == 3, table.concat(p, ","))
    p = Grid.pages(bs)
    assert(#p == 2 and p[1] == 1 and p[2] == 3, table.concat(p, ","))
end)

t.test("navRows groups by row", function()
    local rows = Grid.navRows(L(), 1)
    local flat = {}
    for _i, r in ipairs(rows) do flat[#flat + 1] = table.concat(r, " ") end
    assert(table.concat(flat, "|") == "clock goal|streak|rings|quote", table.concat(flat, "|"))
end)

t.test("readingOrder sorts by page, row, col", function()
    local bs = {
        { id = "c", page = 2, col = 1, row = 1, w = 1, h = 1 },
        { id = "b", page = 1, col = 2, row = 1, w = 1, h = 1 },
        { id = "a", page = 1, col = 1, row = 1, w = 1, h = 1 },
    }
    local o = Grid.readingOrder(bs)
    assert(o[1].id == "a" and o[2].id == "b" and o[3].id == "c")
    assert(bs[1].id == "c", "input reordered")
end)

t.test("boxesFrom and writeBack round-trip", function()
    local items = {
        { id = "a", module = "x", at = { page = 1, col = 2, row = 3, w = 1, h = 2 } },
        { id = "b", module = "y" },
    }
    local boxes, unplaced = Grid.boxesFrom(items, "at")
    assert(#boxes == 1 and at(boxes[1], 1, 2, 3, 1, 2))
    assert(#unplaced == 1 and unplaced[1].id == "b")
    Grid.writeBack(items, { { id = "b", page = 2, col = 1, row = 1, w = 2, h = 1 } }, "at")
    assert(items[2].at.page == 2 and items[2].at.w == 2)
    assert(items[1].at.col == 2, "untouched item changed")
end)

t.test("resolve shrinks a box hanging off the edge instead of moving it", function()
    local out, moved = Grid.resolve({ { id = "q", page = 1, col = 3, row = 1, w = 8, h = 2 } }, D)
    assert(#moved == 0, "moved")
    assert(at(out[1], 1, 3, 1, 2, 2), show(out[1]))
end)

t.test("a refusal names the module that's in the way", function()
    local out, why, blocker = Grid.resize(L(), "clock", "w", 1, D)
    assert(out == nil and why == "no_room" and blocker == "goal", tostring(blocker))
end)

t.done()
