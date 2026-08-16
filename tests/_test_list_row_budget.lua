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

local t = dofile("tests/_helpers.lua").runner()

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

-- ── _listRowHeight ─────────────────────────────────────────────────────────

-- Run the real body with a stub font stack. `ring`, `font_h` and `chip_h` are
-- sentinels rather than real device numbers, so what comes back can only be
-- right if the body composed it out of exactly those three things.
--
-- ListRow is stubbed with the three accessors the widget is now supposed to go
-- through -- textFace, chipRowHeight, RING. A widget that went back to reading
-- Size.item.height_default or a font-scale setting for itself would have to
-- name them, and there is nothing in this environment to name.
local function rowHeight(opts)
    local RING   = opts.ring or 7
    local FONT_H = opts.font_h or 41
    local CHIP_H = opts.chip_h or 0
    local faces_asked = 0
    local ListRow = {
        FONT_FACE = "infofont",
        RING      = RING,
        fontSize  = function() return 16 end,
        textFace  = function() faces_asked = faces_asked + 1
                                return { face = true }, false end,
        chipRowHeight = function() return CHIP_H end,
    }
    local probes = 0
    local env = {
        require = function(name)
            if name == "lib/bookshelf_list_geom" then return ListGeom end
            if name == "lib/bookshelf_list_row"  then return ListRow  end
            error("unexpected require: " .. name)
        end,
        TextWidget = { new = function(_, o)
            probes = probes + 1
            assert(o.text == "Ag", "the probe should measure the row's own face")
            return { getSize = function() return { h = FONT_H } end,
                     free    = function() end }
        end },
        -- The memo cache is an upvalue in the real file; a fresh table per call
        -- keeps each case independent.
        _list_font_h_cache = {},
        math = math,
    }
    -- `self` is the method's implicit parameter; the extracted body has no
    -- parameter list, so it resolves as a global out of the environment.
    --
    -- _listColumns answers the LAYOUT table. The only thing the budget is
    -- allowed to read out of it is the line count -- whether row 2 has any
    -- columns -- so show_cover is deliberately set to the value that would
    -- have mattered under the old has-cover branch and must not.
    env.self = {
        _listColumns = function()
            return { show_cover = opts.show_cover ~= false,
                     row1 = { {} },
                     row2 = opts.two_rows and { {} } or {} }
        end,
    }
    local h = compile(bodyOf("_listRowHeight"), env, "_listRowHeight")()
    return h, probes, faces_asked
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

t.test("a populated row 2 buys the budget a second line", function()
    -- The budget and the render have to agree about how tall an item is, and
    -- with two text rows that is no longer a constant. One extra line height,
    -- exactly -- the same expression ListGeom.rowHeight uses, reached through
    -- the widget's own read of the column layout.
    local one = rowHeight{ chip_h = 50, font_h = 34, ring = 2 }
    local two = rowHeight{ chip_h = 50, font_h = 34, ring = 2, two_rows = true }
    assert(one == 50, "one line should still be the chip band, got " .. one)
    assert(two == 84, string.format(
        "two lines should be the band plus one line height (84), got %d", two))
end)

t.test("the widget asks ListRow for the face, and measures it once", function()
    -- _listRowHeight is called from _maxRows, _maxShelfRows, _baseShelves and
    -- _rebuild on every rebuild; a TextWidget probe per call is exactly the
    -- kind of per-render cost this plugin has had to fix before. The face has
    -- to come from ListRow.textFace so the budget measures the same size the
    -- row renders at -- which moves with list_font_scale.
    local _h, probes, faces = rowHeight{ chip_h = 50, font_h = 41, ring = 2 }
    assert(probes == 1, "expected one probe per fresh cache, got " .. probes)
    assert(faces >= 1, "the widget did not ask ListRow for the face")
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
local PW5 = {
    height = 1648, PAD = 37, content_w = 1174, chip_h = 50,
    footer = 88, row_h = 52, row_gap = 1, cover_hero = 477, strip = 41,
}

local function bandPlan(o, expanded, hide_chips)
    o = o or PW5
    local env = {
        require = function(name)
            assert(name == "lib/bookshelf_list_geom",
                "the plan must take its row arithmetic from ListGeom, not " .. name)
            return ListGeom
        end,
        Size = { padding = { large = 24 } },
        math = math,
        _footerReserveH = function() return o.footer end,
    }
    local self = {
        height = o.height,
        _layoutPrimitives = function() return o.PAD, o.content_w, o.chip_h end,
        _statusStripHeight = function() return o.strip end,
        _listCollapsedHeroHeight = function() return o.cover_hero end,
        _listRowHeight = function() return o.row_h end,
        _listRowGap    = function() return o.row_gap end,
    }
    return methodOf("_listBandPlan", env)(self, expanded, hide_chips)
end

t.test("the plan accounts for every pixel of the band", function()
    local p = bandPlan(nil, false, false)
    local block = p.rows * p.row_h + (p.rows - 1) * p.row_gap
    assert(p.top_gap + block + p.bottom_gap == p.band, string.format(
        "top %d + rows %d + bottom %d != band %d",
        p.top_gap, block, p.bottom_gap, p.band))
    assert(p.top_extra == p.top_gap - p.base_top_pad, string.format(
        "top_extra %d must be what _rebuild adds to the %d already in the "
        .. "layout to reach a top gap of %d",
        p.top_extra, p.base_top_pad, p.top_gap))
end)

t.test("the gap below the last row matches the gap above the first", function()
    -- Ruling 2. Equal, or one pixel more at the bottom when the leftover is
    -- odd -- never less, which is the direction "at least" asks for.
    for _i, case in ipairs({ { false, false }, { true, false },
                             { false, true }, { true, true } }) do
        local p = bandPlan(nil, case[1], case[2])
        assert(p.bottom_gap >= p.top_gap, string.format(
            "expanded=%s hide_chips=%s: bottom gap %d is SMALLER than the top "
            .. "gap %d", tostring(case[1]), tostring(case[2]),
            p.bottom_gap, p.top_gap))
        assert(p.bottom_gap - p.top_gap <= 1, string.format(
            "expanded=%s hide_chips=%s: gaps differ by %d, not 0 or 1",
            tostring(case[1]), tostring(case[2]), p.bottom_gap - p.top_gap))
        assert(p.top_gap >= p.base_top_pad, string.format(
            "the top gap %d fell below the layout's own pad %d",
            p.top_gap, p.base_top_pad))
    end
end)

t.test("the margin is paid for out of the row count", function()
    -- "this will often mean losing a row, that's fine." One more row must not
    -- fit -- the count is maximal against the reserved margin, not merely
    -- conservative -- and it must be strictly fewer than the count that
    -- ignores the margin, or nothing has been reserved at all.
    local p = bandPlan(nil, false, false)
    local one_more = (p.rows + 1) * p.row_h + p.rows * p.row_gap
    assert(one_more > p.band - 2 * p.base_top_pad, string.format(
        "%d rows would still have fitted inside the reserved margins",
        p.rows + 1))
    local greedy = ListGeom.rowsThatFit(p.band - p.row_gap, p.row_h, p.row_gap)
    assert(p.rows < greedy, string.format(
        "the margin cost nothing: %d rows either way", p.rows))
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
        _listRowHeight = function() return row_h end,
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

t.test("the row widget sizes itself on the LIST key, through BandMetrics", function()
    -- The row is built to the chip strip's SHAPE on its OWN SETTING. Both
    -- halves are load-bearing and this is the only place either is visible:
    -- the shape comes from BandMetrics (so the two surfaces cannot round
    -- differently), the setting is LIST_KEY (so they can be tuned apart).
    assert(row_src:match("BandMetrics%.paintedHeight%(BandMetrics%.LIST_KEY%)"),
        "the row's height must be BandMetrics.paintedHeight on the LIST key")
    assert(row_src:match("BandMetrics%.fontSize%(BandMetrics%.LIST_KEY%)"),
        "the row's font size must be BandMetrics.fontSize on the LIST key")
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

t.done()
