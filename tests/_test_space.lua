-- tests/_test_space.lua
-- Spacing does not grow with a DPI override (lib/bookshelf_space).
--
-- Usage (from plugin root): lua tests/_test_space.lua
--
-- Maintainer: "at large dpis when space is at a premium, we end up with even
-- less space because all the padding increases with the text size".

package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

-- KOReader's fb:scaleBySize, restated.
local screen = { w = 1236, h = 1648, dpi = nil }
function screen:getWidth() return self.w end
function screen:getHeight() return self.h end
function screen:scaleBySize(px)
    local size_scale = math.min(self.w, self.h) / 600
    local dpi_scale = self.dpi and self.dpi / 160 or size_scale
    return math.ceil(px * (size_scale + dpi_scale) / 2)
end
package.loaded["device"] = { screen = screen }
local Space = dofile("lib/bookshelf_space.lua")

t.test("no override: exactly scaleBySize, so nothing moves", function()
    screen.dpi = nil
    for _i, v in ipairs({ 0.5, 1, 2, 5, 10, 15, 37 }) do
        eq(Space.px(v), screen:scaleBySize(v), "v=" .. v)
    end
end)

t.test("an override at or under the panel's scale: still exactly scaleBySize", function()
    for _i, dpi in ipairs({ 160, 200, 300 }) do   -- a PW5's panel scale is 2.06 (330dpi)
        screen.dpi = dpi
        for _j, v in ipairs({ 1, 5, 10, 15 }) do
            eq(Space.px(v), screen:scaleBySize(v), "dpi=" .. dpi .. " v=" .. v)
        end
    end
end)

t.test("a high override: capped at the panel's scale", function()
    screen.dpi = 480
    eq(screen:scaleBySize(10), 26, "the premise: 10 grew to 26 at 480")
    eq(Space.px(10), 21, "spacing grew with the override")
    screen.dpi = 640
    eq(Space.px(10), 21, "spacing grew past the panel scale")
end)

t.test("the named groups mirror KOReader's Size", function()
    screen.dpi = nil
    eq(Space.padding.large, screen:scaleBySize(10))
    eq(Space.padding.default, screen:scaleBySize(5))
    eq(Space.margin.default, screen:scaleBySize(5))
    eq(Space.span.vertical_default, screen:scaleBySize(2))
    eq(Space.padding.nope, nil)
    screen.dpi = 480
    eq(Space.padding.large, 21, "computed on access, so a DPI change is followed")
end)

t.test("a rotated screen uses its short edge", function()
    screen.dpi, screen.w, screen.h = 480, 1648, 1236
    eq(Space.px(10), 21)
    screen.w, screen.h = 1236, 1648
end)

t.done()
