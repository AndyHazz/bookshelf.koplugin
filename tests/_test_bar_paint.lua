-- tests/_test_bar_paint.lua
-- Every %bar style used to need bookends installed: the hero bar borrowed its
-- painter and, without it, fell back to KOReader's ProgressWidget with only
-- bordered / solid, so the fresh-install default "rounded" drew as a plain
-- square bar for most readers. The painter is now bookshelf's own copy
-- (lib/bookshelf_bar_paint.lua, parity-checked against bookends by
-- tools/check_bar_parity.sh); these pin that the hero / list bar uses it with
-- bookends ABSENT, and that it really draws each style.
package.path = "./?.lua;./?/init.lua;" .. package.path

local H  = dofile("tests/_helpers.lua")
local t  = H.runner()
local eq = H.eq

-- bookends is NOT installed: any attempt to load it fails, as it would on a
-- device without the plugin.
for _i, m in ipairs({ "bookends_overlay_widget", "bookends_colour",
                      "bookends_pacman_sprite" }) do
    package.loaded[m] = nil
    package.preload[m] = function() error("bookends is not installed") end
end

-- ffi, in the two calls the painter makes: a colour is "RGB32" when it is a
-- table carrying .r. Stubbed under luajit too: the real ffi has no
-- ColorRGB32 cdef outside KOReader.
local RGB_T = {}
package.loaded["ffi"] = {
    typeof = function() return RGB_T end,
    istype = function(ct, c) return ct == RGB_T and type(c) == "table" and c.r ~= nil end,
}
local function grey(v) return { a = v } end
package.loaded["ffi/blitbuffer"] = {
    COLOR_BLACK = grey(0), COLOR_DARK_GRAY = grey(0x88), COLOR_GRAY = grey(0xAA),
    COLOR_GRAY_5 = grey(0x55), COLOR_WHITE = grey(0xFF),
    Color8 = grey,
    ColorRGB32 = function(r, g, b, a) return { r = r, g = g, b = b, a = a } end,
    isColor8 = function(c) return c.r == nil end,
}
package.loaded["device"] = {
    screen = {
        scaleBySize = function(_s, v) return v end,
        isColorEnabled = function() return false end,
    },
}
package.loaded["ui/font"] = { getFace = function() return {} end }
package.loaded["ui/rendertext"] = { getGlyph = function() return nil end }
package.loaded["ui/geometry"] = { new = function(_self, o) return o or {} end }
do
    local W = {}
    W.extend = function(self, subclass)
        subclass = subclass or {}
        setmetatable(subclass, { __index = self })
        return subclass
    end
    W.new = function(self, o)
        o = o or {}
        setmetatable(o, { __index = self })
        if o.init then o:init() end
        return o
    end
    package.loaded["ui/widget/widget"] = W
end

-- A Blitbuffer that records every paint call.
local function recordingBB()
    local calls = {}
    local bb = { calls = calls }
    for _i, m in ipairs({ "paintRect", "paintRectRGB32", "paintRoundedRect",
                          "paintRoundedRectRGB32", "paintBorder",
                          "paintBorderRGB32", "colorblitFrom",
                          "colorblitFromRGB32" }) do
        bb[m] = function(_self, ...)
            calls[#calls + 1] = { op = m, args = { ... } }
        end
    end
    bb.getWidth  = function() return 600 end
    bb.getHeight = function() return 800 end
    return bb
end

local HeroBar = require("lib/bookshelf_hero_bar")

t.test("every line bar style is offered without bookends", function()
    eq(HeroBar.availableStyles(),
       { "bordered", "solid", "rounded", "metro", "wavy", "pacman" },
       "the Bar style cycle must not depend on bookends")
end)

t.test("rounded paints a pill without bookends", function()
    local bb = recordingBB()
    HeroBar:new{ width = 100, height = 10, percentage = 0.5, style = "rounded" }
        :paintTo(bb, 0, 0)
    local rounded = 0
    for _i, c in ipairs(bb.calls) do
        if c.op == "paintRoundedRect" and c.args[6] == 5 then rounded = rounded + 1 end
    end
    assert(rounded > 0, "a 10px rounded bar must paint with radius 5")
end)

t.test("each offered style paints", function()
    for _i, style in ipairs(HeroBar.availableStyles()) do
        local bb = recordingBB()
        HeroBar:new{ width = 120, height = 12, percentage = 0.4, style = style }
            :paintTo(bb, 10, 20)
        assert(#bb.calls > 0, style .. " painted nothing")
    end
end)

t.test("a picked fill reaches the painter in true colour", function()
    local red = { r = 255, g = 0, b = 0, a = 255 }
    local bb = recordingBB()
    HeroBar:new{ width = 100, height = 10, percentage = 0.5, style = "bordered",
                 colors = { fill = red } }:paintTo(bb, 0, 0)
    local seen = false
    for _i, c in ipairs(bb.calls) do
        if c.op:find("RGB32", 1, true) then
            for _j, a in ipairs(c.args) do if a == red then seen = true end end
        end
    end
    assert(seen, "a picked colour fill must go down through an RGB32 paint")
end)

t.test("a see-through track paints no track", function()
    local bb = recordingBB()
    HeroBar:new{ width = 100, height = 10, percentage = 0, style = "solid",
                 colors = { bg = false } }:paintTo(bb, 0, 0)
    for _i, c in ipairs(bb.calls) do
        assert(not (c.op == "paintRect" and c.args[3] == 100),
               "bg = false must leave the track unpainted")
    end
end)

-- One renderer: the bookends branch and the ProgressWidget fallback are gone,
-- so a bar cannot look different depending on what else is installed.
t.test("the hero bar paints with bookshelf's own painter only", function()
    local src = io.open("lib/bookshelf_hero_bar.lua"):read("*a")
    assert(src:find('require("lib/bookshelf_bar_paint")', 1, true),
           "the hero bar must paint with lib/bookshelf_bar_paint")
    assert(not src:find("bookends_overlay_widget", 1, true),
           "the hero bar must not borrow bookends' painter")
    assert(not src:find("progresswidget", 1, true),
           "the hero bar must not fall back to KOReader's ProgressWidget")
    local paint = io.open("lib/bookshelf_bar_paint.lua"):read("*a")
    for req in paint:gmatch('require%("([^"]+)"%)') do
        assert(not req:find("^bookends"), "the painter requires " .. req
               .. ": it must not need bookends")
    end
end)

t.done()
