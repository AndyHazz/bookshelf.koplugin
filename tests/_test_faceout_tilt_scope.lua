-- tests/_test_faceout_tilt_scope.lua
-- Opening a face-out book on a spine shelf repainted and refreshed the whole
-- row to show what is behind the tipping book (maintainer, PW5,
-- 2026-10-31: "the full row just to open one book?"). Only the book's
-- footprint, across the row's height, is put back and refreshed; the rest of
-- the row is untouched.
--
-- Usage (from plugin root): lua tests/_test_faceout_tilt_scope.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()
local src = io.open("lib/bookshelf_spine_shelf.lua"):read("*a")
local body = assert(src:match("\nfunction SpineShelf%.paintFaceOutTilt%(tile%)\n(.-)\nend\n"), "paintFaceOutTilt moved")

t.test("the row behind the book is repainted inside the book's footprint only", function()
    assert(body:find("ClipBB.new(bb, { foot })", 1, true), "the row is repainted across its width")
    assert(body:find("ground(foot)", 1, true) and body:find("Wallpaper.restore(bb, r.x, r.y, r.w, r.h)", 1, true),
        "the ground is put back across the whole row")
    assert(not body:find("Wallpaper.restore(bb, rx, ry, rw, rh)", 1, true), "the whole row's ground is still put back")
end)

-- The plank design of the row above draws its drop (a shadow, an apron) a
-- little into this row's top. Putting the ground back from the row's top
-- erased it behind the book (maintainer, PW5 photo, 2026-10-31): only from
-- just above the book's own top down, which the book never drew above.
t.test("the band above the book keeps what the row above drew there", function()
    assert(body:find("math.max(ry, rect.y - math.ceil(fx.depth or 0) - margin)", 1, true), "the ground is put back from the row's top")
    assert(not body:find("foot = { x = fx0, y = ry,", 1, true), "the footprint still starts at the row's top")
end)

t.test("the refresh is the footprint and the pose, not the row", function()
    local tail = assert(body:match("%-%- The footprint was repainted(.*)$"), "no return region")
    assert(tail:find("math.min(foot.x, math.floor(info.minx))", 1, true), "the refresh still starts at the row's edge")
    assert(not tail:find("rx + rw", 1, true), "the refresh still runs the row's width")
end)

t.done()
