-- tests/_test_band_metrics.lua
-- lib/bookshelf_band_metrics.lua: the one declaration of how a tap band is
-- sized, and the separation of the two keys that drive it.
--
-- Behavioural, not source-shape: the module's only two dependencies on the
-- KOReader runtime are `ui/size` (a plain table of numbers) and the settings
-- store (a read), so both stub cleanly and the REAL module runs. That matters
-- here more than usual -- the whole point of the file is that two surfaces get
-- independent answers from one derivation, and only running it can show that.
--
-- Usage (from plugin root): lua tests/_test_band_metrics.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

local t  = dofile("tests/_helpers.lua").runner()
local eq = dofile("tests/_helpers.lua").eq

-- Stub the two environment reads BEFORE requiring the module.
--
-- ITEM_H is a Paperwhite 5's real Size.item.height_default -- Screen:scaleBySize(30)
-- at 1248x1648 dpi 200 -- and BORDER its Size.border.thin, both read out of the
-- offscreen sweep. Real numbers rather than round ones so the expected values
-- below are the ones a device actually produces.
local ITEM_H = 50
local BORDER = 1
package.loaded["ui/size"] = {
    item   = { height_default = ITEM_H },
    border = { thin = BORDER },
}

local store = {}
package.loaded["lib/bookshelf_settings_store"] = {
    read = function(key, default)
        local v = store[key]
        if v == nil then return default end
        return v
    end,
}

local ListGeom    = require("lib/bookshelf_list_geom")
local BandMetrics = require("lib/bookshelf_band_metrics")

local CHIP, LIST = BandMetrics.CHIP_KEY, BandMetrics.LIST_KEY

local function reset() store = {} end

-- ── The keys ───────────────────────────────────────────────────────────────

t.test("both keys are declared, and the chip key keeps its historical name", function()
    -- chip_font_scale predates list view and is what a user's existing
    -- settings file holds. Renaming it would silently reset every install.
    eq(CHIP, "chip_font_scale")
    eq(LIST, "list_font_scale")
    assert(CHIP ~= LIST, "the two surfaces must not share a key")
    eq(BandMetrics.DEFAULT_SCALE, 100)
end)

t.test("an unset key reads as 100, and so does a nonsense one", function()
    reset()
    eq(BandMetrics.scale(CHIP), 100)
    eq(BandMetrics.scale(LIST), 100)
    -- A hand-edited settings file is the only way to get here; 100 beats an
    -- arithmetic error on the home screen.
    store[LIST] = "150"
    eq(BandMetrics.scale(LIST), 100)
    store[LIST] = true
    eq(BandMetrics.scale(LIST), 100)
    reset()
end)

-- ── Parity at the defaults ─────────────────────────────────────────────────

t.test("at 100 on both keys the two bands are identical", function()
    -- The migration promise: separating the keys must not move a pixel for
    -- anyone who has not touched either setting. Every derivation, both keys.
    reset()
    eq(BandMetrics.cellHeight(CHIP),    BandMetrics.cellHeight(LIST))
    eq(BandMetrics.paintedHeight(CHIP), BandMetrics.paintedHeight(LIST))
    eq(BandMetrics.fontSize(CHIP),      BandMetrics.fontSize(LIST))
    eq(BandMetrics.scaled(18, CHIP),    BandMetrics.scaled(18, LIST))
    -- And they are the numbers the pre-separation code produced, spelled out
    -- as the literal arithmetic those call sites carried rather than as
    -- another call into ListGeom (which would only assert ListGeom == itself).
    eq(BandMetrics.cellHeight(CHIP), math.floor(ITEM_H * 100 / 100 + 0.5))
    eq(BandMetrics.cellHeight(CHIP), 50)
    eq(BandMetrics.fontSize(CHIP), math.floor(16 * 100 / 100 + 0.5))
    eq(BandMetrics.fontSize(CHIP), 16)
    -- The painted band is the cell plus the strip frame's border twice: 52 on
    -- a Paperwhite 5, measured (see ListGeom.CHIP_BORDER_DP).
    eq(BandMetrics.paintedHeight(CHIP), 52)
end)

-- ── Independence: the whole point of the change ────────────────────────────

t.test("moving the list scale does not move the chip band", function()
    -- THE assertion. If a future change re-couples the two -- a copied string
    -- literal, a shared local, a helper that defaults to the wrong key -- this
    -- is the line that fires.
    reset()
    local chip_cell_before  = BandMetrics.cellHeight(CHIP)
    local chip_paint_before = BandMetrics.paintedHeight(CHIP)
    local chip_font_before  = BandMetrics.fontSize(CHIP)

    store[LIST] = 150
    eq(BandMetrics.cellHeight(CHIP),    chip_cell_before,  "list scale moved the chip cell")
    eq(BandMetrics.paintedHeight(CHIP), chip_paint_before, "list scale moved the chip band")
    eq(BandMetrics.fontSize(CHIP),      chip_font_before,  "list scale moved the chip font")
    -- ...and it did move the list side, or the test above proves nothing.
    eq(BandMetrics.cellHeight(LIST), 75)
    eq(BandMetrics.fontSize(LIST), 24)
    reset()
end)

t.test("moving the chip scale does not move the list row", function()
    reset()
    local list_cell_before  = BandMetrics.cellHeight(LIST)
    local list_paint_before = BandMetrics.paintedHeight(LIST)
    local list_font_before  = BandMetrics.fontSize(LIST)

    store[CHIP] = 200
    eq(BandMetrics.cellHeight(LIST),    list_cell_before,  "chip scale moved the list cell")
    eq(BandMetrics.paintedHeight(LIST), list_paint_before, "chip scale moved the list band")
    eq(BandMetrics.fontSize(LIST),      list_font_before,  "chip scale moved the list font")
    eq(BandMetrics.cellHeight(CHIP), 100)
    eq(BandMetrics.fontSize(CHIP), 32)
    reset()
end)

t.test("the two keys hold different values at the same time", function()
    -- The state a user who has tuned both is actually in. Neither reading may
    -- leak into the other.
    reset()
    store[CHIP] = 80
    store[LIST] = 130
    eq(BandMetrics.scale(CHIP), 80)
    eq(BandMetrics.scale(LIST), 130)
    eq(BandMetrics.cellHeight(CHIP), 40)    -- floor(50 * 0.8 + 0.5)
    eq(BandMetrics.cellHeight(LIST), 65)    -- floor(50 * 1.3 + 0.5)
    eq(BandMetrics.fontSize(CHIP), 13)      -- floor(16 * 0.8 + 0.5)
    eq(BandMetrics.fontSize(LIST), 21)      -- floor(16 * 1.3 + 0.5)
    reset()
end)

-- ── The derivation itself ──────────────────────────────────────────────────

t.test("the height is the pre-separation arithmetic, at every scale", function()
    -- bookshelf_widget.lua carried this expression inline in two places and
    -- bookshelf_list_row.lua a third time. It now lives here once; this is the
    -- statement that "once" did not change the answer.
    reset()
    for pct = 50, 300 do
        store[CHIP] = pct
        eq(BandMetrics.cellHeight(CHIP), math.floor(ITEM_H * pct / 100 + 0.5),
            "cellHeight diverged at " .. pct .. "%")
        eq(BandMetrics.fontSize(CHIP), math.floor(16 * pct / 100 + 0.5),
            "fontSize diverged at " .. pct .. "%")
        eq(BandMetrics.scaled(18, CHIP), math.floor(18 * pct / 100 + 0.5),
            "scaled(18) diverged at " .. pct .. "%")
    end
    reset()
end)

t.test("the painted band adds the strip's border twice, unscaled", function()
    -- A FrameContainer's bordersize does not know about a font scale, so the
    -- border comes off both sides of any comparison across scales.
    reset()
    for _i, pct in ipairs({ 50, 100, 175, 300 }) do
        store[LIST] = pct
        eq(BandMetrics.paintedHeight(LIST),
           BandMetrics.cellHeight(LIST) + 2 * BORDER,
           "the band is not the cell plus two borders at " .. pct .. "%")
    end
    reset()
end)

t.test("the base font size is ListGeom's, not a second copy", function()
    -- If bookshelf_chip_bar.lua's base size ever moves, it moves in ListGeom
    -- and both surfaces follow. A literal 16 here would let them split.
    eq(ListGeom.FONT_SIZE_DP, 16)
    reset()
    store[LIST] = 100
    eq(BandMetrics.fontSize(LIST), ListGeom.FONT_SIZE_DP)
    reset()
end)

t.done()
