-- tests/_test_list_row_budget.lua
-- The WIDGET side of the list density model: BookshelfWidget:_listRowHeight()
-- and :_listRowGap(), driven against their real method bodies.
--
-- tests/_test_list_geom.lua proves the arithmetic in bookshelf_list_geom.lua.
-- It cannot prove that the widget actually asks for that arithmetic, because
-- it cannot load bookshelf_widget.lua. That gap is not theoretical: the gap
-- accessor used to return Size.line.thin restated locally, and the pure test
-- hardcoded scaleBySize(0.5) alongside it. Reverting the accessor to PAD --
-- which drops a 1248x1648 panel from 27 rows to 10, below the cover grid's 12
-- and straight back into the failure list view exists to fix -- left the whole
-- suite green.
--
-- So the two accessors are extracted by name and run under stubs, the same way
-- _test_jump_scan_list and _test_select_all_view drive their methods. What is
-- asserted is the WIRING: that the budget is built from ListGeom's own
-- declarations rather than from numbers restated in the widget.
package.path = "./?.lua;./?/init.lua;" .. package.path

local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local ListGeom = require("lib/bookshelf_list_geom")

local src = io.open("lib/bookshelf_widget.lua"):read("*a")

local function bodyOf(name)
    local body = src:match("\nfunction BookshelfWidget:" .. name
        .. "%(%)\n(.-)\nend\n")
    assert(body, "could not find BookshelfWidget:" .. name .. "() - renamed?")
    return body
end

local function compile(code, env, chunkname)
    if _G.setfenv then
        local f = assert(_G.loadstring(code, chunkname))
        _G.setfenv(f, env)
        return f
    end
    return assert(load(code, chunkname, "t", env))
end

-- ── _listRowGap ────────────────────────────────────────────────────────────

t.test("_listRowGap budgets exactly the declared hairline", function()
    local scaled = {}
    local env = {
        require = function(name)
            assert(name == "lib/bookshelf_list_geom",
                "_listRowGap should read the gap from ListGeom, not " .. name)
            return ListGeom
        end,
        Screen = { scaleBySize = function(_, px) scaled[#scaled + 1] = px
                                                 return px * 100 end },
    }
    local out = compile(bodyOf("_listRowGap"), env, "_listRowGap")()
    -- The dp it scaled must be ListGeom's declaration, not a local restatement
    -- and not PAD: this is the assertion the previous revision was missing.
    assert(#scaled == 1, "expected exactly one scaleBySize call, got " .. #scaled)
    assert(scaled[1] == ListGeom.ROW_GAP_DP, string.format(
        "the widget budgeted %s dp of gap; ListGeom declares %s",
        tostring(scaled[1]), tostring(ListGeom.ROW_GAP_DP)))
    assert(out == ListGeom.ROW_GAP_DP * 100,
        "the gap must be the scaled declaration, got " .. tostring(out))
end)

-- ── _listNaturalRowHeight ──────────────────────────────────────────────────
--
-- What the row height used to be outright, and now the DEFAULT: the height the
-- configured lines want. A reader who never picks a row count gets exactly
-- this, so every expectation below is also the no-regression check on the
-- inversion.

-- Run the real body with a stub font stack. `ring`, the line heights and
-- `chip_h` are sentinels rather than real device numbers, so what comes back
-- can only be right if the body composed it out of exactly those things.
--
-- ListRow is stubbed with the accessors the widget is supposed to go through --
-- lineHeights, chipRowHeight, RING, TEXT_PAD, INTRA_LEAD. A widget that went
-- back to reading Size.item.height_default, a font-scale setting, or
-- KOReader's TextWidget for itself would have to name them, and there is
-- nothing in this environment to name: `TextWidget` and `BFont` are
-- deliberately ABSENT, so a body that resolves or measures a face for itself
-- raises rather than quietly keeping a second opinion about the faces the row
-- renders in.
--
-- Every line answers a DIFFERENT height, so a budget that spent the first
-- line's height twice -- or measured only the first -- cannot land on the
-- expected number.

local function rowHeight(opts)
    local RING   = opts.ring or 7
    local CHIP_H = opts.chip_h or 0
    local TEXT_PAD = opts.text_pad or 0
    local LEAD     = opts.lead or 0
    -- The harness's own shorthand: one line unless a second height is given.
    local heights = opts.line_heights
        or (opts.line2_h and { opts.font_h or 41, opts.line2_h })
        or { opts.font_h or 41 }
    local asked = {}
    local ListRow = {
        FONT_FACE  = "infofont",
        RING       = RING,
        TEXT_PAD   = TEXT_PAD,
        INTRA_LEAD = LEAD,
        chipRowHeight = function() return CHIP_H end,
        -- Answers the height of each line the LAYOUT holds, so a body that
        -- passed something other than the layout's own line array gets the
        -- wrong count back.
        lineHeights = function(lines)
            asked[#asked + 1] = lines
            local out = {}
            for i = 1, #(lines or {}) do out[i] = heights[i] or 0 end
            return out
        end,
    }
    local env = {
        require = function(name)
            if name == "lib/bookshelf_list_geom" then return ListGeom end
            if name == "lib/bookshelf_list_row"  then return ListRow  end
            error("unexpected require: " .. name)
        end,
        math = math,
    }
    -- `self` is the method's implicit parameter; the extracted body has no
    -- parameter list, so it resolves as a global out of the environment.
    --
    -- _listLines answers the LAYOUT table. The only thing the budget is
    -- allowed to read out of it is the line array -- so show_cover is
    -- deliberately set to the value that would have mattered under the old
    -- has-cover branch and must not.
    local layout_lines = {}
    for i = 1, #heights do
        layout_lines[i] = { template = "%title", font_size = 16 }
    end
    env.self = {
        _listLines = function()
            return { show_cover = true, lines = layout_lines }
        end,
        -- The per-rebuild geometry memo, as a pass-through: what these tests
        -- pin is the arithmetic, and the caching layer is exercised by the
        -- real widget. A memo that CACHED here would also let one test's
        -- geometry leak into the next.
        _listGeomMemo = function(_self, _key, compute) return compute() end,
    }
    local h = compile(bodyOf("_listNaturalRowHeight"), env,
                      "_listNaturalRowHeight")()
    return h, asked, layout_lines
end

t.test("the budget is the chip's height", function()
    -- The ruling: a row measures like a chip. 90 is not derivable from the
    -- font sentinels, so the only way to land on it is to have asked
    -- ListRow.chipRowHeight().
    local h = rowHeight{ chip_h = 90, font_h = 41, ring = 7 }
    assert(h == 90, "expected the chip height 90, got " .. tostring(h))
end)

t.test("the chip's height drives the budget, one to one", function()
    local a = rowHeight{ chip_h = 60, font_h = 20, ring = 2 }
    local b = rowHeight{ chip_h = 90, font_h = 20, ring = 2 }
    assert(b - a == 30, string.format(
        "the chip height is not reaching the budget: %d vs %d", a, b))
end)

t.test("a line taller than the chip still gets its row", function()
    -- The text's veto. Without it a font that renders taller than the chip
    -- strip -- which is what a 600x800 Kindle actually does -- clips its own
    -- descenders in every row.
    local h = rowHeight{ chip_h = 30, font_h = 41, ring = 7 }
    assert(h == 41 + 2 * 7, "expected 55, got " .. tostring(h))
end)

t.test("the ring comes from ListRow, not from SpineWidget's cover ring", function()
    -- SELECTED_BORDER is 7px on a PW5 and would spend 14 of a ~50px row on a
    -- band that is page-white unless the row is selected. With the text term
    -- binding, changing the ring must change the budget.
    local a = rowHeight{ chip_h = 0, font_h = 41, ring = 2 }
    local b = rowHeight{ chip_h = 0, font_h = 41, ring = 7 }
    assert(b - a == 2 * (7 - 2), string.format(
        "the ring is not reaching the budget: %d vs %d", a, b))
end)

t.test("the cover no longer changes the row height", function()
    -- The inversion, pinned shut. It used to be that _listRowHeight asked
    -- whether a cover was present and floored the answer at 42dp when it was
    -- not, so turning the Cover column OFF made rows TALLER (84px/16 rows on a
    -- PW5 against 49px/27 with covers on). The cover is a boolean now and the
    -- budget must be blind to it.
    local on  = rowHeight{ chip_h = 50, font_h = 45, ring = 2, show_cover = true }
    local off = rowHeight{ chip_h = 50, font_h = 45, ring = 2, show_cover = false }
    assert(on == 50 and off == 50, string.format(
        "expected the chip height 50 either way, got %d / %d", on, off))
end)

t.test("a second line buys the budget a second line", function()
    -- The budget and the render have to agree about how tall an item is, and
    -- with a variable number of text lines that is no longer a constant. Each
    -- line below the first costs its own box, less the padding that box carries
    -- twice over between the lines, plus the declared leading -- the same
    -- expression ListGeom.rowHeight uses, reached through the widget's own read
    -- of the line layout.
    local one = rowHeight{ chip_h = 50, font_h = 34, ring = 2,
                           text_pad = 4, lead = 2 }
    local two = rowHeight{ chip_h = 50, font_h = 34, ring = 2,
                           line2_h = 30, text_pad = 4, lead = 2 }
    assert(one == 50, "one line should still be the chip band, got " .. one)
    -- 50 + (30 - 8 + 2)
    assert(two == 74, string.format(
        "two lines should be the band plus the second line's cost (74), got %d",
        two))
end)

t.test("the line COUNT is not two -- three lines cost three lines", function()
    -- The whole point of the model change: nothing in the budget may assume a
    -- second line is the last one.
    local two = rowHeight{ chip_h = 0, ring = 0, text_pad = 0, lead = 0,
                           line_heights = { 40, 20 } }
    local three = rowHeight{ chip_h = 0, ring = 0, text_pad = 0, lead = 0,
                             line_heights = { 40, 20, 20 } }
    assert(two == 60, "expected 40 + 20, got " .. two)
    assert(three == 80, "expected 40 + 20 + 20, got " .. three)
    -- The leading is paid per GAP, so three lines pay it twice.
    local led = rowHeight{ chip_h = 0, ring = 0, text_pad = 0, lead = 5,
                           line_heights = { 40, 20, 20 } }
    assert(led - three == 10, string.format(
        "three lines should pay two leadings, got %d", led - three))
end)

t.test("each line is measured at its OWN height", function()
    -- If the budget spent the first line's height for every line, a row would
    -- reserve more height than the render uses and every item would carry the
    -- difference as dead space.
    local h = rowHeight{ chip_h = 0, font_h = 40, ring = 0,
                         line2_h = 20, text_pad = 0, lead = 0 }
    assert(h == 60, string.format(
        "expected 40 + 20 with each line at its own height, got %d", h))
    -- And the trim and the leading both reach the budget, or the renderer's
    -- bands and the reserved height drift apart by exactly the difference.
    local trimmed = rowHeight{ chip_h = 0, font_h = 40, ring = 0,
                               line2_h = 20, text_pad = 3, lead = 0 }
    assert(h - trimmed == 6, string.format(
        "the padding trim is not reaching the budget: %d vs %d", h, trimmed))
    local led = rowHeight{ chip_h = 0, font_h = 40, ring = 0,
                           line2_h = 20, text_pad = 0, lead = 5 }
    assert(led - h == 5, string.format(
        "the leading is not reaching the budget: %d vs %d", h, led))
end)

t.test("the widget asks ListRow once, for the layout's own lines", function()
    -- _listRowHeight is called from _maxRows, _maxShelfRows, _baseShelves and
    -- _rebuild on every rebuild; a font probe per call is exactly the kind of
    -- per-render cost this plugin has had to fix before, which is why the
    -- resolution and the measurement (and their memo) are ListRow.lineHeights
    -- and not a TextWidget here. The lines have to come from the layout so the
    -- budget measures the sizes the row renders at -- which move with
    -- list_font_scale and with what the user put in each line.
    local _h, asked, layout_lines =
        rowHeight{ chip_h = 50, font_h = 41, ring = 2 }
    assert(#asked == 1, "expected exactly one lineHeights call, got " .. #asked)
    assert(asked[1] == layout_lines,
        "the budget measured something other than the layout's own lines")

    local _h2, asked2, layout2 =
        rowHeight{ chip_h = 50, font_h = 41, ring = 2, line2_h = 30 }
    assert(#asked2 == 1 and #asked2[1] == 2 and asked2[1] == layout2,
        "two lines must still be one call, over both of them")
end)

-- ── The vertical band: the hero across a flip, and the symmetric margin ────
--
-- Two maintainer rulings, both of them about numbers this file can reach:
--   1. "when switching to list mode on the collapsed shelf, the hero size
--      should be larger, ideally staying the exact same size before/after the
--      list mode switch."
--   2. "There should always be at least the same gap at the bottom of the list
--      above the footer icons, as there is at the top of the list between the
--      chip bar and the first row ... this will often mean losing a row,
--      that's fine."
--
-- bodyOf above only matches a method with an empty parameter list. These three
-- take arguments, so the body is wrapped back into a function with its real
-- signature and `self` becomes an explicit first parameter rather than a
-- global.
local function methodOf(name, env)
    local params, body = src:match("\nfunction BookshelfWidget:" .. name
        .. "%((.-)%)\n(.-)\nend\n")
    assert(body, "could not find BookshelfWidget:" .. name .. "(...) - renamed?")
    local wrapped = "return function(self, " .. params .. ")\n" .. body .. "\nend"
    return compile(wrapped, env, name)()
end

-- A Paperwhite 5 at 200dpi, measured off a real offscreen render rather than
-- invented: PAD 37, chip band 50, footer reservation 88, list row 52, hairline
-- gap 1, and the cover grid's own collapsed hero at 477.
--
-- row_h_two is the same panel with a populated row 2, also measured: 87, i.e.
-- the 52 plus the second line's 41px box less the 8px of TextWidget padding
-- that box carries twice over between the lines, plus 2px of leading.
local PW5 = {
    name = "PW5 1248x1648@200",
    height = 1648, PAD = 37, content_w = 1174, chip_h = 50, pad_large = 17,
    footer = 88, row_h = 61, row_gap = 1, cover_hero = 453, strip = 41,
    row_h_two = 96,
    -- The row counts this panel renders, collapsed and expanded, at each item
    -- height, in the configuration the rest of this record was measured in
    -- (which is what fixes cover_hero -- a different hero_size renders a
    -- taller collapsed hero and correspondingly fewer rows). Pinned so a
    -- change to the margins that GAINS or LOSES a row has to say so here
    -- rather than arriving as a side effect.
    rows1 = 15, rows2 = 9, rows1_exp = 22, rows2_exp = 14,
}

-- The other three calibrated geometries, measured the same way and in the same
-- run (`shots/margin_sweep.sh`, 28-leading.lua's `prim` and `plan` lines): the
-- 1088x1448 Paperwhite 3, the 600x800 Kindle basic at dpi 167, and a stock
-- 1248x1648 with NO screen_dpi override, which is what an out-of-the-box Kindle
-- does and which scales everything larger.
--
-- pad_large is Size.padding.large at that geometry -- the hero->chips span in
-- EXPANDED mode -- and it is per-panel because Size scales by screen size. It
-- used to be stubbed at a flat 24 for every case, which made the expanded band
-- off by up to 7px on three of the four panels.
--
-- RE-MEASURED (`shots/margin/msweep4.sh 2-rowcount.lua`) when min_edge_pad was
-- introduced, and the sweep found TWO changes, not one. Keeping them apart
-- matters, because a stale fixture that happens to agree with the model is not
-- evidence of anything:
--
--   * cover_hero had gone stale on all four panels -- 477 -> 453, 411 -> 393,
--     195 -> 183, 438 -> 414 -- so the fixture was budgeting against a
--     collapsed hero the tree stopped rendering some commits ago. That alone
--     accounts for PW5 rows1 14 -> 15, PW3 rows2 8 -> 9 and KBASIC rows2
--     6 -> 7: those cases gain their row with the OLD reservation too, once
--     the hero is right.
--   * min_edge_pad's leeway moves exactly ONE of the sixteen cases: PW3
--     collapsed one-line, 13 -> 14. Which is the intended shape -- it claws
--     back a row that was a few pixels short and leaves the rest alone.
local PW3 = {
    name = "PW3 1088x1448@200",
    height = 1448, PAD = 32, content_w = 1024, chip_h = 46, pad_large = 16,
    footer = 83, row_h = 59, row_gap = 1, cover_hero = 393, strip = 38,
    row_h_two = 91,
    rows1 = 14, rows2 = 9, rows1_exp = 20, rows2_exp = 13,
}
local KBASIC = {
    name = "Kindle 600x800@167",
    height = 800, PAD = 18, content_w = 564, chip_h = 31, pad_large = 11,
    footer = 56, row_h = 44, row_gap = 1, cover_hero = 183, strip = 27,
    row_h_two = 67,
    rows1 = 10, rows2 = 7, rows1_exp = 14, rows2_exp = 9,
}
local STOCK = {
    name = "1248x1648 stock (no screen_dpi)",
    height = 1648, PAD = 37, content_w = 1174, chip_h = 63, pad_large = 21,
    footer = 110, row_h = 79, row_gap = 2, cover_hero = 414, strip = 51,
    row_h_two = 123,
    rows1 = 11, rows2 = 7, rows1_exp = 16, rows2_exp = 10,
}

local BASELINES = { PW5, PW3, KBASIC, STOCK }

-- The four (expanded, hide_chips) combinations, as a list, so no test can
-- quietly cover one of them and call it the configuration.
local COMBOS = { { false, false }, { true, false },
                 { false, true },  { true, true } }

-- The plan now leans on _listBand for the band and its three pads, and on
-- _listRows for the reader's row count. Both are supplied here so the
-- extracted body runs -- and _listBand is driven from ITS OWN source rather
-- than faked, or the split between the two would be untested and a pad could
-- drift from one to the other unseen.
--
-- `rows_setting` is what the reader chose; nil means "never touched it", which
-- is the default that has to reproduce the old layout exactly.
local function bandOf(o, expanded, hide_chips)
    local env = {
        Size = { padding = { large = o.pad_large or 24 } },
        math = math,
        _footerReserveH = function() return o.footer end,
    }
    local self = {
        height = o.height,
        _layoutPrimitives = function() return o.PAD, o.content_w, o.chip_h end,
        _statusStripHeight = function() return o.strip end,
        _listCollapsedHeroHeight = function() return o.cover_hero end,
    }
    return methodOf("_listBandUncached", env)(self, expanded, hide_chips)
end

local function bandPlan(o, expanded, hide_chips, rows_setting)
    o = o or PW5
    local env = {
        require = function(name)
            assert(name == "lib/bookshelf_list_geom",
                "the plan must take its row arithmetic from ListGeom, not " .. name)
            return ListGeom
        end,
        Size = { padding = { large = o.pad_large or 24 } },
        math = math, string = string, tostring = tostring,
        logger = { dbg = function() end },
        _footerReserveH = function() return o.footer end,
    }
    local self = {
        height = o.height,
        _layoutPrimitives = function() return o.PAD, o.content_w, o.chip_h end,
        _statusStripHeight = function() return o.strip end,
        _listCollapsedHeroHeight = function() return o.cover_hero end,
        _listBand = function(_s, e, h) return bandOf(o, e, h) end,
        _listRowHeight = function() return o.row_h end,
        _listRowGap    = function() return o.row_gap end,
        _listRows      = function(_s, max_rows)
            if not rows_setting then return nil end
            return math.max(1, math.min(rows_setting, max_rows or rows_setting))
        end,
    }
    return methodOf("_listBandPlanUncached", env)(self, expanded, hide_chips)
end

t.test("the plan accounts for every pixel of the band", function()
    local p = bandPlan(nil, false, false)
    local block = p.rows * p.row_h + (p.rows - 1) * p.row_gap
    assert(p.top_gap + block + p.bottom_gap == p.band, string.format(
        "top %d + rows %d + bottom %d != band %d",
        p.top_gap, block, p.bottom_gap, p.band))
    -- THE INVARIANT THAT MATTERS: what _rebuild ends up emitting above row 1
    -- equals what the plan intends. It emits the span already in the tree
    -- (layout_top_pad) plus the correction, so those two have to land on
    -- top_gap.
    --
    -- This used to be written as `top_extra == top_gap - base_top_pad`, which
    -- is the plan checked against ITSELF: it holds for any value of
    -- base_top_pad, including one the layout knows nothing about. Halving
    -- base_top_pad alone therefore passed this test while changing nothing on
    -- screen and leaving the budget half a PAD adrift from the layout.
    assert(p.layout_top_pad + p.top_extra == p.top_gap, string.format(
        "the layout emits %d + %d = %d above row 1, but the plan wants %d",
        p.layout_top_pad, p.top_extra, p.layout_top_pad + p.top_extra,
        p.top_gap))
end)

-- A copy of a baseline with one field changed, so a case can vary the row
-- height without the others drifting.
local function withRowH(row_h, base)
    local o = {}
    for k, v in pairs(base or PW5) do o[k] = v end
    o.row_h = row_h
    return o
end

t.test("the top gap is the standard padding, on every baseline", function()
    -- The maintainer's ruling: "keep the top padding the standard amount".
    -- base_top_pad IS that amount -- the span the layout already carries above
    -- row 1, which with the chip strip up is the same PAD the cover grid
    -- spends between the chips and its first shelf row -- so the assertion is
    -- that the plan asks for exactly it and adds nothing.
    --
    -- top_extra == 0 is the same statement from _rebuild's side: the span
    -- above row 1 is left at the width the layout already gave it. This is the
    -- property that was broken. The top gap used to be floor(slack / 2), and
    -- slack carries a MODULAR REMAINDER whose scale is the row height, so the
    -- pad came out at 40 to 87px against an intended 18 to 37 depending on the
    -- panel, the mode and how tall an item happened to be.
    --
    -- BOTH ITEM HEIGHTS on every panel. The maintainer's report was against
    -- two-row items, but the one-row list had the identical defect and is
    -- fixed by the same line -- so a one-row-only check would miss half of
    -- what changed, and a two-row-only check would miss the case every
    -- configured user is currently looking at.
    for _b, dev in ipairs(BASELINES) do
    for _h, row_h in ipairs({ dev.row_h, dev.row_h_two }) do
    for _i, case in ipairs(COMBOS) do
        local p = bandPlan(withRowH(row_h, dev), case[1], case[2])
        -- UNLESS THE LEEWAY BOUGHT A ROW. min_edge_pad lets the count take a
        -- row that only fits if both margins shrink, and then the top gap is
        -- half the slack rather than the standard pad -- see min_edge_pad in
        -- _listBandPlan for why that trade is the one being made. What the
        -- ruling still forbids, and what this test exists for, is the top gap
        -- coming out BIGGER than the standard pad, which is the modular
        -- remainder returning; that is asserted unconditionally below.
        local bought_a_row = p.top_gap + p.bottom_gap < 2 * p.base_top_pad
        if not bought_a_row then
            assert(p.top_gap == p.base_top_pad, string.format(
                "%s row_h=%d expanded=%s hide_chips=%s: top gap %d, "
                .. "wanted pad %d", dev.name, row_h, tostring(case[1]),
                tostring(case[2]), p.top_gap, p.base_top_pad))
        else
            assert(p.top_gap == math.floor(
                       (p.top_gap + p.bottom_gap) / 2), string.format(
                "%s row_h=%d expanded=%s hide_chips=%s: a bought row should "
                .. "split the slack evenly, top %d bottom %d",
                dev.name, row_h, tostring(case[1]), tostring(case[2]),
                p.top_gap, p.bottom_gap))
            assert(p.top_gap >= p.min_edge_pad
                   or p.rows * p.row_h + (p.rows - 1) * p.row_gap > p.band
                       - 2 * p.min_edge_pad, string.format(
                "%s row_h=%d: top gap %d is below the floor %d without being "
                .. "a starved band", dev.name, row_h, p.top_gap,
                p.min_edge_pad))
        end
        assert(p.top_gap <= p.base_top_pad, string.format(
            "%s row_h=%d expanded=%s hide_chips=%s: top gap %d is BIGGER "
            .. "than the standard pad %d -- the remainder is back",
            dev.name, row_h, tostring(case[1]), tostring(case[2]),
            p.top_gap, p.base_top_pad))
        -- HALF the span the layout carries, which is the whole point of the
        -- change. Asserted against layout_top_pad rather than against
        -- top_extra being some particular number, so it says what a reader
        -- would see rather than how the code gets there.
        assert(p.base_top_pad == math.floor(p.layout_top_pad / 2), string.format(
            "%s row_h=%d expanded=%s hide_chips=%s: wanted pad %d is not half "
            .. "the layout's %d",
            dev.name, row_h, tostring(case[1]), tostring(case[2]),
            p.base_top_pad, p.layout_top_pad))
        assert(p.layout_top_pad + p.top_extra == p.top_gap, string.format(
            "%s row_h=%d expanded=%s hide_chips=%s: the layout would emit "
            .. "%d above row 1, but the plan wants %d",
            dev.name, row_h, tostring(case[1]), tostring(case[2]),
            p.layout_top_pad + p.top_extra, p.top_gap))
    end
    end
    end
end)

t.test("the gap below the last row is AT LEAST the gap above the first",
function()
    -- Ruling 2, re-pointed to what it actually says: "There should always be
    -- AT LEAST the same gap at the bottom of the list above the footer icons,
    -- as there is at the top". A minimum, not an equality -- an earlier
    -- revision of this file pinned the two within a pixel of each other, which
    -- is a stronger claim than was ever asked for and is what forced the top
    -- margin to be a remainder.
    --
    -- The bottom gap is now simply what the rows did not use, and it is
    -- SUPPOSED to be larger: "leave a larger gap at the bottom if there's no
    -- room for another row". So there is no upper bound here on purpose.
    for _b, dev in ipairs(BASELINES) do
    for _h, row_h in ipairs({ dev.row_h, dev.row_h_two }) do
    for _i, case in ipairs(COMBOS) do
        local p = bandPlan(withRowH(row_h, dev), case[1], case[2])
        assert(p.bottom_gap >= p.top_gap, string.format(
            "%s row_h=%d expanded=%s hide_chips=%s: bottom gap %d is SMALLER "
            .. "than the top gap %d", dev.name, row_h, tostring(case[1]),
            tostring(case[2]), p.bottom_gap, p.top_gap))
    end
    end
    end
end)

t.test("the row count per baseline, so a gained or lost row is visible",
function()
    -- The margins and the row count come out of one budget, so a change to
    -- either can move the other. What is pinned here is ONE configuration --
    -- the collapsed hero heights in this table fix it -- not the only one.
    --
    -- ── WHAT IS MEASURED AND WHAT IS DERIVED, after the box/margin pass ────
    --
    -- Two changes moved these: the selection box's inset (which grew row_h)
    -- and halving the reserved band margin (which buys rows). Both were
    -- re-measured rather than recomputed, but not all of it could be:
    --
    --   row_h, row_h_two   MEASURED fresh, all four geometries, off a live
    --                      _listRowHeight(). Independent of the hero, so these
    --                      transfer to this table's configuration directly.
    --   rows1_exp, rows2_exp
    --                      MEASURED fresh, and they AGREE with the model --
    --                      the expanded hero is the status strip, which is the
    --                      same whatever hero_size says.
    --   rows1, rows2       DERIVED from the model for THIS table's hero
    --                      heights. The render profile available for the
    --                      re-measure has a shorter collapsed hero (453 rather
    --                      than 477 on the PW5) and so fits one more row; its
    --                      numbers are not this configuration's.
    --
    -- The derivation is trustworthy because the model was checked against the
    -- device in the same run: fed the profile's OWN measured inputs (band 983,
    -- hero 453, footer 88, row_h 61) it answers 15 rows, which is exactly what
    -- the shelf rendered. A model that reproduces the device on one hero height
    -- reproduces it on another; only the input differs.
    for _b, dev in ipairs(BASELINES) do
        local cases = {
            { dev.row_h,     false, dev.rows1 },
            { dev.row_h_two, false, dev.rows2 },
            { dev.row_h,     true,  dev.rows1_exp },
            { dev.row_h_two, true,  dev.rows2_exp },
        }
        for _i, c in ipairs(cases) do
            local p = bandPlan(withRowH(c[1], dev), c[2], false)
            assert(p.rows == c[3], string.format(
                "%s row_h=%d expanded=%s: %d rows, expected %d",
                dev.name, c[1], tostring(c[2]), p.rows, c[3]))
        end
    end
end)

t.test("the top gap is the standard pad at EVERY item height", function()
    -- The property, rather than eight configurations of it: whatever an item
    -- costs, the top of the block does not move. Swept from a row shorter than
    -- any panel produces to one taller than the whole band, so the case where
    -- a row does not fit at all is included.
    --
    -- That last case is the one exception, and it is deliberate. rowsThatFit
    -- floors at 1 -- a band too small for one row plus its margins still gets
    -- a row -- and the leftover is then less than two standard pads, so the
    -- standard pad is not affordable at both ends. There the plan falls back
    -- to an even split with the odd pixel at the bottom, which is the only
    -- rule that still keeps bottom >= top when neither end can have what it
    -- wants. What must NEVER happen is the top taking MORE than the standard
    -- pad, which is the defect this test exists for.
    local starved_seen = false
    for _b, dev in ipairs(BASELINES) do
        for row_h = 20, 1000, 7 do
            for _i, case in ipairs(COMBOS) do
                local p = bandPlan(withRowH(row_h, dev), case[1], case[2])
                local slack = p.top_gap + p.bottom_gap
                local starved = slack < 2 * p.base_top_pad
                if starved then
                    starved_seen = true
                    assert(p.top_gap == math.floor(slack / 2), string.format(
                        "%s row_h=%d: starved band should split evenly, "
                        .. "top %d of %d", dev.name, row_h, p.top_gap, slack))
                else
                    assert(p.top_gap == p.base_top_pad, string.format(
                        "%s row_h=%d expanded=%s hide_chips=%s: top gap %d, "
                        .. "standard pad %d", dev.name, row_h,
                        tostring(case[1]), tostring(case[2]),
                        p.top_gap, p.base_top_pad))
                end
                assert(p.top_gap <= p.base_top_pad, string.format(
                    "%s row_h=%d: the top gap %d is BIGGER than the standard "
                    .. "pad %d -- the remainder is back",
                    dev.name, row_h, p.top_gap, p.base_top_pad))
                assert(p.bottom_gap >= p.top_gap, string.format(
                    "%s row_h=%d expanded=%s hide_chips=%s: top %d bottom %d",
                    dev.name, row_h, tostring(case[1]), tostring(case[2]),
                    p.top_gap, p.bottom_gap))
                -- And the plan still accounts for the whole band, so _rebuild's
                -- slack absorber lands on bottom_gap rather than overflowing the
                -- last row under the footer.
                local block = p.rows * p.row_h + (p.rows - 1) * p.row_gap
                assert(p.top_gap + block + p.bottom_gap == p.band
                       or p.band < block, string.format(
                    "%s row_h=%d: %d + %d + %d != band %d",
                    dev.name, row_h, p.top_gap, block, p.bottom_gap, p.band))
            end
        end
    end
    assert(starved_seen,
        "the sweep never reached a band too tight for both margins, so the "
        .. "case this test exists for was not exercised")
end)

t.test("top_extra is signed, so the layout's span can shrink", function()
    -- The mechanism behind the fix above. _rebuild reaches the top gap by
    -- adding top_extra to a span that is ALREADY layout_top_pad wide, so while
    -- top_extra was max(0, ...) the plan could not ask for a smaller top gap
    -- however little room there was -- which is why the split had to clamp,
    -- and why the bottom paid for it.
    --
    -- It is also the whole mechanism behind the HALVED margin: the plan wants
    -- less than the layout carries, so top_extra is negative in the ordinary
    -- case now, not only in the starved one.
    -- Taller than any band on any device, so the starved branch is reached
    -- whatever the margins are. It used to be 900, which starved a band when
    -- the reserved pad was a full PAD and stopped starving it the moment the
    -- pad was halved -- a test that quietly stops exercising its own case is
    -- worse than one that fails.
    local p = bandPlan(withRowH(4000), false, false)
    assert(p.top_gap < p.base_top_pad, string.format(
        "expected a starved band for this case; top gap %d, base pad %d",
        p.top_gap, p.base_top_pad))
    assert(p.top_extra == p.top_gap - p.layout_top_pad and p.top_extra < 0,
        string.format("top_extra %d must be the signed difference from the "
            .. "layout's own span (%d)",
            p.top_extra, p.top_gap - p.layout_top_pad))
    -- And what the layout actually lays down is the plan's top gap, in both
    -- branches: layout_top_pad + top_extra, never a floored version of it.
    -- Measured against the span the TREE carries, not against what the plan
    -- wanted -- comparing the plan with itself is what let a half-PAD
    -- discrepancy between budget and layout pass unnoticed.
    assert(p.layout_top_pad + p.top_extra == p.top_gap,
        "layout_top_pad + top_extra must be exactly top_gap")
end)

t.test("the margin is paid for out of the row count", function()
    -- "this will often mean losing a row, that's fine." One more row must not
    -- fit: the count is maximal against the reservation the plan actually
    -- makes, not merely conservative.
    --
    -- Against min_edge_pad, not base_top_pad. That is the whole of the later
    -- leeway ruling -- "add a bit more leeway for the last row to be filled" --
    -- and the difference between the two is the leeway, in pixels.
    local p = bandPlan(nil, false, false)
    local one_more = (p.rows + 1) * p.row_h + p.rows * p.row_gap
    assert(one_more > p.band - 2 * p.min_edge_pad, string.format(
        "%d rows would still have fitted inside the reserved minimum",
        p.rows + 1))
    -- The floor is a real reservation and not a rounding artefact: a count
    -- that ignored the margins entirely would take strictly more rows on some
    -- band, so sweep for one rather than asserting it of this configuration.
    -- (Pinning it here instead broke the moment the leeway landed, because on
    -- THIS panel the greedy count and the reserved one now agree.)
    local floor_bites = false
    for row_h = 20, 400 do
        local q = bandPlan(withRowH(row_h), false, false)
        local greedy = ListGeom.rowsThatFit(q.band, q.row_h, q.row_gap)
        assert(q.rows <= greedy, string.format(
            "row_h=%d: the plan took %d rows, more than fit in the whole "
            .. "band (%d)", row_h, q.rows, greedy))
        if q.rows < greedy then floor_bites = true end
    end
    assert(floor_bites,
        "min_edge_pad never cost a row anywhere in the sweep, so nothing is "
        .. "being reserved at either end")
end)

t.test("the leftover below the last row cannot hold another row", function()
    -- THE UNDER-FILL INVARIANT, and the reason this file gets a second
    -- maximality test: the one above pins a single configuration of a single
    -- baseline. What has to hold everywhere is that whatever is left below the
    -- last row BEYOND the pad reserved there is smaller than one row pitch --
    -- i.e. the count is maximal against the reservation, and the band cannot
    -- be under-filled by a whole row while the budget claims it is full.
    --
    -- Stated as the SURPLUS over the reserved minimum, not as the bottom gap
    -- itself. "The bottom gap is less than one pitch" is the tempting form and
    -- it is false by construction: the gap is the reservation PLUS the
    -- leftover, so it runs up to min_edge_pad + pitch - 1.
    --
    -- AGAINST min_edge_pad, which is what the count reserves. It used to be
    -- written against base_top_pad, which is what the plan WANTS, and the two
    -- were the same number until the leeway landed. Left as it was, every case
    -- where the leeway bought a row would have fallen into the skip branch
    -- below and gone unchecked -- the test would have kept passing while
    -- quietly covering less, which is the failure mode this file has already
    -- been bitten by once.
    --
    -- The starved band is excluded and only there: rowsThatFit floors at 1, so
    -- a band too small for one row plus both minimums still gets a row and the
    -- reservation is not affordable at either end. That case has its own
    -- coverage above.
    local checked, starved_seen = 0, false
    for _b, dev in ipairs(BASELINES) do
        local heights = { dev.row_h, dev.row_h_two }
        for row_h = 20, 1000, 3 do heights[#heights + 1] = row_h end
        for _h, row_h in ipairs(heights) do
            for _i, case in ipairs(COMBOS) do
                local p = bandPlan(withRowH(row_h, dev), case[1], case[2])
                local pitch   = p.row_h + p.row_gap
                local surplus = p.bottom_gap - p.min_edge_pad
                if p.top_gap + p.bottom_gap < 2 * p.min_edge_pad then
                    starved_seen = true
                else
                    checked = checked + 1
                    assert(surplus >= 0, string.format(
                        "%s row_h=%d expanded=%s hide_chips=%s: bottom gap %d "
                        .. "is under the reserved minimum %d", dev.name, row_h,
                        tostring(case[1]), tostring(case[2]),
                        p.bottom_gap, p.min_edge_pad))
                    assert(surplus < pitch, string.format(
                        "%s row_h=%d expanded=%s hide_chips=%s: %d px left "
                        .. "below the last row beyond the %d px reserved "
                        .. "there, and a row is only %d -- the band is "
                        .. "under-filled by a whole row", dev.name, row_h,
                        tostring(case[1]), tostring(case[2]), surplus,
                        p.min_edge_pad, pitch))
                end
            end
        end
    end
    assert(checked > 0, "the sweep never ran")
    assert(starved_seen,
        "the sweep never reached a starved band, so the branch this test "
        .. "excludes was not exercised and the exclusion is untested")
end)

t.test("the collapsed list hero is the cover grid's, to the pixel", function()
    -- Ruling 1, and the whole of it: not "bigger", the SAME NUMBER. The plan
    -- must take the hero from _listCollapsedHeroHeight (which asks the cover
    -- grid) and must not derive one of its own from a fraction of the screen.
    local p = bandPlan(nil, false, false)
    assert(p.hero_h == PW5.cover_hero, string.format(
        "collapsed list hero %d, cover grid hero %d", p.hero_h, PW5.cover_hero))
    -- Expanded is a status strip in both modes and is unaffected.
    local e = bandPlan(nil, true, false)
    assert(e.hero_h == PW5.strip, string.format(
        "expanded list hero %d, status strip %d", e.hero_h, PW5.strip))
end)

t.test("the hero height is untouched by the margins, on every baseline",
function()
    -- "Do not change the hero height." The margin surplus is the hero's
    -- neighbour in the band -- the obvious place to put it, and explicitly
    -- ruled out, because the collapsed list hero is the cover grid's hero to
    -- the pixel and spending slack on it would break the mode flip.
    --
    -- Two claims, and they are different sizes:
    --
    --  * the numbers. cover_hero and strip per baseline are what the four
    --    geometries RENDER; they were read off the live widget before this
    --    margin change and again after, and were identical. Pinned here as
    --    data so a future revision that moves them has to edit this table.
    --  * the wiring, which is what the assertion proves: the plan returns the
    --    hero it was HANDED, unmodified, at every row height and in every
    --    configuration -- so no amount of slack, from any item height, can
    --    reach it. This is the part a unit test can establish; the numbers
    --    themselves come from the renders.
    for _b, dev in ipairs(BASELINES) do
        for _i, case in ipairs(COMBOS) do
            local want = case[1] and dev.strip or dev.cover_hero
            local seen
            for row_h = 20, 1000, 13 do
                local p = bandPlan(withRowH(row_h, dev), case[1], case[2])
                assert(p.hero_h == want, string.format(
                    "%s row_h=%d expanded=%s hide_chips=%s: hero %d, expected "
                    .. "%d", dev.name, row_h, tostring(case[1]),
                    tostring(case[2]), p.hero_h, want))
                seen = p.hero_h
            end
            assert(seen == want, dev.name .. ": the sweep never ran")
        end
    end
end)

t.test("a shorter row buys rows, never a smaller hero", function()
    -- The bug, stated as arithmetic. The old model filled the screen with rows
    -- and left the hero its HERO_MIN_FRAC floor, so halving the row height
    -- doubled the row count AND shrank the hero. The hero is now decided
    -- before the first row is counted, so it cannot move.
    local tall = bandPlan(nil, false, false)
    local o = {}
    for k, v in pairs(PW5) do o[k] = v end
    o.row_h = 26
    local short = bandPlan(o, false, false)
    assert(short.rows > tall.rows, "a shorter row should buy more rows")
    assert(short.hero_h == tall.hero_h, string.format(
        "the hero moved with the row height: %d vs %d",
        short.hero_h, tall.hero_h))
end)

-- _listCollapsedHeroHeight and _collapsedGridSplit, run against each other.
-- The point of the pair is that there is exactly ONE derivation: the list
-- hero is not "the same formula written twice", it is the cover grid's own
-- answer, fetched.
local function heroPair(o)
    o = o or {}
    local height     = o.height or 1648
    local PAD        = o.PAD or 37
    local content_w  = o.content_w or 1174
    local chip_h     = o.chip_h or 50
    local footer     = o.footer or 88
    local n_shelves  = o.n_shelves or 2
    local n_cols     = o.n_cols or 4
    local aspect     = o.aspect or 1.5
    local row_h      = o.row_h or 52
    local pinned     = 0
    local env = {
        math = math,
        type = type,
        Size = { padding = { default = 12, large = 24 } },
        HERO_MIN_FRAC = 0.20,
        SHELF_PACK_FLOOR = 1.0,
        BookshelfSettings = { read = function() return nil end },
        _footerReserveH = function() return footer end,
    }
    local self = {
        height = height,
        _layoutPrimitives = function() return PAD, content_w, chip_h end,
        _baseShelves   = function() return n_shelves end,
        _gridCols      = function() return n_cols end,
        _bookGap       = function(_s, pad) return pad end,
        _coverAspect   = function() return aspect end,
        _shelfLabelMode = function() return nil end,
        _listMinRowHeight = function() return row_h end,
    }
    local split = methodOf("_collapsedGridSplit", env)
    self._collapsedGridSplit = function(s, hide) return split(s, hide) end
    -- The real _asCoverGrid pins the view mode and calls through; nothing in
    -- this environment reads the mode, so counting the calls is what is worth
    -- asserting -- the hero MUST be fetched under the pin, or _baseShelves
    -- would answer with a list row count.
    env._asCoverGrid = function(fn) pinned = pinned + 1 return fn() end
    local hero = methodOf("_listCollapsedHeroHeight", env)(self, false)
    local _shelf_h, grid_hero = split(self, false)
    return hero, grid_hero, pinned
end

t.test("the list hero is fetched from the grid, under the covers pin", function()
    local hero, grid_hero, pinned = heroPair()
    assert(pinned == 1, "the hero must be read with the view mode pinned to "
        .. "covers; _asCoverGrid was called " .. pinned .. " times")
    assert(hero == grid_hero, string.format(
        "list hero %d, cover grid hero %d -- the flip is not size-preserving",
        hero, grid_hero))
end)

t.test("the flip is size-preserving across row counts and screens", function()
    for _i, o in ipairs({
        { n_shelves = 1 }, { n_shelves = 2 }, { n_shelves = 3 },
        { n_shelves = 4, n_cols = 5 },
        { height = 800, PAD = 18, content_w = 564, chip_h = 33,
          footer = 44, n_shelves = 2, n_cols = 4, row_h = 34 },
        { height = 1248, PAD = 37, content_w = 1574, chip_h = 50,
          footer = 88, n_shelves = 1, n_cols = 6, row_h = 52 },
    }) do
        local hero, grid_hero = heroPair(o)
        assert(hero == grid_hero, string.format(
            "rows=%s cols=%s h=%s: list hero %d against grid hero %d",
            tostring(o.n_shelves), tostring(o.n_cols), tostring(o.height),
            hero, grid_hero))
    end
end)

t.test("the hero is capped so at least one row survives", function()
    -- A cover hero is sized against cover ROWS, and a list row is a different
    -- height entirely. Solving hero > cap gives row_h + PAD > n*(PAD + shelf_h)
    -- -- i.e. the cap can only bite where a list row is taller than a cover
    -- shelf row, which is a short screen at a large list_font_scale with small
    -- covers. There the hero must give way to leave exactly one row and its
    -- two margins, rather than clipping the row under the footer.
    local hero, grid_hero = heroPair{
        height = 700, PAD = 37, content_w = 1174, chip_h = 50, footer = 88,
        n_shelves = 1, n_cols = 8, row_h = 200,
    }
    assert(hero < grid_hero, "expected the cap to bite on a 700px screen")
    local room = 700 - 37 - 88 - 50 - 37
    assert(hero == room - 2 * 37 - 200, string.format(
        "capped hero %d, expected %d", hero, room - 2 * 37 - 200))
end)

-- ── Source shape: the row widget's own declarations ────────────────────────

-- bookshelf_list_row.lua cannot be loaded under a plain interpreter (it pulls
-- in the whole KOReader widget stack), so these are SOURCE-SHAPE checks, not
-- behavioural ones -- named as such rather than dressed up. They exist because
-- each of these decisions has exactly one call site and no other test in the
-- suite can reach it: remove any of them and everything stays green while the
-- render moves.
--
-- Comment lines are dropped first: that file explains at length which Size.*
-- values the dp declarations scale to, and matching the prose would make the
-- check fire on its own documentation.
local row_src
do
    local code = {}
    for line in io.lines("lib/bookshelf_list_row.lua") do
        if not line:match("^%s*%-%-") then code[#code + 1] = line end
    end
    row_src = table.concat(code, "\n")
end

t.test("the per-row band share is ListGeom's arithmetic, not the row's",
function()
    -- tests/_test_list_geom.lua proves shareBands conserves the row's height.
    -- It cannot prove the row ASKS for it, and a renderer that grew its own
    -- opinion about how a row's height is divided is exactly the drift this
    -- file exists to catch -- the same gap that let the row gap accessor and
    -- the pure test disagree about scaleBySize(0.5) while everything stayed
    -- green.
    assert(row_src:match("ListGeom%.fillRow"),
        "packRow must allocate the row's height through ListGeom.fillRow")
    assert(not row_src:match("ListGeom%.shareBands"),
        "the old proportional allocator is gone; two of them in the tree is "
        .. "how the budget and the render come to disagree")
    -- Both halves of the remainder reach the widget tree. Dropping either one
    -- loses pixels: extra_lead is what keeps the bottom line on the bottom
    -- edge, extra_bottom is what keeps the text column measuring content_h so
    -- the HorizontalGroup does not centre a short column against the cover.
    assert(row_src:match("packed%.extra_lead"),
        "the row must emit the remainder above its last line")
    assert(row_src:match("packed%.extra_bottom"),
        "the row must emit the remainder below its lines when the bottom "
        .. "line had nothing to say")
end)

t.test("the shared line tables are never written to per row", function()
    -- pageLayout builds ONE table per line for the whole page and hands the
    -- same table to every row on it. The band and the text vary per row, so
    -- the tempting fix is to patch the line before rendering it -- and that
    -- would leak row N's band into row N+1. They travel as a separate
    -- argument instead, which is what the opts table in textLine is for.
    assert(not row_src:match("line%.band_h%s*="),
        "a per-row band must never be written into the page's line table")
    assert(row_src:match("opts%.band_h"),
        "textLine must take the band from its caller, so packRow's per-row "
        .. "figure is what the box is built at")
    assert(row_src:match("opts%.text"),
        "textLine must take the caller's expansion rather than repeating it")
end)

t.test("the row widget reads the ring and gap declarations", function()
    assert(row_src:match("ListGeom%.ROW_RING_DP"),
        "the row must scale ListGeom.ROW_RING_DP for its selection ring")
    assert(row_src:match("ListGeom%.ROW_GAP_DP"),
        "the row must scale ListGeom.ROW_GAP_DP for its divider")
    assert(not row_src:match("SpineWidget%.SELECTED_BORDER"),
        "the row must not reserve the cover grid's 7px ring")
    assert(not row_src:match("Size%.line%.thin"),
        "the divider height must come from ROW_GAP_DP, not a second copy")
end)

t.test("the row divider is a byte an e-ink panel can actually show", function()
    -- The byte, pinned. 0.13 shipped here first and came back off the device
    -- as "a bit feint" in BOTH modes: it paints 222, an e-ink panel renders
    -- 16 levels one every 17 bytes, so 222 quantises to 0xDD -- one step off
    -- paper out of fifteen, on a rule one pixel tall. Nothing about that is
    -- visible in a desktop render, which is why it has to be asserted as a
    -- number here rather than eyeballed.
    local frac = row_src:match("DIVIDER_INK%s*=%s*([%d/%.]+)")
    assert(frac, "DIVIDER_INK must be a literal this test can read")
    local f = load("return " .. frac)()
    local painted = math.floor(255 + (0 - 255) * f + 0.5)
    assert(painted == 0x88, string.format(
        "the divider paints %d; a rule between list items is %d "
        .. "(Blitbuffer.COLOR_DARK_GRAY)", painted, 0x88))

    -- Exactly on a palette level, so a 1px rule reaches it without dithering.
    assert(painted % 0x11 == 0, string.format(
        "%d is not a multiple of 17, so it does not land on an e-ink level "
        .. "and a 1px rule has to be dithered to approximate it", painted))

    -- Where 0x88 comes from, checked rather than asserted in prose. KOReader's
    -- own Menu rules its items with it, and a table of books sits next to
    -- those lists.
    local menu = io.open("/usr/lib/koreader/frontend/ui/widget/menu.lua")
    if menu then
        local src = menu:read("*a")
        menu:close()
        assert(src:match("line_color%s*=%s*Blitbuffer%.COLOR_DARK_GRAY"),
            "KOReader's Menu no longer rules its items with COLOR_DARK_GRAY; "
            .. "re-derive DIVIDER_INK against whatever it became")
    end

    -- The ceiling, so the next round of "still a bit feint" cannot walk this
    -- into a border: the rule must stay LIGHTER than the type it separates.
    local sec = row_src:match("SECONDARY_INK%s*=%s*([%d/%.]+)")
    local sec_painted = math.floor(255 + (0 - 255) * load("return " .. sec)() + 0.5)
    assert(painted > sec_painted, string.format(
        "the divider paints %d and the muted line %d -- a rule darker than "
        .. "the text it separates has become a border", painted, sec_painted))
end)

t.test("the second line is muted the way this surface has to compute a colour",
function()
    -- Night mode in this plugin is NOT an inversion you reason about: the row
    -- paints paper and ink and lets KOReader's framebuffer inversion do the
    -- rest, so any colour in between has to be INTERPOLATED between the two
    -- colours the surface actually paints. Blitbuffer.gray()'s argument is
    -- DARKNESS, so the intuitive value paints its own opposite -- this plugin
    -- has shipped that bug on the stack borders more than once.
    assert(row_src:match("secondaryColor"),
        "the second line needs a muted colour, derived on this surface")
    assert(not row_src:match("Blitbuffer%.gray%("),
        "the row must not compute a colour with gray(); interpolate between "
        .. "ROW_BG and ROW_FG, which is what the surface paints")
    -- Both derived colours go through the one interpolation, so moving an
    -- endpoint moves both rather than one of them silently.
    local n = 0
    for _m in row_src:gmatch("inkAt%(") do n = n + 1 end
    assert(n >= 3, string.format(
        "expected the divider and the secondary text to share one "
        .. "interpolation helper; found %d references", n))

    -- The arithmetic itself, reproduced here against the same endpoints the
    -- file declares (paper 255, ink 0). It must land on COLOR_GRAY_5 (0x55),
    -- which is the plugin's declared MUTED role -- so the list's secondary
    -- line is the same grey as every other piece of secondary text, reached
    -- the way this surface has to reach it.
    local frac = row_src:match("SECONDARY_INK%s*=%s*([%d/%.]+)")
    assert(frac, "SECONDARY_INK must be a literal this test can read")
    local f = load("return " .. frac)()
    local painted = math.floor(255 + (0 - 255) * f + 0.5)
    assert(painted == 0x55, string.format(
        "the muted line paints %d; the plugin's MUTED role is %d "
        .. "(Blitbuffer.COLOR_GRAY_5)", painted, 0x55))
    -- And that role is where it is claimed to be, or the comment is fiction.
    local sm = io.open("lib/bookshelf_start_menu_modules.lua"):read("*a")
    assert(sm:match("COLOR_MUTED%s*=.-COLOR_GRAY_5"),
        "the plugin's MUTED role is no longer COLOR_GRAY_5; re-derive "
        .. "SECONDARY_INK against whatever it became")
end)

t.test("selecting a row changes only its perimeter, never its geometry",
function()
    -- The focused row is a rounded BOX, and the whole reason it is drawn as a
    -- colour change rather than as a border that appears is that
    -- FrameContainer:getSize() counts bordersize. Toggling the thickness would
    -- resize the frame and shift every row on the page each time the selection
    -- moved.
    assert(row_src:match("bordersize%s*=%s*BORDER"),
        "the row's border must be present in every state, at a constant "
        .. "thickness; only its COLOUR may depend on focus")
    assert(row_src:match("color%s*=%s*%(focused"),
        "the selection box should change colour on focus")
    -- ...unless the row's content already marks itself. A button row is a
    -- SpineWidget card that thickens its OWN border when selected, and the row
    -- drawing one too put two concentric outlines round a tapped catalogue
    -- entry. The condition has to name that, or the next reader deletes it as
    -- a redundant term.
    assert(row_src:match("focused%s+and%s+not%s+marks_itself"),
        "a row whose content draws its own selection must not draw a second")

    -- Rounded to the cover card's radius, not one of its own: two roundings on
    -- one screen read as two design languages.
    assert(row_src:match("RADIUS%s*=%s*SpineWidget%.CARD_RADIUS"),
        "the row's corner radius must be borrowed from the cover card")

    -- The inset every consumer reserves is the sum of the three bands, and it
    -- has to be ONE number: the height budget, the thumbnail sizing and the
    -- renderer all inset by ListRow.RING, and a second opinion about it is how
    -- the row and its contents come to disagree.
    assert(row_src:match("local RING%s*=%s*OUTER %+ BORDER %+ INNER"),
        "ListRow.RING must be the whole reserved band, not one part of it")
end)

t.test("a wrapping line cannot punch a hole in the row's background",
function()
    -- TextBoxWidget FILLS its own background and defaults it to white, where
    -- TextWidget does not. That is why a {xN} line showed as a white rectangle
    -- when the focused row was a tinted band. The border design does not care,
    -- but naming the row's paper here means the bug cannot come back if a fill
    -- ever returns.
    -- The RENDERING box, found by the field only it sets. There are two
    -- TextBoxWidgets in the file now -- packRow builds one to count wrapped
    -- lines and throws it away without ever painting it -- and a plain
    -- first-match grabbed the measuring one, which has no business carrying a
    -- background and made this test pass for the wrong widget.
    local box
    for b in row_src:gmatch("TextBoxWidget:new{(.-)}") do
        if b:match("height_overflow_show_ellipsis") then box = b end
    end
    assert(box, "the wrapping path no longer builds a TextBoxWidget")
    assert(box:match("bgcolor"),
        "TextBoxWidget must be given the row's background explicitly; its "
        .. "own default is opaque white")
end)

t.test("a multi-line item is trimmed of the doubled padding", function()
    -- The renderer has to trim exactly what the budget subtracted, or the
    -- bands and the reserved height disagree by 2 * text_pad per item.
    assert(row_src:match("ListRow%.TEXT_PAD%s*=%s*Size%.padding%.small"),
        "the trim must be TextWidget's own default padding, read from Size, "
        .. "not a number of our own")
    assert(row_src:match("ListGeom%.textBands"),
        "the row must lay its lines out with ListGeom.textBands, so the "
        .. "budget and the render are one expression")
    assert(row_src:match("ListGeom%.INTRA_LEAD_DP"),
        "the leading must be ListGeom's declaration, scaled here")
end)

t.test("the row widget sizes itself on the LIST key, through BandMetrics", function()
    -- The row is built to the chip strip's SHAPE on its OWN SETTING. Both
    -- halves are load-bearing and this is the only place either is visible:
    -- the shape comes from BandMetrics (so the two surfaces cannot round
    -- differently), the setting is LIST_KEY (so they can be tuned apart).
    assert(row_src:match("BandMetrics%.paintedHeight%(BandMetrics%.LIST_KEY,"),
        "the row's height must be BandMetrics.paintedHeight on the LIST key")
    -- The band takes a scale override for the same reason the line heights do:
    -- the DEFAULT row count is measured at 100 so the text size cannot move
    -- it. Without this term the line heights were pinned and the band was not,
    -- and above 120% the band overtook them and drove the row height again --
    -- which is the coupling the whole inversion exists to remove.
    assert(row_src:match("function ListRow%.chipRowHeight%(scale_pct%)"),
        "chipRowHeight must accept a stated scale, not only the reader's")
    -- A line declares its point size and BandMetrics applies the LIST scale to
    -- it. Not BandMetrics.fontSize, which is the fixed 16 the row had when
    -- every line rendered at the same size -- a line carries its own now, and
    -- the DEFAULT of that is 16, so the two agree at the default and diverge
    -- exactly where the user has said they should.
    assert(row_src:match("BandMetrics%.scaled%([%w_%.]+,%s*BandMetrics%.LIST_KEY%)"),
        "a line's point size must go through BandMetrics on the LIST key, or "
        .. "list_font_scale stops moving the type")
    -- Re-coupling, pinned shut. Until this pass the row read the chip bar's
    -- key; naming it here again -- as a literal or as CHIP_KEY -- is exactly
    -- the regression the separation exists to prevent, and nothing else in the
    -- suite would see it.
    assert(not row_src:match("chip_font_scale"),
        "the row must not read the chip bar's scale; it has its own key")
    assert(not row_src:match("BandMetrics%.CHIP_KEY"),
        "the row must not size itself on CHIP_KEY")
    -- The environment reads moved to BandMetrics with the arithmetic. Doing
    -- either one here again would be a second derivation that agrees today
    -- and drifts on the next change.
    assert(not row_src:match("Size%.item%.height_default"),
        "the band's height is BandMetrics' read, not a second one here")
    assert(not row_src:match("Size%.border%.thin"),
        "the strip border is BandMetrics' read, not a second one here")
    assert(row_src:match("ListRow%.FONT_FACE%s*=%s*ListGeom%.FONT_FACE"),
        "the row's face must be ListGeom's declaration, not a second copy")
    -- The old hardcoded pair. Either one back in this file means the row has
    -- stopped following the chip bar's shape.
    assert(not row_src:match('getFace%(%s*"cfont"'),
        "the row must not hardcode cfont; the chip bar renders infofont")
    assert(not row_src:match("ListRow%.FONT_SIZE%s*="),
        "the row's size is scale-dependent; it cannot be a constant")
end)

-- ── One declaration, not three copies ──────────────────────────────────────

-- The hazard this closes, stated: `floor(Size.item.height_default * <scale> /
-- 100 + 0.5)` used to be written out at bookshelf_widget.lua's _rebuild and
-- _layoutPrimitives AND in bookshelf_list_row.lua, with a comment at the first
-- of them asking whoever touched it to keep the copies in sync by hand. Adding
-- a second scale key made that two keys across three copies. It is now one
-- declaration taking the key as an argument.
t.test("nothing outside BandMetrics derives a band height for itself", function()
    local band_src = io.open("lib/bookshelf_band_metrics.lua"):read("*a")
    -- BandMetrics is the one file allowed to read these.
    assert(band_src:match("Size%.item%.height_default"),
        "BandMetrics must be the one place Size.item.height_default is read for a band")
    assert(band_src:match("Size%.border%.thin"),
        "BandMetrics must be the one place the strip border is read")

    -- And no other file may. Comment lines are dropped first: several files
    -- (this one included) describe the derivation in prose, and matching the
    -- documentation would make the check fire on its own explanation.
    local function codeOf(path)
        local code = {}
        for line in io.lines(path) do
            if not line:match("^%s*%-%-") then code[#code + 1] = line end
        end
        return table.concat(code, "\n")
    end
    for _i, path in ipairs({
        "lib/bookshelf_widget.lua",
        "lib/bookshelf_list_row.lua",
        "lib/bookshelf_chip_bar.lua",
        "lib/bookshelf_reviews_modal.lua",
    }) do
        local src = codeOf(path)
        assert(not src:match("Size%.item%.height_default%s*%*"), string.format(
            "%s scales Size.item.height_default itself; that derivation is "
            .. "BandMetrics.cellHeight", path))
        assert(not src:match('read%("chip_font_scale"%)'), string.format(
            "%s reads chip_font_scale directly; the key is BandMetrics.CHIP_KEY "
            .. "and the derivations that use it live there", path))
        assert(not src:match('read%("list_font_scale"%)'), string.format(
            "%s reads list_font_scale directly; the key is BandMetrics.LIST_KEY "
            .. "and the derivations that use it live there", path))
    end
end)

t.test("both widget layout sites take the chip height from BandMetrics", function()
    -- _layoutPrimitives and _rebuild have to land on the same chip_h -- one is
    -- what the layout math budgets, the other is what the strip is actually
    -- built at -- and they used to be two independent copies of the same
    -- expression. `_rebuild` is far too large to extract and run, so this is a
    -- source-shape check, named as such.
    local n = 0
    for _m in src:gmatch("BandMetrics%.cellHeight%(BandMetrics%.CHIP_KEY%)") do
        n = n + 1
    end
    assert(n == 2, string.format(
        "expected both chip-height sites (_rebuild and _layoutPrimitives) to "
        .. "call BandMetrics.cellHeight(CHIP_KEY); found %d", n))
    -- The chip strip stays on the CHIP key: this pass separated the list rows
    -- off it and must not have taken the strip with them.
    assert(not src:match("BandMetrics%.cellHeight%(BandMetrics%.LIST_KEY%)"),
        "the chip strip's height must stay on the chip bar's own key")
end)

t.test("the thumbnail stays flat", function()
    -- flat_thumb is what strips SpineWidget's rounded corners, drop shadow and
    -- the shadow's height reservation for the list's 30x45 cell. Nothing else
    -- in the suite reaches it: delete the argument and every suite stays green
    -- while the rounded, shadowed card comes back and eats the row.
    assert(row_src:match("flat_thumb%s*=%s*true"),
        "the cover cell must pass flat_thumb = true to SpineWidget")
    assert(row_src:match("bare_placeholder%s*=%s*true"),
        "the no-cover placeholder must stay bare at thumbnail size")
end)

-- ── The pinch changes the row count ────────────────────────────────────────
--
-- What used to live here: a binary search for the font scale that produced one
-- more or one fewer row, and the counterfactual pin it measured through. Both
-- are gone. The row count is a setting now, so the gesture adds one to it --
-- there is nothing to solve, and nothing left worth a search test.
--
-- "Pinch/zoom would change the number of rows but not the font size."

t.test("the pinch moves the row count and nothing else", function()
    local body = src:match("\nfunction BookshelfWidget:_nudgeListRows%(delta%)\n(.-)\nend\n")
    assert(body, "_nudgeListRows is gone or was renamed")
    body = body:gsub("%-%-[^\n]*", "")
    assert(body:match("_setChipListRows"),
        "the pinch must write the row count")
    assert(not body:match("list_font_scale"),
        "the pinch must not touch the font scale any more -- that is the "
        .. "whole point of separating them")
    -- Still consumes the gesture at the limits: falling through hands the
    -- pinch to whatever is underneath.
    assert(body:match("if new == cur then return true end"),
        "a no-op pinch must still consume the gesture")
end)

t.test("the scale-snapping machinery is gone, not merely unused", function()
    for _i, name in ipairs({ "_listScaleForRows", "_listScaleStep",
                             "_settleListFontScale", "_atListFontScale" }) do
        assert(not src:match("function BookshelfWidget:" .. name),
            name .. " is still defined; the font scale and the row count are "
            .. "separate controls now and nothing should be solving one from "
            .. "the other")
    end
end)

-- ── Inline style runs ──────────────────────────────────────────────────────
--
-- tests/_test_inline_style.lua proves the parser. These prove the ROW asks it
-- the right questions -- the half no pure test can reach, and the half where
-- an omission is silent: every one of these failures renders something that
-- looks almost right.

t.test("the row's line height covers its tallest inline run", function()
    -- Without this a [size=28] span renders into a band reserved for 16pt and
    -- is clipped by the row above it. The height has to come off the TEMPLATE,
    -- because the row is reserved before any book is expanded against it.
    local body = row_src:match("\nfunction ListRow%.lineStyles%b()\n(.-)\nend\n")
    assert(body, "ListRow.lineStyles is gone or was renamed")
    assert(body:match("InlineStyle%.styles"),
        "lineStyles must ask InlineStyle which sizes the template can reach")
    assert(body:match("if%s+h%s*>%s*height%s+then"),
        "lineStyles must take the TALLEST run's height, not the last one")
end)

t.test("run faces are resolved once for the page, not per row", function()
    -- A font NAME becomes a file by going through BFont's scanner, and the
    -- render loop runs that per line per row. lineStyles resolves each
    -- distinct style once and the renderer looks its face up by key.
    local styles = row_src:match("\nfunction ListRow%.lineStyles%b()\n(.-)\nend\n")
    assert(styles:match("InlineStyle%.key"),
        "lineStyles must key the faces it resolved")
    local lookup = row_src:match("local function runFace%(run%)(.-)\n    end")
    assert(lookup, "textLine's runFace helper is gone or was renamed")
    assert(lookup:match("line%.faces"),
        "a run must take the face the page already resolved")
    assert(not lookup:match("BFont"),
        "a run must not resolve a font name inside the render loop")
end)

t.test("the kept right side must clear an ABSOLUTE floor, not just 30%", function()
    -- Issue 345: 30% of a short author name is a handful of pixels, which
    -- passed the percentage floor and rendered as a lone ellipsis beside the
    -- spacer gap - the exact fragment MIN_KEEP exists to prevent. The keep
    -- test must also require room for the ellipsis plus real glyphs,
    -- measured from the line's own face.
    local i = row_src:find("local MIN_KEEP", 1, true)
    assert(i, "the MIN_KEEP overflow rule went missing")
    local block = row_src:sub(i, i + 1200)
    assert(block:find("getEllipsisWidth", 1, true),
        "the absolute floor must be measured from the ellipsis width")
    assert(block:find("avail_a >= min_abs", 1, true),
        "the keep test must compare avail_a against the absolute floor")
end)

t.test("boxHeight bills VISIBLE lines, not the whole description", function()
    -- The 4-rows-lose-their-progress-bar defect: vertical_string_list is the
    -- FULL text's wrapped lines (TextBoxWidget's ellipsis check compares it
    -- against lines_per_page), so counting it billed a clipped blurb for its
    -- entire description and the inflated "used" spent the height fillRow
    -- had reserved for the bar. Run the REAL function against both shapes.
    local body = row_src:match("\nlocal function boxHeight%b()\n(.-)\nend\n")
    assert(body, "boxHeight is gone or was renamed")
    local compile = loadstring or load   -- LuaJIT vs 5.2+
    local fn = assert(compile("return function(box)\n" .. body .. "\nend"))()
    -- A clipped blurb: ten lines of text, two visible.
    local clipped = { vertical_string_list = { 1,2,3,4,5,6,7,8,9,10 },
                      lines_per_page = 2, line_height_px = 30 }
    assert(fn(clipped) == 60,
        "a clipped box must bill its visible lines only, got " .. fn(clipped))
    -- A short blurb: two lines of text in a five-line offer.
    local short = { vertical_string_list = { 1, 2 },
                    lines_per_page = 5, line_height_px = 30 }
    assert(fn(short) == 60,
        "a short box must bill its actual lines, got " .. fn(short))
end)

t.test("the emptiness test and the wrap path read PLAIN text", function()
    -- lineText leaves the markup in for the renderer, so both readers that
    -- ask a QUESTION about the text have to strip it first. Miss the first and
    -- a line expanding to "[size=12][/size]" holds a band open with nothing in
    -- it; miss the second and a {xN} paragraph draws its own tags.
    local pack = row_src:match("\nfunction ListRow%.packRow%b()\n(.-)\nend\n")
    assert(pack, "ListRow.packRow is gone or was renamed")
    assert(pack:match("ListRow%.plain%(text%):match"),
        "packRow's empty-line test must run on the stripped text")
    local flatten = row_src:match("\nfunction ListRow%.flatten%b()\n(.-)\nend\n")
    assert(flatten and flatten:match("ListRow%.plain"),
        "flatten must strip the style tags before a TextBoxWidget sees them")
end)

t.test("mixed-size runs are forced onto one height AND one baseline",
function()
    -- Both, and for different reasons. The shared baseline is what puts the
    -- runs on one line instead of stepping; the shared height is what stops
    -- the group's centre alignment from undoing it. Dropping either one looks
    -- fine at 14pt beside 16pt and obviously broken at 30.
    assert(row_src:match("forced_height%s*=%s*max_h"),
        "the runs must share the tallest run's height")
    assert(row_src:match("forced_baseline%s*=%s*max_base"),
        "the runs must share the tallest run's baseline")
end)

t.test("a line with no markup still takes the single-widget path", function()
    -- The fast path is the whole reason parse answers nil rather than a
    -- one-run array: a shelf of 26 rows must not start building
    -- HorizontalGroups because the feature exists.
    local seg = row_src:match("local function seg%(s, max_w, trunc_left%)(.-)\n    end")
    assert(seg, "textLine's seg helper is gone or was renamed")
    assert(seg:match("if%s+not%s+runs%s+then%s+return%s+piece"),
        "seg must return a plain TextWidget when there is no markup")
end)

-- ── The art budget reaches the row ─────────────────────────────────────────

t.test("the cover and the deck are both capped against the row's width",
function()
    -- tests/_test_list_geom.lua proves the cap's arithmetic. It cannot prove
    -- the row ASKS for it, and both call sites size their artwork from the row
    -- HEIGHT -- which is exactly how the pinch crash happened, twice over: the
    -- cover on a plain row, the deck on a group row.
    assert(row_src:match("ListGeom%.thumbSize%([^)]-ListGeom%.artBudget"),
        "the cover cell must be sized against the row's art budget")
    assert(row_src:match("max_w%s*=%s*art_budget"),
        "the deck must be given the row's art budget")
    assert(row_src:match("ListGroup%.slotWidth%(content_h,%s*art_budget%)"),
        "the tile fallback costs the row the same width as the deck it "
        .. "replaces, so it takes the same budget")
end)

t.test("a text column too thin for an ellipsis does not ask for one",
function()
    -- The backstop. TextBoxWidget RAISES rather than truncating when the box
    -- is narrower than the ellipsis it was told to add, and the raise came out
    -- through _draftRebuild and killed KOReader. The budget above keeps the
    -- column far clear of it; this is the guard for the next thing that eats a
    -- row's width.
    local guard = row_src:match("local function canEllipsis%(face, inner_w%)(.-)\nend")
    assert(guard, "the canEllipsis guard is gone or was renamed")
    assert(guard:match("getEllipsisWidth"),
        "the guard must measure the real ellipsis, not assume a width")
    assert(guard:match("inner_w%s*>%s*ell"),
        "the guard must compare the box width against the ellipsis")
    assert(row_src:match("height_overflow_show_ellipsis%s*=%s*canEllipsis"),
        "wrapBox must route the ellipsis flag through the guard")
end)

-- ── The inversion: the row COUNT is chosen, the height follows ─────────────
--
-- "You should be able to keep for example a 3 row layout, and scale the font
--  size within that ... The font size would generally be set once, for
--  legibility, then the rows would be adjusted based on preference."

-- Drive the real _listRowHeight body against a baseline, with a chosen row
-- count. natural/min are the two heights it picks between.
local function rowHeightFor(o, rows_setting, natural, min_row)
    o = o or PW5
    local env = {
        require = function(name)
            assert(name == "lib/bookshelf_list_geom",
                "the row height must take its arithmetic from ListGeom")
            return ListGeom
        end,
        math = math,
    }
    env.self = {
        _chip_bar_hidden = false,
        _listBand = function(_s, e, h) return bandOf(o, e, h) end,
        _listRowGap = function() return o.row_gap end,
        _listMinRowHeight = function() return min_row or 40 end,
        _listNaturalRowHeight = function() return natural or o.row_h end,
        _listRows = function(_s, max_rows)
            if not rows_setting then return nil end
            return math.max(1, math.min(rows_setting, max_rows or rows_setting))
        end,
    }
    return compile(bodyOf("_listRowHeightUncached"), env,
                   "_listRowHeightUncached")()
end

t.test("no row count saved means the layout does not move", function()
    -- The migration, and there is no other: a reader who never opens the
    -- control keeps the density model's row height exactly.
    for _i, dev in ipairs(BASELINES) do
        eq(rowHeightFor(dev, nil, dev.row_h), dev.row_h, dev.name)
    end
end)

t.test("the chosen row count divides the band", function()
    -- Three rows means the band split three ways, whatever the font is doing.
    local b = bandOf(PW5, false, false)
    local usable = b.band - 2 * b.base_top_pad
    for _i, rows in ipairs({ 2, 3, 4, 6 }) do
        local h = rowHeightFor(PW5, rows, PW5.row_h, 40)
        local block = rows * h + (rows - 1) * PW5.row_gap
        assert(block <= usable, string.format(
            "%d rows of %d + gaps = %d, which overflows the usable band %d",
            rows, h, block, usable))
        -- And it is not leaving a whole row's worth unspent either.
        assert(block + h > usable, string.format(
            "%d rows of %d leaves %d unspent, enough for another row",
            rows, h, usable - block))
    end
end)

t.test("the row height moves with the count, not with the font", function()
    -- The complaint, inverted into a test: changing the count changes the
    -- height, and the FONT (natural height) does not enter into it.
    local three = rowHeightFor(PW5, 3, PW5.row_h, 40)
    local six   = rowHeightFor(PW5, 6, PW5.row_h, 40)
    assert(three > six, "more rows must mean shorter rows")
    -- Same count, wildly different font: same row height.
    eq(rowHeightFor(PW5, 3, 40,  40), three,
        "a smaller font must not change the row height")
    eq(rowHeightFor(PW5, 3, 400, 40), three,
        "a larger font must not change the row height either")
end)

t.test("a row is never shorter than one line of the first line", function()
    -- Ask for more rows than can hold a line and the COUNT gives way, not the
    -- row: _listRows is handed the ceiling, and the height floors at the
    -- minimum regardless.
    local h = rowHeightFor(PW5, 999, PW5.row_h, 40)
    assert(h >= 40, "row height " .. h .. " is under the one-line minimum 40")
end)

t.test("expanding the shelf buys rows, not taller rows", function()
    -- The row height is solved against the COLLAPSED band on purpose. If it
    -- tracked the live band, collapsing the hero would resize every row --
    -- which is the thing the reader set once and does not want moving.
    local collapsed = bandPlan(PW5, false, false, 3)
    local expanded  = bandPlan(PW5, true,  false, 3)
    eq(expanded.row_h, collapsed.row_h,
        "the row height must not change when the hero collapses")
    assert(expanded.rows > collapsed.rows,
        string.format("expanding showed %d rows, collapsed showed %d -- "
            .. "the freed band must become MORE rows",
            expanded.rows, collapsed.rows))
end)

t.test("the chosen count is what the collapsed shelf shows", function()
    for _i, rows in ipairs({ 2, 3, 5 }) do
        eq(bandPlan(PW5, false, false, rows).rows, rows)
    end
end)

t.test("the top gap is still the standard pad", function()
    -- The earlier ruling survives the inversion: "keep the top padding the
    -- standard amount, leave a larger gap at the bottom if there's no room for
    -- another row". Dividing the WHOLE band by the row count would have made
    -- the top margin a rounding remainder again.
    for _i, rows in ipairs({ 2, 3, 4 }) do
        local p = bandPlan(PW5, false, false, rows)
        eq(p.top_gap, p.base_top_pad, "row count " .. rows)
        assert(p.bottom_gap >= p.top_gap, string.format(
            "row count %d: bottom %d < top %d",
            rows, p.bottom_gap, p.top_gap))
        assert(p.top_gap + p.rows * p.row_h + (p.rows - 1) * p.row_gap
               + p.bottom_gap == p.band,
            "row count " .. rows .. ": the plan lost a pixel")
    end
end)

t.test("the DEFAULT row height is measured at 100, not at the reader's size",
function()
    -- THE REPORTED BUG: "it should now control the size of text lines within
    -- the rows without changing the row height".
    --
    -- With no row count saved the height comes from the configured lines, and
    -- if those are measured at the reader's text size then every font nudge
    -- moves the row height and the row count -- the density model coming back
    -- through the one door left open to it.
    --
    -- Both terms have to be pinned. Fixing only the line heights left the
    -- CHIP BAND scaling, and above 120% it overtook them and drove the row on
    -- its own: measured 166 / 166 / 166 / 167 / 187 / 207 across 60..200.
    local body = src:match(
        "\nfunction BookshelfWidget:_listNaturalRowHeight%(%)\n(.-)\nend\n")
    assert(body, "_listNaturalRowHeight is gone or was renamed")
    body = body:gsub("%-%-[^\n]*", "")
    -- %b() rather than a character class: the argument is
    -- `self:_listLines().lines, 100`, whose own parens end a [^)]- match early
    -- and make the assertion fail against correct code.
    local args = body:match("lineHeights(%b())")
    assert(args and args:match(",%s*100%s*%)$"), string.format(
        "the line heights must be measured at 100, got lineHeights%s",
        tostring(args)))
    assert(body:match("chipRowHeight%(100%)"),
        "the band must be measured at 100 too -- pinning only the lines "
        .. "leaves the band free to drive the row height above 120%")
end)

t.test("fitsOneLine treats the clamp's exact-width landing as overflow",
function()
    -- THE KATABASIS ROW: one truncated line of blurb over a block of dead
    -- space, while every neighbour wrapped. RenderText:sizeUtf8Text CLAMPS --
    -- it stops adding glyphs once pen_x reaches the width -- so a long text
    -- answers with x in [width, width + one glyph), and when the integer
    -- advances land EXACTLY on width, `<=` called a five-line description
    -- "fits on one line". The landing point is roughly uniform over one glyph
    -- advance, so this hits order one-in-a-dozen long texts at any width:
    -- common enough to meet a real library, rare enough to pass every probe
    -- that came before it.
    local body = row_src:match(
        "\nfunction ListRow%.fitsOneLine%b()\n(.-)\nend\n")
    assert(body, "ListRow.fitsOneLine is gone or was renamed")
    body = body:gsub("%-%-[^\n]*", "")
    assert(body:match("<%s*width"), "the comparison must be strict")
    assert(not body:match("<=%s*width"),
        "<= turns the clamp's exact-width landing into a false 'fits', and "
        .. "the row renders one truncated line over dead space")
end)

t.done()
