-- tests/_test_colour_borders.lua
-- Borders and fills in a picked colour keep it on every colour screen.
-- KOReader's paintBorder draws its straight edges with paintRect, and
-- paintRect / paintRoundedRect take a colour's grey on a screen with the C
-- blitter (a colour Kobo, a Kindle Colorsoft): a blue module card border came
-- out grey with only its corners blue. FrameContainer paints its border that
-- way too. Color.paintBorder / paintRoundedRect / colourBorder dispatch to the
-- RGB32 calls for a colour, and leave a grey on the plain ones.
--
-- Usage (from plugin root): lua tests/_test_colour_borders.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local GREY, BLUE = { grey = true }, { blue = true }
package.loaded["ffi/blitbuffer"] = { isColor8 = function(c) return c.grey == true end,
    COLOR_WHITE = { grey = true }, COLOR_BLACK = { grey = true } }
package.loaded["device"] = { isAndroid = function() return false end, screen = {} }
local Color = dofile("lib/bookshelf_color.lua")

local function bb()
    local calls = {}
    local b = { calls = calls }
    for _i, m in ipairs({ "paintBorder", "paintBorderRGB32", "paintRect", "paintRectRGB32",
                          "paintRoundedRect", "paintRoundedRectRGB32" }) do
        b[m] = function(_s, ...) calls[#calls + 1] = m end
    end
    b.getInverse = function() return 0 end
    return b
end

t.test("a picked colour takes the RGB32 calls, a grey the plain ones", function()
    local b = bb()
    Color.paintBorder(b, 0, 0, 10, 10, 1, BLUE, 2)
    Color.paintBorder(b, 0, 0, 10, 10, 1, GREY, 2)
    Color.paintRoundedRect(b, 0, 0, 10, 10, BLUE, 2)
    Color.paintRoundedRect(b, 0, 0, 10, 10, GREY, 2)
    eq(table.concat(b.calls, ","), "paintBorderRGB32,paintBorder,paintRoundedRectRGB32,paintRoundedRect")
end)

t.test("a frame's border is drawn again in its colour, where it was", function()
    local b = bb()
    local frame = { bordersize = 1, color = BLUE, margin = 2, radius = 3,
        getSize = function() return { w = 40, h = 20 } end,
        paintTo = function() end }
    Color.colourBorder(frame)
    local args
    b.paintBorderRGB32 = function(_s, ...) args = { ... } end
    frame:paintTo(b, 10, 20)
    eq(table.concat(args, ",", 1, 5), "12,22,36,16,1")
    eq(args[7], 3)
    frame.color = GREY
    args = nil
    frame:paintTo(b, 10, 20)
    eq(args, nil, "a grey frame was painted twice")
end)

t.test("picked colours reach these borders and fills through the colour-aware calls", function()
    local function has(path, needle)
        local src = io.open(path):read("*a")
        assert(src:find(needle, 1, true), path .. " lost: " .. needle)
    end
    has("lib/bookshelf_hero_modules.lua", 'require("lib/bookshelf_color").colourBorder(FrameContainer:new{')
    has("lib/bookshelf_hero_modules.lua", 'require("lib/bookshelf_color").paintBorder(bb, dx, dy')
    has("lib/bookshelf_count_badge.lua", 'require("lib/bookshelf_color").colourBorder(FrameContainer:new{')
    has("lib/bookshelf_widget.lua", 'require("lib/bookshelf_color").colourBorder(FrameContainer_:new{')
    has("micromodules/battery.lua", "Color.paintBorder(bb, bx, by")
    local add = io.open("lib/bookshelf_add_tile.lua"):read("*a")
    assert(not add:find("bb:paintRect(x", 1, true), "the add tile's dashes take the ink's grey")
end)

t.done()
