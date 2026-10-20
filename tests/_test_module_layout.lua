-- Headless tests for lib/bookshelf_module_layout.lua: turning a surface's
-- stored entries into the boxes the renderer draws, and deciding when that
-- work has to be saved (placement, migration, landscape seeding) and when it
-- must not be (overflow on a smaller grid).
package.path = "./?.lua;./?/init.lua;" .. package.path

local Layout = dofile("lib/bookshelf_module_layout.lua")
local Grid   = dofile("lib/bookshelf_module_grid.lua")
local t = dofile("tests/_helpers.lua").runner()

local D  = { cols = 4, rows = 5, cell_w = 100, cell_h = 100, gap = 10 }
local D4 = { cols = 4, rows = 4, cell_w = 100, cell_h = 100, gap = 10 }
local DL = { cols = 6, rows = 3, cell_w = 100, cell_h = 100, gap = 10 }

local function at(page, col, row, w, h)
    return { page = page, col = col, row = row, w = w, h = h }
end

local function placed() return {
    { id = "clock",  type = "module", module = "analogue_clock", at = at(1, 1, 1, 2, 2) },
    { id = "goal",   type = "module", module = "reading_goal",   at = at(1, 3, 1, 2, 1) },
    { id = "rings",  type = "module", module = "rings",          at = at(1, 1, 3, 4, 2) },
    { id = "quote",  type = "module", module = "quote_of_day",   at = at(1, 1, 5, 3, 1) },
} end

local function size_for() return 1, 1 end

local function find(bs, id)
    for _i, b in ipairs(bs) do if b.id == id then return b end end
end

local function copyAt(a) return at(a.page, a.col, a.row, a.w, a.h) end

t.test("key picks the orientation's field", function()
    assert(Layout.key(false) == "at" and Layout.key(true) == "at_land")
end)

t.test("a layout that fits renders as stored and saves nothing", function()
    local items = placed()
    local boxes, changed = Layout.resolveFor(items, D, { migrated = true, size_for = size_for })
    assert(changed == false)
    assert(#boxes == 4 and find(boxes, "quote").row == 5)
end)

t.test("overflow-only does not save", function()
    local items = placed()
    local before = copyAt(items[4].at)
    local boxes, changed = Layout.resolveFor(items, D4, { migrated = true, size_for = size_for })
    assert(changed == false, "overflow must be render-time only")
    assert(find(boxes, "quote").page == 2, "quote should spill to page 2")
    local a = items[4].at
    assert(a.page == before.page and a.row == before.row, "stored position changed")
end)

t.test("landscape seeds once from portrait reading order", function()
    local items = placed()
    local boxes, changed = Layout.resolveFor(items, DL,
        { landscape = true, migrated = true, size_for = size_for })
    assert(changed == true)
    for _i, it in ipairs(items) do assert(Grid.validAt(it.at_land), it.id .. " not seeded") end
    assert(#boxes == 4)
    local _b, changed2 = Layout.resolveFor(items, DL,
        { landscape = true, migrated = true, size_for = size_for })
    assert(changed2 == false, "second landscape build re-seeded")
end)

t.test("landscape seeding doesn't touch portrait", function()
    local items = placed()
    local before = {}
    for i, it in ipairs(items) do before[i] = copyAt(it.at) end
    Layout.resolveFor(items, DL, { landscape = true, migrated = true, size_for = size_for })
    for i, it in ipairs(items) do
        local a, b = it.at, before[i]
        assert(a.page == b.page and a.col == b.col and a.row == b.row
            and a.w == b.w and a.h == b.h, it.id .. " portrait position changed")
    end
end)

t.test("migration runs once and clears legacy fields", function()
    local items = {
        { id = "a", type = "module", module = "x", size = 2, page = 1 },
        { id = "b", type = "module", module = "y", page = 2 },
    }
    local function legacy()
        return {
            { id = "a", page = 1, px_w = 430, px_h = 100 },
            { id = "b", page = 2, px_w = 210, px_h = 210 },
        }
    end
    local boxes, changed = Layout.resolveFor(items, D,
        { migrated = false, legacy = legacy, size_for = size_for })
    assert(changed == true)
    assert(items[1].at.w == 4 and items[1].at.page == 1, "a not snapped")
    -- b was alone on its old page, so it filled it, and still does.
    assert(items[2].at.w == 4 and items[2].at.h == 5 and items[2].at.page == 2, "b not snapped")
    assert(items[1].size == nil and items[1].page == nil and items[2].page == nil,
        "legacy fields not cleared")
    assert(#boxes == 2)
end)

t.test("migration is skipped once the flag is set", function()
    local called = false
    local items = { { id = "a", type = "module", module = "x" } }
    Layout.resolveFor(items, D, { migrated = true, size_for = size_for,
        legacy = function() called = true; return {} end })
    assert(not called, "legacy packer ran after migration")
    assert(Grid.validAt(items[1].at), "unplaced item not placed")
end)

t.test("a newly added module lands on the current page's first free cell", function()
    local items = placed()
    items[#items + 1] = { id = "new", type = "module", module = "z" }
    local boxes, changed = Layout.resolveFor(items, D,
        { migrated = true, size_for = size_for, page = 2 })
    assert(changed == true)
    assert(items[5].at.page == 2 and items[5].at.col == 1 and items[5].at.row == 1,
        string.format("new at p%d c%d r%d", items[5].at.page, items[5].at.col, items[5].at.row))
    assert(find(boxes, "new").page == 2)
end)

t.test("a new module uses the size size_for gives it", function()
    local items = { { id = "q", type = "module", module = "quote" } }
    Layout.resolveFor(items, D, { migrated = true, size_for = function() return 2, 1 end })
    assert(items[1].at.w == 2 and items[1].at.h == 1)
end)

t.test("spill past four pages still renders", function()
    local items = {}
    for i = 1, 30 do items[i] = { id = "m" .. i, type = "module", module = "x" } end
    local boxes = Layout.resolveFor(items, D,
        { migrated = true, size_for = function() return 2, 2 end })
    assert(#boxes == 30, "#boxes " .. #boxes)
    assert(#Grid.pages(boxes) == 8, "pages " .. #Grid.pages(boxes))
end)

t.test("a first landscape seed before any portrait layout migrates from the old one", function()
    local items = {
        { id = "a", type = "module", module = "x", size = 2 },
        { id = "b", type = "module", module = "y" },
    }
    local function legacy()
        return {
            { id = "a", page = 1, row = 1, px_w = 600, px_h = 300 },
            { id = "b", page = 1, row = 1, px_w = 300, px_h = 300 },
        }
    end
    Layout.resolveFor(items, DL, { landscape = true, migrated = false,
        legacy = legacy, size_for = size_for })
    assert(items[1].at_land.w == 4 and items[2].at_land.w == 2,
        "widths " .. items[1].at_land.w .. "," .. items[2].at_land.w)
    assert(items[1].at_land.h == 3, "a single old row fills the height")
end)

t.test("the default top panel seeds into landscape on one page", function()
    -- hero DEFAULTS: clock 2x2 at col 1, quote asks for w = 8 from col 3.
    local items = {
        { id = "hm_clock", type = "module", module = "analogue_clock", at = at(1, 1, 1, 2, 2) },
        { id = "hm_quote", type = "module", module = "quote_of_day",   at = at(1, 3, 1, 8, 2) },
    }
    local P7 = { cols = 7, rows = 2, cell_w = 100, cell_h = 100, gap = 10 }
    local boxes = Layout.resolveFor(items, P7, { landscape = true, migrated = true, size_for = size_for })
    for _i, b in ipairs(boxes) do assert(b.page == 1, b.id .. " on page " .. b.page) end
    assert(items[2].at_land.page == 1 and items[2].at_land.w == 5, "quote seeded as " ..
        items[2].at_land.page .. ":" .. items[2].at_land.w)
end)

t.done()
