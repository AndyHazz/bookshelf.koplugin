--- bookshelf_tags_sheet.lua -- a small modal that shows the FULL set of a
--- book's "tag" pills (author / series / collections / genres / folder) when
--- the +N overflow label is tapped in the hero or the long-press book menu.
---
--- Generic framing only: the caller supplies a build_content(avail_w) callback
--- that returns the pill widget laid out to avail_w. The sheet frames it with a
--- title bar and scrolls it when it's taller than the screen. Dismissal mirrors
--- ReviewsModal -- title-bar X, multiswipe, Back key, and a tap outside the
--- frame (the pills inside consume their own taps to drill, so an in-frame tap
--- that reaches us is swallowed without closing).
local Blitbuffer          = require("ffi/blitbuffer")
local CenterContainer     = require("ui/widget/container/centercontainer")
local Device              = require("device")
local FrameContainer      = require("ui/widget/container/framecontainer")
local Geom                = require("ui/geometry")
local GestureRange        = require("ui/gesturerange")
local InputContainer      = require("ui/widget/container/inputcontainer")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local Size                = require("ui/size")
local TitleBar            = require("ui/widget/titlebar")
local UIManager           = require("ui/uimanager")
local VerticalGroup       = require("ui/widget/verticalgroup")
local Screen              = Device.screen
local _                   = require("lib/bookshelf_i18n").gettext

local TagsSheet = InputContainer:extend{
    title         = nil,
    build_content = nil,  -- function(avail_w) -> widget laid out to avail_w
    width         = nil,  -- optional override; defaults to ~86% screen width
}

function TagsSheet:init()
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    self.width = self.width or math.floor(screen_w * 0.86)
    -- One uniform inset on ALL sides of the pill block (top below the title
    -- line, bottom, left, right). The title bar's own below-line padding is
    -- zeroed (bottom_v_padding) so this is the only top gap -- otherwise the
    -- top reads larger than the bottom.
    local pad = Screen:scaleBySize(20)

    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    if Device:isTouchDevice() then
        local full = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h }
        self.ges_events = {
            TapClose   = { GestureRange:new{ ges = "tap",        range = full } },
            MultiSwipe = { GestureRange:new{ ges = "multiswipe", range = full } },
        }
    end

    self.titlebar = TitleBar:new{
        width            = self.width,
        align            = "left",
        with_bottom_line = true,
        bottom_v_padding = 0,   -- uniform `pad` below supplies the gap instead
        title            = self.title or _("Tags"),
        close_callback   = function() self:onClose() end,
        show_parent      = self,
    }

    -- Reserve the vertical scrollbar's width up front so the content is laid
    -- out to the same width whether or not it ends up scrolling -- no reflow
    -- when the scrollbar appears.
    local scrollbar_w = ScrollableContainer:getScrollbarWidth()
    local avail_w = self.width - 2 * pad - scrollbar_w
    if avail_w < Screen:scaleBySize(40) then avail_w = Screen:scaleBySize(40) end
    self.content = self.build_content(avail_w)

    local titlebar_h = self.titlebar:getSize().h
    local content_h  = self.content:getSize().h
    -- Centre the pill block within the available width (its own rows are
    -- already centred relative to each other; this centres the whole block).
    local centered = CenterContainer:new{
        dimen = Geom:new{ w = avail_w, h = content_h },
        self.content,
    }
    -- Cap the visible content to what fits, leaving room for the title bar,
    -- frame border and the top/bottom pad; scroll past the cap.
    local max_h = screen_h - titlebar_h - 2 * pad
        - 2 * Size.border.window - Screen:scaleBySize(24)
    if max_h < Screen:scaleBySize(80) then max_h = Screen:scaleBySize(80) end

    local body
    if content_h > max_h then
        local scroll = ScrollableContainer:new{
            dimen       = Geom:new{ w = avail_w + scrollbar_w, h = max_h },
            show_parent = self,
            centered,
        }
        -- UIManager needs this to crop inner self-repaints/inverts (the pill
        -- tap-feedback flash) to the scroll area -- see ScrollableContainer's
        -- header comment.
        self.cropping_widget = scroll
        body = scroll
    else
        body = centered
    end

    -- Uniform padding on all four sides of the body, below the title bar.
    local padded = FrameContainer:new{
        bordersize = 0,
        padding    = pad,
        margin     = 0,
        body,
    }

    self.frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        radius     = Size.radius.window,
        bordersize = Size.border.window,
        padding    = 0,
        VerticalGroup:new{
            align = "center",
            self.titlebar,
            padded,
        },
    }

    self[1] = CenterContainer:new{
        dimen = Geom:new{ w = screen_w, h = screen_h },
        self.frame,
    }
end

function TagsSheet:onShow()
    UIManager:setDirty(self, function() return "ui", self.frame.dimen end)
    return true
end

function TagsSheet:onCloseWidget()
    UIManager:setDirty(nil, function() return "ui", self.frame.dimen end)
end

-- Tap outside the frame dismisses; an in-frame tap that reaches us (not
-- consumed by a pill) is swallowed without closing.
function TagsSheet:onTapClose(_arg, ges)
    if ges and ges.pos and self.frame.dimen
            and ges.pos:notIntersectWith(self.frame.dimen) then
        self:onClose()
    end
    return true
end

function TagsSheet:onMultiSwipe()
    self:onClose()
    return true
end

function TagsSheet:onClose()
    UIManager:close(self)
    return true
end

return TagsSheet
