-- tests/_test_transparent_text.lua
-- A text block that composites over whatever is behind it.
--
-- WHAT NEEDS PINNING. KOReader's TextBoxWidget renders into its own bitmap
-- (`_bb`, filled with bgcolor) and blits that opaquely, which is why the hero
-- card over a wallpaper used to wrap its whole column in an alpha mask: a
-- second render of everything, into a scratch the size of the column, per
-- hero build. The widget's own bitmap IS the mask: black text on white,
-- inverted, is exactly the coverage colorblitFromRGB32 wants. So: render as
-- black on white whatever ink was asked for, and apply the ink at paint,
-- with no second render and no scratch. (Idea taken from a community patch.)
--
-- Usage (from plugin root): lua tests/_test_transparent_text.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

-- Stubs: a TextBoxWidget base whose init renders a fake bitmap, and colours
-- that are distinguishable tables rather than cdata.
local WHITE, BLACK, INK = { name = "white" }, { name = "black" }, { name = "ink" }
package.loaded["ffi/blitbuffer"] = { COLOR_WHITE = WHITE, COLOR_BLACK = BLACK, TYPE_BB8 = 1 }
local base_paints = 0
local Base = {}
Base.__index = Base
function Base:extend(spec)
    spec = spec or {}
    spec.__index = spec
    return setmetatable(spec, { __index = self })
end
function Base:new(o)
    o = o or {}
    setmetatable(o, { __index = self })
    if o.init then o:init() end
    return o
end
function Base:init()
    -- what TextBoxWidget:init does: render the text into _bb with fg on bg
    self.rendered_fg, self.rendered_bg = self.fgcolor, self.bgcolor
    local bb = { inverts = 0, w = self.width or 10, h = 4 }
    bb.getHeight = function() return bb.h end
    bb.getWidth  = function() return bb.w end
    bb.invertRect = function() bb.inverts = bb.inverts + 1 end
    self._bb = bb
    self.dimen = { w = self.width or 10, h = 4 }
end
function Base:paintTo(bb, x, y) base_paints = base_paints + 1 end
package.loaded["ui/widget/textboxwidget"] = Base

package.loaded["lib/bookshelf_transparent_text"] = nil
local TT = dofile("lib/bookshelf_transparent_text.lua")

local function target()
    local calls = {}
    return { calls = calls,
             colorblitFrom = function(_s, src, x, y, ox, oy, w, h, color)
                 calls[#calls + 1] = { src = src, x = x, y = y, w = w, h = h, color = color } end }, calls
end

t.test("renders black on white whatever ink is asked for", function()
    local w = TT:new{ text = "hello", width = 20, fgcolor = INK }
    eq(w.rendered_fg, BLACK)
    eq(w.rendered_bg, WHITE)
    eq(w.ink, INK, "the asked-for colour is kept for paint")
end)

t.test("paints its own bitmap as the mask, in the ink, and leaves it as it found it", function()
    local w = TT:new{ text = "hello", width = 20, fgcolor = INK }
    local bb, calls = target()
    base_paints = 0
    w:paintTo(bb, 7, 9)
    eq(#calls, 1)
    eq(calls[1].src, w._bb, "the widget's own bitmap is the mask")
    eq(calls[1].color, INK)
    eq(calls[1].x, 7); eq(calls[1].y, 9); eq(calls[1].w, 20); eq(calls[1].h, 4)
    eq(w._bb.inverts, 2, "inverted to make the mask, inverted back afterwards")
    eq(base_paints, 0, "no opaque blit")
    eq(w.dimen.x, 7); eq(w.dimen.y, 9)
end)

t.test("without a bitmap it falls back to the base paint rather than failing", function()
    local w = TT:new{ text = "hello", width = 20, fgcolor = INK }
    w._bb = nil
    local bb = target()
    base_paints = 0
    w:paintTo(bb, 0, 0)
    eq(base_paints, 1)
end)

t.test("a failing blit restores the bitmap and paints the opaque block instead", function()
    local w = TT:new{ text = "hello", width = 20, fgcolor = INK }
    local bb = { colorblitFrom = function() error("boom") end }
    base_paints = 0
    w:paintTo(bb, 0, 0)
    eq(base_paints, 1, "readable text in a box beats no text")
    eq(w._bb.inverts, 2, "the bitmap must not be left inverted")
end)

t.test("no ink asked for means black, as TextBoxWidget defaults", function()
    local w = TT:new{ text = "hello", width = 20 }
    eq(w.ink, BLACK)
end)

t.done()
