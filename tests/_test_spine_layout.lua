-- tests/_test_spine_layout.lua
-- lib/bookshelf_spine_layout.lua: the spine view's pure geometry.
--
-- Pins the three mappings (pages->width, aspect->height, favourite
-- face-out width) at their clamps and midpoints, and the greedy
-- variable-width pagination -- the part a device screenshot cannot
-- check at the boundaries (unknown pages, absurd aspect, one book
-- wider than the whole shelf).
--
-- Usage (from plugin root): lua tests/_test_spine_layout.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

local H  = dofile("tests/_helpers.lua")
local t  = H.runner()
local eq = H.eq

local SL = require("lib/bookshelf_spine_layout")

-- ── width from page count ───────────────────────────────────────────────

t.test("width: unknown pages -> the DEFAULT_PAGES width, not the minimum", function()
    local dflt = SL.spineWidthDp(SL.DEFAULT_PAGES)
    eq(SL.spineWidthDp(nil), dflt)
    eq(SL.spineWidthDp(0), dflt)
    eq(SL.spineWidthDp(-5), dflt)
    eq(SL.spineWidthDp("not a number"), dflt)
    assert(dflt > SL.MIN_W_DP, "default width must sit above the minimum")
end)

t.test("width: clamps at both ends", function()
    eq(SL.spineWidthDp(1), SL.MIN_W_DP)
    eq(SL.spineWidthDp(SL.MIN_PAGES), SL.MIN_W_DP)
    eq(SL.spineWidthDp(SL.MAX_PAGES), SL.MAX_W_DP)
    eq(SL.spineWidthDp(99999), SL.MAX_W_DP)
end)

t.test("width: monotonic in pages", function()
    local prev = SL.spineWidthDp(SL.MIN_PAGES)
    for pages = SL.MIN_PAGES, SL.MAX_PAGES, 100 do
        local w = SL.spineWidthDp(pages)
        assert(w >= prev, "width shrank as pages grew at " .. pages)
        prev = w
    end
end)

-- ── height from aspect ──────────────────────────────────────────────────

t.test("height: reference aspect nearly fills the row", function()
    eq(SL.spineHeight(1000, SL.REF_ASPECT), 980)  -- TOP_FRAC = 0.98
end)

t.test("height: taller-than-reference clamps to TOP_FRAC, never over the row", function()
    eq(SL.spineHeight(1000, 5.0), 980)
    assert(SL.spineHeight(100, 5.0) <= 100)
end)

t.test("height: squat covers floor at MIN_FRAC", function()
    eq(SL.spineHeight(1000, 0.5), 620)  -- MIN_FRAC = 0.62
end)

t.test("height: unknown aspect uses the default, and never returns 0", function()
    eq(SL.spineHeight(1000, nil), SL.spineHeight(1000, SL.DEFAULT_ASPECT))
    assert(SL.spineHeight(1, 1.5) >= 1)
end)

-- ── auto thickness from shelf height ────────────────────────────────────

t.test("auto thickness: 1.0 at the reference two-row height", function()
    local s = SL.autoThickness(SL.THICKNESS_REF_ROW_DP)
    assert(math.abs(s - 1.0) < 0.001, "reference height must scale 1.0")
end)

t.test("auto thickness: a doubled row wants ~1.5x (device calibration)", function()
    local s = SL.autoThickness(SL.THICKNESS_REF_ROW_DP * 2)
    assert(s > 1.45 and s < 1.6, "got " .. tostring(s))
end)

t.test("auto thickness: clamps and degenerates", function()
    eq(SL.autoThickness(nil), 1)
    eq(SL.autoThickness(0), 1)
    eq(SL.autoThickness(1), SL.THICKNESS_MIN)
    eq(SL.autoThickness(1e6), SL.THICKNESS_MAX)
end)

-- ── favourite face-out width ────────────────────────────────────────────

t.test("face-out: width is spine height over aspect", function()
    eq(SL.faceOutWidth(300, 1.5), 200)
    eq(SL.faceOutWidth(300, nil), 200)  -- default aspect 1.5
    assert(SL.faceOutWidth(1, 10) >= 1)
end)

-- ── greedy row fill ─────────────────────────────────────────────────────

t.test("fill: packs greedily and starts a new row when full", function()
    -- shelf 100 wide, gap 2: 40+2+40 = 82 fits, +2+40 would be 124 -> new row
    local rows = SL.fillRows({ 40, 40, 40, 40, 40 }, 100, 2)
    eq(#rows, 3)
    eq(rows[1], { first = 1, last = 2 })
    eq(rows[2], { first = 3, last = 4 })
    eq(rows[3], { first = 5, last = 5 })
end)

t.test("fill: a single book wider than the shelf still gets a row", function()
    local rows = SL.fillRows({ 500, 40 }, 100, 2)
    eq(#rows, 2)
    eq(rows[1], { first = 1, last = 1 })
    eq(rows[2], { first = 2, last = 2 })
end)

t.test("fill: empty input -> no rows", function()
    eq(#SL.fillRows({}, 100, 2), 0)
end)

t.test("fill: exact fit is kept on one row", function()
    local rows = SL.fillRows({ 49, 49 }, 100, 2)
    eq(#rows, 1)
    eq(rows[1], { first = 1, last = 2 })
end)

t.test("fill: per-book gaps make a group boundary count against the row", function()
    -- 40+2+40 = 82 fits; book 3 carries a 20 boundary gap: 82+20+40 = 142
    -- -> wraps, where a flat gap of 2 would have kept it (124 > 100 anyway;
    -- use a wider shelf so only the boundary gap forces the wrap).
    local rows = SL.fillRows({ 40, 40, 40 }, 130, { 0, 2, 20 })
    eq(#rows, 2)
    eq(rows[1], { first = 1, last = 2 })
    eq(rows[2], { first = 3, last = 3 })
    -- Same widths with the small gap everywhere DO fit three across.
    eq(#SL.fillRows({ 40, 40, 40 }, 130, { 0, 2, 2 }), 1)
end)

-- ── pagination ──────────────────────────────────────────────────────────

t.test("paginate: groups rows and reports book index bounds", function()
    local rows = SL.fillRows({ 40, 40, 40, 40, 40 }, 100, 2)  -- 3 rows
    local pages = SL.paginate(rows, 2)
    eq(#pages, 2)
    eq(pages[1].first, 1); eq(pages[1].last, 4); eq(#pages[1].rows, 2)
    eq(pages[2].first, 5); eq(pages[2].last, 5); eq(#pages[2].rows, 1)
end)

t.test("paginate: single-row pages give the footer its n-m slice", function()
    local rows = SL.fillRows({ 40, 40, 40 }, 100, 2)  -- {1-2},{3}
    local pages = SL.paginate(rows, 1)
    eq(#pages, 2)
    eq(pages[1].first, 1); eq(pages[1].last, 2)
end)

t.test("paginate: rows_per_page below 1 behaves as 1", function()
    local rows = SL.fillRows({ 40, 40, 40 }, 100, 2)
    eq(#SL.paginate(rows, 0), 2)
end)

-- ── the top edge, and the face-out/spine-out agreement ────────────────────
--
-- A face-out and a spine-out of the SAME book are the same physical object,
-- so their visible FRONT FACES must be the same height. They were not: the
-- painter carved the spine's top edge (cover width, foreshortened) out of the
-- allotted height, while the planner gave the face-out everything left after
-- its own much smaller thickness. Device report: "the face out cover is as
-- tall as the spine plus its pages top box".

t.test("the top edge is the COVER WIDTH foreshortened, not a fraction of height", function()
    -- A wide book (low aspect) has more depth into the shelf than a narrow
    -- one of the same height, so it shows more lid. The bug this replaced
    -- used a flat 5% of height and made every spine identical up there.
    local wide   = SL.topEdgeHeight(300, 1.2, 0)
    local narrow = SL.topEdgeHeight(300, 2.0, 0)
    assert(wide > narrow, "a squatter book must show a deeper top edge")
    eq(wide,   math.floor((300 / 1.2) * SL.VIEW_SIN))
    eq(narrow, math.floor((300 / 2.0) * SL.VIEW_SIN))
end)

t.test("the top edge is capped at a fifth of the book", function()
    -- An absurd aspect would otherwise turn a book into mostly lid.
    eq(SL.topEdgeHeight(300, 0.2, 0), math.floor(300 * SL.TOP_EDGE_MAX_FRAC))
end)

t.test("the top edge honours a caller's minimum, but the cap still wins", function()
    -- The painter passes scaleBySize(5): below that the page stripes are mush.
    -- A narrow book gets lifted to it...
    eq(SL.topEdgeHeight(200, 6.0, 12), 12)
    -- ...but on a book too SHORT to spare a fifth, the cap wins, because the
    -- clamps apply in that order. Inherited from the painter deliberately: a
    -- minimum that could exceed the cap would put a lid on a book with almost
    -- no spine left under it.
    eq(SL.topEdgeHeight(40, 3.0, 12), math.floor(40 * SL.TOP_EDGE_MAX_FRAC))
    assert(SL.topEdgeHeight(300, 1.5, 12) > 12, "the minimum is a floor, not a value")
end)

t.test("an unknown or absurd aspect falls back, and a zero height is zero", function()
    eq(SL.topEdgeHeight(300, nil, 0), SL.topEdgeHeight(300, SL.DEFAULT_ASPECT, 0))
    eq(SL.topEdgeHeight(300, -1, 0),  SL.topEdgeHeight(300, SL.DEFAULT_ASPECT, 0))
    eq(SL.topEdgeHeight(0, 1.5, 0), 0)
end)

t.test("a face-out cover and its spine show the SAME front face", function()
    -- The whole point. Both derive from one allotted height and one helper,
    -- so this holds by construction -- which is the fix.
    for _i, aspect in ipairs({ 1.2, 1.5, 1.8, 2.4 }) do
        local h        = SL.spineHeight(400, aspect)
        local min_px   = 10
        local edge     = SL.topEdgeHeight(h, aspect, min_px)
        local spine_face = h - edge          -- what the painter leaves below the lid
        local cover_h    = h - edge          -- what the planner gives the cover
        eq(cover_h, spine_face, "aspect " .. aspect)
    end
end)

t.test("a face-out's total silhouette is SHORTER than a spine-out's", function()
    -- Not a regression to fix by stretching the cover back up: a face-out
    -- shows its thickness above the cover where a spine-out shows its cover
    -- width, so it genuinely occupies less of the row.
    local aspect = 1.5
    local h      = SL.spineHeight(400, aspect)
    local edge   = SL.topEdgeHeight(h, aspect, 0)          -- spine-out lid
    local thick  = math.floor(SL.spineWidthDp(300) * SL.VIEW_SIN)  -- face-out lid
    assert(thick < edge, "a book is thinner than it is wide, so its lid is shallower")
    assert((h - edge) + thick < h, "the face-out should not fill the allotted height")
end)

t.test("the cover width follows the COVER height, so it stays aspect-true", function()
    -- Sizing the width off the allotted height instead would have left the
    -- cover a shade too wide for its new height.
    local aspect = 1.5
    local h      = SL.spineHeight(400, aspect)
    local face_h = h - SL.topEdgeHeight(h, aspect, 0)
    local w      = SL.faceOutWidth(face_h, aspect)
    assert(math.abs(face_h / w - aspect) < 0.05,
        "cover aspect drifted: " .. (face_h / w) .. " vs " .. aspect)
end)

-- ── balanced row breaking ───────────────────────────────────────────────
--
-- The greedy fill decides WHICH books are on the page (it packs the most
-- books into the rows available, which is what pagination depends on), then
-- balanceRows re-breaks that same prefix across the same number of rows so
-- the slack is shared out instead of all landing on the last shelf. Rows are
-- painted CENTRED, so a lone trailing book sits marooned mid-plank -- the
-- thing this pass exists to stop.

local function repeated(n, w)
    local t = {}
    for i = 1, n do t[i] = w end
    return t
end

t.test("balance: the hanging last book comes back onto an even shelf", function()
    -- 16 books at 65 on a 1000-wide shelf: 15 fit (975), the 16th hangs.
    local widths = repeated(16, 65)
    local greedy = SL.fillRows(widths, 1000, 0)
    eq(greedy[1], { first = 1, last = 15 })
    eq(greedy[2], { first = 16, last = 16 })
    local rows = SL.balanceRows(widths, 1000, 0, 16, 2)
    eq(#rows, 2)
    eq(rows[1], { first = 1, last = 8 })
    eq(rows[2], { first = 9, last = 16 })
end)

t.test("balance: the page keeps exactly the books the greedy fill gave it", function()
    -- 20 books, two rows: greedy takes 1..20 (15 + 5). Re-breaking must not
    -- lose or gain a book, or the cursor step and the footer range drift.
    local widths = repeated(20, 65)
    local rows = SL.balanceRows(widths, 1000, 0, 20, 2)
    eq(#rows, 2)
    eq(rows[1].first, 1)
    eq(rows[#rows].last, 20)
    eq(rows[1], { first = 1, last = 10 })
end)

t.test("balance: an already even page is left alone", function()
    local widths = repeated(30, 65)
    local rows = SL.balanceRows(widths, 1000, 0, 30, 2)
    eq(rows[1], { first = 1, last = 15 })
    eq(rows[2], { first = 16, last = 30 })
end)

t.test("balance: one row has nothing to balance", function()
    eq(SL.balanceRows({ 40, 40 }, 100, 0, 2, 1), nil)
    eq(SL.balanceRows({ 40 }, 100, 0, 1, 2), nil)
    eq(SL.balanceRows({}, 100, 0, 0, 2), nil)
end)

t.test("balance: a book wider than the shelf still gets its own row", function()
    -- Same contract as the greedy fill: an overwide book is not a dead end.
    local rows = SL.balanceRows({ 500, 40, 40 }, 100, 0, 3, 2)
    eq(#rows, 2)
    eq(rows[1], { first = 1, last = 1 })
    eq(rows[2], { first = 2, last = 3 })
end)

t.test("balance: the gap before a row's first book is dropped, as in the fill", function()
    -- Book 3 carries a 100 boundary gap. Starting a row AT book 3 drops it,
    -- so {1,2}{3,4} measures 82 and 82. Counting it would make every two-row
    -- split overflow the 150 shelf and there would be no answer at all.
    local rows = SL.balanceRows({ 40, 40, 40, 40 }, 150, { 0, 2, 100, 2 }, 4, 2)
    assert(rows, "the leading gap was charged to the row that starts with it")
    eq(rows[1], { first = 1, last = 2 })
    eq(rows[2], { first = 3, last = 4 })
end)

-- ── keeping a section whole ─────────────────────────────────────────────
--
-- On a grouping chip the flattened runs are sections of the shelf, badged
-- underneath. opts.runs carries each book's section id, and a break landing
-- INSIDE a section costs extra -- a preference, not a rule.

t.test("balance: a break prefers a section boundary over the evenest split", function()
    -- 10 books at 60 on a 500 shelf, sections of 3/3/2/2. The evenest split
    -- is 5/5, which cuts the second section in half; 6/4 lands on a boundary
    -- and is only slightly less even.
    local widths = repeated(10, 60)
    local runs   = { 1, 1, 1, 2, 2, 2, 3, 3, 4, 4 }
    eq(SL.balanceRows(widths, 500, 0, 10, 2)[1], { first = 1, last = 5 })
    local rows = SL.balanceRows(widths, 500, 0, 10, 2, { runs = runs })
    eq(rows[1], { first = 1, last = 6 })
    eq(rows[2], { first = 7, last = 10 })
end)

t.test("balance: a stranded book still wins over keeping a section whole", function()
    -- The only section boundary is the greedy break itself: 15 books in one
    -- section, then a 16th on its own. Keeping the section whole is exactly
    -- the 15-and-1 shelf we are trying to fix, so evenness has to win.
    local widths = repeated(16, 65)
    local runs   = {}
    for i = 1, 15 do runs[i] = 1 end
    runs[16] = 2
    local rows = SL.balanceRows(widths, 1000, 0, 16, 2, { runs = runs })
    eq(rows[1], { first = 1, last = 8 })
    eq(rows[2], { first = 9, last = 16 })
end)

t.test("balance: a section too wide for one row is not defended", function()
    -- Section 1 is 10 books wide on a shelf that holds 8 -- it HAS to be cut
    -- wherever the breaks fall, so charging for those cuts would only buy a
    -- lopsided shelf. Exempting it leaves the even 4/4/4.
    local widths = repeated(12, 60)
    local runs   = {}
    for i = 1, 10 do runs[i] = 1 end
    runs[11], runs[12] = 2, 2
    local rows = SL.balanceRows(widths, 500, 0, 12, 3, { runs = runs })
    eq(#rows, 3)
    eq(rows[1], { first = 1, last = 4 })
    eq(rows[2], { first = 5, last = 8 })
    eq(rows[3], { first = 9, last = 12 })
end)

t.done()
