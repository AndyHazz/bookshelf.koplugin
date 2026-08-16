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
-- Size.item.height_default or the chip_font_scale setting for itself would
-- have to name them, and there is nothing in this environment to name.
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
    env.self = {}
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

t.test("the column set no longer changes the row height", function()
    -- The inversion, pinned shut. It used to be that _listRowHeight asked
    -- _listColumns() whether a cover was present and floored the answer at
    -- 42dp when it was not, so turning the Cover column OFF made rows TALLER
    -- (84px/16 rows on a PW5 against 49px/27 with covers on). The extracted
    -- body runs with NO _listColumns on self at all: if it asked, this errors.
    local h = rowHeight{ chip_h = 50, font_h = 45, ring = 2 }
    assert(h == 50, "expected the chip height 50, got " .. tostring(h))
end)

t.test("the widget asks ListRow for the face, and measures it once", function()
    -- _listRowHeight is called from _maxRows, _maxShelfRows, _baseShelves and
    -- _rebuild on every rebuild; a TextWidget probe per call is exactly the
    -- kind of per-render cost this plugin has had to fix before. The face has
    -- to come from ListRow.textFace so the budget measures the same size the
    -- row renders at -- which now moves with chip_font_scale.
    local _h, probes, faces = rowHeight{ chip_h = 50, font_h = 41, ring = 2 }
    assert(probes == 1, "expected one probe per fresh cache, got " .. probes)
    assert(faces >= 1, "the widget did not ask ListRow for the face")
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

t.test("the row widget takes its type and height from the chip bar", function()
    -- The two environment reads the whole Part 2 change rests on. ListGeom
    -- owns the arithmetic and cannot do these reads itself (no widget stack),
    -- so this file is where they have to happen -- and if they stop happening,
    -- the row silently goes back to a private hardcoded size that no setting
    -- reaches.
    assert(row_src:match("Size%.item%.height_default"),
        "the row's height must come from the chip strip's Size.item.height_default")
    -- And the strip's outer FrameContainer border, which paints OUTSIDE that
    -- height: without it the row is 2px shy of the band beside it on a
    -- Paperwhite 5, which is the mismatch the maintainer reported.
    assert(row_src:match("Size%.border%.thin"),
        "the row's height must count the chip strip's own border")
    assert(row_src:match('read%("chip_font_scale"%)'),
        "the row must honour chip_font_scale, the setting that sizes the chips")
    assert(row_src:match("ListGeom%.chipRowHeight"),
        "the chip-height arithmetic belongs in ListGeom, not restated here")
    assert(row_src:match("ListGeom%.fontSize"),
        "the font-size arithmetic belongs in ListGeom, not restated here")
    assert(row_src:match("ListRow%.FONT_FACE%s*=%s*ListGeom%.FONT_FACE"),
        "the row's face must be ListGeom's declaration, not a second copy")
    -- The old hardcoded pair. Either one back in this file means the row has
    -- stopped following the chip bar.
    assert(not row_src:match('getFace%(%s*"cfont"'),
        "the row must not hardcode cfont; the chip bar renders infofont")
    assert(not row_src:match("ListRow%.FONT_SIZE%s*="),
        "the row's size is chip_font_scale-dependent; it cannot be a constant")
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
