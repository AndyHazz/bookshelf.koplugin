-- tests/_test_spine_text_direction.lua
-- Which way a spine's title runs, and the gradient that has to follow it.
--
-- WHAT NEEDS PINNING. British and American books are printed so the spine
-- reads downwards: stand one on a shelf and you tilt your head right. That is
-- the default. Continental European printing runs the other way, and issue 410
-- asked for the choice ("the spine text orientation of real books is majority
-- clockwise").
--
-- THE TRAP, which the source has warned about since the rotation was first
-- set: the title band's gradient prefill has to move WITH the rotation.
-- Rotation maps each scratch ROW to a screen COLUMN, so reversing it reverses
-- which end of the ramp the band carries, and a band left alone sits mirrored
-- against the spine body it is painted on. They are one decision, so this test
-- insists they are also one expression rather than two constants that agree
-- today.
--
-- Usage (from plugin root): lua tests/_test_spine_text_direction.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq
local src = io.open("lib/bookshelf_spine_shelf.lua"):read("*a")

local body = src:match("\nfunction SpineShelf%.titleRotation%(%)\n(.-)\nend\n")
assert(body, "SpineShelf.titleRotation missing")

local function rotationWith(stored)
    local env = {
        SpineShelf = {},
        BookshelfSettings = { read = function(_k, dflt) return stored == nil and dflt or stored end },
    }
    local fn = assert(load("return function()\n" .. body .. "\nend", "rot", "t", env))
    return fn()()
end

t.test("an untouched library reads downwards, as a British book is printed", function()
    eq(rotationWith(nil), 270)
end)

t.test("the setting turns it the other way", function()
    eq(rotationWith("bottom_up"), 90)
    eq(rotationWith("top_down"), 270)
end)

t.test("a value from nowhere falls back rather than rotating to nonsense", function()
    -- rotatedCopy takes 90/180/270; anything else would be a paint-time error
    -- a long way from the setting that caused it.
    eq(rotationWith("sideways"), 270)
    eq(rotationWith(true), 270)
end)

t.test("the gradient flip is DERIVED from the rotation, not a second constant", function()
    assert(not src:find("local GRAD_BAND_FLIP = true", 1, true),
        "the flip is still a constant; it cannot follow a rotation that moves")
    -- Both live in the band block, computed from one local.
    local block = src:match("(local rot_deg%s*=.-local rot = scratch:rotatedCopy%(rot_deg%))")
    assert(block, "the band block no longer computes the rotation once and uses it twice")
    assert(block:find("rot_deg == 270", 1, true),
        "the flip must be read off the rotation itself")
end)

t.test("a direction change re-renders rather than serving the old bitmap", function()
    local key = src:match("function SpineBookSlot:_renderKey%(night%)(.-)\nend\n")
    assert(key, "the render key moved")
    assert(key:find("titleRotation", 1, true),
        "two directions share a cache key, so the shelf keeps the old rotation "
        .. "until something else evicts it")
end)

t.done()
