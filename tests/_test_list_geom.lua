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
--   w, h, dpi   the four geometries the layout sweep runs (the maintainer's
--               real devices; the 600x800 Kindle is covered separately below)
--   font_h      rendered height of ListRow's face (cfont at size 16) there
--   PAD         _layoutPrimitives' PAD, the cover grid's inter-shelf gap
--   avail       the vertical budget _maxRows(list) hands the expanded shelf
--               block (logged as "[bookshelf perf] _maxRows(list) ... avail=")
--   grid_books  what the COVER grid shows expanded at the same geometry:
--               _nShelves() * _nCols(). This is the number list mode has to
--               beat to justify existing.
local PW5  = { name = "PW5",       w = 1248, h = 1648, dpi = 200,
               font_h = 45, PAD = 37, avail = 1378, grid_books = 12 }
local PW3  = { name = "PW3",       w = 1088, h = 1448, dpi = 200,
               font_h = 43, PAD = 32, avail = 1201, grid_books = 12 }
local LAND = { name = "landscape", w = 1648, h = 1248, dpi = 200,
               font_h = 45, PAD = 40, avail =  972, grid_books =  8 }
local ALL  = { PW5, PW3, LAND }

-- KOReader's own scaleBySize, reproduced rather than approximated:
-- ceil(px * (min(w,h)/600 + dpi/160) / 2), ffi/framebuffer.lua:414-425. Every
-- scaled primitive below (padding, the ring, the hairline, the cover target)
-- comes through here, so the test sizes rows exactly as the device does --
-- verified against the sweep: 96px rows on PW5, 90 on PW3, 96 in landscape.
local function scaleBySize(dev, px)
    return math.ceil(px * (math.min(dev.w, dev.h) / 600 + dev.dpi / 160) / 2)
end

-- The primitives ListRow and bookshelf_widget feed into rowHeight.
local function padOf(dev)  return scaleBySize(dev, 2)   end  -- Size.padding.small
local function ringOf(dev) return scaleBySize(dev, 4)   end  -- SELECTED_BORDER
local function gapOf(dev)  return scaleBySize(dev, 0.5) end  -- Size.line.thin
local function coverOf(dev) return scaleBySize(dev, ListGeom.COVER_H_DP) end

local function coverRowH(dev)
    return ListGeom.rowHeight{
        has_cover = true, font_h = dev.font_h, pad = padOf(dev),
        ring = ringOf(dev), cover_h = coverOf(dev),
        scale = scaleBySize(dev, 1),
    }
end

local function textRowH(dev)
    return ListGeom.rowHeight{
        has_cover = false, font_h = dev.font_h, pad = padOf(dev),
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

t.test("a cover row is the cover plus padding, not a multiple of the font", function()
    -- The inversion this file exists to protect. A cover row is
    -- cover + pad + ring on each side and nothing else; changing the font
    -- must not change it (the old font_h * 2.4 model is what left list mode
    -- less dense than the grid).
    local dev = PW5
    local small = ListGeom.rowHeight{
        has_cover = true, font_h = 20, pad = padOf(dev), ring = ringOf(dev),
        cover_h = coverOf(dev), scale = scaleBySize(dev, 1),
    }
    local big = ListGeom.rowHeight{
        has_cover = true, font_h = 45, pad = padOf(dev), ring = ringOf(dev),
        cover_h = coverOf(dev), scale = scaleBySize(dev, 1),
    }
    assert(small == big, string.format("font changed the row: %d vs %d", small, big))
    assert(small == coverOf(dev) + 2 * padOf(dev) + 2 * ringOf(dev),
        string.format("row %d is not cover %d + pads", small, coverOf(dev)))
end)

t.test("a cover row still grows to hold an oversized font", function()
    -- A user font scale big enough to out-measure the thumbnail must not get
    -- its descenders clipped.
    local dev = PW5
    local h = ListGeom.rowHeight{
        has_cover = true, font_h = 400, pad = padOf(dev), ring = ringOf(dev),
        cover_h = coverOf(dev), scale = scaleBySize(dev, 1),
    }
    assert(h >= 400 + 2 * padOf(dev), "row " .. h .. " cannot hold a 400px line")
end)

t.test("a cover row is taller than a text row", function()
    -- Dropping the cover column is still how a user buys more rows per page.
    for _i, dev in ipairs(ALL) do
        local with, without = coverRowH(dev), textRowH(dev)
        assert(with > without, string.format(
            "%s: cover=%d text=%d", dev.name, with, without))
    end
end)

t.test("row height never drops below the tap-target floor", function()
    -- A row is a tap target. Below roughly 9mm it stops being reliably
    -- tappable on e-ink, and a stray tap opens the wrong book.
    local tiny = ListGeom.rowHeight{ has_cover = false, font_h = 1, pad = 0, scale = 1 }
    assert(tiny >= ListGeom.MIN_ROW_H, string.format(
        "got %d, floor is %d", tiny, ListGeom.MIN_ROW_H))
    -- And the floor still applies to the cover-anchored branch: a tiny cover
    -- target must not produce a row too small to hit.
    local squat = ListGeom.rowHeight{
        has_cover = true, font_h = 10, pad = 1, ring = 1, cover_h = 4, scale = 1 }
    assert(squat >= ListGeom.MIN_ROW_H, string.format(
        "cover row %d is under the floor %d", squat, ListGeom.MIN_ROW_H))
end)

t.test("the tap-target floor clears at the tightened density", function()
    -- The density change must not have bought its rows by shrinking them
    -- below a reliable tap. On these three the cover-anchored height wins
    -- outright; the floor is there for smaller panels.
    for _i, dev in ipairs(ALL) do
        local floor_h = math.floor(ListGeom.MIN_ROW_H * scaleBySize(dev, 1))
        assert(coverRowH(dev) >= floor_h, string.format(
            "%s: row %d under floor %d", dev.name, coverRowH(dev), floor_h))
    end
end)

t.test("cover size keeps the 2:3 book aspect", function()
    local w, h = ListGeom.coverSize(90, 6)
    assert(h == 90 - 6 * 2, "cover height should inset by pad, got " .. h)
    assert(w == math.floor(h / 1.5), "cover width should be h/1.5, got " .. w)
end)

t.test("the row height and the cover target round-trip", function()
    -- ListRow.pageLayout takes the row height back apart (content_h =
    -- row_h - 2*ring, then coverSize insets the pad) to size the thumbnail.
    -- If that doesn't land back on COVER_H_DP the row reserves space for a
    -- cover of one size and draws one of another.
    for _i, dev in ipairs(ALL) do
        local pad, ring = padOf(dev), ringOf(dev)
        local _cw, ch = ListGeom.coverSize(coverRowH(dev) - 2 * ring, pad)
        assert(ch == coverOf(dev), string.format(
            "%s: asked for %d, row yields %d", dev.name, coverOf(dev), ch))
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

t.test("a list of covers beats the cover grid on every baseline", function()
    -- THE assertion. Its absence is why a list view that showed 9 rows where
    -- the grid showed 12 books passed this suite: nothing here compared list
    -- mode against the mode it is an alternative to, so "at least 5 rows"
    -- looked healthy while the feature failed its own premise.
    --
    -- grid_books is measured at the same geometry in the same sweep, so this
    -- is a like-for-like count of books on screen, not two budgets.
    for _i, dev in ipairs(ALL) do
        local rows = rowsFor(dev, coverRowH(dev))
        assert(rows > dev.grid_books, string.format(
            "%s: list shows %d rows (row_h=%d gap=%d avail=%d), the cover grid "
            .. "shows %d books -- list view has to show MORE, not fewer",
            dev.name, rows, coverRowH(dev), gapOf(dev), dev.avail, dev.grid_books))
    end
end)

t.test("a list of text rows beats the cover grid too", function()
    -- Same bar for the column set with the cover turned off. That path is
    -- floored by MIN_ROW_DP rather than by the font on all three panels, which
    -- is why it was already dense enough.
    for _i, dev in ipairs(ALL) do
        local rows = rowsFor(dev, textRowH(dev))
        assert(rows > dev.grid_books, string.format(
            "%s: %d text rows against %d grid books (row_h=%d)",
            dev.name, rows, dev.grid_books, textRowH(dev)))
    end
end)

t.test("cover rows fit a useful count", function()
    -- Measured after the density fix: 14 rows on PW5, 13 on PW3, 10 in
    -- landscape (before it: 9, 8, 6). The bar sits at the weakest of the
    -- three; the grid comparison above is the assertion that actually pins
    -- the density, this one just refuses a collapse.
    for _i, dev in ipairs(ALL) do
        local rows = rowsFor(dev, coverRowH(dev))
        assert(rows >= 10, string.format(
            "only %d cover rows on %s (row_h=%d)", rows, dev.name, coverRowH(dev)))
    end
end)

t.done()
