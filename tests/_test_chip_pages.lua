-- tests/_test_chip_pages.lua
-- Pure-Lua tests for lib/bookshelf_chip_pages.lua (the chip-bar pagination math).
-- Run from the plugin root: `lua tests/_test_chip_pages.lua`

local Pages = dofile("lib/bookshelf_chip_pages.lua")

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1
    else fail = fail + 1; io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n") end
end
local function pg(r, i) return r.pages[i] end

test("all chips fit -> one page, not multi, spans everything", function()
    local r = Pages.paginate{ widths = { 50, 50, 50 }, spacing = 2, avail = 200, chevron_w = 40 }
    assert(r.num_pages == 1, "num_pages=" .. r.num_pages)
    assert(r.multi == false, "should not be multi")
    assert(pg(r, 1).first == 1 and pg(r, 1).last == 3, "page 1 spans 1..3")
end)

test("overflow -> multiple pages with correct boundaries", function()
    local r = Pages.paginate{ widths = { 40, 40, 40, 40, 40, 40 }, spacing = 0, avail = 100, chevron_w = 10 }
    assert(r.num_pages == 3, "num_pages=" .. r.num_pages)
    assert(r.multi == true, "should be multi")
    assert(pg(r, 1).first == 1 and pg(r, 1).last == 2, "p1=1..2")
    assert(pg(r, 2).first == 3 and pg(r, 2).last == 4, "p2=3..4")
    assert(pg(r, 3).first == 5 and pg(r, 3).last == 6, "p3=5..6")
end)

test("pageOf maps a flex index to its page", function()
    local r = Pages.paginate{ widths = { 40, 40, 40, 40, 40, 40 }, spacing = 0, avail = 100, chevron_w = 10 }
    assert(Pages.pageOf(r, 1) == 1)
    assert(Pages.pageOf(r, 4) == 2)
    assert(Pages.pageOf(r, 5) == 3)
    assert(Pages.pageOf(r, 99) == 1, "out of range falls back to page 1")
end)

test("reserved chevron width reduces per-page capacity (spill)", function()
    -- Without chevrons, two 45px chips fit in 100px. With chevrons reserved,
    -- only one fits per page -> the second spills to page 2.
    local r = Pages.paginate{ widths = { 45, 45, 45 }, spacing = 0, avail = 100, chevron_w = 20 }
    assert(r.multi == true)
    assert(pg(r, 1).first == 1 and pg(r, 1).last == 1, "p1 holds only 1 chip once chevrons reserved")
end)

test("a single chip wider than a page gets its own page (renderer truncates)", function()
    local r = Pages.paginate{ widths = { 500 }, spacing = 0, avail = 100, chevron_w = 10 }
    assert(r.num_pages == 1 and r.multi == false, "one page, no chevrons")
    assert(pg(r, 1).first == 1 and pg(r, 1).last == 1)
end)

test("a too-wide chip mid-list still takes a page alone, never over-fills", function()
    local r = Pages.paginate{ widths = { 40, 200, 40 }, spacing = 0, avail = 100, chevron_w = 10 }
    -- every page must hold >= 1 chip and no page may exceed avail in a way that
    -- drops a chip; just assert each chip lands on exactly one page in order.
    local seen = {}
    for _p, range in ipairs(r.pages) do
        assert(range.last >= range.first, "page not empty")
        for k = range.first, range.last do seen[#seen + 1] = k end
    end
    assert(#seen == 3 and seen[1] == 1 and seen[2] == 2 and seen[3] == 3,
        "all 3 chips placed once, in order")
end)

test("empty chip list -> zero pages", function()
    local r = Pages.paginate{ widths = {}, spacing = 0, avail = 100, chevron_w = 10 }
    assert(r.num_pages == 0 and r.multi == false)
end)

print(string.format("%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
