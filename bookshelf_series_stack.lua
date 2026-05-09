-- bookshelf_series_stack.lua
-- Renders a series/author/genre/tag slot: a single representative book
-- cover with a compact folder card below carrying the group's name, and
-- a count badge ("×N") on the cover's top-right edge to convey "this
-- represents N books".
--
-- The previous design rendered three diagonally-offset book covers
-- (Layer1/2/3) to imply "stack" plus a black series-name band. The
-- back layers were never visually distinguishable from the front
-- (small offsets, identical artwork in single-book series), and they
-- forced a defensive `safeCopy(bb)` of the cover bb to avoid a
-- use-after-free when three SpineWidgets shared one bb. Dropping
-- them removes both the per-paint copy and that whole class of bug.
--
-- The folder card matches FolderStack exactly via folder_card.lua.
-- The count badge is the only thing that distinguishes this widget
-- visually from FolderStack.

local FrameContainer = require("ui/widget/container/framecontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup   = require("ui/widget/overlapgroup")
local TextWidget     = require("ui/widget/textwidget")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local Size           = require("ui/size")
local Font           = require("ui/font")
local Blitbuffer     = require("ffi/blitbuffer")
local Screen         = require("device").screen
local SpineWidget    = require("bookshelf_spine_widget")
local FolderCard     = require("bookshelf_folder_card")

local SeriesStack = InputContainer:extend{
    series  = nil,    -- { series_name, books[] }
    width   = nil,
    height  = nil,
    on_tap  = nil,
    on_hold = nil,
}

function SeriesStack:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    local books = self.series and self.series.books
    local front = books and books[1]

    -- Book layer: full-slot SpineWidget for the representative cover.
    local book_widget
    if front then
        book_widget = SpineWidget:new{
            book       = front,
            width      = self.width,
            height     = self.height,
            cover_fill = true,
        }
    else
        -- Empty group: SpineWidget's fallback path with the group name
        -- as the title (analogous to FolderStack's empty-folder path).
        book_widget = SpineWidget:new{
            book   = { title = self.series and self.series.series_name or "" },
            width  = self.width,
            height = self.height,
        }
    end

    local folder_widget, label_widget = FolderCard.build{
        width  = self.width,
        height = self.height,
        label  = self.series and self.series.series_name or "",
    }

    -- Count badge: white pill with "×N" on the cover's top-right corner,
    -- lifted by SHADOW_OFFSET so it sits proud of the cover top rather
    -- than flush against it. Positioned via overlap_offset (relative to
    -- the slot's top-left). The cover's right edge in slot coords is
    -- (slot_w - SHADOW_OFFSET); we centre the badge on that x so half
    -- hangs off the cover.
    local children = {
        book_widget,
        folder_widget,
        label_widget,
    }
    if books and #books > 0 then
        local badge = FrameContainer:new{
            bordersize     = Size.border.thin,
            background     = Blitbuffer.COLOR_WHITE,
            radius         = Screen:scaleBySize(3),
            padding_left   = Size.padding.default,
            padding_right  = Size.padding.default,
            padding_top    = Size.padding.small,
            padding_bottom = Size.padding.small,
            TextWidget:new{
                text = "\xc3\x97" .. tostring(#books),  -- × (UTF-8 U+00D7)
                face = Font:getFace("smallinfofont", 12),
                bold = true,
            }
        }
        local badge_w = badge:getSize().w
        local cover_right_x = self.width - FolderCard.SHADOW_OFFSET
        local badge_x = math.max(0, math.min(self.width - badge_w,
                                             cover_right_x - math.floor(badge_w / 2)))
        badge.overlap_offset = { badge_x, -FolderCard.SHADOW_OFFSET }
        children[#children + 1] = badge
    end

    children.dimen = self.dimen
    self[1] = OverlapGroup:new(children)
    self.ges_events = {
        Tap  = { GestureRange:new{ ges = "tap",  range = self.dimen } },
        Hold = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
end

function SeriesStack:onTap()  if self.on_tap  then self.on_tap(self.series)  end; return true end
function SeriesStack:onHold() if self.on_hold then self.on_hold(self.series) end; return true end

return SeriesStack
