--[[
TransparentTextBox -- a TextBoxWidget that composites over what is behind it.

KOReader's TextBoxWidget renders its text into a private bitmap (`_bb`,
filled with bgcolor) at init and paintTo blits that OPAQUELY, so a text block
over a wallpaper or a dark ground used to need a wrapper (Wallpaper.mask) that
rendered the whole column a second time into a scratch buffer and used that
as an alpha stencil. But the widget's own bitmap already IS that stencil:
black text on white, inverted, is exactly the coverage colorblitFrom wants
(the source's grey value is the alpha, see setPixelColorize). So this widget
renders as black on white whatever ink is asked for, and at paint time
inverts its bitmap, blends the ink through it, and inverts it back. No second
render, no scratch, and each block keeps its own colour where the mask had
one colour for everything. The idea comes from a community patch.

The invert-blit-invert costs two passes over the widget's own bitmap per
paint (a title line, not the page), and the blend is the same call the mask
made. When the blit fails the base class paints the opaque block instead:
readable text in a box beats no text.
]]
local TextBoxWidget = require("ui/widget/textboxwidget")
local Blitbuffer    = require("ffi/blitbuffer")

local TransparentTextBox = TextBoxWidget:extend{
    -- The colour the text is shown in. Taken from fgcolor at init, which the
    -- render itself never sees: it always draws black on white.
    ink = nil,
}

function TransparentTextBox:init()
    self.ink     = self.fgcolor or Blitbuffer.COLOR_BLACK
    self.fgcolor = Blitbuffer.COLOR_BLACK
    self.bgcolor = Blitbuffer.COLOR_WHITE
    TextBoxWidget.init(self)
end

function TransparentTextBox:paintTo(bb, x, y)
    local m = self._bb
    if not m then return TextBoxWidget.paintTo(self, bb, x, y) end
    self.dimen.x, self.dimen.y = x, y
    local w, h = m:getWidth(), m:getHeight()
    m:invertRect(0, 0, w, h)
    local ok = pcall(bb.colorblitFrom, bb, m, x, y, 0, 0, w, h, self.ink)
    m:invertRect(0, 0, w, h)
    if not ok then TextBoxWidget.paintTo(self, bb, x, y) end
end

return TransparentTextBox
