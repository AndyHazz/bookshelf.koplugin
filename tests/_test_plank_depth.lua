-- tests/_test_plank_depth.lua
-- The shelf plank's three numbers, and the one relationship that must hold.
--
-- WHAT NEEDS PINNING.
--
-- 1. THE SHELF IS AS DEEP AS THE BOOKS. The plank's top face and a spine's
--    page block are both horizontal surfaces under the same 12-degree camera,
--    so the eye compares them directly. The plank painted 24px under books
--    showing 43px, which does not read as a shallow shelf -- it reads as an
--    impossible one (maintainer). The board now asks SpineLayout for the same
--    depth the tallest book shows, so the two cannot drift apart again.
--
-- 2. THREE NUMBERS, NOT TWO. Inset (what shows in front of the feet), surface
--    (the painted board) and lift (how far a held book rises) used to be two
--    literals, with surface and lift sharing one value by accident. Deepening
--    the board would have doubled the lift. They are separate now, and the
--    test that matters is that changing the depth does NOT move the lift.
--
-- 3. ONE DEFINITION EACH. `3 * b` appeared in five places and
--    `math.floor(b * 0.8)` in three. Each site looked locally correct, so
--    nothing caught a change to one copy.
--
-- Usage (from plugin root): lua tests/_test_plank_depth.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
package.loaded["logger"] = { dbg = function() end, info = function() end,
                             warn = function() end, err = function() end }
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local SL = require("lib/bookshelf_spine_layout")

-- Read the model out of the source: the shelf drags in Screen, fonts and the
-- whole render stack, and these five functions need none of it. SpineLayout
-- is the REAL module, because the relationship being pinned is the one
-- between the board and the books, and a stub would pin nothing.
local src = io.open("lib/bookshelf_spine_shelf.lua"):read("a")
local chunk = src:match("(function SpineShelf%.plankUnit.-function SpineShelf%.plankSurfaceOf.-\nend)")
assert(chunk, "the plank model could not be located")
local SpineShelf = {}
-- Screen at the rig's 300 DPI, where scaleBySize doubles.
local Screen = { scaleBySize = function(_self, n) return math.floor(n * 2) end }
local fn = load(chunk, "plankmodel", "t",
                { SpineShelf = SpineShelf, SpineLayout = SL, Screen = Screen,
                  math = math, tonumber = tonumber, type = type })
assert(fn, "the plank model would not compile standalone")
fn()

-- Rows in the range a device actually renders: three or four shelves on a
-- 1200-1900px screen, plus the extremes that hit plankUnit's clamps.
local ROWS = { 120, 200, 300, 380, 420, 500, 650, 900 }

-- ── 1. the board is never shallower than the books ────────────────────────

t.test("the plank's surface reaches at least as deep as its tallest book", function()
    for _i, row_h in ipairs(ROWS) do
        local b     = SpineShelf.plankUnit(row_h)
        local stand = row_h - SpineShelf.plankFace(row_h) - SpineShelf.plankInset(b)
        local box   = SL.topEdgeHeight(stand, SL.DEFAULT_ASPECT)
        assert(SpineShelf.plankSurface(row_h) >= box,
            ("row %d: board %d < page block %d -- the shelf is shallower than "
             .. "the books standing on it"):format(
                row_h, SpineShelf.plankSurface(row_h), box))
    end
end)

t.test("it is derived from the books, not from the edge unit", function()
    -- The literal-multiple version is what let the two drift. If the board
    -- were k * plankUnit, this ratio would be constant across every row.
    local ratios = {}
    for _i, row_h in ipairs(ROWS) do
        ratios[#ratios + 1] =
            SpineShelf.plankSurface(row_h) / SpineShelf.plankUnit(row_h)
    end
    local lo, hi = ratios[1], ratios[1]
    for _i, r in ipairs(ratios) do
        if r < lo then lo = r end
        if r > hi then hi = r end
    end
    assert(hi - lo > 0.5,
        "the board tracks the edge unit again, not the books")
end)

t.test("the board stays close to the books rather than towering over them", function()
    -- A shelf deeper than the books is right; one twice as deep is a table.
    for _i, row_h in ipairs(ROWS) do
        local b     = SpineShelf.plankUnit(row_h)
        local stand = row_h - SpineShelf.plankFace(row_h) - SpineShelf.plankInset(b)
        local box   = SL.topEdgeHeight(stand, SL.DEFAULT_ASPECT)
        if box > 0 then
            assert(SpineShelf.plankSurface(row_h) <= box * 1.5,
                ("row %d: board %d is way past the books' %d"):format(
                    row_h, SpineShelf.plankSurface(row_h), box))
        end
    end
end)

-- ── 2. the three numbers are independent ──────────────────────────────────

t.test("deepening the board does NOT change how far a held book lifts", function()
    -- The bug this prevents: surface and lift were one number, so making the
    -- shelf look right would have doubled the jump when a book is picked.
    local before = {}
    for b = 4, 20 do before[b] = SpineShelf.plankLift(b) end
    SpineShelf.PLANK_DEPTH_FACTOR = SpineShelf.PLANK_DEPTH_FACTOR * 2
    for b = 4, 20 do
        eq(SpineShelf.plankLift(b), before[b],
           "the lift followed the board's depth at b=" .. b)
    end
    SpineShelf.PLANK_DEPTH_FACTOR = SpineShelf.PLANK_DEPTH_FACTOR / 2
end)

t.test("the books still stand almost on the lip", function()
    -- Explicitly NOT the fix for the depth complaint: moving the feet back
    -- was tried and rejected ("I don't mind the spines standing almost on
    -- the lip"). Pinned so a future depth tweak does not reach for it again.
    assert(SpineShelf.PLANK_INSET_UNITS <= 1.0,
        "the books have been pushed back onto the plank again")
    for _i, row_h in ipairs(ROWS) do
        local b = SpineShelf.plankUnit(row_h)
        assert(SpineShelf.plankInset(b) < SpineShelf.plankSurface(row_h),
            "the strip in front of the feet has swallowed the whole board")
    end
end)

t.test("plankSurfaceOf prefers the stashed band, and has a sane fallback", function()
    eq(SpineShelf.plankSurfaceOf{ b = 8, inset = 6, surf = 41 }, 41)
    -- No stash: the value these painters used before the board was deepened,
    -- so an un-stashed descriptor still paints a coherent shelf.
    eq(SpineShelf.plankSurfaceOf{ b = 8, inset = 6 },
       SpineShelf.plankLift(8) + 6)
    eq(SpineShelf.plankSurfaceOf(nil), 1)
    eq(SpineShelf.plankSurfaceOf{ b = 8, inset = 6, surf = 0 },
       SpineShelf.plankLift(8) + 6)
end)

t.test("nonsense in is zero-ish out rather than an arithmetic error", function()
    eq(SpineShelf.plankInset(nil), 0)
    eq(SpineShelf.plankInset("x"), 0)
    eq(SpineShelf.plankLift(nil), 0)
    eq(SpineShelf.plankSurface(nil), 1)
    eq(SpineShelf.plankSurface(0), 1)
end)

-- ── 3. one definition, every consumer ─────────────────────────────────────

t.test("no bare plank multiplier survives anywhere in the painter", function()
    -- Comments still quote the old literals -- that is how the reason
    -- survives -- so strip them before looking.
    local code = src:gsub("%-%-[^\n]*", "")
    assert(not code:match("3 %* b%f[%W]"),         "a bare `3 * b` is back")
    assert(not code:match("3 %* [%w_]+%.b%f[%W]"), "a bare `3 * something.b` is back")
    assert(not code:match("%f[%w]b %* 0%.8"),      "a bare `b * 0.8` is back")
end)

t.test("the band painters read the STASHED surface, never the row", function()
    -- They reproduce the plank's own quantised bands over the height the
    -- plank actually painted. Recomputing from a row they do not have, or
    -- from the edge unit, is how the patch stops matching the shelf.
    local n = select(2, src:gsub("SpineShelf%.plankSurfaceOf%(", ""))
    assert(n >= 4, "a band painter has stopped using the stashed surface: " .. n)
    assert(src:match("surf = SpineShelf%.plankSurface%(opts%.height%)"),
        "rowWidget no longer stashes the band on its plank descriptors")
    local stashes = select(2, src:gsub("surf = surf", ""))
    assert(stashes >= 3, "a plank descriptor is built without its band: " .. stashes)
end)

t.test("every lift site reads the lift, not the board", function()
    local n = select(2, src:gsub("SpineShelf%.plankLift%(", ""))
    assert(n >= 5, "a lift site has gone back to the board's depth: " .. n)
end)

-- ── the chamfered ends ────────────────────────────────────────────────────

t.test("the far edge gets a nick, not a chamfer", function()
    -- It sits flat against the back wall (user ruling), so the corner only
    -- needs to not be a sharp point. One to three pixels, square.
    assert(src:match("SpineShelf%.PLANK_BACK_CHAMFER_MAX = 3"),
        "the back nick has lost its cap")
    assert(src:match("local cb = math%.max%(1, math%.min%(SpineShelf%.PLANK_BACK_CHAMFER_MAX"),
        "the back corner is no longer clamped to a few pixels")
    for scale = 1, 6 do
        local cb = math.max(1, math.min(3, scale))
        assert(cb >= 1 and cb <= 3,
            "the back nick left the 1-3px range at scale " .. scale)
    end
end)

t.test("the far corner is NOT derived from the front one", function()
    -- Sharing `c` is what produced the slice. The top surface recedes, so a
    -- vertical cut of c up there is worth c / VIEW_SIN of real board --
    -- nearly five times the intended easing.
    local far = src:match("Far %(top%) edge:.-\n(.-)\n    end")
    assert(far, "the far edge has lost its own loop")
    assert(not far:match("%f[%w]c%f[%W]") or far:match("cb"),
        "the far corner is reading the front corner's size again")
    assert(SL.VIEW_SIN < 0.3, "VIEW_SIN is no longer a shallow pitch")
end)

t.test("the two corners are cut by separate loops", function()
    -- One loop doing all four corners is what made them share a profile.
    local near = src:match("Front%-bottom: a vertical face.-\n(.-)\n    end")
    assert(near, "the front-bottom bevel has lost its own loop")
    assert(not near:match("band_top"),
        "the front loop is cutting the far edge again")
end)

-- ── where a book meets the board ──────────────────────────────────────────

t.test("contact is darker than a lifted book's soft patch", function()
    -- Contact occlusion is the darkest shadow on a shelf: no angle reaches
    -- the join. A LIFTED book is away from the board and casts a softer one.
    -- They were the same value, and the corner nick came out BRIGHTER than
    -- the spine's own dark board edge -- a highlight where a corner should
    -- be coming off (maintainer, twice).
    local shade = tonumber(src:match("SpineShelf%.PLANK_CONTACT_SHADE = ([%d%.]+)"))
    assert(shade, "the contact shade has gone")
    assert(shade < 0.72, "contact is no darker than the lifted patch: " .. shade)
    assert(shade > 0.2, "contact has gone to near-black: " .. shade)
end)

t.test("a face-out gets a contact strip across its whole width", function()
    -- The recess's occlusion runs down the gaps either side and had nothing
    -- to join across the cover, so a face-out sat on a lit board looking like
    -- it floated. A spine hides this behind its own dark board edge.
    local feet = src:match("function FaceOutFeet:paintTo.-\nend")
    assert(feet, "FaceOutFeet:paintTo could not be located")
    assert(feet:match("PLANK_CONTACT_SHADE"),
        "the face-out contact strip has gone")
    assert(feet:match("pk%.lip"),
        "the strip no longer indexes the board from its own front edge")
end)

-- ── reproducing the board ─────────────────────────────────────────────────

t.test("everything that must MATCH the board goes through _plankRowAt", function()
    -- The board draws five bands and fills each with the colour of its TOP
    -- row. Asking _plankBandColor for a row in the MIDDLE of a band can
    -- quantise a step away, so a patch meant to be invisible comes out a
    -- shade off the pixels beside it.
    assert(src:match("local function _plankRowAt"), "_plankRowAt has gone")
    local code = src:gsub("%-%-[^\n]*", "")
    -- Drop the definition itself before looking at the call sites.
    code = code:gsub("local function _plankBandColor%b()", "")
    for call in code:gmatch("_plankBandColor%b()") do
        local ok = call:match("^_plankBandColor%(0,")           -- the guard
              or call:match("by0")                               -- the board itself
              or call:match("math%.floor%(surf_h %* i / PLANK_BANDS%)")  -- inside _plankRowAt
        assert(ok, "a board-matching site calls _plankBandColor direct: " .. call)
    end
end)

t.test("the opening tilt refills with the board's real depth", function()
    -- It reconstructed the surface as `3 * pb`, which was right only while
    -- the board WAS three edge units. Deepening it left the tilt repainting
    -- the vacated strip with a shelf less than half the right size.
    assert(src:match("local ps = fx%.plank_surf or %(3 %* pb%)"),
        "the tilt no longer prefers the board's passed-through depth")
    assert(src:match("_plankRowAt%(yy %- surf_top, ps%)"),
        "the tilt is painting from a reconstructed depth again")
    assert(src:match("plank_surf = surf"), "faceout_fx no longer carries the depth")
end)

t.test("PLANK_BANDS is declared before the function that closes over it", function()
    -- Lua binds the upvalue that exists when the body is COMPILED. Declared
    -- below plankBandT, it reads nil at call time and the shelf dies on its
    -- first paint -- which is exactly what happened while writing this.
    local decl = src:find("local PLANK_BANDS")
    local use  = src:find("function SpineShelf%.plankBandT")
    assert(decl and use, "one of the two has gone")
    assert(decl < use, "PLANK_BANDS is declared after its first consumer again")
end)

t.test("the solid lift box under a face-out is the wallpaper look only", function()
    -- A lifted SPINE without a wallpaper still gets the banded plank shadow
    -- (SpineBookSlot:_renderIntoAt branches on has_wallpaper). The face-out's
    -- LiftShadow took the solid box unconditionally, so a plain-page shelf
    -- showed two different shadows for the same gesture.
    local src = io.open("lib/bookshelf_spine_shelf.lua"):read("a")
    local body = src:match("function LiftShadow:paintTo%(.-\nend\n")
    assert(body, "LiftShadow:paintTo could not be located")
    local code = body:gsub("%-%-[^\n]*", "")
    local gate = code:find("SpineShelf%.has_wallpaper")
    local box  = code:find("_liftBoxColor")
    assert(gate and box and gate < box,
        "LiftShadow paints the solid box before asking whether there is a wallpaper")
    assert(code:find("_plankRowAt", 1, true),
        "LiftShadow has no banded fallback for the plain shelf")
    assert(not code:find('require%("lib/bookshelf_wallpaper"%)'),
        "LiftShadow requires the wallpaper module and never uses it")
end)

t.done()
