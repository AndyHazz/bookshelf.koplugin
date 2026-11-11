--[[
RunTextBox -- a wrapping text block in which some runs take their own colour.

KOReader's TextBoxWidget breaks the text into lines, truncates it, and draws
it in ONE ink into a private bitmap. It also keeps, per line, a record of the
glyphs it placed: which character each came from and where it sits. So a run
of characters (lib/bookshelf_colour_runs: today the rating stars) can be
coloured after the fact, with the layout left entirely to KOReader:

  1. the base class renders as it always does (black on white, the mask
     TransparentTextBox paints its ink through);
  2. the pixels under each run are copied into a small bitmap of their own and
     wiped from the main one;
  3. paint blends the main bitmap in the ink and each lifted piece in its
     run's colour.

A run split by a line break is two pieces; glyphs the ellipsis cut are simply
not in the record. With KOReader's advanced text shaping turned off there is
no glyph record, nothing is lifted, and the stars stay in the ink.

`runs` is a list of { s, e, colour } in characters of `text`. Without runs
this is a TransparentTextBox.
]]
local TransparentTextBox = require("lib/bookshelf_transparent_text")
local TextBoxWidget      = require("ui/widget/textboxwidget")
local Blitbuffer         = require("ffi/blitbuffer")
local Runs               = require("lib/bookshelf_colour_runs")

local RunTextBox = TransparentTextBox:extend{
    runs    = nil,
    _lifted = nil,   -- { { x, y, w, h, bb, colour } }
}

function RunTextBox:_freeLifted()
    if self._lifted then
        for _, piece in ipairs(self._lifted) do
            if piece.bb and piece.bb.free then piece.bb:free() end
        end
    end
    self._lifted = nil
end

-- Copy each run's pixels out of the freshly rendered bitmap, rows first..last.
-- A piece is wiped from the main bitmap only once its copy exists, so a
-- failure part-way leaves every star drawn somewhere.
function RunTextBox:_liftRuns(first, last)
    self:_freeLifted()
    local m, lines = self._bb, self.vertical_string_list
    if not m or type(lines) ~= "table" or type(self.runs) ~= "table" or #self.runs == 0 then
        return
    end
    local shown = {}
    for i = first, last do shown[#shown + 1] = lines[i] or {} end
    local rects = Runs.rects(shown, self.runs, self.line_height_px or 0)
    if #rects == 0 then return end
    local bw, bh = m:getWidth(), m:getHeight()
    local lifted = {}
    self._lifted = lifted
    for _, r in ipairs(rects) do
        local x = math.max(0, math.floor(r.x))
        local y = math.max(0, r.y)
        local w = math.min(bw, math.ceil(r.x + r.w)) - x
        local h = math.min(bh, r.y + r.h) - y
        if w > 0 and h > 0 then
            local piece = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
            piece:blitFrom(m, 0, 0, x, y, w, h)
            piece:invertRect(0, 0, w, h)   -- black on white > coverage, once
            lifted[#lifted + 1] = { x = x, y = y, w = w, h = h, bb = piece, colour = r.colour }
            m:paintRect(x, y, w, h, Blitbuffer.COLOR_WHITE)
        end
    end
end

function RunTextBox:_renderText(first, last)
    TextBoxWidget._renderText(self, first, last)
    if type(self.runs) == "table" and #self.runs > 0 then
        local ok = pcall(self._liftRuns, self, first, last)
        if not ok and self._lifted and #self._lifted == 0 then self._lifted = nil end
    else
        self:_freeLifted()
    end
end

function RunTextBox:paintTo(bb, x, y)
    TransparentTextBox.paintTo(self, bb, x, y)
    if not self._lifted then return end
    local blend = require("lib/bookshelf_color").blendInk
    for _, piece in ipairs(self._lifted) do
        pcall(blend, bb, piece.bb, x + piece.x, y + piece.y, piece.w, piece.h, piece.colour)
    end
end

function RunTextBox:free(full)
    self:_freeLifted()
    return TextBoxWidget.free(self, full)
end

return RunTextBox
