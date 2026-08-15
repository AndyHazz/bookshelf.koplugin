-- tests/_test_list_geom.lua
-- Pure-Lua tests for list-view row geometry.
-- Usage (from plugin root): lua tests/_test_list_geom.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local helpers = dofile("tests/_helpers.lua")
local t       = helpers.runner()

local ListGeom = require("lib/bookshelf_list_geom")

-- Device baselines, matching the ones tests/_test_tall_screen.lua uses.
--   PW5:       1236x1648 @ 264dpi, scaleBySize factor ~1.8
--   PW3:        1072x1448 @ 300dpi
--   landscape:  1448x1072
local PW5  = { w = 1236, h = 1648, scale = 1.8 }
local PW3  = { w = 1072, h = 1448, scale = 2.0 }
local LAND = { w = 1448, h = 1072, scale = 2.0 }

t.test("hasCover detects the cover column by id", function()
    assert(ListGeom.hasCover({ { id = "cover" }, { id = "title" } }) == true)
    assert(ListGeom.hasCover({ { id = "title" } }) == false)
    assert(ListGeom.hasCover({}) == false)
    assert(ListGeom.hasCover(nil) == false)
end)

t.test("a cover row is taller than a text row", function()
    -- The whole density story rests on this: dropping the cover column is how
    -- a user gets more rows per page.
    local with    = ListGeom.rowHeight{ has_cover = true,  font_h = 30, pad = 8, scale = PW5.scale }
    local without = ListGeom.rowHeight{ has_cover = false, font_h = 30, pad = 8, scale = PW5.scale }
    assert(with > without, string.format("cover=%d text=%d", with, without))
end)

t.test("row height never drops below the tap-target floor", function()
    -- A row is a tap target. Below roughly 9mm it stops being reliably
    -- tappable on e-ink, and a stray tap opens the wrong book.
    local tiny = ListGeom.rowHeight{ has_cover = false, font_h = 1, pad = 0, scale = 1 }
    assert(tiny >= ListGeom.MIN_ROW_H, string.format(
        "got %d, floor is %d", tiny, ListGeom.MIN_ROW_H))
end)

t.test("cover size keeps the 2:3 book aspect", function()
    local w, h = ListGeom.coverSize(90, 6)
    assert(h == 90 - 6 * 2, "cover height should inset by pad, got " .. h)
    assert(w == math.floor(h / 1.5), "cover width should be h/1.5, got " .. w)
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

t.test("list mode shows more rows than the cover grid on every baseline", function()
    -- The point of the feature. The cover grid fits 2-4 rows of covers; a
    -- text list must comfortably beat that or there is no reason to build it.
    for _i, dev in ipairs({ PW5, PW3, LAND }) do
        local row_h = ListGeom.rowHeight{
            has_cover = false, font_h = math.floor(16 * dev.scale),
            pad = math.floor(4 * dev.scale), scale = dev.scale,
        }
        -- Budget roughly what the shelf block gets: screen minus hero, chips
        -- and footer. Two thirds is a deliberately conservative stand-in.
        local avail = math.floor(dev.h * 0.66)
        local rows  = ListGeom.rowsThatFit(avail, row_h, math.floor(2 * dev.scale))
        assert(rows >= 8, string.format(
            "only %d rows at %dx%d (row_h=%d avail=%d)",
            rows, dev.w, dev.h, row_h, avail))
    end
end)

t.test("cover rows still fit a useful count", function()
    for _i, dev in ipairs({ PW5, PW3 }) do
        local row_h = ListGeom.rowHeight{
            has_cover = true, font_h = math.floor(16 * dev.scale),
            pad = math.floor(4 * dev.scale), scale = dev.scale,
        }
        local avail = math.floor(dev.h * 0.66)
        local rows  = ListGeom.rowsThatFit(avail, row_h, math.floor(2 * dev.scale))
        assert(rows >= 5, string.format(
            "only %d cover rows at %dx%d (row_h=%d)", rows, dev.w, dev.h, row_h))
    end
end)

t.done()
