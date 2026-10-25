-- tests/_test_faceout_pull_wiring.lua
-- The face-out opening pose is wired into the shelf: the row records where
-- it is painted on screen and hands each face-out its row, its widget and its
-- recess column, so the painter can draw the shelf as if the book were gone;
-- the entry carries the book's true thickness.
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t = H.runner()
local src = io.open("lib/bookshelf_spine_shelf.lua"):read("*a")
local code = src:gsub("%-%-[^\n]*", "")

t.test("the entry carries the true thickness, before the top block's rounding", function()
    assert(code:find("true_thick = Screen:scaleBySize(depth_dp)", 1, true), "no true thickness taken")
    assert(code:find("thick = true_thick,", 1, true), "the entry does not carry it")
    -- `thick` is already the page-count record thicknessPages reads in that
    -- scope; reusing the name nilled it and crashed every face-out (rig).
    assert(not code:find("local w_dp, w, depth, face_h, thick\n", 1, true), "the page-count record is shadowed")
    assert(code:find("thick = e.thick", 1, true), "faceout_fx does not carry it")
end)

t.test("each face-out knows its row, its widget and its recess column", function()
    assert(code:find("fx_here.item = tile", 1, true), "the face-out's widget is not recorded")
    assert(code:find("fx_here.col = recess_cols[#recess_cols]", 1, true), "its recess column is not recorded")
    assert(code:find("fx.row = row_group", 1, true), "its row is not recorded")
end)

t.test("the row records where it is painted, on the real screen only", function()
    -- The real screen behind a clipped repaint's stand-in counts as the screen.
    assert(code:find('local on_screen = require("lib/bookshelf_clip_bb").real(bb) == Screen.bb', 1, true)
        and code:find("if on_screen then self._screen_x", 1, true), "offscreen paints would record wrong positions")
    assert(code:find("self._screen_x, self._screen_y = x, y", 1, true), "the row's screen position is not recorded")
end)

t.test("the opening pose paints through the pose module, with the old tilt as fallback", function()
    local body = code:match("\nfunction SpineShelf%.paintFaceOutTilt%(tile%)\n(.-)\nend\n")
    assert(body, "paintFaceOutTilt moved")
    assert(body:find("Pose.pose(", 1, true), "it does not use the pose module")
    assert(body:find("SpineShelf._paintFaceOutTip(tile)", 1, true), "no fallback to the old tilt")
    assert(body:find("card:paintTo(src, 0, 0)", 1, true), "the cover is captured with its glyphs")
end)

t.test("runs of one colour are compared by identity, not ==", function()
    -- Blitbuffer colours are cdata whose __eq LuaJIT calls even against
    -- false, and it indexes the other operand: the pose fell back on the rig.
    local body = code:match("\nfunction SpineShelf%.paintFaceOutTilt%(tile%)\n(.-)\nend\n")
    assert(body:find("rawequal(c, run_c)", 1, true) and not body:find("c ~= run_c", 1, true),
        "colours compared with ~=")
end)

t.test("in a Shelf module the row keeps what is behind it, as its spines do", function()
    -- The pose repaints the row "as if the book were gone" over the page put
    -- back. In a module that page is the module's, not the shelf's: put back
    -- through Wallpaper.restore, the library's wallpaper or ground filled the
    -- module's row on a PW5, opened from inside a book (maintainer).
    assert(code:find("if keep_ground and on_screen then", 1, true), "the row keeps no ground")
    assert(code:find("self._ground:blitFrom(require(\"lib/bookshelf_clip_bb\").real(bb), 0, 0, x, y, w, h)", 1, true), "the ground is not copied before the paint")
    local body = code:match("\nfunction SpineShelf%.paintFaceOutTilt%(tile%)\n(.-)\nend\n")
    local kept = body:find("bb:blitFrom(g, rx, ry, 0, 0, rw, rh)", 1, true)
    local wp = body:find("Wallpaper.restore(bb, rx, ry, rw, rh)", 1, true)
    assert(kept and wp and kept < wp, "the kept ground is not put back before the shelf's own")
end)

t.done()
