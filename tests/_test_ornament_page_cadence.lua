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
    -- Both curves go through one resolver now; what matters is that it reads
    -- only the level, never what is already on screen.
    local body = orn:match("local function levelFrom%(curve%)(.-)\nend\n")
    assert(body, "levelFrom missing")
    assert(not body:find("screenCount", 1, true) and not body:find("_used", 1, true),
        "the curve counts what is already on screen; that splits the "
        .. "two planning passes")
    assert(orn:find("function M.groupLevel() return levelFrom(M.GROUP_LEVEL) end", 1, true),
        "the group curve no longer goes through it")
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

t.test("Rarely is exactly its promise, with no channel adding to it", function()
    -- "9 ornaments across 11 pages... often 2 on a page. That's not rare
    -- enough." Both opportunistic channels are zero at that level, so the
    -- only placements left are the promised ones: one page in four.
    local GRP = load("return " .. orn:match("M.GROUP_LEVEL = (%b{})"))()
    local ROW = load("return " .. orn:match("M.ROW_END_LEVEL = (%b{})"))()
    eq(GRP[0.5], 0, "section breaks still roll at Rarely")
    eq(ROW[0.5], 0, "row ends still roll at Rarely")
    assert(ROW[1] > 0 and GRP[1] > 0, "Often lost its rolls as well")
    -- The promise must NOT be damped, or Rarely places nothing at all.
    assert(shelf:find("level     = (not owed) and Orn.rowEndLevel", 1, true),
        "the level is applied to the promised placement too, which would "
        .. "cancel it at Rarely")
end)

t.test("the rotation starts somewhere in the folder, and still cycles", function()
    -- "It should cycle through them all, starting at a random position in the
    -- file list." It began at the first file every time, so a folder always
    -- introduced itself in the same order after every restart.
    local body = orn:match("\nfunction M.rotationFor%(seed, count%)\n(.-)\nend\n")
    assert(body, "rotationFor missing")
    assert(body:find("M._rot_start", 1, true), "the start is not offset")
    assert(body:find("((M._rot_n + M._rot_start) % count) + 1", 1, true),
        "the offset does not reach the index, so it still starts at file one")
    -- Handing them out in TURN is what gives every file an equal share; an
    -- offset must not become a random pick per seed.
    assert(body:find("M._rot_n + 1", 1, true) or orn:find("M._rot_n = M._rot_n + 1", 1, true),
        "the rotation no longer advances one at a time")
    assert(not body:find("math.random", 1, true),
        "reseeding here would disturb anything else drawing random numbers")
end)

t.test("a piece that cannot fit the gap steps aside instead of taking the slot", function()
    -- Reported with twelve test ornaments in the folder: "I still have cacti
    -- and the template plant on the same ends of the shelfs on pages 2 and
    -- 3." The rotation was handing out turns evenly, but a chosen entry that
    -- came out too small for THIS gap ended the attempt -- so the gap stayed
    -- empty and only the two files that happen to fit a row end ever showed.
    local body = orn:match("\nfunction M%.pick%(seed, gap_px, stand_h, entries, o%)\n(.-)\nend\n")
    assert(body, "pick not found")
    assert(body:find("local function sizeFor(entry)", 1, true),
        "the size is not worked out per candidate")
    -- The walk must consult the size, not just whether it is already standing.
    local walk = body:match("(for step = 0, #entries %- 1 do.-end)")
    assert(walk and walk:find("sizeFor(cand)", 1, true),
        "the walk still stops at the first unused entry whatever its size")
    -- And a repeat is still better than a hole when nothing unused fits.
    assert(select(2, body:gsub("for step = 0, #entries %- 1 do", "")) == 2,
        "the fallback walk over already-standing pieces is gone")
end)

t.test("a wide ornament is given room instead of being dropped", function()
    -- "Can we make space for wider ornaments, instead of discarding them?
    -- Otherwise users will wonder why their ornament never appears if it's
    -- just over some hidden limit ..." (maintainer).
    --
    -- The limit WAS the row-end slot: a stand-height square, which is not a
    -- rule anybody chose, just what falls out of using the height for the
    -- width too. Anything wider was shrunk to fit and then dropped for being
    -- short. The slot now asks for a quarter of the row -- the one share the
    -- shelf does declare, the same one a section break may take -- and a piece
    -- spread across it may stand lower than one wedged between two spines.
    local SHARE = tonumber(orn:match("M.ASIDE_SHARE%s*=%s*([%d.]+)"))
    local FRAC  = tonumber(orn:match("M.ROW_END_MIN_H_FRAC%s*=%s*([%d.]+)"))
    local HFRAC = tonumber(orn:match("M.HEIGHT_FRAC%s*=%s*([%d.]+)"))
    local MFRAC = tonumber(orn:match("M.MIN_H_FRAC%s*=%s*([%d.]+)"))
    assert(SHARE and FRAC, "the row-end constants are gone")
    assert(FRAC < MFRAC, "a row end must allow a lower piece than a gap does")

    -- The slot itself: the larger of the two, so no shelf is offered less
    -- than it was before.
    local slot = shelf:match("local square = math.floor%(orn.stand_h %* Orn.HEIGHT_FRAC%)\n%s*local share%s*=%s*orn.budget\n%s*orn.row_end = ([^\n]+)")
    assert(slot and slot:find("math.max(square, share)", 1, true),
        "the row-end slot is no longer max(stand-height square, a quarter of the row)")
    assert(shelf:find("min_h_frac = Orn.ROW_END_MIN_H_FRAC", 1, true),
        "the row-end pick does not pass its own minimum height")

    -- The slot is now derived from content_w as well as the row height, and
    -- it feeds fillRows, so BOTH planning passes have to arrive at the same
    -- number or the page boundaries drift apart again. They do only because
    -- both build content_w by the same subtraction.
    local calls = {}
    for body in widget:gmatch("SpineShelf.plan%(items, {\n(.-)\n%s*}%)") do
        -- One pass reads the stashed dims (d.content_w), the other the locals
        -- they were stashed FROM; drop the prefix and the subtraction must be
        -- the same one.
        calls[#calls + 1] = (body:match("content_w%s*=%s*([^\n]-),?\n") or "")
                            :gsub("d%.", "")
    end
    eq(#calls, 2, "expected the render plan and the pagination plan, no more")
    eq(calls[1], calls[2],
        "the two planning passes no longer compute the same content width, "
        .. "so they will disagree about the row-end slot and page boundaries")
    -- ...and the stash really is those locals, not a second measurement.
    local stash = widget:match("self._shelf_dims = {\n(.-)\n%s*}")
    assert(stash and stash:find("content_w%s*=%s*content_w")
           and stash:find("shelf_h%s*=%s*shelf_h"),
        "the pagination pass reads dims that are no longer the render's own")

    -- And the behaviour, run through the real pick(). PW5 geometry, measured
    -- off a device screenshot: books stand 280px on a 1135px row.
    local body = orn:match("\nfunction M%.pick%(seed, gap_px, stand_h, entries, o%)\n(.-)\nend\n")
    assert(body, "pick not found")
    local env = {
        M = { HEIGHT_FRAC = HFRAC, MIN_H_FRAC = MFRAC, CHANCE = 0.5, _used = {},
              frequency = function() return 1 end,
              rotationFor = function() return 1 end,
              hash = function() return 0 end,
              budgetLeft = function() return 99 end },
        math = math, tostring = tostring, type = type, pairs = pairs,
    }
    local pick = assert(load("return function(seed, gap_px, stand_h, entries, o)\n"
        .. body .. "\nend", "pick", "t", env))()
    local STAND, CONTENT = 280, 1135
    local square = math.floor(STAND * HFRAC)
    local slot_w = math.max(square, math.floor(CONTENT * SHARE))
    assert(slot_w > square, "the quarter row must be the wider offer on a normal shelf")
    local function stands(gap, aspect, frac)
        env.M._used = {}
        return pick("s", gap, STAND, { { name = "w", aspect = aspect, overhang = 0 } },
                    { chance = math.huge, min_h_frac = frac })
    end
    -- Two to one: dropped by the old square, stands in the wider slot. This
    -- is the slot's doing alone -- it clears the gap's own floor.
    assert(not stands(square, 2.0, MFRAC), "the old slot took a 2:1 piece; this test proves nothing")
    local wide = stands(slot_w, 2.0, MFRAC)
    assert(wide, "a 2:1 ornament is still dropped at a row end")
    assert(wide.w <= slot_w, "the piece overflowed the slot it was offered")
    -- Three to one needs the other half: spread across the quarter row it
    -- comes out low, and the gap's floor would still refuse it.
    assert(not stands(slot_w, 3.0, MFRAC),
        "a 3:1 piece already cleared the gap's floor; the lower row-end floor proves nothing")
    local wider = stands(slot_w, 3.0, FRAC)
    assert(wider, "a 3:1 ornament is still dropped at a row end")
    -- ...and one that fits either way keeps its full height now rather than
    -- being shrunk to the square.
    local mid_old = stands(square, 1.5, nil)
    local mid_new = stands(slot_w, 1.5, FRAC)
    assert(mid_old and mid_new and mid_new.h > mid_old.h,
        "a 1.5:1 piece is still being shrunk to fit the old square")
    -- The quarter is a real ceiling, not a formality: something absurd is
    -- still refused rather than drawn as a sliver.
    assert(not stands(slot_w, 8.0, FRAC), "an 8:1 sliver was allowed to stand")
end)

t.done()
