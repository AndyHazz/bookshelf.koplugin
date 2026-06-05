-- bookshelf_reviews_modal.lua
-- A small modal that renders Hardcover review HTML (built + sanitised by
-- bookshelf_tokens.reviewsHtml) through KOReader's MuPDF-backed
-- ScrollHtmlWidget, so reviewer names can be italic, headers bold, and the
-- review body keeps its own paragraph/emphasis formatting.
--
-- This replaces the previous plain-text TextViewer for reviews: TextViewer
-- has no inline markup. We keep a title bar plus Refresh / Close buttons and
-- close on a tap outside the frame, mirroring the standard popup idiom.

local Blitbuffer      = require("ffi/blitbuffer")
local ButtonTable     = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local InputContainer  = require("ui/widget/container/inputcontainer")
local MovableContainer = require("ui/widget/container/movablecontainer")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local Size            = require("ui/size")
local TitleBar        = require("ui/widget/titlebar")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local Screen          = Device.screen
local _               = require("lib/bookshelf_i18n").gettext

-- Minimal stylesheet for the MuPDF HTML renderer. Keep it conservative --
-- the engine supports a CSS subset. The body margin gives a little side
-- breathing room since the frame itself has no inner horizontal padding.
local REVIEW_CSS = [[
    body   { margin: 0 0.6em; font-family: sans-serif; }
    h2     { font-size: 1.1em; margin: 0.2em 0 0.3em 0; }
    p      { margin: 0.35em 0; text-align: left; }
    hr     { border: 0; border-top: 1px solid #888888; margin: 0.6em 0; }
    i, em       { font-style: italic; }
    b, strong   { font-weight: bold; }
    blockquote  { margin: 0.4em 1em; color: #444444; }
    ul, ol      { margin: 0.3em 0 0.3em 1.2em; }
]]

local ReviewsModal = InputContainer:extend{
    title      = nil,
    html_body  = nil,
    width      = nil,
    height     = nil,
    on_refresh = nil,   -- optional callback fired by the Refresh button
}

function ReviewsModal:init()
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    self.width  = self.width  or math.floor(screen_w * 0.92)
    self.height = self.height or math.floor(screen_h * 0.86)

    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    if Device:isTouchDevice() then
        self.ges_events = {
            TapClose = {
                GestureRange:new{
                    ges = "tap",
                    range = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h },
                },
            },
        }
    end

    self.titlebar = TitleBar:new{
        width            = self.width,
        align            = "left",
        with_bottom_line = true,
        title            = self.title or _("Hardcover reviews"),
        close_callback   = function() self:onClose() end,
        show_parent      = self,
    }

    local buttons = ButtonTable:new{
        width = self.width,
        buttons = {
            {
                {
                    text = _("Refresh"),
                    callback = function()
                        local cb = self.on_refresh
                        self:onClose()
                        if cb then cb() end
                    end,
                },
                {
                    text = _("Close"),
                    callback = function() self:onClose() end,
                },
            },
        },
        show_parent = self,
    }

    local titlebar_h = self.titlebar:getSize().h
    local buttons_h  = buttons:getSize().h
    local html_h     = self.height - titlebar_h - buttons_h
    if html_h < Screen:scaleBySize(80) then
        html_h = Screen:scaleBySize(80)
    end

    self.scroll_html = ScrollHtmlWidget:new{
        html_body         = self.html_body or "",
        css               = REVIEW_CSS,
        default_font_size = Screen:scaleBySize(18),
        width             = self.width,
        height            = html_h,
        dialog            = self,
    }

    self.frame = FrameContainer:new{
        background  = Blitbuffer.COLOR_WHITE,
        radius      = Size.radius.window,
        bordersize  = Size.border.window,
        padding     = 0,
        VerticalGroup:new{
            align = "left",
            self.titlebar,
            self.scroll_html,
            buttons,
        },
    }

    self[1] = CenterContainer:new{
        dimen = Geom:new{ w = screen_w, h = screen_h },
        MovableContainer:new{ self.frame },
    }
end

function ReviewsModal:onShow()
    UIManager:setDirty(self, function()
        return "ui", self.frame.dimen
    end)
    return true
end

function ReviewsModal:onCloseWidget()
    UIManager:setDirty(nil, function()
        return "ui", self.frame.dimen
    end)
end

function ReviewsModal:onClose()
    UIManager:close(self)
    return true
end

-- Tap outside the frame closes; taps inside fall through so the
-- ScrollHtmlWidget can handle tap-to-scroll.
function ReviewsModal:onTapClose(_arg, ges)
    if ges and ges.pos and self.frame and self.frame.dimen
            and not ges.pos:intersectWith(self.frame.dimen) then
        self:onClose()
        return true
    end
    return false
end

return ReviewsModal
