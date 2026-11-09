-- tests/_test_swatch_night.lua
-- A colour swatch shows its own colour in night mode.
--
-- Night mode inverts what is painted, whichever way the device does it: the
-- panel (a PW5, a Kobo), the paint (KOReader's Lua blit), or the whole frame
-- (Android). A swatch painted as it is came out as its opposite, so the tile
-- that looked green was #8B008B; picked, it was stored night-inverted as
-- #74FF74 and the shelf's text showed purple (maintainer, Android).
package.path = "./?.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq

local SRC = io.open("lib/bookshelf_color_palette.lua"):read("*a")
local BODY = assert(SRC:match("\nfunction Swatch:paintTo%(bb, x, y%)\n(.-)\nend\n"), "Swatch:paintTo moved")

local function rgb(r, g, b) return { r = r, g = g, b = b,
    getR = function(c) return c.r end } end
local inverting = false
local painted
local env = setmetatable({
    Geom = { new = function(_, o) return o end },
    Space = { px = function(n) return n end },
    Size = { border = { thin = 1 } },
    Blitbuffer = { ColorRGB32 = function(r, g, b) return rgb(r, g, b) end,
                   COLOR_BLACK = {}, COLOR_GRAY = {} },
    require = function(n)
        if n == "lib/bookshelf_popup_kit" then
            return { RADIUS = 4, SHADOW = {}, STRIP_BG = {}, shadowSize = function() return 1 end }
        elseif n == "lib/bookshelf_color" then
            return { paintRoundedRect = function(_bb, _x, _y, _w, _h, c) painted = c end }
        elseif n == "lib/bookshelf_night_mode_sync" then
            return { active = function() return inverting end }
        end
        return require(n)
    end,
}, { __index = _G })
local src = "local self, bb, x, y = ...\n" .. BODY
local paint
if setfenv then paint = assert(loadstring(src)); setfenv(paint, env)
else paint = assert(load(src, "swatch", "t", env)) end

local bb = { paintRoundedRect = function() end, paintBorder = function() end,
             getInverse = function() return inverting and 1 or 0 end }
local function swatch(o)
    o.side = 60
    o._fill = rgb(0x74, 0xFF, 0x74)
    return o
end

t.test("by day a swatch paints its own colour", function()
    inverting = false
    paint(swatch{ hex = "#74FF74" }, bb, 0, 0)
    eq(painted.r, 0x74); eq(painted.g, 0xFF); eq(painted.b, 0x74)
end)

t.test("in night mode it paints the colour inverted, so it shows as itself", function()
    inverting = true
    paint(swatch{ hex = "#74FF74" }, bb, 0, 0)
    eq(painted.r, 0x8B); eq(painted.g, 0x00); eq(painted.b, 0x8B)
end)

t.done()
