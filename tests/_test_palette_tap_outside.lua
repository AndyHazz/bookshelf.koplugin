-- tests/_test_palette_tap_outside.lua
-- A tap outside the colour picker closes it, keeping what it shows (each
-- swatch tap already previews, as Apply keeps it). The old black-and-white
-- % dialog took rapid taps, so a tap outside could not close it; the
-- picker's taps are one at a time (maintainer). A tap outside while the hex
-- keyboard is up only puts the keyboard away.
--
-- Usage (from plugin root): lua tests/_test_palette_tap_outside.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local pal = io.open("lib/bookshelf_color_palette.lua"):read("*a")
local body = assert(pal:match("\nfunction ColorPaletteWidget:onTapOutside%(arg, ges%)\n(.-)\nend\n"),
    "onTapOutside moved")
local onTapOutside = assert(load("local self, arg, ges = ...\n" .. body))

local function pos(x, y)
    return { x = x, y = y, notIntersectWith = function(p, r)
        return p.x < r.x or p.y < r.y or p.x >= r.x + r.w or p.y >= r.y + r.h end }
end
local function picker(keyboard)
    local log = {}
    local self = {
        _frame = { dimen = { x = 100, y = 100, w = 500, h = 600 } },
        _keyboardVisible = function() return keyboard end,
        _closeKeyboard = function() log.keyboard_closed = true end,
        hex_input = { keyboard = { dimen = { x = 0, y = 900, w = 800, h = 300 } } },
        ok_callback = function() log.applied = true end,
    }
    return self, log
end

t.test("a tap outside closes the picker, keeping what it shows", function()
    local self, log = picker(false)
    eq(onTapOutside(self, nil, { pos = pos(20, 20) }), true)
    eq(log.applied, true, "the picker stayed open")
end)

t.test("a tap inside the picker leaves it open", function()
    local self, log = picker(false)
    onTapOutside(self, nil, { pos = pos(300, 300) })
    eq(log.applied, nil, "a tap between swatches closed the picker")
end)

t.test("with the keyboard up, a tap outside only puts the keyboard away", function()
    local self, log = picker(true)
    onTapOutside(self, nil, { pos = pos(20, 20) })
    eq(log.keyboard_closed, true)
    eq(log.applied, nil, "the picker closed under the keyboard")
end)

t.done()
