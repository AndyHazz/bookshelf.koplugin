-- tests/_test_spine_lift_gap.lua
-- What fills the space a lifted book leaves on a spine shelf.
--
-- Usage (from plugin root): lua tests/_test_spine_lift_gap.lua
--
-- THE TWO LOOKS IT REPLACES. Over a wallpaper, a solid black box (a translucent
-- ramp whose alpha the device's BB8A buffer dropped, kept because it read
-- well -- and reported as "a thick black bar" in #446). On a plain page, a
-- banded reproduction of the plank with full-strength strips down each side,
-- which never matched the plank around it (maintainer: glitchy).
--
-- THE MAINTAINER'S REPLACEMENT, for both: take the one-pixel column just left
-- of the gap, as it stands on screen, and stretch it across the gap. Whatever
-- the shelf paints beside the lifted book carries straight through, so the
-- gap is continuous with it by construction -- and in night mode too, since
-- the pixels copied are already the right way round.
--
-- That column only exists on the DESTINATION, after the row and the books to
-- the left have painted: the slot's own render is cached in a buffer of its
-- own, empty or page-ground, where there is nothing to the left to copy. So
-- the render stops painting the gap and says where it is, and every path that
-- draws a lifted book fills it after its blit.

package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local src = io.open("lib/bookshelf_spine_shelf.lua"):read("*a")

-- A function's body by name. Declared up here, above every test that uses it:
-- a local function referenced before its declaration reads a nil global.
local function fn(name)
    return src:match("\nfunction " .. name:gsub("[%.:]", "%%%0") .. "%(.-%)\n(.-)\nend\n")
end

-- ── fillLiftGap, run for real against a fake buffer ────────────────────────

local body = src:match("\nfunction SpineShelf%.fillLiftGap%(bb, x, y, w, h, from_x%)\n(.-)\nend\n")
assert(body, "SpineShelf.fillLiftGap is missing or its signature changed")
local fillLiftGap = assert(load(
    "return function(bb, x, y, w, h, from_x)\n" .. body .. "\nend",
    "fillLiftGap", "t", { math = math }))()

local lifted_body = src:match("\nfunction SpineShelf%.fillLifted%(bb, ox, oy, g, from_x%)\n(.-)\nend\n")
assert(lifted_body, "SpineShelf.fillLifted is missing or its signature changed")
local fillLifted = assert(load(
    "return function(bb, ox, oy, g, from_x)\n" .. lifted_body .. "\nend",
    "fillLifted", "t", { SpineShelf = { fillLiftGap = fillLiftGap } }))()

-- A buffer whose every pixel names where it came from, so a copy can be
-- traced back to its source column.
local function fakeBB(w, h)
    local px = {}
    for yy = 0, h - 1 do
        px[yy] = {}
        for xx = 0, w - 1 do px[yy][xx] = xx .. "," .. yy end
    end
    local bb = { w = w, h = h, px = px }
    function bb:getWidth()  return self.w end
    function bb:getHeight() return self.h end
    -- Snapshots the source first, so a blit from itself behaves like the real
    -- one does for non-overlapping regions.
    function bb:blitFrom(s, dx, dy, sx, sy, bw, bh)
        local tmp = {}
        for j = 0, bh - 1 do
            tmp[j] = {}
            for i = 0, bw - 1 do tmp[j][i] = s.px[sy + j][sx + i] end
        end
        for j = 0, bh - 1 do
            for i = 0, bw - 1 do self.px[dy + j][dx + i] = tmp[j][i] end
        end
    end
    return bb
end

t.test("every column of the gap becomes the column just left of it", function()
    local bb = fakeBB(20, 12)
    fillLiftGap(bb, 5, 3, 4, 4)
    for yy = 3, 6 do
        for xx = 5, 8 do
            eq(bb.px[yy][xx], "4," .. yy,
               "pixel " .. xx .. "," .. yy .. " is not the column left of the gap")
        end
    end
end)

t.test("row by row: the copy is a stretch, not a single colour", function()
    -- The column carries the shelf's vertical structure -- recess, plank
    -- surface, front face -- so each row keeps its own source row.
    local bb = fakeBB(20, 12)
    fillLiftGap(bb, 5, 3, 4, 4)
    eq(bb.px[3][6], "4,3")
    eq(bb.px[6][6], "4,6")
end)

t.test("nothing outside the gap moves", function()
    local bb = fakeBB(20, 12)
    fillLiftGap(bb, 5, 3, 4, 4)
    eq(bb.px[2][6], "6,2", "the row above the gap was touched")
    eq(bb.px[7][6], "6,7", "the row below the gap was touched")
    eq(bb.px[4][9], "9,4", "the column right of the gap was touched")
    eq(bb.px[4][4], "4,4", "the source column itself was touched")
end)

t.test("a book at the buffer's left edge takes the column to its right", function()
    -- There is nothing at x-1 to copy, and the shelf continues either way.
    local bb = fakeBB(20, 12)
    fillLiftGap(bb, 0, 3, 4, 4)
    eq(bb.px[3][0], "4,3")
    eq(bb.px[6][3], "4,6")
end)

-- ── Spines stand flush: the shelf is left of the whole run ────────────────
--
-- The maintainer, on seeing it: the column just left of a lifted SPINE is the
-- next book, not shelf -- inside a run the plan leaves no gap between spines
-- (book_gap is 0), so x-1 is the neighbour's edge and stretching it paints a
-- band of that book. A face-out has face_gap either side, which is why x-1 was
-- right for those. The shelf beside a spine is just left of its FLUSH BLOCK:
-- the run of spines with no gap between them.

t.test("the column can be taken from further left than the gap", function()
    local bb = fakeBB(20, 12)
    fillLiftGap(bb, 9, 3, 3, 4, 2)
    eq(bb.px[3][9], "2,3", "the fill ignored the column it was given")
    eq(bb.px[6][11], "2,6")
end)

t.test("a given column that is off the buffer falls back to the right", function()
    local bb = fakeBB(20, 12)
    fillLiftGap(bb, 3, 3, 3, 4, -5)
    eq(bb.px[3][3], "6,3")
end)

t.test("the row tells each spine how far its flush block reaches left", function()
    -- rowWidget is the only place that knows the gaps: it starts a new block
    -- after any real gap (a group gap, the gap beside a face-out, an
    -- ornament's) and at the row's first book.
    local row = src:match("\nfunction SpineShelf%.rowWidget%(opts%)\n(.-)\nend\n")
    assert(row, "SpineShelf.rowWidget moved")
    assert(row:find("flush_dx", 1, true), "the slots are never told where their run begins")
    assert(row:find("if gap_w > 0 then block_x0 = cursor end", 1, true),
        "a real gap does not start a new flush block")
end)

t.test("a lifted spine fills from the shelf left of its run", function()
    local paint = fn("SpineBookSlot:paintTo")
    local n = select(2, paint:gsub("x %- %(self%.flush_dx or 0%) %- 1", ""))
    assert(n >= 2, "a spine path still copies the neighbouring book (found " .. n .. ")")
    local tilt = fn("SpineShelf.paintOpeningTilt")
    assert(tilt:find("d.x - (slot.flush_dx or 0) - 1", 1, true),
        "the tilting spine still copies the neighbouring book")
    assert(tilt:find("SpineShelf.fillLifted(", 1, true),
        "the tilting spine fills its gap but not its cut corners")
end)

t.test("a lifted face-out still takes the column right beside it", function()
    -- It has face_gap either side, so x-1 IS shelf: no source column given.
    local lift = fn("LiftShadow:paintTo")
    assert(lift:find("SpineShelf.fillLiftGap(bb, x, y, w, lift_h)", 1, true),
        "the face-out no longer fills from right beside itself")
end)

-- ── The cut foot corners (maintainer: "bright pixels in the bottom corners") ─
--
-- A standing spine has a pixel square cut off each bottom corner. Lifted,
-- those squares showed page-ground white (or, over a wallpaper, whatever was
-- behind at that height) -- right when the space under a lifted book was light
-- air. Once the gap filled with the shelf, they sat on it as bright specks.
-- They are part of what the lift uncovers, so they take the same fill.

t.test("the cut corners take the shelf, like the gap below them", function()
    local bb = fakeBB(30, 12)
    -- Gap at x=10..15, rows 5..7, the book's foot at row 5; corners 1px.
    fillLifted(bb, 10, 0, { dx = 0, dy = 5, w = 6, h = 3, corner = 1 }, 8)
    eq(bb.px[4][10], "8,4", "the left foot corner still shows its old pixel")
    eq(bb.px[4][15], "8,4", "the right foot corner still shows its old pixel")
    eq(bb.px[6][12], "8,6", "the gap itself was not filled")
end)

t.test("between the corners, the book's own bottom edge stays", function()
    local bb = fakeBB(30, 12)
    fillLifted(bb, 10, 0, { dx = 0, dy = 5, w = 6, h = 3, corner = 1 }, 8)
    for xx = 11, 14 do
        eq(bb.px[4][xx], xx .. ",4", "the foot between the corners was painted over")
    end
end)

t.test("a spine too narrow for two corners keeps its foot whole", function()
    local bb = fakeBB(30, 12)
    fillLifted(bb, 10, 0, { dx = 0, dy = 5, w = 2, h = 3, corner = 1 }, 8)
    eq(bb.px[4][10], "10,4")
end)

t.test("no gap recorded, nothing painted", function()
    local bb = fakeBB(30, 12)
    fillLifted(bb, 10, 0, nil, 8)
    eq(bb.px[6][12], "12,6")
end)

t.test("the render says how big the cut corners are", function()
    local render = fn("SpineBookSlot:_renderIntoAt")
    assert(render:find("corner = hairline", 1, true),
        "the gap record does not carry the corner cut, so nothing can fill it")
end)

t.test("a gap as wide as the buffer is left alone", function()
    local bb = fakeBB(6, 6)
    fillLiftGap(bb, 0, 1, 6, 2)
    eq(bb.px[1][2], "2,1", "a gap with no shelf either side was filled with something")
end)

t.test("a gap running off the buffer is clipped, not an error", function()
    local bb = fakeBB(20, 8)
    fillLiftGap(bb, 5, 5, 4, 10)
    eq(bb.px[7][6], "4,7")
end)

t.test("an empty gap does nothing", function()
    local bb = fakeBB(20, 8)
    fillLiftGap(bb, 5, 3, 0, 4)
    fillLiftGap(bb, 5, 3, 4, 0)
    eq(bb.px[3][5], "5,3")
end)

-- ── where it is used ───────────────────────────────────────────────────────


t.test("the black box is gone", function()
    assert(not src:find("_liftBoxColor", 1, true),
        "the solid lift box is still defined or painted somewhere")
end)

t.test("the render no longer paints the gap itself, in either mode", function()
    local render = fn("SpineBookSlot:_renderIntoAt")
    assert(render, "_renderIntoAt moved")
    assert(not render:find("_plankRowAt(yy - surf_top, surf_h, 0.72)", 1, true),
        "the plain-page plank reproduction is still painted into the gap")
    assert(render:find("self._lift_gap", 1, true),
        "the render does not say where the gap is")
end)

t.test("a cached render's gap is dropped with the render", function()
    -- One choke point for eviction and invalidation, so the gap table cannot
    -- outlive, or disagree with, the render it describes.
    local drop = src:match("\nlocal function _renderCacheDrop%(key%)\n(.-)\nend\n")
    assert(drop and drop:find("_render_gap[key] = nil", 1, true),
        "a dropped render leaves its gap behind")
end)

t.test("the cached path and the fallback both fill after drawing", function()
    local paint = fn("SpineBookSlot:paintTo")
    assert(paint, "paintTo moved")
    local n = select(2, paint:gsub("SpineShelf%.fillLifted%(", ""))
    assert(n >= 2, "a drawing path leaves the gap or its corners unfilled (found " .. n .. ")")
    assert(paint:find("_render_gap[key]", 1, true),
        "a cache hit cannot know where the gap is")
end)

t.test("the opening tilt fills its gap too", function()
    local tilt = fn("SpineShelf.paintOpeningTilt")
    assert(tilt and tilt:find("SpineShelf.fillLifted(", 1, true),
        "a tilting book leaves a bare patch on a plain page")
end)

t.test("a lifted face-out gets the same fill, one gesture one shadow", function()
    local lift = fn("LiftShadow:paintTo")
    assert(lift and lift:find("SpineShelf.fillLiftGap(", 1, true),
        "a lifted face-out still paints its own kind of shadow")
end)

-- ── A lifted FACE-OUT's cut corners ────────────────────────────────────────
--
-- The report was on a face-out (the device grab: a 2x2 of 255 at each bottom
-- corner of a lifted cover, with 41 -- the shelf -- all round it). The cover
-- card cuts its rounded corners by putting back what CornerKeep snapshotted
-- behind them when the card began to paint, and at that moment the pixels
-- under a lifted cover's bottom corners were still white. So the card takes
-- the shelf column into those squares FIRST, and the snapshot keeps shelf.

local widget_src = io.open("lib/bookshelf_spine_widget.lua"):read("*a")

t.test("a lifted face-out's card fills its foot corners before the snapshot", function()
    local paint = widget_src:match("\nfunction RoundedCornerCard:paintTo%(bb, x, y%)\n(.-)\nend\n")
    assert(paint, "RoundedCornerCard:paintTo moved")
    local fill = paint:find("fillLiftGap(", 1, true)
    local take = paint:find("CornerKeep.take(", 1, true)
    assert(fill, "the card never fills its foot corners from the shelf")
    assert(take and fill < take,
        "the corners are filled AFTER CornerKeep has already kept the white")
    assert(paint:find("self.fill_feet_from_shelf", 1, true),
        "the fill is not gated on the card being a lifted face-out")
end)

t.test("the cover tile hands the flag to its card", function()
    assert(widget_src:find("cover_args.fill_feet_from_shelf = self.fill_feet_from_shelf", 1, true),
        "the flag stops at the tile and never reaches the card")
end)

t.test("the spine shelf sets it for a SELECTED face-out only", function()
    assert(src:find("fill_feet_from_shelf = is_sel", 1, true),
        "the shelf does not tell a lifted face-out to fill its corners")
end)

t.done()
