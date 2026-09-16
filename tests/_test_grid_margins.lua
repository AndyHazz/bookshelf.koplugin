-- tests/_test_grid_margins.lua
-- How the cover grid's vertical gaps are shared out between the chrome above
-- it and the footer below it.
--
-- WHAT NEEDS PINNING. The layout spends PAD above row 1 and PAD after the
-- last row, but the chrome is not symmetric: the top panel bleeds PAD/2 down
-- over the top gap, and without a footer panel the footer's icons sit below
-- the top of their reserve. So the eye saw ~11px above the grid and ~41px
-- below it on a Paperwhite 5. The split keeps the total spend (so shelf_h,
-- hero_h and row counts do not move for anyone) and redistributes it so the
-- VISIBLE gaps match; expanded mode spreads its slack over every gap
-- including the top one, instead of only the gaps below rows.
--
-- Usage (from plugin root): lua tests/_test_grid_margins.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local GM = dofile("lib/bookshelf_grid_margins.lua")

local function visible(o, r)
    return r.top - (o.top_bleed or 0), r.last + (o.foot_offset or 0)
end

t.test("collapsed, no chrome: the spans stay PAD and the remainder is shared", function()
    local o = { pad = 37, n_rows = 2, top_bleed = 0, foot_offset = 0, extra = 0, spread = false }
    local r = GM.split(o)
    eq(r.top, 37); eq(r.between, 37); eq(r.last, 37)
    o.extra = 5
    r = GM.split(o)
    eq(r.between, 37, "between-row gaps do not move in collapsed mode")
    eq(r.top + r.last, 37 * 2 + 5, "the total spend is unchanged")
    local vt, vb = visible(o, r)
    assert(math.abs(vt - vb) <= 1, "visible gaps differ: " .. vt .. " vs " .. vb)
end)

t.test("collapsed with a top panel: the bleed is paid for from the bottom gap", function()
    -- The Paperwhite 5 case: PAD 37, bleed 19, footer panel at the reserve.
    local o = { pad = 37, n_rows = 2, top_bleed = 19, foot_offset = 0, extra = 4, spread = false }
    local r = GM.split(o)
    eq(r.top + r.last, 37 * 2 + 4)
    local vt, vb = visible(o, r)
    assert(math.abs(vt - vb) <= 1, "visible gaps differ: " .. vt .. " vs " .. vb)
    assert(r.last >= 0 and r.top >= 0)
end)

t.test("collapsed without panels: the footer's inset counts as bottom gap", function()
    local o = { pad = 37, n_rows = 2, top_bleed = 0, foot_offset = 12, extra = 4, spread = false }
    local r = GM.split(o)
    local vt, vb = visible(o, r)
    assert(math.abs(vt - vb) <= 1, "visible gaps differ: " .. vt .. " vs " .. vb)
    assert(r.top > 37, "the grid should move down when the footer sits inside its reserve")
end)

t.test("the bottom span never goes negative; the shortfall stays at the top", function()
    local o = { pad = 10, n_rows = 1, top_bleed = 40, foot_offset = 0, extra = 0, spread = false }
    local r = GM.split(o)
    eq(r.last, 0)
    eq(r.top, 20, "total spend still 2 * PAD")
end)

t.test("expanded: every gap, the top one included, gets an equal visible share", function()
    -- 4 rows, 100px of screen slack, a top panel bleed of 19, footer panel.
    local o = { pad = 37, n_rows = 4, top_bleed = 19, foot_offset = 0, extra = 100, spread = true }
    local r = GM.split(o)
    local total = r.top + (o.n_rows - 1) * r.between + r.last
    eq(total, 37 * 5 + 100, "the whole pool is spent")
    local vt, vb = visible(o, r)
    assert(math.abs(vt - r.between) <= 1, "top visible " .. vt .. " vs between " .. r.between)
    assert(math.abs(vb - r.between) <= (o.n_rows + 1), "bottom visible " .. vb .. " vs between " .. r.between)
    assert(r.between > 37, "the slack must widen the between-row gaps")
end)

t.test("expanded with no slack still evens the visible gaps", function()
    local o = { pad = 37, n_rows = 3, top_bleed = 19, foot_offset = 0, extra = 0, spread = true }
    local r = GM.split(o)
    local total = r.top + (o.n_rows - 1) * r.between + r.last
    eq(total, 37 * 4)
    local vt = visible(o, r)
    assert(math.abs(vt - r.between) <= 1)
end)

t.test("one row: no between gap is needed and none is spent", function()
    local o = { pad = 30, n_rows = 1, top_bleed = 10, foot_offset = 0, extra = 6, spread = true }
    local r = GM.split(o)
    eq(r.top + r.last, 30 * 2 + 6)
    local vt, vb = visible(o, r)
    assert(math.abs(vt - vb) <= 1)
end)

t.test("a narrower span above row 1 (chip strip hidden) is still balanced by eye", function()
    -- Expanded mode with the strip hidden: the span above row 1 is
    -- Size.padding.large, not PAD. The split must reason from that base.
    local o = { pad = 37, top_base = 9, n_rows = 3, top_bleed = 19, foot_offset = 0, extra = 0, spread = true }
    local r = GM.split(o)
    eq(r.top + 2 * r.between + r.last, 9 + 37 * 3, "the spend is base + n * pad")
    local vt = r.top - 19
    assert(math.abs(vt - r.between) <= 1, "visible top " .. vt .. " vs between " .. r.between)
    o.spread = false
    r = GM.split(o)
    eq(r.top + r.last, 9 + 37)
    assert(math.abs((r.top - 19) - r.last) <= 1, "collapsed: " .. (r.top - 19) .. " vs " .. r.last)
end)

t.test("last_min: the gap after the last row never shrinks below what hangs from it", function()
    -- A spine row's section badge hangs below its plank; the fixed PAD used to
    -- clear it by luck, and the balanced split trimmed the last gap under it,
    -- so the badges sat flush on the footer panel (maintainer: "at least 1px
    -- separation"). The caller says how much must stay below the last row and
    -- the split pays for it from the top gap.
    local o = { pad = 37, n_rows = 3, top_bleed = 19, foot_offset = 0, extra = 4, spread = false, last_min = 36 }
    local r = GM.split(o)
    eq(r.last, 36, "the floor holds")
    eq(r.top + r.last, 37 * 2 + 4, "the spend is unchanged; the top paid for it")
    o.spread = true
    r = GM.split(o)
    assert(r.last >= 36, "expanded: the floor holds too, got " .. r.last)
    eq(r.top + (o.n_rows - 1) * r.between + r.last, 37 * 4 + 4, "the whole pool is still spent")
    -- A floor that is already met changes nothing.
    local base = GM.split{ pad = 37, n_rows = 2, extra = 0, spread = false }
    local same = GM.split{ pad = 37, n_rows = 2, extra = 0, spread = false, last_min = 10 }
    eq(same.top, base.top); eq(same.last, base.last)
    -- A floor the pool cannot afford takes the whole top gap and no more.
    r = GM.split{ pad = 10, n_rows = 1, extra = 0, spread = false, last_min = 50 }
    eq(r.top, 0); eq(r.last, 20)
end)

t.test("nothing is ever fractional", function()
    for _, o in ipairs{
        { pad = 37, n_rows = 2, top_bleed = 19, foot_offset = 0, extra = 3, spread = false },
        { pad = 23, n_rows = 5, top_bleed = 12, foot_offset = 7, extra = 41, spread = true },
    } do
        local r = GM.split(o)
        for _, k in ipairs{ "top", "between", "last" } do
            assert(r[k] == math.floor(r[k]), k .. " is fractional: " .. r[k])
        end
    end
end)


-- ── the wiring in _rebuild ──────────────────────────────────────────────────
-- Source-level: _rebuild is a thousand lines on a live Screen, so these pin
-- the shape of the wiring rather than run it. The rig shots are the behaviour
-- check.
local function read(path) local f = assert(io.open(path)); local s = f:read("*a"); f:close(); return s end

t.test("_rebuild spends its row gaps through GridMargins.split", function()
    local src = read("lib/bookshelf_widget.lua")
    local body = src:match("\nfunction BookshelfWidget:_rebuild%(%)\n(.-)\nend\n")
    assert(body, "no _rebuild")
    assert(body:find("GridMargins.split", 1, true), "_rebuild does not ask GridMargins")
    assert(not body:find("after_row_bonus", 1, true),
        "the old n-gap bonus is still there; the split owns the between/last gaps now")
    -- The span above row 1 carries the split's top extra in BOTH branches
    -- (chip strip shown and hidden), the way list_top_extra already does.
    assert(body:find("width = PAD + list_top_extra + grid_top_extra", 1, true),
        "the chips-to-row-1 span does not carry grid_top_extra")
    assert(body:find("hide_chip_bar and (list_top_extra + grid_top_extra) or 0", 1, true),
        "the hero-to-row-1 span (strip hidden) does not carry grid_top_extra")
    -- After each row: the between gap, and the last gap after the final row.
    assert(body:find("(r < n_shelves) and grid_between or grid_last", 1, true),
        "the after-row spans are not the split's between/last")
    -- wipe_rows_top is derived from pre_rows_h, so it must know the extra too.
    local pre = body:match("local pre_rows_h%s*=(.-)\n%s*local rows_block_h")
    assert(pre and pre:find("grid_top_extra", 1, true), "pre_rows_h ignores grid_top_extra")
    local sum = body:match("local layout_sum%s*=(.-)\n%s*local layout_slack")
    assert(sum and sum:find("grid_top_extra", 1, true) and sum:find("grid_between", 1, true)
           and sum:find("grid_last", 1, true), "layout_sum does not add up the split's spans")
end)

t.test("the top panel is decided once, and the split sees its bleed", function()
    local src = read("lib/bookshelf_widget.lua")
    local body = src:match("\nfunction BookshelfWidget:_rebuild%(%)\n(.-)\nend\n")
    local n = select(2, body:gsub("PAD %- math%.floor%(PAD / 2%)", ""))
    assert(n == 1, "the panel bleed is computed " .. n .. " times in _rebuild; expected once")
    assert(body:find("top_bleed = top_panel_bleed", 1, true), "the split is not told the panel bleed")
    assert(body:find("foot_offset", 1, true), "the split is not told the footer inset")
    -- Spine rows hang a section badge below the plank: the last gap must clear it.
    assert(body:find("last_min = ", 1, true) and body:find("SpineShelf.badgeDrop", 1, true),
        "the split is not told what hangs below the last spine row")
end)

t.done()
