-- tests/_test_spine_shadows.lua
-- Spine shelves paint their depth on any ground, not only over a picture.
--
-- WHAT NEEDS PINNING. The recess behind the books, and the shading either
-- side of each spine that reads as a cast shadow, were gated on
-- Wallpaper.isShowing(). The reasoning was that a plain page separates books
-- well enough and a wash behind them would change everyone's shelf; comparing
-- the two side by side says otherwise, and the depth is what makes a shelf
-- look like a shelf (maintainer). Nothing in the painter ever needed a
-- picture: Wallpaper.shadeRect is a darken on whatever pixels are there.
--
-- The escape hatch is a performance tweak, because the painter issues a band
-- per column per slot and now meets devices on shelves that used to be
-- exempt. Off must mean the old flat look, so the DEFAULT has to be "on" in
-- the read, not merely absent.
--
-- Usage (from plugin root): lua tests/_test_spine_shadows.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq
local shelf    = io.open("lib/bookshelf_spine_shelf.lua"):read("*a")
local settings = io.open("lib/bookshelf_settings.lua"):read("*a")

local body = shelf:match("\nfunction SpineShelf%.shadowsEnabled%(%)\n(.-)\nend\n")
assert(body, "SpineShelf.shadowsEnabled missing")

local function enabledWith(stored)
    local env = { BookshelfSettings = { read = function(_k, dflt)
        if stored == nil then return dflt end
        return stored
    end } }
    local fn = assert(load("return function()\n" .. body .. "\nend", "shadowsEnabled", "t", env))
    return fn()()
end

t.test("on by default, and on when never set", function()
    eq(enabledWith(nil), true)
    eq(enabledWith(false), true)
end)

t.test("off only when the reader turned it off", function()
    eq(enabledWith(true), false)
end)

t.test("the recess no longer asks whether a picture is showing", function()
    local guard = shelf:match("(local ok_wp, Wallpaper = pcall%(require, \"lib/bookshelf_wallpaper\"%).-then)")
    assert(guard, "the recess guard moved")
    assert(guard:find("SpineShelf.shadowsEnabled()", 1, true), "the guard must be the switch")
    assert(not guard:find("isShowing", 1, true), "a picture is no longer the condition")
end)

t.test("the switch is offered as a performance tweak, and drops the plan when flipped", function()
    local row = settings:match('(text = _%("Disable spine mode shadows"%).-\n        },)')
    assert(row, "the performance row is missing")
    assert(row:find("spine_no_shadows", 1, true), "the row must write the setting")
    assert(row:find("dropPlanCache", 1, true),
        "the depth is built into the shelf plan, so a flip has to drop it")
end)

t.done()
