-- hero_card.lua
-- Currently-reading detail card: cover thumbnail + title + author + token strip + progress bar.

local FrameContainer  = require("ui/widget/container/framecontainer")
local InputContainer  = require("ui/widget/container/inputcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local TopContainer    = require("ui/widget/container/topcontainer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local VerticalGroup   = require("ui/widget/verticalgroup")
local OverlapGroup    = require("ui/widget/overlapgroup")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local ProgressWidget  = require("ui/widget/progresswidget")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local Size            = require("ui/size")
local Font            = require("ui/font")
local SpineWidget     = require("spine_widget")
local Tokens          = require("tokens")

local HeroCard = InputContainer:extend{
    book        = nil,
    width       = nil,
    height      = nil,
    cover_w     = 116,
    cover_h     = nil,
    pad         = nil,   -- single gap value (cover↔text). Caller passes the
                         -- BookshelfWidget-wide PAD here for consistent layout.
    lines       = nil,   -- list of token-format strings
    device_state= nil,   -- { now, batt, charging, wifi, light, warmth, mem, ram_mib, disk_free }
    on_tap      = nil,   -- function(book)
    on_hold     = nil,
}

function HeroCard:init()
    self.cover_h = self.cover_h or self.height
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
        width      = self.width,
        height     = self.height,
        bordersize = Size.border.thin,
        padding    = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = self.height },
            TextBoxWidget:new{
                text  = "Welcome to Bookshelf · Tap a cover to start reading",
                face  = Font:getFace("infofont", 14),
                width = self.width - Size.padding.large * 2,
                alignment = "center",
            },
        },
    }
end

function HeroCard:_renderFull()
    local cover_h = self.cover_h or self.height
    -- Pass tap/hold callbacks through so the cover area itself opens the book
    -- (otherwise SpineWidget consumes the tap with `return true` even when
    -- its own on_tap is nil, and the HeroCard's outer handler never fires).
    local cover = SpineWidget:new{
        book    = self.book,
        width   = self.cover_w,
        height  = cover_h,
        on_tap  = self.on_tap,
        on_hold = self.on_hold,
    }

    -- Single gap value driven by the caller (BookshelfWidget's PAD), so every
    -- spacing on the home screen — page edges, cover↔text, cover↔cover —
    -- shares one consistent number.
    local text_padding = self.pad or Size.padding.fullscreen
    local right_w = self.width - self.cover_w - text_padding
    local title = TextBoxWidget:new{
        text  = self.book.title or "Untitled",
        face  = Font:getFace("infofont", 26),
        width = right_w,
        bold  = true,
    }
    -- KOReader's TextBoxWidget doesn't support italic; render upright.
    -- italic deferred to font-face work in a future revision
    local author = TextBoxWidget:new{
        text  = self.book.author or "",
        face  = Font:getFace("infofont", 16),
        width = right_w,
    }

    -- Content stacked from the top: title, author, token detail lines.
    local right_top = VerticalGroup:new{ align = "left", title, author }

    -- Token-rendered detail lines.
    -- Tokens.isEmpty is consulted before adding each widget so empty lines auto-hide.
    if self.lines then
        for _, line in ipairs(self.lines) do
            local rendered = Tokens.expand(line, self.book, self.device_state)
            if not Tokens.isEmpty(rendered) then
                local display = rendered:gsub("%[/?[biu]%]", "")
                right_top[#right_top + 1] = TextBoxWidget:new{
                    text  = display,
                    face  = Font:getFace("infofont", 14),
                    width = right_w,
                }
            end
        end
    end

    -- Spacer before the description so the blurb has visible breathing
    -- room from the title/author/detail lines above.
    local VerticalSpan = require("ui/widget/verticalspan")
    local Screen = require("device").screen

    -- Book description / blurb. Pulled from BookInfoManager.description
    -- (populated when the book has been opened or scanned by coverbrowser).
    -- Constrained to ~half the cover height with ellipsis overflow so it
    -- can't push the progress bar / clock off the bottom.
    local desc = self.book.description
    if desc and desc ~= "" then
        -- BookInfoManager stores the raw <dc:description> with embedded
        -- HTML markup (<p><b><i><br>…). TextBoxWidget has no markup
        -- renderer so we strip tags + decode the most common entities.
        --
        -- &#NNN; entities can be out-of-ASCII codepoints (e.g. 8217 for
        -- a right single quote) — string.char only handles 0-255 and
        -- raises on larger values. The codepointToUtf8 helper produces
        -- valid multi-byte UTF-8 instead, falling back to empty for
        -- malformed inputs.
        local function codepointToUtf8(n)
            n = tonumber(n)
            if not n or n < 0 then return "" end
            if n < 0x80    then return string.char(n) end
            if n < 0x800   then return string.char(0xC0 + math.floor(n / 0x40),
                                                   0x80 + n % 0x40) end
            if n < 0x10000 then return string.char(0xE0 + math.floor(n / 0x1000),
                                                   0x80 + math.floor(n / 0x40) % 0x40,
                                                   0x80 + n % 0x40) end
            return ""
        end
        desc = desc:gsub("<br%s*/?>", "\n")
                   :gsub("</p>",     "\n\n")
                   :gsub("<[^>]+>",  "")
                   :gsub("&amp;",    "&")
                   :gsub("&quot;",   "\"")
                   :gsub("&apos;",   "'")
                   :gsub("&lt;",     "<")
                   :gsub("&gt;",     ">")
                   :gsub("&#(%d+);", codepointToUtf8)
                   :gsub("^%s+", ""):gsub("%s+$", "")
        if desc ~= "" then
            right_top[#right_top + 1] = VerticalSpan:new{ width = Size.padding.large }
            -- TopContainer and BottomContainer share the same dimen and don't
            -- coordinate — if right_top's natural height exceeds the cover
            -- minus the bottom stack, the blurb visibly collides with the
            -- progress bar / clock. Measure what's already in right_top and
            -- subtract the estimated bottom-stack height to get a safe cap.
            local top_used = 0
            for i = 1, #right_top do
                local s = right_top[i]:getSize()
                top_used = top_used + (s and s.h or 0)
            end
            local bottom_h = Screen:scaleBySize(14)             -- progress bar
                          + Size.padding.default                -- bar→clock gap
                          + Screen:scaleBySize(16) * 1.4        -- clock line height
                          + Size.padding.default                -- buffer
            local available = cover_h - top_used - bottom_h
            if available > Screen:scaleBySize(40) then
                right_top[#right_top + 1] = TextBoxWidget:new{
                    text   = desc,
                    face   = Font:getFace("infofont", 14),
                    width  = right_w,
                    height = available,
                    height_overflow_show_ellipsis = true,
                }
            end
        end
    end

    -- Bottom-anchored stack: [bar  N%] then clock+battery below.
    -- Progress bar gets the percentage label inline on the right.
    local right_bottom_items = {}
    if self.book.book_pct then
        local TextWidget    = require("ui/widget/textwidget")
        local HorizontalSpan = require("ui/widget/horizontalspan")
        local pct_widget = TextWidget:new{
            text = string.format("%d%%", math.floor(self.book.book_pct * 100 + 0.5)),
            face = Font:getFace("infofont", 14),
            bold = true,
        }
        local pct_w = pct_widget:getSize().w
        local gap   = Size.padding.small
        local bar = ProgressWidget:new{
            width      = right_w - pct_w - gap,
            height     = Screen:scaleBySize(14),
            percentage = self.book.book_pct,
            margin_h   = 0,
            margin_v   = 0,
        }
        -- [N%  bar] — percentage on the LEFT, then standard padding, then bar.
        right_bottom_items[#right_bottom_items + 1] = HorizontalGroup:new{
            align = "center",
            pct_widget,
            HorizontalSpan:new{ width = Size.padding.default },
            bar,
        }
    end

    -- Clock + battery — right-aligned, modest size (matches author font).
    local time_str = os.date("%I:%M %p"):gsub("^0", "")
    local batt_str = ""
    local s = self.device_state
    if s and s.batt then
        batt_str = (s.charging and "\xe2\x9a\xa1" or "") .. tostring(s.batt) .. "%"
    end
    local clock_text = batt_str ~= "" and (time_str .. "   " .. batt_str) or time_str
    right_bottom_items[#right_bottom_items + 1] = TextBoxWidget:new{
        text      = clock_text,
        face      = Font:getFace("infofont", 16),
        width     = right_w,
        alignment = "right",
    }
    local right_bottom = VerticalGroup:new{
        align = "left",
        unpack(right_bottom_items),
    }

    -- Compose right column: top content + bottom-anchored stack.
    local right_dimen = Geom:new{ w = right_w, h = cover_h }
    local right = OverlapGroup:new{
        dimen = right_dimen,
        TopContainer:new{ dimen = right_dimen, right_top },
        BottomContainer:new{ dimen = right_dimen, right_bottom },
    }

    -- Insert a HorizontalSpan between the cover and the right column so the
    -- text doesn't butt up against the cover edge.
    local HorizontalSpan = require("ui/widget/horizontalspan")
    return HorizontalGroup:new{
        align = "top",
        cover,
        HorizontalSpan:new{ width = text_padding },
        right,
    }
end

function HeroCard:onTap()  if self.on_tap  then self.on_tap(self.book)  end; return true end
function HeroCard:onHold() if self.on_hold then self.on_hold(self.book) end; return true end

return HeroCard
