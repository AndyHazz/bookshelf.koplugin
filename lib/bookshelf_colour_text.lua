--[[
bookshelf_colour_text.lua -- KOReader's TextWidget, but a colour fgcolor stays
a colour.

TextWidget draws each glyph with bb:colorblitFrom, which flattens its colour to
one grey (getColor8A) before it reaches the buffer. So on a colour screen every
single-line text Bookshelf draws in a colour the reader picked -- a badge's
text, the selected shelf button's label, the bookmark ribbon and the other
glyph badges, the shelf's own "Text ink" -- came out as that colour's grey.
KOReader's TextBoxWidget already switches to colorblitFromRGB32 for a colour
fgcolor; this does the same for TextWidget.

Everything else is TextWidget's own: sizing, shaping, truncation, the
non-xtext path. A grey fgcolor, a greyscale buffer, or a KOReader without the
RGB32 blitter all take TextWidget's own paintTo, unchanged. Bookshelf requires
this in place of "ui/widget/textwidget" everywhere, so the swap is one line per
file and a widget built here is a TextWidget in every other respect.
]]

local TextWidget = require("ui/widget/textwidget")
-- Headless tests stub TextWidget with a plain table: hand that straight back.
if type(TextWidget) ~= "table" or type(TextWidget.extend) ~= "function"
        or type(TextWidget.paintTo) ~= "function" then
    return TextWidget
end

local ok_bb, Blitbuffer = pcall(require, "ffi/blitbuffer")
local ok_rt, RenderText = pcall(require, "ui/rendertext")
if not (ok_bb and ok_rt and Blitbuffer.isColor8) then return TextWidget end

local COLOUR_BB = {}
for _i, name in ipairs({ "TYPE_BBRGB32", "TYPE_BBRGB24", "TYPE_BBRGB16" }) do
    if Blitbuffer[name] then COLOUR_BB[Blitbuffer[name]] = true end
end

local ColourTextWidget = TextWidget:extend{}

-- keepColour(c) -> the colour that asks another plugin to leave `c` alone,
-- or nil. The Appearance plugin (Euphoriyy/appearance.koplugin) replaces
-- TextWidget:paintTo and paints every text in the reader's font colour,
-- which put black titles on dark spines (issue 543). Its one way out is its
-- exclusion colour: a widget painted in it gets its original_fgcolor instead
-- (what it does for KOReader's footer). Text Bookshelf colours on purpose --
-- anything but plain black ink, which is left to follow the reader's font
-- colour -- asks for that. Looked up at paint time: plugins load in any order.
local function keepColour(c)
    -- type(), not `c == nil`: a colour is cdata, and comparing it to nil
    -- calls Blitbuffer's __eq, which indexes nil (it crashed on the rig).
    if type(c) == "nil" or (Blitbuffer.isColor8(c) and c.a == 0) then return nil end
    if not package.loaded["ui/font_color"] then return nil end
    local common = package.loaded["lib/common"]
    if type(common) ~= "table" or type(common.EXCLUSION_COLOR) == "nil"
            or type(common.is_excluded) ~= "function" then
        return nil
    end
    return common.EXCLUSION_COLOR
end

function ColourTextWidget:paintTo(bb, x, y)
    local c = self.fgcolor
    if type(c) == "nil" or Blitbuffer.isColor8(c) or not bb.colorblitFromRGB32
            or not COLOUR_BB[bb:getType()] or not self.use_xtext then
        local keep = keepColour(c)
        if not keep then return TextWidget.paintTo(self, bb, x, y) end
        self.original_fgcolor, self.fgcolor = c, keep
        local ok, err = pcall(TextWidget.paintTo, self, bb, x, y)
        self.fgcolor, self.original_fgcolor = c, nil
        if not ok then error(err, 0) end
        return
    end
    -- TextWidget:paintTo's xtext path, with the RGB32 blit.
    self:updateSize()
    if self._is_empty then return end
    if not self._xshaping then
        self._xshaping = self._xtext:shapeLine(self._shape_start, self._shape_end,
                                               self._shape_idx_to_substitute_with_ellipsis)
    end
    local text_width = bb:getWidth() - x
    if self.max_width and self.max_width < text_width then text_width = self.max_width end
    local pen_x = 0
    local baseline = self.forced_baseline or self._baseline_h
    for _i, xglyph in ipairs(self._xshaping) do
        if pen_x >= text_width then break end
        local face = self.face.getFallbackFont(xglyph.font_num)
        local glyph = RenderText:getGlyphByIndex(face, xglyph.glyph, self.bold)
        bb:colorblitFromRGB32(
            glyph.bb,
            x + pen_x + glyph.l + xglyph.x_offset,
            y + baseline - glyph.t - xglyph.y_offset,
            0, 0,
            glyph.bb:getWidth(), glyph.bb:getHeight(),
            c)
        pen_x = pen_x + xglyph.x_advance
    end
end

return ColourTextWidget
