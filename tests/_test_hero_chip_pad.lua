-- tests/_test_hero_chip_pad.lua
-- The gap between the hero slot and the chip strip.
--
-- THE REPORT (maintainer, on a PW5). With the status line disabled, the
-- expanded shelf has visibly more space above the chip bar than below it.
-- Their guess was right: the gap is there for the pointer triangle that sits
-- on the selected chip when the top area is showing, and in expanded mode
-- with no strip there is no triangle and nothing to separate the chips from.
--
-- MEASURED on the rig, panel and bar edges from the rendered framebuffer:
--
--     before          panel 18..123   bar 54..106   above=36  below=17
--     after           panel 18..106   bar 37..89    above=19  below=17
--     status line on  panel 18..164   bar 95..147   above=77  below=17
--
-- The top panel bleeds equally above and below (PAD - floor(PAD/2) = 19), so
-- hero_chip_pad was the whole of the asymmetry. With the strip present it
-- stays, because then there IS something above the chips. The residual 2px
-- is the chip strip painting two border-widths taller than it declares,
-- which is documented at ChipBar:paintTo.
--
-- WHY A HELPER. hero_chip_pad was the same expression copied to three sites
-- that MUST agree -- the row-count budget, the layout, and the list-mode
-- band. A probe that changed only one of them rendered identically and cost
-- an hour of wrong conclusions. They go through one function now.
--
-- Usage (from plugin root): lua tests/_test_hero_chip_pad.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq
local src = io.open("lib/bookshelf_widget.lua"):read("*a")

local body = src:match("(function BookshelfWidget:_heroChipPad.-\nend)")
assert(body, "_heroChipPad moved or was renamed")

local function pad(opts)
    local env = { Size = { padding = { large = 17 } } }
    local BookshelfWidget = {}
    env.BookshelfWidget = BookshelfWidget
    assert(load(body, "pad", "t", env))()
    local self_ = {
        _expanded = opts.expanded,
        _expandedStripEmpty = function() return opts.empty and true or false end,
    }
    return BookshelfWidget._heroChipPad(self_, 37, opts.arg)
end

t.test("collapsed shelves keep the full pad, whatever the strip would do", function()
    eq(pad{ expanded = false, empty = true }, 37,
       "the regular view must be untouched -- the maintainer asked explicitly")
    eq(pad{ expanded = false, empty = false }, 37)
end)

t.test("expanded with a strip keeps the gap the pointer needs", function()
    eq(pad{ expanded = true, empty = false }, 17,
       "there is something above the chips, so the separation still earns its place")
end)

t.test("expanded with NO strip reserves nothing", function()
    eq(pad{ expanded = true, empty = true }, 0,
       "no strip means no triangle and nothing to separate the chips from")
end)

t.test("an explicit expanded argument overrides the widget's own state", function()
    -- _listBandUncached is asked to cost a band for a state the widget is
    -- not currently in, so the parameter has to win.
    eq(pad{ expanded = false, empty = true, arg = true }, 0)
    eq(pad{ expanded = true,  empty = true, arg = false }, 37)
end)

t.test("all four call sites go through the helper", function()
    -- The bug this prevents: copies of one expression, where changing one
    -- changes nothing visible and looks like the theory was wrong. _rebuild
    -- asks twice (sizing the rows, then laying the gap down), the list band
    -- once, and the expanded row budget once (_expandedBand, which used to
    -- carry a frozen Size.padding.large of its own).
    local n = select(2, src:gsub("self:_heroChipPad%(", ""))
    eq(n, 4, "expected four callers, found " .. n)
    local band = src:match("\nfunction BookshelfWidget:_expandedBand%(.-%)\n(.-)\nend\n")
    assert(band and band:find("self:_heroChipPad(PAD, true)", 1, true),
        "the expanded row budget prices the gap on its own again")
    assert(not src:find("expanded and Size.padding.large or PAD", 1, true),
        "a copy of the old expression is back")
end)

t.test("0 is returned as a number, not left to an and/or chain", function()
    -- `a and 0 or b` happens to work in Lua because 0 is truthy, which is
    -- precisely the reasoning that made issue 439's toggle unturnoffable.
    -- The helper is spelled out; this pins that it stays that way.
    assert(body:find("return 0", 1, true), "the zero case must be an explicit return")
    local chained = body:match("and%s+0%s+or")
    eq(chained, nil, "no and/or chain around the zero")
end)

t.done()
