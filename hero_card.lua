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
local CoverLoader     = require("cover_loader")
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

-- Reads the user's font-scale setting (% of nominal). Applied to every
-- font face used in the hero card so the user can dial the whole card up
-- or down without the rest of the home screen following along.
local function fontFace(name, base)
    local scale = (G_reader_settings:readSetting("bookshelf_font_scale") or 100) / 100
    return Font:getFace(name, math.max(8, math.floor(base * scale + 0.5)))
end

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
                face  = fontFace("infofont", 14),
                width = self.width - Size.padding.large * 2,
                alignment = "center",
            },
        },
    }
end

function HeroCard:_renderFull()
    local cover_h = self.cover_h or self.height
    -- Hero uses a HIGH-RESOLUTION cover bb fetched fresh from the document,
    -- not BookInfoManager's downscaled thumbnail. This makes the hero-size
    -- render a DOWNSCALE in RenderImage:scaleBlitBuffer (clean) instead of
    -- an UPSCALE (corrupts on Kindle with horizontal-stripe static).
    -- CoverLoader owns the bb's lifetime — it's reused across rebuilds for
    -- the same book and freed when a different file becomes the hero. May
    -- return nil if the document fails to open; SpineWidget then falls back
    -- to book.cover_bb (which still produces visible-but-corrupted output —
    -- better than nothing).
    local hero_bb = self.book.filepath and CoverLoader:get(self.book.filepath) or nil

    -- Pass tap/hold callbacks through so the cover area itself opens the book
    -- (otherwise SpineWidget consumes the tap with `return true` even when
    -- its own on_tap is nil, and the HeroCard's outer handler never fires).
    local cover = SpineWidget:new{
        book         = self.book,
        cover_bb     = hero_bb,    -- high-res override; nil = use book.cover_bb
        width        = self.cover_w,
        height       = cover_h,
        on_tap       = self.on_tap,
        on_hold      = self.on_hold,
        -- Fill the slot (default). Now safe because the high-res bb is
        -- larger than the slot, so the stretch becomes a downscale —
        -- avoids the upscale corruption path even at non-2:3 covers.
    }

    -- Single gap value driven by the caller (BookshelfWidget's PAD), so every
    -- spacing on the home screen — page edges, cover↔text, cover↔cover —
    -- shares one consistent number.
    local text_padding = self.pad or Size.padding.fullscreen
    local right_w = self.width - self.cover_w - text_padding

    -- Clock + battery as a "header strip" above the title, full right-column
    -- width, with a hairline rule beneath separating it from book details.
    local VerticalSpan = require("ui/widget/verticalspan")
    local LineWidget   = require("ui/widget/linewidget")
    local Blitbuffer   = require("ffi/blitbuffer")
    local Screen       = require("device").screen

    -- Bookends-style template, user-customisable via Settings → Edit clock
    -- line. Tokens available: %time_12h %time_24h %date %weekday %batt
    -- %charging (lightning bolt when charging, else empty) %wifi %light
    -- %warmth %mem %ram %disk_free, plus [if:foo]…[/if] conditionals.
    local clock_template = G_reader_settings:readSetting("bookshelf_clock_line")
                           or Tokens.DEFAULT_CLOCK_LINE
    local clock_text = Tokens.expand(clock_template, self.book or {}, self.device_state)
    clock_text = clock_text:gsub("%[/?[biu]%]", "")
    local clock_strip = TextBoxWidget:new{
        text      = clock_text,
        face      = fontFace("infofont", 14),
        width     = right_w,
        alignment = "right",
    }
    -- Subtle grey hairline so the strip reads as separate from the title
    -- without competing visually. Tiny vertical breathing space below.
    local hairline = LineWidget:new{
        dimen      = Geom:new{ w = right_w, h = Size.line.medium },
        background = Blitbuffer.gray(0.4),
    }
    local hairline_gap = VerticalSpan:new{ width = Size.padding.default }

    local title = TextBoxWidget:new{
        text  = self.book.title or "Untitled",
        face  = fontFace("infofont", 26),
        width = right_w,
        bold  = true,
    }
    -- KOReader's TextBoxWidget doesn't support italic; render upright.
    -- italic deferred to font-face work in a future revision
    local author = TextBoxWidget:new{
        text  = self.book.author or "",
        face  = fontFace("infofont", 16),
        width = right_w,
    }

    -- Content stacked from the top: clock/battery strip, hairline, title,
    -- author, token detail lines.
    local right_top = VerticalGroup:new{
        align = "left",
        clock_strip,
        hairline,
        hairline_gap,
        title,
        author,
    }

    -- Token-rendered detail lines.
    -- Tokens.isEmpty is consulted before adding each widget so empty lines auto-hide.
    if self.lines then
        for _, line in ipairs(self.lines) do
            local rendered = Tokens.expand(line, self.book, self.device_state)
            if not Tokens.isEmpty(rendered) then
                local display = rendered:gsub("%[/?[biu]%]", "")
                right_top[#right_top + 1] = TextBoxWidget:new{
                    text  = display,
                    face  = fontFace("infofont", 14),
                    width = right_w,
                }
            end
        end
    end

    -- Book description / blurb. Pulled from BookInfoManager.description
    -- (populated when the book has been opened or scanned by coverbrowser).
    -- We BUILD THE BOTTOM STACK FIRST below, so we can measure its actual
    -- rendered height and cap the description to whatever's left over.
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
        -- Defer adding the description widget — we need to measure the
        -- bottom stack's ACTUAL height first to compute the available space.
        -- Stash the cleaned blurb on a local for use below.
    end
    local cleaned_desc = desc and desc ~= "" and desc or nil

    -- Build the bottom stack [bar N%] + clock-and-battery, BEFORE the
    -- description, so we can measure its actual height. Estimating from
    -- font sizes was too lossy and the description visibly collided with
    -- the progress bar.
    local right_bottom_items = {}
    if self.book.book_pct then
        local TextWidget     = require("ui/widget/textwidget")
        local HorizontalSpan = require("ui/widget/horizontalspan")
        local pct_widget = TextWidget:new{
            text = string.format("%d%%", math.floor(self.book.book_pct * 100 + 0.5)),
            face = fontFace("infofont", 14),
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

    local right_bottom = VerticalGroup:new{
        align = "left",
        unpack(right_bottom_items),
    }

    -- Now we can MEASURE the bottom stack to compute available space for
    -- the description. The previous estimate (font 14 + font*1.4 etc.) was
    -- consistently too small, leaving the description widget too tall and
    -- overlapping the progress bar.
    if cleaned_desc then
        right_top[#right_top + 1] = VerticalSpan:new{ width = Size.padding.default }
        local top_used = 0
        for i = 1, #right_top do
            local g = right_top[i]:getSize()
            top_used = top_used + (g and g.h or 0)
        end
        local bottom_h  = right_bottom:getSize().h
        local breath    = Size.padding.default   -- small gap between description and progress bar
        local available = cover_h - top_used - bottom_h - breath
        if available > Screen:scaleBySize(40) then
            right_top[#right_top + 1] = TextBoxWidget:new{
                text   = cleaned_desc,
                face   = fontFace("infofont", 14),
                width  = right_w,
                height = available,
                height_overflow_show_ellipsis = true,
            }
        end
    end

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
