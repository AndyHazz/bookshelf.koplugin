-- spine_widget.lua
-- One book's cover. Cover render path when book.cover_bb is present;
-- otherwise paper-tone fallback (Task 3.2 adds this).

local FrameContainer = require("ui/widget/container/framecontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local ImageWidget    = require("ui/widget/imagewidget")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local Size           = require("ui/size")
local InputContainer = require("ui/widget/container/inputcontainer")

local SpineWidget = InputContainer:extend{
    book      = nil,    -- Book record
    width     = nil,    -- pixels
    height    = nil,    -- pixels
    on_tap    = nil,    -- function(book) — opens reader
    on_hold   = nil,    -- function(book) — long-press menu
}

function SpineWidget:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    if self.book and self.book.has_cover and self.book.cover_bb then
        self[1] = self:_renderCover()
    else
        self[1] = self:_renderFallback()
    end
    self.ges_events = {
        Tap  = { GestureRange:new{ ges = "tap",  range = self.dimen } },
        Hold = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
end

function SpineWidget:_renderCover()
    local Screen = require("device").screen
    return FrameContainer:new{
        bordersize = Screen:scaleBySize(1),     -- 1dp border (was 2, too heavy)
        radius     = Screen:scaleBySize(4),     -- slight rounding
        padding    = 0,
        ImageWidget:new{
            image  = self.book.cover_bb,
            width  = self.width,
            height = self.height,
            -- scale_factor omitted (= nil) → ImageWidget stretches the image
            -- to fill width × height without preserving aspect ratio.
            -- CSS object-fit: fill semantics. Trades off some distortion for
            -- a fully-occupied slot, which keeps the shelf grid uniform.
        },
    }
end

function SpineWidget:_renderFallback()
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local Font = require("ui/font")
    local Blitbuffer = require("ffi/blitbuffer")
    -- White bar spans the full slot width; the TEXT inside has padding.
    -- This wraps a (text-width) TextBoxWidget in a FrameContainer with
    -- horizontal padding equal to text_pad, so the wrapper renders a
    -- white bar of the full slot width with the title text inset.
    local text_pad = Size.padding.large
    local card_w   = self.width

    local function whiteBar(text, face, bold, alignment)
        local box = TextBoxWidget:new{
            text  = text,
            face  = face,
            width = card_w - text_pad * 2,
            alignment = alignment or "center",
            bold  = bold,
        }
        return FrameContainer:new{
            bordersize    = 0,
            background    = Blitbuffer.COLOR_WHITE,
            padding       = 0,
            padding_left  = text_pad,
            padding_right = text_pad,
            box,
        }
    end

    local title  = whiteBar(self.book and self.book.title or "?",
                            Font:getFace("infofont", 12), true)
    local author = whiteBar(self.book and self.book.author or "",
                            Font:getFace("infofont", 10), false)

    local stack = VerticalGroup:new{
        align = "center",
        title,
        author,
    }

    -- Faint grey card so the "no cover" fallback reads as a tile against the
    -- white page. Blitbuffer.gray semantics: 0 = white, 1 = black.
    local paper  = Blitbuffer.gray(0.07)
    local Screen = require("device").screen
    local border = Screen:scaleBySize(1)
    -- Match the cover render path: 2dp border, slight rounding, EXACTLY
    -- the same self.width × self.height footprint. Inner CenterContainer
    -- subtracts the border so the FrameContainer's outer size stays at
    -- self.width × self.height (otherwise the fallback overflows the
    -- shelf base rule by ~4dp on each side).
    return FrameContainer:new{
        bordersize = border,
        radius     = Screen:scaleBySize(4),
        padding    = 0,
        background = paper,
        CenterContainer:new{
            dimen = Geom:new{
                w = self.width  - border * 2,
                h = self.height - border * 2,
            },
            stack,
        },
    }
end

-- Only consume the gesture when we actually have a callback to invoke.
-- Otherwise let it bubble so an enclosing widget (e.g. HeroCard) can handle it.
function SpineWidget:onTap()
    if not self.on_tap then return false end
    self.on_tap(self.book)
    return true
end
function SpineWidget:onHold()
    if not self.on_hold then return false end
    self.on_hold(self.book)
    return true
end

return SpineWidget
