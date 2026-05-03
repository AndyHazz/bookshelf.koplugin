-- chip_strip.lua
-- Segmented control: zero-gap horizontally-joined chips. Active chip inverts
-- (black fill, paper text). Tap dispatches an on_change(key) callback.
--
-- Border-butting approach: chips are joined by giving each chip (after the
-- first) a padding_left = -Size.border.thin, which shifts the left edge left
-- by one border-width so the adjacent right-border and this left-border
-- overlap at the same pixel. If KOReader's FrameContainer clamps negative
-- padding to zero, the visual gap is a 1px double-border rather than a
-- seamless join — still readable. No divider-widget alternative is needed
-- because the border overlap is only cosmetic.

local FrameContainer = require("ui/widget/container/framecontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local HorizontalGroup= require("ui/widget/horizontalgroup")
local TextWidget     = require("ui/widget/textwidget")
local CenterContainer= require("ui/widget/container/centercontainer")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local Size           = require("ui/size")
local Font           = require("ui/font")
local Blitbuffer     = require("ffi/blitbuffer")

local ChipStrip = InputContainer:extend{
    chips     = nil,   -- list of { key="recent", label="Recent" }
    active    = nil,   -- key of the currently-selected chip
    width     = nil,
    height    = nil,
    on_change = nil,   -- function(key) called when a different chip is tapped
}

function ChipStrip:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    if not self.chips or #self.chips == 0 then
        -- Empty chip-strip: render a no-op widget so callers can still
        -- compose us into a layout without conditionals.
        self[1] = require("ui/widget/widget"):new{ dimen = self.dimen }
        return
    end
    local n = #self.chips
    local chip_w = math.floor(self.width / n)
    local row = HorizontalGroup:new{}
    self._chip_dimens = {}

    -- Inactive chip background: page colour (pure white) so the chip reads as
    -- an outlined button against the page. Active chip is inverted to black.
    local paper = Blitbuffer.COLOR_WHITE

    -- Each chip is a borderless cell; a single outer border around the whole
    -- strip provides the outline. 1dp LineWidget separators between adjacent
    -- chips give the segmented-control look without the double-border issue
    -- that adjacent FrameContainers produced.
    local LineWidget = require("ui/widget/linewidget")
    local separator_w = Size.border.thin
    for i, chip in ipairs(self.chips) do
        if i > 1 then
            row[#row + 1] = LineWidget:new{
                background = Blitbuffer.COLOR_BLACK,
                dimen = Geom:new{ w = separator_w, h = self.height },
            }
        end
        local is_active = (chip.key == self.active)
        -- Last chip absorbs any rounding remainder. Subtract separator widths
        -- from the column so the strip's total still equals self.width.
        local sep_total = separator_w * (n - 1)
        local cell_w = (self.width - sep_total) / n
        local w = (i == n) and (self.width - sep_total - math.floor(cell_w) * (n - 1))
                 or math.floor(cell_w)
        row[#row + 1] = FrameContainer:new{
            bordersize = 0,
            margin     = 0,
            padding    = 0,
            background = is_active and Blitbuffer.COLOR_BLACK or paper,
            CenterContainer:new{
                dimen = Geom:new{ w = w, h = self.height },
                TextWidget:new{
                    text    = (chip.label or ""):upper(),
                    face    = Font:getFace("infofont", 16),
                    bold    = true,
                    fgcolor = is_active and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK,
                }
            }
        }
        -- Track each chip's screen-x range for tap dispatch (cumulative).
        local prev = self._chip_dimens[self.chips[i - 1] and self.chips[i - 1].key]
        local x = prev and (prev.x + prev.w + separator_w) or 0
        self._chip_dimens[chip.key] = { x = x, w = w }
    end
    -- Single outer border framing the whole strip.
    self[1] = FrameContainer:new{
        bordersize = Size.border.thin,
        margin     = 0,
        padding    = 0,
        row,
    }

    -- Single gesture binding for the whole strip; we resolve which chip was
    -- tapped by the x-coordinate within onTapStrip.
    self.ges_events = {
        TapStrip = { GestureRange:new{ ges = "tap", range = self.dimen } },
    }
end

function ChipStrip:onTapStrip(_, ges)
    local x = ges.pos.x - self.dimen.x
    for _, chip in ipairs(self.chips) do
        local d = self._chip_dimens[chip.key]
        if x >= d.x and x < d.x + d.w then
            if self.on_change and chip.key ~= self.active then
                self.on_change(chip.key)
            end
            return true
        end
    end
    return false
end

return ChipStrip
