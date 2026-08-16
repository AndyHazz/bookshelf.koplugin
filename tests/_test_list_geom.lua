-- tests/_test_list_geom.lua
-- Pure-Lua tests for list-view row geometry.
-- Usage (from plugin root): lua tests/_test_list_geom.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local helpers = dofile("tests/_helpers.lua")
local t       = helpers.runner()

local ListGeom = require("lib/bookshelf_list_geom")

-- Device baselines. Every number here is MEASURED, not invented: each comes
-- from driving KOReader offscreen at that geometry (SDL_VIDEODRIVER=offscreen
-- with EMULATE_READER_W/H/DPI) and reading back what the plugin actually
-- computed. The earlier fabricated `scale = 1.8 / 2.0` figures could not be
-- checked against anything, and a row-count test whose inputs are invented can
-- only ever prove its own arithmetic -- which is how a list view that showed
-- FEWER books than the cover grid passed this file.
--
--   w, h, dpi   the geometry the sweep ran. `dpi` is the screen_dpi override
--               in force; nil means NO override (see scaleBySize below).
--   font_h      rendered height of ListRow's face -- infofont, the CHIP BAR's
--               face, at the chip bar's size 16 -- measured there
--   PAD         _layoutPrimitives' PAD, the cover grid's inter-shelf gap
--   avail       the vertical budget _maxRows(list) hands the expanded shelf
--               block (logged as "[bookshelf perf] _maxRows(list) ... avail=")
--   grid_books  what the COVER grid shows expanded at the same geometry:
--               _nShelves() * _nCols(). This is the number list mode has to
--               beat to justify existing.
--   rows        what list mode ACTUALLY shows expanded, read back from the
--               same sweep. One number, not two: the row height no longer
--               depends on whether the Cover column is on.
--   was_rows    what the PREVIOUS density model showed with covers on, kept so
--               the cost of moving to the chip bar's height is stated in the
--               suite rather than only in a report.
--
-- The first four are the maintainer's calibrated geometries. ALL FOUR are
-- here: an earlier revision listed three and said the 600x800 Kindle was
-- "covered separately below", and nothing below covered it -- which mattered,
-- because that panel was the one where list mode showed 7 rows against the
-- grid's 12. An exemption nobody can find is not an exemption.
local PW5    = { name = "PW5",       w = 1248, h = 1648, dpi = 200,
                 font_h = 45, PAD = 37, avail = 1378, grid_books = 12,
                 rows = 27, was_rows = 27 }
local PW3    = { name = "PW3",       w = 1088, h = 1448, dpi = 200,
                 font_h = 43, PAD = 32, avail = 1201, grid_books = 12,
                 rows = 25, was_rows = 25 }
local KBASIC = { name = "Kindle 600x800", w = 600, h = 800, dpi = 167,
                 font_h = 30, PAD = 18, avail =  639, grid_books = 12,
                 rows = 18, was_rows = 18 }
local LAND   = { name = "landscape", w = 1648, h = 1248, dpi = 200,
                 font_h = 45, PAD = 40, avail =  972, grid_books =  8,
                 rows = 19, was_rows = 19 }

-- The same three Kindles in their OUT-OF-THE-BOX configuration: true panel
-- sizes, and no "screen_dpi" reader setting, which is the default. That
-- setting is the only thing that makes KOReader factor DPI into scaleBySize at
-- all: frontend/device/generic/device.lua reads it and, only if it is
-- non-nil, calls setScreenDPI, which is what raises fb.dpi_override. So a
-- stock Kindle scales by SIZE twice and everything comes out bigger.
--
-- They are pinned here because the four calibrated geometries above all carry
-- an override, and measuring only that configuration hid a real failure once
-- already. They are also the only rows the mm figures in the report can
-- honestly be computed from -- "dpi 200" is an emulator setting, not a panel.
local PW5_STOCK = { name = "PW5 stock",    w = 1236, h = 1648,
                    font_h = 55, PAD = 37, avail = 1332, grid_books = 12,
                    rows = 20, was_rows = 21 }
local PW3_STOCK = { name = "PW3 stock",    w = 1072, h = 1448,
                    font_h = 48, PAD = 32, avail = 1172, grid_books = 12,
                    rows = 21, was_rows = 22 }
local KT4_STOCK = { name = "Kindle stock", w =  600, h =  800,
                    font_h = 26, PAD = 18, avail =  648, grid_books = 12,
                    rows = 20, was_rows = 22 }

local ALL = { PW5, PW3, KBASIC, LAND, PW5_STOCK, PW3_STOCK, KT4_STOCK }

-- KOReader's own scaleBySize, reproduced rather than approximated
-- (ffi/framebuffer.lua:414-425):
--
--   size_scale = min(w, h) / 600
--   dpi_scale  = dpi_override and (dpi / 160) or size_scale
--   scaleBySize(px) = ceil(px * (size_scale + dpi_scale) / 2)
--
-- The dpi_override branch is the one the calibrated sweep exercises and the
-- one an earlier revision of this file baked in unconditionally. Every scaled
-- primitive below (the ring, the hairline, and now the chip strip's height)
-- comes through here, so the test sizes rows exactly as the device does.
local function scaleBySize(dev, px)
    local size_scale = math.min(dev.w, dev.h) / 600
    local dpi_scale  = dev.dpi and (dev.dpi / 160) or size_scale
    return math.ceil(px * (size_scale + dpi_scale) / 2)
end

-- The primitives the density model is made of, ALL read from ListGeom's own
-- declarations. Nothing here restates a number the widget also carries: the
-- previous revision hardcoded the gap as scaleBySize(0.5) with nothing tying it
-- to _listRowGap(), so reverting that one accessor to PAD left this suite green
-- while PW5 dropped below the cover grid it exists to beat.
local function ringOf(dev) return scaleBySize(dev, ListGeom.ROW_RING_DP) end
local function gapOf(dev)  return scaleBySize(dev, ListGeom.ROW_GAP_DP)  end

-- Size.item.height_default is Screen:scaleBySize(30) -- the value the chip
-- strip is built from and the value bookshelf_list_row.lua passes through to
-- ListGeom.chipRowHeight. 30 is KOReader's number, not ours, so it is written
-- out here rather than declared in ListGeom: a copy in our own file would look
-- authoritative and would not be.
local KO_ITEM_HEIGHT_DEFAULT_DP = 30
local function chipHOf(dev, pct)
    return ListGeom.chipRowHeight(
        scaleBySize(dev, KO_ITEM_HEIGHT_DEFAULT_DP), pct or 100)
end

local function rowH(dev, pct)
    return ListGeom.rowHeight{
        chip_h = chipHOf(dev, pct),
        font_h = dev.font_h,
        ring   = ringOf(dev),
    }
end

-- What _maxRows(list) does with those: n rows and n gaps in `avail`, so one
-- gap comes off up front and rowsThatFit counts the (n-1) between the rest.
local function rowsFor(dev, row_h)
    local gap = gapOf(dev)
    return ListGeom.rowsThatFit(dev.avail - gap, row_h, gap)
end

t.test("hasCover detects the cover column by id", function()
    assert(ListGeom.hasCover({ { id = "cover" }, { id = "title" } }) == true)
    assert(ListGeom.hasCover({ { id = "title" } }) == false)
    assert(ListGeom.hasCover({}) == false)
    assert(ListGeom.hasCover(nil) == false)
end)

t.test("the density model is declared in dp, in one place", function()
    -- Both scaled primitives have to be readable from here, or the widget can
    -- move one and this file will not notice.
    assert(type(ListGeom.ROW_RING_DP) == "number", "ROW_RING_DP must be declared")
    assert(type(ListGeom.ROW_GAP_DP) == "number", "ROW_GAP_DP must be declared")
    -- And they must stay the sizes they were chosen to be: the gap is
    -- Size.line.thin (0.5dp), the ring Size.border.default (1dp). A gap that
    -- grew to PAD would silently cost a third of the rows.
    assert(ListGeom.ROW_GAP_DP == 0.5, "the row gap is the hairline rule")
    assert(ListGeom.ROW_RING_DP == 1, "the row ring is a 1dp border")
end)

-- ── The chip bar's sizing ──────────────────────────────────────────────────

t.test("the chip declarations are the chip bar's own", function()
    -- Both are copies of what bookshelf_chip_bar.lua renders with. If either
    -- moves without the chip bar moving, the row stops matching the thing it
    -- was told to match, and nothing else in the suite can see that.
    assert(ListGeom.FONT_FACE == "infofont",
        "the chip strip renders infofont; got " .. tostring(ListGeom.FONT_FACE))
    assert(ListGeom.FONT_SIZE_DP == 16,
        "the chip strip's base size is 16; got " .. tostring(ListGeom.FONT_SIZE_DP))
end)

t.test("scalePercent rounds the way both chip-bar sites round", function()
    -- floor(x + 0.5). Not ceil, not math.floor(x): _layoutPrimitives and the
    -- strip's own _scaled() both round half up, and a row that rounded the
    -- other way would sit a pixel off the chips on half the scales.
    assert(ListGeom.scalePercent(50, 100) == 50)
    assert(ListGeom.scalePercent(50, 150) == 75)
    assert(ListGeom.scalePercent(50, 101) == 51)   -- 50.5 rounds up
    assert(ListGeom.scalePercent(50, 99)  == 50)   -- 49.5 rounds up
    assert(ListGeom.scalePercent(50, nil) == 50)   -- unset scale is 100%
    assert(ListGeom.fontSize(100) == 16)
    assert(ListGeom.fontSize(200) == 32)
    assert(ListGeom.fontSize(50)  == 8)
    -- Degenerate scales must not produce a zero-point font or a zero-height
    -- row; FreeType and the row-count arithmetic both divide by these.
    assert(ListGeom.fontSize(1) >= 1)
    assert(ListGeom.chipRowHeight(0, 100) >= 1)
end)

t.test("the row is the chip strip's height on every baseline", function()
    -- The ruling: a row and a chip are the same tap target. Where the chip is
    -- the taller of the two terms it IS the row, exactly.
    local chip_bound = {}
    for _i, dev in ipairs(ALL) do
        local chip_h = chipHOf(dev)
        local text_h = dev.font_h + 2 * ringOf(dev)
        local h      = rowH(dev)
        assert(h == math.max(chip_h, text_h), string.format(
            "%s: row %d is neither the chip's %d nor the text's %d",
            dev.name, h, chip_h, text_h))
        if chip_h >= text_h then chip_bound[#chip_bound + 1] = dev.name end
    end
    -- WHICH term binds is a measured fact, so it is stated rather than
    -- assumed. On PW3 and the 600x800 Kindle at dpi 200/167 the rendered line
    -- is a few pixels taller than a 30dp chip, so the text wins and the row
    -- comes out slightly TALLER than a chip -- never shorter, which is the
    -- direction that would matter.
    table.sort(chip_bound)
    local got = table.concat(chip_bound, ", ")
    assert(got == "Kindle stock, PW3 stock, PW5, PW5 stock, landscape",
        string.format("the set of panels where the chip's height binds has "
        .. "changed: got \"%s\"", got))
end)

t.test("a line taller than the chip still gets a row that holds it", function()
    -- The text's veto. Without it a large user font clips its own descenders
    -- in every row.
    local h = ListGeom.rowHeight{ chip_h = 20, font_h = 400, ring = 3 }
    assert(h == 406, "row " .. h .. " cannot hold a 400px line")
end)

t.test("the row scales with chip_font_scale, like the chips", function()
    -- The user control the change exists to give. At 200% the chip strip is
    -- twice as tall, so the row must be too (until the font term takes over,
    -- which it does not here: both terms scale together).
    local dev = PW5
    local at100 = chipHOf(dev, 100)
    local at200 = chipHOf(dev, 200)
    assert(at200 == at100 * 2, string.format(
        "chip height did not double: %d -> %d", at100, at200))
    -- The row follows it, given a font that grew by the same factor.
    local big = ListGeom.rowHeight{
        chip_h = at200, font_h = dev.font_h * 2, ring = ringOf(dev) }
    assert(big >= at200, "the row did not follow the chip strip")
end)

t.test("rowHeight has one degenerate guard and no floor", function()
    -- TAP_TARGET_DP used to be a floor on the text-only branch, which is what
    -- made turning the Cover column OFF produce TALLER rows. Re-applying it
    -- would undo the whole change: it is 42dp where a chip is 30dp, so it
    -- would fire on every panel. All that is left is "not zero".
    assert(ListGeom.rowHeight{} == 1, "an empty request must still be 1px")
    assert(ListGeom.rowHeight{ chip_h = 0, font_h = 0, ring = 0 } == 1)
    for _i, dev in ipairs(ALL) do
        local floor_h = math.floor(ListGeom.TAP_TARGET_DP * scaleBySize(dev, 1))
        assert(rowH(dev) < floor_h, string.format(
            "%s: row %d is at or above the old floor %d -- if a change ever "
            .. "pushes it there, the density trade needs re-deciding",
            dev.name, rowH(dev), floor_h))
    end
end)

t.test("the thumbnail is the row minus the ring, at the 2:3 book aspect", function()
    local w, h = ListGeom.thumbSize(90, 6)
    assert(h == 90 - 6 * 2, "thumbnail height should inset by the ring, got " .. h)
    assert(w == math.floor(h / 1.5), "thumbnail width should be h/1.5, got " .. w)
    -- Degenerate rows floor at 1x1 rather than going negative: TextWidget and
    -- ImageWidget both divide by these.
    local dw, dh = ListGeom.thumbSize(4, 10)
    assert(dw >= 1 and dh >= 1, "thumbnail must never be zero or negative")
end)

t.test("the row height and the thumbnail round-trip", function()
    -- ListRow.pageLayout and the two BIM/preload sites all size the thumbnail
    -- by handing thumbSize the ROW height. Taking the ring off once, inside
    -- thumbSize, is what stops a caller warming an 88px cover for a 74px slot.
    -- Measured cover dims from the sweep, in baseline order.
    local expect = { ["PW5"] = { 30, 46 }, ["PW3"] = { 28, 43 },
                     ["Kindle 600x800"] = { 20, 30 }, ["landscape"] = { 30, 46 },
                     ["PW5 stock"] = { 37, 56 }, ["PW3 stock"] = { 33, 50 },
                     ["Kindle stock"] = { 18, 28 } }
    for _i, dev in ipairs(ALL) do
        local cw, ch = ListGeom.thumbSize(rowH(dev), ringOf(dev))
        local want = expect[dev.name]
        assert(cw == want[1] and ch == want[2], string.format(
            "%s: thumbnail %dx%d, sweep rendered %dx%d",
            dev.name, cw, ch, want[1], want[2]))
    end
end)

t.test("rowsThatFit is exact at the boundary", function()
    -- 4 rows of 100 with a 10 gap occupy 4*100 + 3*10 = 430.
    assert(ListGeom.rowsThatFit(430, 100, 10) == 4)
    assert(ListGeom.rowsThatFit(429, 100, 10) == 3)
    assert(ListGeom.rowsThatFit(440, 100, 10) == 4)
    -- One more row needs another 110 (gap + row).
    assert(ListGeom.rowsThatFit(540, 100, 10) == 5)
end)

t.test("rowsThatFit always yields at least one row", function()
    -- Zero rows would render an empty shelf with a live pagination footer,
    -- which reads as a bug rather than a tight screen.
    assert(ListGeom.rowsThatFit(10, 100, 10) == 1)
    assert(ListGeom.rowsThatFit(0, 100, 10) == 1)
    assert(ListGeom.rowsThatFit(-50, 100, 10) == 1)
end)

t.test("a list beats the cover grid on every baseline", function()
    -- THE assertion. Its absence is why a list view that showed 9 rows where
    -- the grid showed 12 books passed this suite: nothing here compared list
    -- mode against the mode it is an alternative to, so "at least 5 rows"
    -- looked healthy while the feature failed its own premise.
    --
    -- It now holds for EVERY column set, not just the default one, because the
    -- row height no longer depends on the column set. Before this pass a
    -- text-only list lost to the grid on the 600x800 Kindle (7 rows to 12) and
    -- on a stock PW5 (10 to 12); both are gone with the branch that caused
    -- them. grid_books is measured at the same geometry in the same sweep, so
    -- it is a like-for-like count of books on screen, not two budgets.
    for _i, dev in ipairs(ALL) do
        local rows = rowsFor(dev, rowH(dev))
        assert(rows > dev.grid_books, string.format(
            "%s: list shows %d rows (row_h=%d gap=%d avail=%d), the cover grid "
            .. "shows %d books -- list view has to show MORE, not fewer",
            dev.name, rows, rowH(dev), gapOf(dev), dev.avail, dev.grid_books))
    end
end)

t.test("the row count matches what the sweep actually rendered", function()
    -- The arithmetic above is only worth anything if it lands on the same
    -- number the device does. Each `rows` came from the expanded list shot's
    -- own "[bookshelf perf] _maxRows(list)=" line at that geometry.
    for _i, dev in ipairs(ALL) do
        local rows = rowsFor(dev, rowH(dev))
        assert(rows == dev.rows, string.format(
            "%s: computed %d rows, the sweep rendered %d", dev.name, rows, dev.rows))
    end
end)

t.test("what the chip's height cost in density, stated", function()
    -- The trade, in the suite rather than only in a report. Four of the seven
    -- baselines keep exactly the rows they had; the three that lose, lose one
    -- or two, and the worst case is a stock 600x800 Kindle at 22 -> 20.
    -- If a future change makes that worse, this is the line that says so.
    local worst = 0
    for _i, dev in ipairs(ALL) do
        local lost = dev.was_rows - dev.rows
        assert(lost >= 0, string.format(
            "%s gained rows (%d -> %d) -- update was_rows rather than leaving "
            .. "the comparison stale", dev.name, dev.was_rows, dev.rows))
        if lost > worst then worst = lost end
    end
    assert(worst == 2, "the worst density loss is now " .. worst .. " rows, not 2")
end)

t.test("turning the cover column off no longer changes anything", function()
    -- The inversion, gone by construction: rowHeight has no has_cover input to
    -- branch on. This asserts the SIGNATURE, because that is what made the old
    -- behaviour possible -- a caller that starts passing has_cover again gets
    -- an ignored argument, not a second density model.
    for _i, dev in ipairs(ALL) do
        local with_flag = ListGeom.rowHeight{
            chip_h = chipHOf(dev), font_h = dev.font_h, ring = ringOf(dev),
            has_cover = false, scale = scaleBySize(dev, 1) }
        assert(with_flag == rowH(dev), string.format(
            "%s: has_cover still moves the row (%d vs %d)",
            dev.name, with_flag, rowH(dev)))
    end
end)

t.done()
