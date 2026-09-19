-- tests/_test_chip_switch_hero_band.lua
-- The chip-switch refresh band has to allow for the hero MOVING.
--
-- THE REPORT (issue 423). "When changing to a shelf with no books inside
-- there is a glitch when the hero cover is redrawn." It would not reproduce
-- here for days, and the reporter found the condition: it needs "Show text
-- below covers" set to anything but None, and two Home chips whose folders
-- are drawn in different styles.
--
-- WHY THAT MATTERS. A chip whose page holds only divider-card folders prints
-- no name under a tile, so its rows reserve no label strip, so its rows are
-- shorter and the hero takes the slack. Switch to a chip whose folders are
-- book stacks -- those DO print a name outside the tile -- and the strip
-- comes back and the hero shrinks again. Measured on the rig against a
-- library with no loose books at its root: the hero's bottom moved 733 -> 679
-- across one chip tap.
--
-- THE BUG. _rebuildRefreshBelowHero captured the hero's geometry BEFORE the
-- rebuild and started the band there, on the reasoning that a chip switch
-- leaves the hero alone. With the hero shrinking, the band began below where
-- it USED to end and the rows in between kept the old picture. Refresh sent
-- to the panel: y=740 before the fix, y=686 after, against a hero ending at
-- 679.
--
-- Usage (from plugin root): lua tests/_test_chip_switch_hero_band.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq
local src = io.open("lib/bookshelf_widget.lua"):read("*a")

local body = src:match("\nfunction BookshelfWidget:_rebuildRefreshBelowHero%(%)\n(.-)\nend\n")
assert(body, "_rebuildRefreshBelowHero moved or was renamed")

-- ── where the hero ends ───────────────────────────────────────────────────
local hb = body:match("(local function heroBottom.-\n    end)")
assert(hb, "the heroBottom helper moved or was renamed")
local heroBottom = assert(load(hb .. "\nreturn heroBottom", "heroBottom", "t", {}))()

t.test("the painted rect is the pixel truth, so it wins", function()
    eq(heroBottom({ y = 10, h = 100 }, { PAD = 7, hero_h = 500 }), 110)
end)

t.test("...and the stashed geometry answers when nothing has painted yet", function()
    eq(heroBottom(nil, { PAD = 7, hero_h = 500 }), 507)
    eq(heroBottom({ y = 10 }, { PAD = 7, hero_h = 500 }), 507,
       "a half-filled dimen is not a painted rect")
end)

t.test("neither one: no band, which means a full refresh", function()
    eq(heroBottom(nil, nil), nil)
    eq(heroBottom(nil, {}), nil)
end)

-- ── the band takes the shallower of the two ───────────────────────────────
t.test("the band is measured after the rebuild as well as before", function()
    assert(body:match("local before = heroBottom"),
        "the hero's bottom before the rebuild is no longer taken")
    assert(body:match("local after%s+= heroBottom%(nil, self%._hero_dims%)"),
        "nothing measures the hero the rebuild just produced")
    local i_before = body:find("local before", 1, true)
    local i_build  = body:find("self:_rebuild()", 1, true)
    local i_after  = body:find("local after", 1, true)
    assert(i_before < i_build and i_after > i_build,
        "one reading has to straddle the rebuild or they are the same number")
end)

t.test("the shallower one wins, whichever way the hero moved", function()
    local pick = body:match("(local below_y = before.-\n)")
                 .. (body:match("(\n    if after and[^\n]+)") or "")
    assert(pick and pick:find("after < below_y", 1, true),
        "the band does not take the smaller of the two: " .. tostring(pick))
    -- drive it both ways round
    local fn = assert(load([[
        local before, after = ...
        local below_y = before
        if after and (not below_y or after < below_y) then below_y = after end
        return below_y]], "pick", "t", {}))
    eq(fn(733, 679), 679, "the hero shrank: the band must start higher")
    eq(fn(679, 733), 679, "the hero grew: the band must still start at the top of the change")
    eq(fn(700, 700), 700, "unchanged, which is every other chip switch")
    eq(fn(nil, 679), 679, "nothing painted before")
    eq(fn(733, nil), 733, "nothing to measure after")
end)

t.test("the shadow nudge still applies, and only to a real band", function()
    -- The #124 tail: a hard boundary flush against the cover's drop shadow
    -- leaves a residual flash on panels with HW dithering.
    assert(body:match("below_y = below_y %+ Screen:scaleBySize%(4%)"),
        "the shadow nudge went missing")
    assert(body:match("else\n%s+UIManager:setDirty%(self, \"ui\"%)"),
        "with no band to compute, it must still refresh everything")
end)

t.done()
