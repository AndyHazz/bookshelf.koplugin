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

-- Run the real body with a stub font stack. `ring` and `font_h` are sentinels
-- rather than real device numbers, so what comes back can only be right if the
-- body composed it out of exactly those two things.
local function rowHeight(opts)
    local RING   = opts.ring or 7
    local FONT_H = opts.font_h or 41
    local columns = opts.columns or { { id = "cover" }, { id = "title" } }
    local ListRow = { FONT_FACE = "cfont", FONT_SIZE = 16, RING = RING }
    local probes = 0
    local env = {
        require = function(name)
            if name == "lib/bookshelf_list_geom" then return ListGeom end
            if name == "lib/bookshelf_list_row"  then return ListRow  end
            error("unexpected require: " .. name)
        end,
        BFont  = { getFace = function() return { face = true }, false end },
        Screen = { scaleBySize = function(_, px) return px * (opts.scale or 2) end },
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
    env.self = { _listColumns = function() return columns end }
    local h = compile(bodyOf("_listRowHeight"), env, "_listRowHeight")()
    return h, probes
end

t.test("a cover row's budget is the measured text plus the ring band", function()
    -- Sentinels, so the only way to land on 41 + 2*7 is to have composed it
    -- out of the probe's height and ListRow.RING. Any padding term the widget
    -- added back, or a fixed cover height it anchored to instead, misses.
    local h = rowHeight{ font_h = 41, ring = 7 }
    assert(h == 41 + 2 * 7, "expected 55, got " .. tostring(h))
end)

t.test("the ring comes from ListRow, not from SpineWidget's cover ring", function()
    -- SELECTED_BORDER is 7px on a PW5 and would spend 14 of a 49px row on a
    -- band that is page-white unless the row is selected. Changing the ring
    -- must change the budget, or the two have been decoupled.
    local a = rowHeight{ font_h = 41, ring = 2 }
    local b = rowHeight{ font_h = 41, ring = 7 }
    assert(b - a == 2 * (7 - 2), string.format(
        "the ring is not reaching the budget: %d vs %d", a, b))
end)

t.test("a bigger measured line makes a taller budget", function()
    local small = rowHeight{ font_h = 20, ring = 2 }
    local big   = rowHeight{ font_h = 60, ring = 2 }
    assert(big - small == 40, string.format(
        "text height is not driving the row: %d vs %d", small, big))
end)

t.test("a text-only column set still gets the tap-target floor", function()
    -- No cover column: MIN_ROW_DP * scale takes over, and stays untouched.
    local h = rowHeight{ font_h = 20, ring = 2, scale = 2,
                         columns = { { id = "title" }, { id = "author_name" } } }
    assert(h == math.floor(ListGeom.MIN_ROW_H * 2), string.format(
        "expected the floor %d, got %d", math.floor(ListGeom.MIN_ROW_H * 2), h))
end)

t.test("the row widget reads the same two declarations", function()
    -- The third reader. bookshelf_list_row.lua cannot be loaded under a plain
    -- interpreter (it pulls in the whole KOReader widget stack), so this is a
    -- SOURCE-SHAPE check, not a behavioural one -- named as such rather than
    -- dressed up. It exists because the ring has three consumers and the other
    -- two are pinned above: if the row went back to SpineWidget's cover ring or
    -- restated the hairline as Size.line.thin, both of the tests that can
    -- actually execute code would stay green while the render moved.
    -- Comment lines are dropped first: this file explains at length which
    -- Size.* values the dp declarations scale to, and matching that prose
    -- would make the check fire on its own documentation.
    local code = {}
    for line in io.lines("lib/bookshelf_list_row.lua") do
        if not line:match("^%s*%-%-") then code[#code + 1] = line end
    end
    local row = table.concat(code, "\n")
    assert(row:match("ListGeom%.ROW_RING_DP"),
        "the row must scale ListGeom.ROW_RING_DP for its selection ring")
    assert(row:match("ListGeom%.ROW_GAP_DP"),
        "the row must scale ListGeom.ROW_GAP_DP for its divider")
    assert(not row:match("SpineWidget%.SELECTED_BORDER"),
        "the row must not reserve the cover grid's 7px ring")
    assert(not row:match("Size%.line%.thin"),
        "the divider height must come from ROW_GAP_DP, not a second copy")
end)

t.test("the face is measured once and memoised", function()
    -- _listRowHeight is called from _maxRows, _maxShelfRows, _baseShelves and
    -- _rebuild on every rebuild; a TextWidget probe per call is exactly the
    -- kind of per-render cost this plugin has had to fix before.
    local _h, probes = rowHeight{ font_h = 41, ring = 2 }
    assert(probes == 1, "expected one probe per fresh cache, got " .. probes)
end)

t.done()
