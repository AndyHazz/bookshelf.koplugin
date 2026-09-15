-- tests/_test_recess_horizon.lua
-- The shelf recess's 45-degree shadow horizon.
--
-- WHAT NEEDS PINNING. The gap between two books was painted as ONE rectangle
-- at the taller neighbour's height, so a short spine beside a tall face-out
-- met its neighbour's shadow at a square 90-degree step. The end of a RUN
-- already rakes away at 45 degrees (see `wedge`); this is the same rule
-- applied between books.
--
-- A flat neighbour-max was tried once and REJECTED, and the reason is in the
-- painter's own comment: a short spine took the cover's full shadow height,
-- so the cover's outline stopped reading. The horizon is not that. It decays
-- one pixel per pixel travelled, so the tall book's shadow leans over its
-- neighbour and is gone again within its own height -- which is what stops
-- the outline being lost while still removing the step.
--
-- Usage (from plugin root): lua tests/_test_recess_horizon.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
package.loaded["logger"] = { dbg = function() end, info = function() end,
                             warn = function() end, err = function() end }
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local src = io.open("lib/bookshelf_spine_shelf.lua"):read("a")
local chunk = src:match("(function SpineShelf%.recessHorizon.-\nend)")
assert(chunk, "the recess horizon could not be located")
local SpineShelf = {}
local fn = load(chunk, "horizon", "t",
                { SpineShelf = SpineShelf, math = math, ipairs = ipairs,
                  type = type, tonumber = tonumber })
assert(fn, "the recess horizon would not compile standalone")
fn()

local H = function(cols, px) return SpineShelf.recessHorizon(cols, px) end

-- ── the rule ──────────────────────────────────────────────────────────────

t.test("inside a book, the horizon is at least that book's own height", function()
    local cols = { { x = 0, w = 20, h = 100 } }
    eq(H(cols, 0), 100)
    eq(H(cols, 10), 100)
    eq(H(cols, 19), 100)
end)

t.test("it decays one pixel per pixel away from the book", function()
    local cols = { { x = 0, w = 20, h = 100 } }
    eq(H(cols, 20), 100)   -- the pixel abutting the book
    eq(H(cols, 25), 95)
    eq(H(cols, 40), 80)
end)

t.test("it decays the same way on the left", function()
    local cols = { { x = 50, w = 20, h = 100 } }
    eq(H(cols, 50), 100)
    eq(H(cols, 45), 95)
    eq(H(cols, 30), 80)
end)

t.test("it never goes below zero", function()
    local cols = { { x = 0, w = 10, h = 30 } }
    eq(H(cols, 200), 0)
end)

-- ── the case this exists for ──────────────────────────────────────────────

t.test("a tall cover leans over its short neighbour and is gone within its own reach", function()
    -- The step: a 60px spine at x0..19, a 200px face-out at x24..120.
    local cols = { { x = 0, w = 20, h = 60 }, { x = 24, w = 96, h = 200 } }
    -- Hard against the cover, the shadow stands at nearly the cover's height.
    assert(H(cols, 23) >= 195, "the shadow does not reach the cover's height at its edge")
    -- Across the spine it falls away, and by the spine's far end it is back
    -- to the spine's own shadow rather than the cover's.
    assert(H(cols, 19) < H(cols, 23), "the shadow is not decaying across the gap")
    eq(H(cols, 0), 176, "at 24px away a 200px cover still dominates a 60px spine")
    -- ...and far enough out, the tall book stops mattering entirely.
    local far = { { x = 0, w = 20, h = 60 }, { x = 300, w = 96, h = 200 } }
    eq(H(far, 10), 60, "a distant cover is still casting over this spine")
end)

t.test("a flat neighbour-max is NOT what this does", function()
    -- The rejected version: every pixel of the short spine at the tall
    -- neighbour's height, so the cover's outline stopped reading.
    local cols = { { x = 0, w = 20, h = 60 }, { x = 24, w = 96, h = 200 } }
    local flat = 0
    for px = 0, 19 do if H(cols, px) == 200 then flat = flat + 1 end end
    eq(flat, 0, "the short spine is taking the cover's full height again")
end)

t.test("equal-height neighbours produce a flat horizon, so nothing slices", function()
    -- The common case: a shelf of similar spines must paint exactly as it
    -- did, one strip per column, or this costs blends for nothing.
    local cols = { { x = 0, w = 20, h = 100 }, { x = 24, w = 20, h = 100 } }
    for px = 0, 19 do eq(H(cols, px), 100) end
    for px = 24, 43 do eq(H(cols, px), 100) end
end)

-- ── shape ─────────────────────────────────────────────────────────────────

t.test("no columns, or junk, is zero rather than an error", function()
    eq(H({}, 5), 0)
    eq(H(nil, 5), 0)
    eq(SpineShelf.recessHorizon({ { x = 0, w = 10, h = 100 } }, nil), 0)
end)

t.test("the painter uses it for the books AND the gaps", function()
    assert(src:match("SpineShelf%.recessHorizon"),
        "the horizon is defined but nothing paints with it")
    -- The flat max is what produced the step; it must not still be there.
    assert(not src:match("place%(gx, gw, math%.max%(c%.h, nxt%.h%)%)"),
        "the gap is back to one rectangle at the taller neighbour's height")
end)

-- ── the same rule, applied to the FEET (the shadow on the plank) ──────────

t.test("it reads any field, so the feet rake like the shoulders do", function()
    -- A face-out stands one inset further back than the spines beside it, so
    -- its foot is higher up the plank. The gap between them used to drop the
    -- shadow square to the spines' foot line right up against the cover,
    -- which is the block on the shelf the maintainer pointed at.
    local cols = { { x = 0, w = 20, h = 60, foot = 0 },
                   { x = 24, w = 96, h = 200, foot = 6 } }
    eq(SpineShelf.recessHorizon(cols, 30, "foot"), 6, "inside the cover")
    eq(SpineShelf.recessHorizon(cols, 23, "foot"), 5, "one px out from it")
    eq(SpineShelf.recessHorizon(cols, 18, "foot"), 0, "back at the spine's own foot")
    -- and it is a 45-degree ramp: one px of lift per px travelled.
    for d = 0, 6 do
        eq(SpineShelf.recessHorizon(cols, 24 - d, "foot"), math.max(0, 6 - d))
    end
end)

t.test("a missing field is zero, not an error", function()
    local cols = { { x = 0, w = 20, h = 60 } }
    eq(SpineShelf.recessHorizon(cols, 5, "foot"), 0)
end)

t.test("the painter rakes the shadow's base as well as its top", function()
    assert(src:match('recessHorizon%(cols, [%w_%s%+%(%)/%.]-, "foot", side%)'),
        "the shadow's base no longer follows the books' feet")
end)

t.test("a book's shadow does not carry further than the end wedge does", function()
    -- Uncapped, a 250px spine ramps for 250px. That is further than a shadow
    -- travels, and far too long to draw: the slices spread over the whole run
    -- and the diagonal came out as steps you could count -- worst across a
    -- gap holding an ornament, the widest gap a row has.
    local cols = { { x = 0, w = 20, h = 250 } }
    local reach = 28
    eq(SpineShelf.recessHorizon(cols, 20 + reach, "h", reach), 250 - reach,
       "the last pixel within reach should still be lit")
    eq(SpineShelf.recessHorizon(cols, 20 + reach + 1, "h", reach), 0,
       "one pixel past the reach the shadow is gone")
    eq(SpineShelf.recessHorizon(cols, 200, "h", reach), 0)
    -- ...and with no reach given it still carries the whole way, which is
    -- what the plain two-argument callers rely on.
    eq(SpineShelf.recessHorizon(cols, 200), 250 - 180)
end)

t.test("the reach does not shorten a book's own column", function()
    local cols = { { x = 0, w = 20, h = 250 } }
    for px = 0, 19 do eq(SpineShelf.recessHorizon(cols, px, "h", 4), 250) end
end)

t.done()
