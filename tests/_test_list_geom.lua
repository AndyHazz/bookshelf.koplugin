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
--   font_h      rendered height of ListRow's face (cfont at size 16) there
--   PAD         _layoutPrimitives' PAD, the cover grid's inter-shelf gap
--   avail       the vertical budget _maxRows(list) hands the expanded shelf
--               block (logged as "[bookshelf perf] _maxRows(list) ... avail=")
--   grid_books  what the COVER grid shows expanded at the same geometry:
--               _nShelves() * _nCols(). This is the number list mode has to
--               beat to justify existing.
--   rows        what list mode ACTUALLY shows expanded with the default
--               (cover-bearing) column set, read back from the same sweep.
--
-- The first four are the maintainer's calibrated geometries. ALL FOUR are
-- here: an earlier revision listed three and said the 600x800 Kindle was
-- "covered separately below", and nothing below covered it -- which mattered,
-- because that panel was the one where list mode showed 7 rows against the
-- grid's 12. An exemption nobody can find is not an exemption.
local PW5    = { name = "PW5",       w = 1248, h = 1648, dpi = 200,
                 font_h = 45, PAD = 37, avail = 1378, grid_books = 12, rows = 27 }
local PW3    = { name = "PW3",       w = 1088, h = 1448, dpi = 200,
                 font_h = 43, PAD = 32, avail = 1201, grid_books = 12, rows = 25 }
local KBASIC = { name = "Kindle 600x800", w = 600, h = 800, dpi = 167,
                 font_h = 30, PAD = 18, avail =  639, grid_books = 12, rows = 18 }
local LAND   = { name = "landscape", w = 1648, h = 1248, dpi = 200,
                 font_h = 45, PAD = 40, avail =  972, grid_books =  8, rows = 19 }

-- The same three Kindles in their OUT-OF-THE-BOX configuration: true panel
-- sizes, and no "screen_dpi" reader setting, which is the default. That
-- setting is the only thing that makes KOReader factor DPI into scaleBySize at
-- all: frontend/device/generic/device.lua:338-341 reads it and, only if it is
-- non-nil, calls setScreenDPI, which is what raises fb.dpi_override. So a
-- stock Kindle scales by SIZE twice and everything comes out bigger.
--
-- They are pinned here because the four calibrated geometries above all carry
-- an override, and measuring only that configuration hid a real failure: under
-- the previous density model a stock PW5 showed 10 list rows against the same
-- grid's 12, and a stock PW3 and Kindle 11 against 12 -- i.e. the model that
-- looked like it had cleared the bar at dpi200 had not cleared it on any of
-- the three devices as they ship.
local PW5_STOCK = { name = "PW5 stock",    w = 1236, h = 1648,
                    font_h = 55, PAD = 37, avail = 1332, grid_books = 12, rows = 21 }
local PW3_STOCK = { name = "PW3 stock",    w = 1072, h = 1448,
                    font_h = 48, PAD = 32, avail = 1172, grid_books = 12, rows = 22 }
local KT4_STOCK = { name = "Kindle stock", w =  600, h =  800,
                    font_h = 26, PAD = 18, avail =  648, grid_books = 12, rows = 22 }

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
-- primitive below (the ring, the hairline) comes through here, so the test
-- sizes rows exactly as the device does -- verified against the sweep: 49px
-- rows on PW5, 47 on PW3, 34 on the 600x800 Kindle, 49 in landscape, and
-- 61 / 52 / 28 on the three stock Kindles.
local function scaleBySize(dev, px)
    local size_scale = math.min(dev.w, dev.h) / 600
    local dpi_scale  = dev.dpi and (dev.dpi / 160) or size_scale
    return math.ceil(px * (size_scale + dpi_scale) / 2)
end

-- The two primitives the density model is made of, BOTH read from ListGeom's
-- own dp declarations. Nothing here restates a number the widget also carries:
-- the previous revision hardcoded the gap as scaleBySize(0.5) with nothing
-- tying it to _listRowGap(), so reverting that one accessor to PAD left this
-- suite green while PW5 dropped below the cover grid it exists to beat.
local function ringOf(dev) return scaleBySize(dev, ListGeom.ROW_RING_DP) end
local function gapOf(dev)  return scaleBySize(dev, ListGeom.ROW_GAP_DP)  end

local function coverRowH(dev)
    return ListGeom.rowHeight{
        has_cover = true, font_h = dev.font_h, ring = ringOf(dev),
        scale = scaleBySize(dev, 1),
    }
end

local function textRowH(dev)
    return ListGeom.rowHeight{
        has_cover = false, font_h = dev.font_h, ring = ringOf(dev),
        scale = scaleBySize(dev, 1),
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
    -- Finding B's structural half. Both scaled primitives have to be readable
    -- from here, or the widget can move one and this file will not notice.
    assert(type(ListGeom.ROW_RING_DP) == "number", "ROW_RING_DP must be declared")
    assert(type(ListGeom.ROW_GAP_DP) == "number", "ROW_GAP_DP must be declared")
    -- And they must stay the sizes they were chosen to be: the gap is
    -- Size.line.thin (0.5dp), the ring Size.border.default (1dp). A gap that
    -- grew to PAD would silently cost a third of the rows.
    assert(ListGeom.ROW_GAP_DP == 0.5, "the row gap is the hairline rule")
    assert(ListGeom.ROW_RING_DP == 1, "the row ring is a 1dp border")
end)

t.test("a cover row is the text plus the ring band, nothing else", function()
    -- The inversion this file exists to protect, now the other way up. A row
    -- is its own line of text plus the selection-ring reservation on each
    -- side -- the cover fits the row, so nothing about the thumbnail can push
    -- the row taller.
    for _i, dev in ipairs(ALL) do
        local h = coverRowH(dev)
        assert(h == dev.font_h + 2 * ringOf(dev), string.format(
            "%s: row %d is not font %d + 2*ring %d",
            dev.name, h, dev.font_h, ringOf(dev)))
    end
end)

t.test("a bigger font makes a taller row", function()
    -- The cover-anchored model deliberately ignored the font. This one must
    -- not: the row IS the text, so a user font scale that grows the line has
    -- to grow the row or the descenders clip.
    local dev = PW5
    local small = ListGeom.rowHeight{
        has_cover = true, font_h = 20, ring = ringOf(dev), scale = scaleBySize(dev, 1) }
    local big = ListGeom.rowHeight{
        has_cover = true, font_h = 400, ring = ringOf(dev), scale = scaleBySize(dev, 1) }
    assert(big > small, string.format("font did not move the row: %d vs %d", small, big))
    assert(big >= 400, "row " .. big .. " cannot hold a 400px line")
end)

t.test("the tap-target floor governs text-only rows and ONLY those", function()
    -- The ruling this density pass was given: go as tight as the text allows,
    -- and let the floor stop governing cover-bearing rows. A ~49px row on a
    -- 264dpi panel is about half the usual 9mm guideline; the mitigation is
    -- that a tap in collapsed list mode previews rather than opens.
    --
    -- The text-only path keeps the floor untouched -- it has no thumbnail to
    -- shrink and nobody has complained about it.
    local tiny = ListGeom.rowHeight{ has_cover = false, font_h = 1, ring = 0, scale = 1 }
    assert(tiny >= ListGeom.MIN_ROW_H, string.format(
        "got %d, floor is %d", tiny, ListGeom.MIN_ROW_H))
    local squat = ListGeom.rowHeight{
        has_cover = true, font_h = 10, ring = 1, scale = 1 }
    assert(squat == 12, string.format(
        "a cover row must be text-tight, not floored: got %d", squat))
end)

t.test("every baseline's cover row is under the old tap-target floor", function()
    -- Stated as an assertion rather than a comment so the trade is visible in
    -- the suite: on all four panels the new row is BELOW MIN_ROW_H * scale,
    -- which is exactly the thing the controller signed off. If a future change
    -- pushes rows back above it, this test says so and the mitigation
    -- (tap-previews, double-tap-opens) can be reconsidered.
    for _i, dev in ipairs(ALL) do
        local floor_h = math.floor(ListGeom.MIN_ROW_H * scaleBySize(dev, 1))
        assert(coverRowH(dev) < floor_h, string.format(
            "%s: cover row %d is no longer under the old floor %d",
            dev.name, coverRowH(dev), floor_h))
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
    -- thumbSize, is what stops a caller warming an 88px cover for a 74px slot
    -- -- so the round trip has to land exactly on the row's own text height.
    -- Measured cover dims from the sweep, in baseline order: 30x45, 28x43,
    -- 20x30, 30x45, then the stock Kindles at 36x55, 32x48, 17x26.
    local expect = { ["PW5"] = 30, ["PW3"] = 28, ["Kindle 600x800"] = 20,
                     ["landscape"] = 30, ["PW5 stock"] = 36,
                     ["PW3 stock"] = 32, ["Kindle stock"] = 17 }
    for _i, dev in ipairs(ALL) do
        local cw, ch = ListGeom.thumbSize(coverRowH(dev), ringOf(dev))
        assert(ch == dev.font_h, string.format(
            "%s: thumbnail %d should be the row's text height %d",
            dev.name, ch, dev.font_h))
        assert(cw == expect[dev.name], string.format(
            "%s: thumbnail width %d, sweep rendered %d",
            dev.name, cw, expect[dev.name]))
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
    -- The column set is the DEFAULT one (Columns.DEFAULT_IDS starts with
    -- "cover"), which is what every user sees until they go and change it, so
    -- this is the property that decides whether the mode is worth having.
    -- grid_books is measured at the same geometry in the same sweep, so it is
    -- a like-for-like count of books on screen, not two budgets.
    for _i, dev in ipairs(ALL) do
        local rows = rowsFor(dev, coverRowH(dev))
        assert(rows > dev.grid_books, string.format(
            "%s: list shows %d rows (row_h=%d gap=%d avail=%d), the cover grid "
            .. "shows %d books -- list view has to show MORE, not fewer",
            dev.name, rows, coverRowH(dev), gapOf(dev), dev.avail, dev.grid_books))
    end
end)

t.test("the row count matches what the sweep actually rendered", function()
    -- The arithmetic above is only worth anything if it lands on the same
    -- number the device does. Each `rows` came from the expanded list shot's
    -- own "[bookshelf perf] _maxRows(list)=" line at that geometry.
    for _i, dev in ipairs(ALL) do
        local rows = rowsFor(dev, coverRowH(dev))
        assert(rows == dev.rows, string.format(
            "%s: computed %d rows, the sweep rendered %d", dev.name, rows, dev.rows))
    end
end)

t.test("text-only rows sit on the tap-target floor, and what that costs", function()
    -- The column set with the cover turned off is floored by MIN_ROW_DP on
    -- every panel, so it is the FLOOR, not the font, that sets its density --
    -- and dropping the cover column now makes rows TALLER, not shorter,
    -- because cover rows are text-tight and this one is not. That is the
    -- deliberate consequence of leaving MIN_ROW_DP governing this path.
    --
    -- Pinned per device rather than compared against the grid, because on two
    -- of the seven it does NOT beat the grid: the 600x800 Kindle at 7 rows
    -- against 12 books, and a stock PW5 at 10 against 12. Those shortfalls are
    -- stated here, in the suite, rather than in a report -- if either is ever
    -- judged unacceptable, this is the line that has to change, and the only
    -- lever is MIN_ROW_DP, which this pass was told not to touch.
    local expect_rows = { ["PW5"] = 16, ["PW3"] = 14, ["Kindle 600x800"] = 7,
                          ["landscape"] = 11, ["PW5 stock"] = 10,
                          ["PW3 stock"] = 13, ["Kindle stock"] = 15 }
    local shortfalls = {}
    for _i, dev in ipairs(ALL) do
        local floor_h = math.floor(ListGeom.MIN_ROW_H * scaleBySize(dev, 1))
        assert(textRowH(dev) == floor_h, string.format(
            "%s: text row %d is not the floor %d", dev.name, textRowH(dev), floor_h))
        assert(textRowH(dev) > coverRowH(dev), string.format(
            "%s: text row %d should out-measure the text-tight cover row %d",
            dev.name, textRowH(dev), coverRowH(dev)))
        local rows = rowsFor(dev, textRowH(dev))
        assert(rows == expect_rows[dev.name], string.format(
            "%s: %d text rows, expected %d", dev.name, rows,
            tostring(expect_rows[dev.name])))
        if rows <= dev.grid_books then shortfalls[#shortfalls + 1] = dev.name end
    end
    table.sort(shortfalls)
    local got = table.concat(shortfalls, ", ")
    assert(got == "Kindle 600x800, PW5 stock", string.format(
        "the set of panels where a text-only list loses to the cover grid has "
        .. "changed: expected \"Kindle 600x800, PW5 stock\", got \"%s\"", got))
end)

t.done()
