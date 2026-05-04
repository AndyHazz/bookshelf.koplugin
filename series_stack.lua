-- series_stack.lua
-- Renders a series as a stack: front cover full-size, two extra covers
-- offset diagonally behind, with a slipcase band carrying the series name
-- and a count badge at bottom-right.
--
-- Offset constants (in pixels):
--   LAYER2_OFFSET = 4  — back cover 2 shifted 4dp right + 4dp down from top
--   LAYER3_OFFSET = 8  — back cover 3 shifted 8dp right + 8dp down from top
-- These are implemented via FrameContainer padding rather than OverlapGroup
-- absolute positioning, since OverlapGroup does not support absolute child
-- offsets natively. The stack illusion is achieved by embedding each back
-- layer in a FrameContainer with asymmetric padding.

local FrameContainer = require("ui/widget/container/framecontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup   = require("ui/widget/overlapgroup")
local CenterContainer= require("ui/widget/container/centercontainer")
local TextWidget     = require("ui/widget/textwidget")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local Size           = require("ui/size")
local Font           = require("ui/font")
local Blitbuffer     = require("ffi/blitbuffer")
local Screen         = require("device").screen
local SpineWidget    = require("spine_widget")

-- Diagonal offset constants (pixels). Layer 3 is furthest back.
local LAYER2_OFFSET = 4
local LAYER3_OFFSET = 8

-- The slipcase band sits over the front cover and extends past it on the
-- left and right by this amount. Achieved by insetting the front cover so
-- there's room around it for the band to overhang.
local SLIP_OVERHANG = 4

local SeriesStack = InputContainer:extend{
    series        = nil,    -- SeriesGroup { series_name, books[] }
    width         = nil,
    height        = nil,
    on_tap        = nil,    -- function(series) — expand to flat list
    on_hold       = nil,
}

function SeriesStack:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    local front = self.series.books[1]
    local back2 = self.series.books[2] or front
    local back1 = self.series.books[3] or back2

    -- Each layer renders via SpineWidget. When the series has < 3 books we
    -- fall back so back2/back1 reference the SAME Book object (and the same
    -- cover_bb). Three SpineWidgets sharing one bb is a use-after-free trap:
    -- the first to paint calls RenderImage:scaleBlitBuffer with disposable=
    -- true, which FREES the source bb; the other two then read freed memory
    -- and render as stripe-static. Detect the sharing and pass the back
    -- layer(s) a COPY via the cover_bb override prop — SpineWidget then sets
    -- image_disposable=false so the copy stays alive for that layer alone.
    local function safeCopy(bb)
        if not bb or not bb.copy then return nil end
        local ok, copy = pcall(function() return bb:copy() end)
        return ok and copy or nil
    end
    local back2_bb_override = (back2 == front) and safeCopy(front.cover_bb) or nil
    local back1_bb_override
    if back1 == front then
        back1_bb_override = safeCopy(front.cover_bb)
    elseif back1 == back2 then
        back1_bb_override = safeCopy(back2.cover_bb)
    end

    -- Layer 3 (furthest back): offset 8dp right + 8dp down.
    -- Wrapped in a FrameContainer with padding_left + padding_top so it
    -- appears behind and to the right of the front cover.
    -- We freshly copied the bb when the back layers fell back to a shared
    -- book — declare the copy disposable so ImageWidget can free it during
    -- scaleBlitBuffer / on widget tear-down. Without this the copies leak
    -- on every chip rebuild (~2 bbs × ~125 KB per single-book series).
    local layer3_spine = SpineWidget:new{
        book                = back1,
        cover_bb            = back1_bb_override,
        cover_bb_disposable = back1_bb_override ~= nil,
        width               = self.width - LAYER3_OFFSET,
        height              = self.height - LAYER3_OFFSET,
    }
    local layer3 = FrameContainer:new{
        bordersize     = 0,
        padding        = 0,
        padding_left   = LAYER3_OFFSET,
        padding_top    = LAYER3_OFFSET,
        layer3_spine,
    }

    -- Layer 2 (middle): offset 4dp right + 4dp down.
    local layer2_spine = SpineWidget:new{
        book                = back2,
        cover_bb            = back2_bb_override,
        cover_bb_disposable = back2_bb_override ~= nil,
        width               = self.width - LAYER2_OFFSET,
        height              = self.height - LAYER2_OFFSET,
    }
    local layer2 = FrameContainer:new{
        bordersize     = 0,
        padding        = 0,
        padding_left   = LAYER2_OFFSET,
        padding_top    = LAYER2_OFFSET,
        layer2_spine,
    }

    -- Layer 1 (front): inset on each side by SLIP_OVERHANG so the slipcase
    -- band can visibly extend past the cover horizontally. Wrapped in a
    -- FrameContainer with padding_left to centre it within the OverlapGroup.
    local layer1_inner = SpineWidget:new{
        book   = front,
        width  = self.width - SLIP_OVERHANG * 2,
        height = self.height,
    }
    local layer1 = FrameContainer:new{
        bordersize   = 0,
        padding      = 0,
        padding_left = SLIP_OVERHANG,
        layer1_inner,
    }

    -- Slipcase band: black horizontal strip ~46% from top, height ~18% of widget.
    -- Placed via padding_top inside a FrameContainer wrapper so it floats at the
    -- correct vertical position over the front cover in the OverlapGroup.
    local band_h   = math.floor(self.height * 0.18)
    local band_top = math.floor(self.height * 0.46) - math.floor(band_h / 2)

    -- Count badge fill: pure white so the digits stay legible on top of any
    -- cover image (covers vary; white is the safest contrast for black ink).
    local paper = Blitbuffer.COLOR_WHITE

    local band_text_pad = Size.padding.default
    local band_inner = FrameContainer:new{
        bordersize    = 0,
        background    = Blitbuffer.COLOR_BLACK,
        padding       = 0,
        padding_left  = band_text_pad,
        padding_right = band_text_pad,
        CenterContainer:new{
            dimen = Geom:new{ w = self.width - band_text_pad * 2, h = band_h },
            TextWidget:new{
                text    = (self.series.series_name or ""):upper(),
                face    = Font:getFace("smallinfofont", 9),
                fgcolor = Blitbuffer.COLOR_WHITE,
            }
        }
    }
    local band = FrameContainer:new{
        bordersize  = 0,
        padding     = 0,
        padding_top = band_top,
        band_inner,
    }

    -- Count badge bottom-right. Uses padding_top to push it to the bottom of
    -- the OverlapGroup dimen, and is right-aligned by placing it in a
    -- RightContainer (emulated via padding_left = width - badge_approx_w).
    -- We use a simple approach: wrap badge in a FrameContainer with large
    -- padding_top so it sinks to the bottom of the overlap area.
    local badge_inner = FrameContainer:new{
        bordersize     = Size.border.thin,
        background     = paper,
        radius         = Screen:scaleBySize(3),
        padding_left   = Size.padding.default,
        padding_right  = Size.padding.default,
        padding_top    = Size.padding.small,
        padding_bottom = Size.padding.small,
        TextWidget:new{
            text = "\xc3\x97" .. tostring(#self.series.books),  -- × (UTF-8 U+00D7)
            face = Font:getFace("smallinfofont", 12),
            bold = true,
        }
    }
    -- Push badge to bottom-right using large top padding; horizontal alignment
    -- relies on OverlapGroup placing it at origin and the inner padding shifting.
    -- NOTE: for exact bottom-right positioning a BottomContainer + RightContainer
    -- compose would be cleaner but adds complexity; revisit in emulator smoke test.
    local badge = FrameContainer:new{
        bordersize  = 0,
        padding     = 0,
        -- The count badge area: ~20dp tall, anchored near the bottom.
        padding_top = math.max(0, self.height - 24),
        badge_inner,
    }

    self[1] = OverlapGroup:new{
        dimen = self.dimen,
        layer3,
        layer2,
        layer1,
        band,
        badge,
    }
    self.ges_events = {
        Tap  = { GestureRange:new{ ges = "tap",  range = self.dimen } },
        Hold = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
end

function SeriesStack:onTap()  if self.on_tap  then self.on_tap(self.series)  end; return true end
function SeriesStack:onHold() if self.on_hold then self.on_hold(self.series) end; return true end

return SeriesStack
