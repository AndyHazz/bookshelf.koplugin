-- tests/_test_clip_container_colour.lua
-- A module card's background keeps its colour on every colour screen, not
-- only an RGB32 one (issue 565: a PocketBook Era Color is RGB24, and fill()
-- painted every card as its grey). Driven through the real paintTo with a
-- stub Blitbuffer, so the colour path is the one a 24-bit buffer takes.
--
-- Usage (from plugin root): lua tests/_test_clip_container_colour.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local filled, painted_rgb
local function stubBB(btype)
    return {
        getType = function() return btype end,
        fill = function(_s, c) filled = c end,
        paintRectRGB32 = function(_s, _x, _y, _w, _h, c) painted_rgb = c end,
        blitFrom = function() end,
    }
end
local current_type
local BB = {
    TYPE_BB8 = 1, TYPE_BBRGB16 = 2, TYPE_BBRGB24 = 3, TYPE_BBRGB32 = 4,
    COLOR_WHITE = { grey = true },
    isColor8 = function(c) return c.grey == true end,
    new = function(_w, _h, btype) return stubBB(btype) end,
}
package.loaded["ffi/blitbuffer"] = BB
package.loaded["ui/geometry"] = { new = function(_s, o) return o end }
package.loaded["ui/widget/container/widgetcontainer"] = { extend = function(_s, o) return o end }
local Clip = dofile("lib/bookshelf_clip_container.lua")

local red = { getColorRGB32 = function() return "red32" end }
local child = { getSize = function() return { w = 10, h = 10 } end, paintTo = function() end }

local function paint(btype, bg)
    filled, painted_rgb = nil, nil
    current_type = btype
    local c = setmetatable({ w = 40 + btype, h = 40, bg = bg, child }, { __index = Clip })
    c[1] = child
    Clip.paintTo(c, stubBB(btype), 0, 0)
end

for _i, case in ipairs({ { "RGB32", BB.TYPE_BBRGB32 }, { "RGB24 (PocketBook)", BB.TYPE_BBRGB24 },
                         { "RGB16", BB.TYPE_BBRGB16 } }) do
    t.test("a coloured card stays coloured on an " .. case[1] .. " screen", function()
        paint(case[2], red)
        eq(painted_rgb, "red32", "the card was filled with its grey")
        eq(filled, nil)
    end)
end

t.test("a grey card and a greyscale screen take the plain fill", function()
    paint(BB.TYPE_BB8, red)
    eq(filled, red); eq(painted_rgb, nil)
    paint(BB.TYPE_BBRGB24, BB.COLOR_WHITE)
    eq(filled, BB.COLOR_WHITE); eq(painted_rgb, nil)
end)

t.done()
