-- tests/_test_ornament_page_cadence.lua
-- Ornaments are promised per PAGE, and both planners agree which page.
--
-- THE REPORT. "Set to often, there was only one ornament in total on the whole
-- shelf." Every placement was opportunistic -- a piece appeared where a gap
-- happened to be wide enough -- and on a plain shelf that can mean almost
-- never: a shelf with no groups has no section breaks at all, and a densely
-- packed row leaves a few dozen pixels at its end, under the minimum gap.
--
-- THE TRAP THAT SANK THE FIRST ATTEMPT. plan() has two callers. The render
-- plans ONE page. _spinePageFirsts plans the WHOLE library in one call and
-- cuts the rows into pages, and that is where page boundaries come from.
-- Anything decided in plan() changes how many books fit on a row, so the two
-- must decide identically or they disagree about where pages start. The first
-- attempt seeded the promise on the plan's first book -- the chip's first book
-- in one pass, the page's first book in the other -- and page numbers came out
-- twice. It was reverted.
--
-- So the seed is the page's ORDINAL and the row's position WITHIN that page,
-- which both passes can state: the render knows them, and the pagination pass
-- derives them from rows_per_page.
--
-- Usage (from plugin root): lua tests/_test_ornament_page_cadence.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq
local orn   = io.open("lib/bookshelf_ornaments.lua"):read("*a")
local shelf = io.open("lib/bookshelf_spine_shelf.lua"):read("*a")
local widget = io.open("lib/bookshelf_widget.lua"):read("*a")

local PERIOD = load("return " .. orn:match("M.PAGE_PERIOD = (%b{})"))()
local function hash(s)
    local h = 5381
    for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
    return h
end
local function guaranteed(level, page)
    local p = PERIOD[level]
    if not p or p <= 0 then return false end
    if p == 1 then return true end
    return hash("page:" .. page) % p == 0
end

t.test("each level promises a page often enough to be noticed", function()
    eq(PERIOD[0], 0, "None must promise nothing")
    eq(PERIOD[2], 1, "Always must mean every page")
    assert(PERIOD[1] and PERIOD[1] <= 3,
        "Often promises one page in " .. tostring(PERIOD[1]) .. "; too sparse "
        .. "to answer 'only one ornament on the whole shelf'")
    assert(PERIOD[0.5] > PERIOD[1], "Rarely must be rarer than Often")
end)

t.test("Always covers every page, None none, Often about half", function()
    local often = 0
    for p = 1, 200 do
        assert(guaranteed(2, p), "Always missed page " .. p)
        assert(not guaranteed(0, p), "None promised page " .. p)
        if guaranteed(1, p) then often = often + 1 end
    end
    assert(often > 70 and often < 130,
        "Often promised " .. often .. " of 200 pages; expected about half")
end)

t.test("the promise is seeded on the ORDINAL, which both passes can state", function()
    local body = orn:match("\nfunction M.pageGuaranteed%(page%)\n(.-)\nend\n")
    assert(body, "M.pageGuaranteed missing")
    assert(body:find('M.hash("page:" .. tostring(page))', 1, true),
        "the promise is not keyed on the page ordinal")
    -- The shape that was reverted: seeding on the plan's own items.
    assert(not shelf:find("screenGuaranteed", 1, true),
        "the reverted per-screen seeding is back")
end)

t.test("both planners derive the same page for a row", function()
    local body = shelf:match("local function pageOf%(r%)(.-)\n    end")
    assert(body, "pageOf missing")
    assert(body:find("math.floor((r - 1) / per_page) + 1", 1, true),
        "the pagination pass cannot work out which page a row is on")
    assert(body:find("opts.page_index", 1, true),
        "the render pass no longer uses the page it was given")
    -- And the pagination caller has to say how it will cut the rows up.
    assert(widget:find("rows_per_page = self:_nShelves()", 1, true),
        "the pagination plan no longer states its page size, so plan() has to guess")
end)

t.test("the row-end decision has no cap, and is not keyed on a book", function()
    local plan = shelf:match("\nfunction SpineShelf%.plan%(items, opts%)\n(.-)\nfunction SpineShelf%.")
    assert(plan, "plan not found")
    -- It used to stop at 8 rows, which in the whole-library pass is the first
    -- 8 rows of the LIBRARY, so every page after the first went undecided.
    assert(not plan:find("math.min(opts.n_rows or 1, 8)", 1, true),
        "the row-end loop is capped again; in the pagination pass that caps "
        .. "the whole library rather than a page")
    assert(not plan:find('tostring(first_fp) .. "|rowend|"', 1, true),
        "the row-end seed is a book again, which differs between the passes")
    assert(plan:find('"page" .. page .. "|rowend|" .. within', 1, true),
        "the row-end seed is not page-relative")
end)

t.test("page-relative options stay out of the entries cache key", function()
    -- They shape rows, not entries, and the pagination plan has to share the
    -- cache slot with the page plans or it pays for the whole library again.
    local body = shelf:match("local parts = {}(.-)\n    end")
    assert(body, "the entries key builder moved")
    assert(body:find('k ~= "rows_per_page"', 1, true), "rows_per_page is in the key")
    assert(body:find('k ~= "page_index"', 1, true), "page_index is in the key")
end)

t.test("the section-break channel has its own curve, damped when sparse", function()
    -- THE SECOND REPORT. "Set ornaments to rarely appear and I have 4 on
    -- screen right now." One level scaled every channel, but the channels do
    -- not offer the same NUMBER of chances: a plain shelf has a couple of row
    -- ends per page, a grouping chip can have thirty section breaks. The same
    -- multiplier therefore reads as nothing on one shelf and a crowd on the
    -- other.
    local CURVE = load("return " .. orn:match("M.GROUP_LEVEL = (%b{})"))()
    local base  = tonumber(orn:match("M.GROUP_CHANCE%s*=%s*([%d%.]+)"))
    assert(CURVE and base, "the group curve or its base chance moved")
    eq(CURVE[0], 0, "None must place nothing between sections either")
    assert(CURVE[0.5] < 0.5,
        "Rarely is not damped; on a chip of small groups it lands several")
    for _i, pair in ipairs({ {0.5, 1}, {1, 2} }) do
        assert(CURVE[pair[2]] > CURVE[pair[1]],
            "the curve must still rise with the level")
    end
    -- On a page holding thirty section breaks, which is an ordinary genre or
    -- series chip, the expected count per screen:
    local function per_page(level) return 30 * base * CURVE[level] end
    assert(per_page(0.5) < 1.2, string.format(
        "Rarely expects %.1f per screen on a grouped chip", per_page(0.5)))
    assert(per_page(2) > 2, "Always should still fill a grouped shelf")
end)

t.test("the curve is a pure function of the level, not a per-screen count", function()
    -- It wanted to be a cap. It cannot be: the section-break placement widens
    -- the gap it stands in, so it changes how many books fit, and a count kept
    -- per screen would give plan()'s two callers different answers -- the same
    -- crack that made page numbers repeat.
    local body = orn:match("\nfunction M.groupLevel%(%)\n(.-)\nend\n")
    assert(body, "M.groupLevel missing")
    assert(not body:find("screenCount", 1, true) and not body:find("_used", 1, true),
        "the group curve counts what is already on screen; that splits the "
        .. "two planning passes")
    assert(shelf:find("level     = orn.mod.groupLevel", 1, true),
        "the section-break pick no longer uses the damped curve")
end)

t.test("the render-only channels take a per-screen ceiling", function()
    local BUDGET = load("return " .. orn:match("M.PAGE_BUDGET = (%b{})"))()
    assert(BUDGET, "M.PAGE_BUDGET missing")
    eq(BUDGET[0], 0, "None must place nothing")
    eq(BUDGET[0.5], 1, "Rarely should not exceed one a screen")
    assert(BUDGET[1] > BUDGET[0.5] and BUDGET[2] > BUDGET[1],
        "the ceiling must rise with the level")
    -- It counts what is ALREADY standing, so a section-break piece placed
    -- earlier in plan() spends part of the allowance.
    local left = orn:match("\nfunction M.budgetLeft%(%)\n(.-)\nend\n")
    assert(left and left:find("M._used", 1, true),
        "the ceiling does not count what is already on the screen")
    local pick = orn:match("\nfunction M.pick%(seed, gap_px, stand_h, entries, o%)\n(.-)\nend\n")
    assert(pick and pick:find("o.budgeted and M.budgetLeft() <= 0", 1, true),
        "pick does not honour the ceiling")
end)

t.test("only the channels that cannot move a book are capped", function()
    -- The section-break piece WIDENS the gap it stands in, so it decides how
    -- many books fit; capping it per screen would give plan()'s two callers
    -- different answers. The row-end reserve is the same. Both must stay
    -- pure functions of the level.
    local plan = shelf:match("\nfunction SpineShelf%.plan%(items, opts%)\n(.-)\nfunction SpineShelf%.")
    local grp = plan:match("(local pl = orn.mod.pick%(seed, orn.budget.-%})")
    assert(grp, "the section-break pick moved")
    assert(not grp:find("budgeted", 1, true),
        "the section-break pick is budgeted; it changes packing, so that "
        .. "splits the two planning passes")
    local rowend = plan:match("(local ok_p, pl = pcall%(Orn.pick,.-%})")
    assert(rowend, "the row-end pick moved")
    assert(not rowend:find("budgeted", 1, true),
        "the row-end reserve is budgeted; it changes packing too")
    -- And the two that are safe say so.
    eq(select(2, shelf:gsub("budgeted  = true", "")), 2,
        "expected exactly the two render-only channels to be capped")
end)

t.done()
