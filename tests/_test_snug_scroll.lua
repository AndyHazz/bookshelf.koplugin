-- tests/_test_snug_scroll.lua
-- The scrollbar is a rail: a left rule the full height, and the thumb from it
-- to the edge -- no top, right or bottom border of its own.
--
-- Usage (from plugin root): lua tests/_test_snug_scroll.lua
--
-- Maintainer: "as if the scroll bar had no top, right or bottom border of its
-- own, just a left border running top to bottom of the scroll area".

package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

package.loaded["ui/geometry"] = { new = function(_s, o) return o end }
local SC = setmetatable({}, { __index = function() return function() end end })
SC.extend = function(self, o) return setmetatable(o or {}, { __index = self }) end
package.loaded["ui/widget/container/scrollablecontainer"] = SC
local Snug = dofile("lib/bookshelf_snug_scroll.lua")

local function paint(low, high)
    local rects = {}
    local bb = { paintRect = function(_s, x, y, w, h, c) rects[#rects + 1] = { x, y, w, h, c } end,
                 paintBorder = function() error("a box was drawn") end }
    local bar = { enable = true, width = 8, height = 100, bordersize = 2, bordercolor = "B",
                  rectcolor = "T", min_thumb_size = 4, extra_touch_on_side = 8, low = low, high = high }
    Snug._railPaint(bar, bb, 10, 20)
    return rects, bar
end

t.test("a left rule the bar's full height, no box", function()
    local r = paint(0, 0.25)
    eq(r[1][1], 10); eq(r[1][2], 20); eq(r[1][3], 2); eq(r[1][4], 100); eq(r[1][5], "B")
end)

t.test("the thumb runs from the rule to the edge, over its share", function()
    local r = paint(0.5, 0.75)
    eq(r[2][1], 12, "the thumb overlaps the rule or leaves a gap")
    eq(r[2][3], 6, "the thumb stops short of the right edge")
    eq(r[2][2], 70); eq(r[2][4], 25)
end)

t.test("the thumb never runs past the bottom", function()
    local r = paint(0.99, 1)
    eq(r[2][2] + r[2][4], 120)
end)

t.test("the touch area survives the restyle", function()
    local _r, bar = paint(0, 1)
    eq(bar.touch_dimen.x, 2); eq(bar.touch_dimen.w, 24); eq(bar.touch_dimen.h, 100)
end)

t.done()
