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

-- ── Swapping with a same-size group ──────────────────────────────────────────

local function B(id, c, r, w, h) return { id = id, page = 1, col = c, row = r, w = w, h = h } end

t.test("moving onto a same-size group swaps with the whole group", function()
    local bs = { B("clock", 1, 1, 2, 2), B("a", 3, 1, 2, 1), B("b", 3, 2, 2, 1), B("z", 1, 3, 4, 1) }
    local out = assert(Grid.move(bs, "clock", 1, 0, D))
    assert(at(find(out, "clock"), 1, 3, 1, 2, 2), show(find(out, "clock")))
    assert(at(find(out, "a"), 1, 1, 1, 2, 1) and at(find(out, "b"), 1, 1, 2, 2, 1),
        show(find(out, "a")) .. " / " .. show(find(out, "b")))
    assert(same(find(out, "z"), B("z", 1, 3, 4, 1)), "z moved")
end)

t.test("a same-size group below swaps on a move down", function()
    local bs = { B("clock", 1, 1, 2, 2), B("c", 1, 3, 2, 1), B("d", 1, 4, 2, 1) }
    local out = assert(Grid.move(bs, "clock", 0, 1, D))
    assert(at(find(out, "clock"), 1, 1, 3, 2, 2), show(find(out, "clock")))
    assert(at(find(out, "c"), 1, 1, 1) and at(find(out, "d"), 1, 1, 2),
        show(find(out, "c")) .. " / " .. show(find(out, "d")))
end)

t.test("a group that sticks out of the swap block doesn't swap", function()
    -- b reaches below the clock's height, so the block isn't clock-sized.
    local bs = { B("clock", 1, 1, 2, 2), B("a", 3, 1, 2, 1), B("b", 3, 2, 2, 2), B("z", 1, 5, 4, 1) }
    local out = Grid.move(bs, "clock", 1, 0, D)
    if out then
        assert(not at(find(out, "clock"), 1, 3, 1), "clock jumped two columns")
    end
end)

-- ── Growing by squeezing neighbours ──────────────────────────────────────────

local function fillRows(bs, from_row)
    for r = from_row, 5 do
        for c = 1, 4 do bs[#bs + 1] = B("f" .. c .. r, c, r, 1, 1) end
    end
    return bs
end

t.test("wider squeezes the neighbour in that row", function()
    local bs = fillRows({ B("clock", 1, 1, 2, 2), B("quote", 3, 1, 2, 2) }, 3)
    local out = assert(Grid.resize(bs, "clock", "w", 1, D))
    assert(find(out, "clock").w == 3, show(find(out, "clock")))
    assert(at(find(out, "quote"), 1, 4, 1, 1, 2), show(find(out, "quote")))
end)

t.test("a neighbour already at one cell can't be squeezed", function()
    local bs = fillRows({ B("clock", 1, 1, 3, 2), B("quote", 4, 1, 1, 2) }, 3)
    local out, why = Grid.resize(bs, "clock", "w", 1, D)
    assert(out == nil and why == "no_room")
end)

t.test("squeezing respects the neighbour's minimum", function()
    local bs = fillRows({ B("clock", 1, 1, 2, 2), B("quote", 3, 1, 2, 2) }, 3)
    local function mins(id) if id == "quote" then return 2, 1 end return 1, 1 end
    local out, why = Grid.resize(bs, "clock", "w", 1, D, 1, 1, mins)
    assert(out == nil and why == "no_room", "squeezed below its minimum")
end)

t.test("taller squeezes the modules below in that column", function()
    local bs = { B("clock", 1, 1, 2, 2), B("p", 1, 3, 1, 2), B("q", 2, 3, 1, 2),
                 B("r", 3, 1, 2, 5), B("s", 1, 5, 2, 1) }
    local out = assert(Grid.resize(bs, "clock", "h", 1, D))
    assert(find(out, "clock").h == 3, show(find(out, "clock")))
    assert(at(find(out, "p"), 1, 1, 4, 1, 1) and at(find(out, "q"), 1, 2, 4, 1, 1),
        show(find(out, "p")) .. " / " .. show(find(out, "q")))
end)

t.test("wider at the right edge squeezes the neighbour on the left", function()
    local bs = fillRows({ B("w", 1, 1, 2, 2), B("e", 3, 1, 2, 2) }, 3)
    local out = assert(Grid.resize(bs, "e", "w", 1, D))
    assert(at(find(out, "e"), 1, 2, 1, 3, 2), show(find(out, "e")))
    assert(at(find(out, "w"), 1, 1, 1, 1, 2), show(find(out, "w")))
end)

t.test("a free cell next to it means a plain one-cell move, not a swap", function()
    -- The PW5: quote 2x1 at cols 1-2, a gap at col 3, On this day 3x1 at 4-6.
    local D6 = { cols = 6, rows = 7, cell_w = 100, cell_h = 100, gap = 10 }
    local bs = { B("quote", 1, 4, 2, 1), B("otd", 4, 4, 3, 1) }
    local out = assert(Grid.move(bs, "otd", -1, 0, D6))
    assert(at(find(out, "otd"), 1, 3, 4, 3, 1), show(find(out, "otd")))
    assert(at(find(out, "quote"), 1, 1, 4, 2, 1), "quote moved: " .. show(find(out, "quote")))
end)

t.test("a block only partly filled is not swapped with", function()
    -- Left of otd: quote 2x1 plus one empty cell; the step left lands on the
    -- quote, which moves aside under the usual rule rather than trading places.
    local D6 = { cols = 6, rows = 7, cell_w = 100, cell_h = 100, gap = 10 }
    local bs = { B("quote", 2, 4, 2, 1), B("otd", 4, 4, 3, 1) }
    local out = assert(Grid.move(bs, "otd", -1, 0, D6))
    assert(find(out, "otd").col == 3, "otd jumped to " .. find(out, "otd").col)
end)

t.test("wider grows to the left when the right is blocked and the left is free", function()
    -- A full page apart from the cell left of the ornament; its right
    -- neighbour is a single cell, so it can't be squeezed.
    local bs = {}
    for r = 1, 5 do for c = 1, 4 do
        if not (r == 1 and (c == 2 or c == 3)) then bs[#bs + 1] = B("f" .. c .. r, c, r, 1, 1) end
    end end
    bs[#bs + 1] = B("orn", 3, 1, 1, 1)
    local out = assert(Grid.resize(bs, "orn", "w", 1, D))
    assert(at(find(out, "orn"), 1, 2, 1, 2, 1), show(find(out, "orn")))
end)

t.test("taller grows up when below is blocked and above is free", function()
    local bs = {}
    for r = 1, 5 do for c = 1, 4 do
        if not (c == 1 and (r == 2 or r == 3)) then bs[#bs + 1] = B("f" .. c .. r, c, r, 1, 1) end
    end end
    bs[#bs + 1] = B("orn", 1, 3, 1, 1)
    local out = assert(Grid.resize(bs, "orn", "h", 1, D))
    assert(at(find(out, "orn"), 1, 1, 2, 1, 2), show(find(out, "orn")))
end)

t.done()
