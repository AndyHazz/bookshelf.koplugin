-- lib/bookshelf_cap_centre.lua
-- Centre a one-line label's capitals, not its line box.
--
-- A container centres a TextWidget by its height: the face's ascent plus its
-- descent. Shelf chips are mostly capitals, which have no descender, so where
-- a font's line box is weighted to one side the capitals sit visibly high or
-- low in the chip (Reddit screenshots of the chip bar, after a font change).
-- The default UI fonts are within a pixel; others were measured 2-3 px out in
-- a 50 px chip, and further on fonts with tall or deep line boxes.
--
-- M.centre(tw) measures, once per face, where capitals ("HO", so a round
-- letter's overshoot counts) sit in the line box, and moves the label's
-- baseline by however far that is from the middle. Its box keeps its size, so
-- nothing around it moves.
local M = {}

local _offset = setmetatable({}, { __mode = "k" })   -- face -> { [bold] = px }

-- offsetFor(face, bold) -> px to move the baseline by (positive = down).
function M.offsetFor(face, bold)
    if not face then return 0 end
    local per = _offset[face]
    if per and per[bold and true or false] ~= nil then return per[bold and true or false] end
    local delta = 0
    pcall(function()
        local BB = require("ffi/blitbuffer")
        local TextWidget = require("lib/bookshelf_colour_text")
        local probe = TextWidget:new{ text = "HO", face = face, bold = bold or false,
            fgcolor = BB.COLOR_BLACK, padding = 0 }
        local sz = probe:getSize()
        local bb = BB.new(sz.w, sz.h, BB.TYPE_BB8)
        bb:fill(BB.COLOR_WHITE)
        probe:paintTo(bb, 0, 0)
        local top, bot
        for y = 0, sz.h - 1 do
            for x = 0, sz.w - 1 do
                if bb:getPixel(x, y):getColor8().a < 128 then
                    top = top or y; bot = y
                    break
                end
            end
        end
        bb:free()
        probe:free()
        if top then
            -- Whole pixels only, towards zero: a half-pixel lean is within what
            -- the container's own centring rounds, and rounding it up moved
            -- the default font (Noto) a pixel off in the chip.
            local raw = (sz.h - 1) / 2 - (top + bot) / 2
            delta = raw < 0 and -math.floor(-raw) or math.floor(raw)
        end
    end)
    _offset[face] = per or {}
    _offset[face][bold and true or false] = delta
    return delta
end

-- centre(tw) -> tw, its capitals centred in its own box.
function M.centre(tw)
    if not (tw and tw.face) then return tw end
    local d = M.offsetFor(tw.face, tw.bold)
    if d ~= 0 then
        local base = (tw.getBaseline and tw:getBaseline()) or tw._baseline_h
        if base then tw.forced_baseline = base + d end
    end
    return tw
end

return M
