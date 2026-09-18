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

t.test("neighbouring seeds get scattered answers, not neighbouring ones", function()
    -- THE CLUMPING. Every seeded decision is taken modulo something small --
    -- the odds are h % 100, the per-page promise h % period -- and plain djb2
    -- over strings differing in their last byte moves the answer by exactly
    -- that byte. An on-device probe caught it: h % 100 ran 23, 24, 25 ...
    -- straight up the rows of a page, so a row's ornament was not a coin
    -- toss but a contiguous run, and a two-row page gave both rows a piece or
    -- neither. Pages came in clumps with long gaps between.
    local pre = orn:match("(local bxor\n.-\nend\n)")
    local hfn = orn:match("(function M.hash%(s%).-\nend)")
    assert(pre and hfn, "the hash or its xor helper moved")
    local M = {}
    assert(load(pre .. "\n" .. hfn, "hash", "t",
        { math = math, pcall = pcall, require = require, M = M }))()
    -- Neighbouring row seeds must not give neighbouring odds.
    local runs, last = 0, nil
    for i = 1, 40 do
        local v = M.hash("page2|rowend|" .. i) % 100
        if last and v == last + 1 then runs = runs + 1 end
        last = v
    end
    assert(runs <= 3, runs .. " of 40 neighbouring seeds still stepped by one")
    -- And the spread has to be usable: the odds are a modulo of this.
    local lo, hi, sum = math.huge, 0, 0
    for i = 1, 200 do
        local v = M.hash("page" .. i .. "|rowend|1") % 100
        lo, hi, sum = math.min(lo, v), math.max(hi, v), sum + v
    end
    assert(lo < 10 and hi > 90, "the odds only reach " .. lo .. ".." .. hi)
    local mean = sum / 200
    assert(mean > 35 and mean < 65, "mean of h %% 100 is " .. mean)
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
    assert(body:find("+ M._rot_start) % count) + 1", 1, true),
        "the offset does not reach the index, so it still starts at file one")
    -- Handing them out in TURN is what gives every file an equal share; an
    -- offset must not become a random pick per seed.
    assert(body:find("M._rot_n + 1", 1, true) or orn:find("M._rot_n = M._rot_n + 1", 1, true),
        "the rotation no longer advances one at a time")
    assert(not body:find("math.random", 1, true),
        "reseeding here would disturb anything else drawing random numbers")
end)

t.test("consecutive turns land apart in the folder, and still cover it", function()
    -- "png's 2 and 3 appear on page 2 and on page 3." Turns handed out one
    -- after another went to files one after another, so the two rows of a
    -- page showed neighbours and the next page carried straight on -- a slow
    -- march through the folder that reads as the same few pieces recurring.
    -- A stride coprime to the set size visits every piece exactly once per
    -- cycle without visiting them in order.
    local fn = orn:match("\nfunction M.rotationStride%(count%)\n(.-)\nend\n")
    assert(fn, "M.rotationStride missing")
    assert(orn:find("M._rot_n * M.rotationStride(count)", 1, true),
        "the stride is not applied to the turn counter")
    local STRIDES = load("return " .. orn:match("M.ROT_STRIDES = (%b{})"))()
    local function gcd(a, b) while b ~= 0 do a, b = b, a % b end return a end
    local function stride(count)
        for _i = 1, #STRIDES do
            local st = STRIDES[_i]
            if st < count and gcd(st, count) == 1 then return st end
        end
        return 1
    end
    for count = 2, 40 do
        local st = stride(count)
        eq(gcd(st, count), 1, "stride " .. st .. " shares a factor with "
            .. count .. ", so the cycle would skip pieces")
        -- Full coverage: n turns must visit all n pieces.
        local hit = {}
        for n = 0, count - 1 do hit[(n * st) % count] = true end
        local n_hit = 0
        for _k in pairs(hit) do n_hit = n_hit + 1 end
        eq(n_hit, count, "a cycle of " .. count .. " only reached " .. n_hit)
        if count > 3 then
            assert(st > 1, "count " .. count .. " fell back to file order")
        end
    end
end)

t.test("the rotation turns over the pieces that FIT, in equal shares", function()
    -- Reported twice, with twelve test ornaments in the folder: "I still have
    -- cacti and the template plant on the same ends of the shelfs on pages 2
    -- and 3", and again after the first attempt at a fix.
    --
    -- The first attempt sized a candidate and, if it came out too small,
    -- walked on to the next. That removed the empty gaps but not the bias:
    -- the walk always steps the same way, so a piece that can NEVER fit hands
    -- its turn to the same successor every single time. On the maintainer's
    -- device the two widest files came out 121px against a 124px floor and
    -- donated all of their turns to entries 1 and 2 -- cactus and template --
    -- which then stood three times as often as anything else.
    --
    -- Deciding the fit set FIRST and rotating inside it gives every eligible
    -- piece exactly one turn.
    local body = orn:match("\nfunction M%.pick%(seed, gap_px, stand_h, entries, o%)\n(.-)\nend\n")
    assert(body, "pick not found")
    assert(body:find("local fits = {}", 1, true),
        "the fit set is not worked out before the rotation")
    local rot = body:match("local idx = M.rotationFor%(seed, ([^)]+)%)")
    eq(rot, "#fits",
        "the rotation still indexes the whole folder, so a piece that cannot "
        .. "fit keeps donating its turn to whatever follows it")

    -- And the property itself, through the real pick() at the geometry the
    -- device reported: a 974px row end, books standing 415px.
    local M = {
        HEIGHT_FRAC = tonumber(orn:match("M.HEIGHT_FRAC%s*=%s*([%d.]+)")),
        MIN_H_FRAC  = tonumber(orn:match("M.MIN_H_FRAC%s*=%s*([%d.]+)")),
        CHANCE = 0.5, _used = {}, _rot = {}, _rot_n = 0, _rot_start = 0,
        frequency = function() return 1 end,
        hash = function() return 0 end,
        budgetLeft = function() return 99 end,
    }
    M.rotationFor = function(seed, count)
        if not count or count <= 1 then return 1 end
        local had = M._rot[seed]
        if had then return ((had - 1) % count) + 1 end
        local idx = ((M._rot_n + M._rot_start) % count) + 1
        M._rot[seed] = idx
        M._rot_n = M._rot_n + 1
        return idx
    end
    local pick = assert(load("return function(seed, gap_px, stand_h, entries, o)\n"
        .. body .. "\nend", "pick", "t",
        { M = M, math = math, tostring = tostring, type = type,
          pairs = pairs, ipairs = ipairs }))()
    local pool, aspects = {}, { 0.57, 0.57, 0.48, 0.75, 1.0, 1.5, 2.0, 2.5,
                                3.0, 4.0, 5.0, 6.5, 8.0, 9.0 }
    for i, a in ipairs(aspects) do
        pool[i] = { name = "f" .. i, aspect = a, overhang = 0 }
    end
    local GAP, STAND, PAGES = 974, 415, 120
    local seen = {}
    for page = 1, PAGES do
        for within = 1, 2 do
            M._used = {}                       -- beginScreen, once per page
            local pl = pick("page" .. page .. "|rowend|" .. within, GAP, STAND,
                            pool, { chance = math.huge, min_h_frac = 0.3 })
            assert(pl, "the gap was left empty although something fits")
            seen[pl.entry.name] = (seen[pl.entry.name] or 0) + 1
        end
    end
    local lo, hi, standing = math.huge, 0, 0
    for i = 1, #pool do
        local c = seen[pool[i].name] or 0
        if c > 0 then
            standing = standing + 1
            lo, hi = math.min(lo, c), math.max(hi, c)
        end
    end
    assert(standing >= 10, "only " .. standing .. " of the folder ever stood")
    -- Perfectly even is what the rotation gives; allow one for rounding when
    -- the page count is not a multiple of the fit-set size.
    assert(hi - lo <= 1, string.format(
        "shares run %d..%d across the %d files that can stand; the rotation "
        .. "is favouring some of them", lo, hi, standing))
end)

t.test("a wide ornament is given room instead of being dropped", function()
    -- "Can we make space for wider ornaments, instead of discarding them?
    -- Otherwise users will wonder why their ornament never appears if it's
    -- just over some hidden limit ..." and then, of the quarter-row cap that
    -- first replaced it: "I don't think there's any downside to allowing
    -- ornaments that stretch the full width of the shelf?" (maintainer).
    --
    -- There is one, and it is not about taste. The row-end width comes off
    -- the row BEFORE the books are packed, and fillRows seats at least one
    -- book however little is left -- so a row that gave up everything would
    -- show a single spine with the ornament over it. That is the only limit:
    -- the row keeps room for a few average books and the piece has the rest.
    local FRAC  = tonumber(orn:match("M.ROW_END_MIN_H_FRAC%s*=%s*([%d.]+)"))
    local HFRAC = tonumber(orn:match("M.HEIGHT_FRAC%s*=%s*([%d.]+)"))
    local MFRAC = tonumber(orn:match("M.MIN_H_FRAC%s*=%s*([%d.]+)"))
    assert(FRAC, "the row-end constants are gone")
    assert(FRAC < MFRAC, "a row end must allow a lower piece than a gap does")

    -- The slot: everything but `keep`, floored at the old square so no shelf
    -- is offered less than it was before.
    local keep_expr = shelf:match("(local face_h = SpineLayout.-)\n%s*local square")
    local room_expr = shelf:match("local room%s*=%s*([^\n]+)")
    local slot = shelf:match("local room%s*=.-\n%s*[^\n]*\n%s*orn.row_end = ([^\n]+)")
    assert(room_expr and room_expr:find("content_w", 1, true)
           and room_expr:find("orn.keep", 1, true),
        "the slot is not what the row can spare once the books have their "
        .. "room; it is a fixed share again (" .. tostring(room_expr) .. ")")
    assert(keep_expr, "the books-kept-back floor is gone")
    assert(slot and slot:find("math.max(square, room)", 1, true),
        "the row-end slot is no longer max(stand-height square, what the row can spare)")
    assert(shelf:find("min_h_frac = Orn.ROW_END_MIN_H_FRAC", 1, true),
        "the row-end pick does not pass its own minimum height")
    -- THE TWO-PASS TRAP. The floor must come from opts, never from the row's
    -- actual books: one pass plans a page and the other the whole library, so
    -- a statistic over `widths` would put them out of step and repeat page
    -- numbers again.
    assert(keep_expr:find("faceOutWidth", 1, true),
        "the width held back is not a face-out cover, which is the widest "
        .. "single thing a row can hold and the one that overflowed")
    assert(keep_expr:find("opts.row_h", 1, true),
        "the floor is not derived from opts")
    assert(not keep_expr:find("widths", 1, true)
           and not keep_expr:find("entries", 1, true),
        "the floor reads the actual books, which the two planning passes "
        .. "cannot agree on")
    -- And the narrow-shelf guard drops the reservation by the same measure,
    -- not by the old fixed third.
    assert(shelf:find("content_w_books - orn.row_end < (orn.keep or 0)", 1, true),
        "the guard no longer asks whether the books still have their room")
    assert(not shelf:find("content_w_books <= orn.row_end * 3", 1, true),
        "the fixed one-third guard is back; it fires on every shelf now")

    -- Both planning passes have to arrive at the same slot, and they do only
    -- because both build content_w by the same subtraction.
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
    -- off a device screenshot: books stand 280px on a 1135px row, and an
    -- average spine is 44px wide beside a 6px gap.
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
    -- PW5 home tab, measured off a device screenshot and confirmed by an
    -- on-device probe: a 1135px row, books standing 280px, one face-out
    -- cover about 200px wide.
    local STAND, CONTENT, COVER_W, GAP = 280, 1135, 200, 6
    local square = math.floor(STAND * HFRAC)
    local slot_w = math.max(square, CONTENT - (COVER_W + GAP) - 2 * GAP)
    assert(slot_w > CONTENT / 2,
        "the slot came out at " .. slot_w .. "px of " .. CONTENT
        .. "; a piece that spans the shelf still cannot")
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
    -- A four-to-one banner keeps its FULL height: it is not being squeezed
    -- into a corner, it is standing along the shelf.
    local banner = stands(slot_w, 4.0, FRAC)
    assert(banner and banner.h == math.floor(STAND * HFRAC),
        "a 4:1 ornament no longer stands at full height")
    -- And something genuinely panoramic still stands, low and long, rather
    -- than vanishing: the lower row-end floor is what buys this.
    assert(not stands(slot_w, 9.0, MFRAC),
        "a 9:1 piece already cleared the gap's floor; the lower row-end floor "
        .. "proves nothing")
    assert(stands(slot_w, 9.0, FRAC), "a 9:1 ornament is still dropped")
end)

t.done()
