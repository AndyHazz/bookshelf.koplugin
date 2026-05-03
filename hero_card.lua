-- hero_card.lua
-- Currently-reading detail card: cover thumbnail + title + author + token strip + progress bar.

local FrameContainer = require("ui/widget/container/framecontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local HorizontalGroup= require("ui/widget/horizontalgroup")
local VerticalGroup  = require("ui/widget/verticalgroup")
local TextBoxWidget  = require("ui/widget/textboxwidget")
local ProgressWidget = require("ui/widget/progresswidget")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local Size           = require("ui/size")
local Font           = require("ui/font")
local SpineWidget    = require("spine_widget")
local Tokens         = require("tokens")

local HeroCard = InputContainer:extend{
    book        = nil,
    width       = nil,
    height      = nil,
    cover_w     = 116,
    lines       = nil,   -- list of token-format strings
    device_state= nil,   -- { now, batt, charging, wifi, light, warmth, mem, ram_mib, disk_free }
    on_tap      = nil,   -- function(book)
    on_hold     = nil,
}

function HeroCard:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    if not self.book then
        self[1] = self:_renderEmpty()
    else
        self[1] = self:_renderFull()
    end
    -- Corrected positional GestureRange form (keyed form is broken — see fd43c4d).
    self.ges_events = {
        Tap  = { GestureRange:new{ ges = "tap",  range = self.dimen } },
        Hold = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
end

function HeroCard:_renderEmpty()
    return FrameContainer:new{
        bordersize = Size.border.thin,
        TextBoxWidget:new{
            text = "Welcome to Bookshelf · Tap a cover to start reading",
            face = Font:getFace("infofont", 14),
            width = self.width - Size.padding.large * 2,
        }
    }
end

function HeroCard:_renderFull()
    local cover = SpineWidget:new{
        book = self.book, width = self.cover_w, height = self.height,
    }

    local right_w = self.width - self.cover_w - Size.padding.default
    local title = TextBoxWidget:new{
        text = self.book.title or "Untitled",
        face = Font:getFace("infofont", 18),
        width = right_w, bold = true,
    }
    -- KOReader's TextBoxWidget doesn't support italic; render upright.
    -- italic deferred to font-face work in a future revision
    local author = TextBoxWidget:new{
        text = self.book.author or "",
        face = Font:getFace("infofont", 11),
        width = right_w,
    }

    local right = VerticalGroup:new{ align = "left", title, author }

    -- Token-rendered detail lines.
    -- Tokens.isEmpty is consulted before adding each widget so empty lines auto-hide.
    if self.lines then
        for _, line in ipairs(self.lines) do
            local rendered = Tokens.expand(line, self.book, self.device_state)
            if not Tokens.isEmpty(rendered) then
                right[#right + 1] = TextBoxWidget:new{
                    text = rendered, face = Font:getFace("infofont", 11), width = right_w,
                }
            end
        end
    end

    -- Progress bar.
    -- book.book_pct is a 0..1 float from DocSettings "percent_finished".
    -- ProgressWidget's `percentage` also expects 0..1 — no conversion needed.
    if self.book.book_pct then
        right[#right + 1] = ProgressWidget:new{
            width = right_w, height = Size.line.thick * 2,
            percentage = self.book.book_pct,
            margin_h = 0, margin_v = Size.padding.tiny,
        }
    end

    return HorizontalGroup:new{ align = "top", cover, right }
end

function HeroCard:onTap()  if self.on_tap  then self.on_tap(self.book)  end; return true end
function HeroCard:onHold() if self.on_hold then self.on_hold(self.book) end; return true end

return HeroCard
