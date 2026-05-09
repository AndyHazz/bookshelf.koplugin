-- bookshelf_spine_widget.lua
-- One book's cover. Cover render path when book.cover_bb is present;
-- otherwise paper-tone fallback.
--
-- Both render paths produce a "card with shadow" composition: the actual
-- card occupies the bottom-left of the slot, and a darker rounded
-- rectangle is painted at top-right offset behind it, giving the
-- impression of light from below-left. The slot's outer (w × h)
-- footprint is preserved so adjacent shelf cells don't overlap.

local Blitbuffer      = require("ffi/blitbuffer")
local ScaledCoverCache = require("bookshelf_scaled_cover_cache")
local FrameContainer  = require("ui/widget/container/framecontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local TopContainer    = require("ui/widget/container/topcontainer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local RightContainer  = require("ui/widget/container/rightcontainer")
local OverlapGroup    = require("ui/widget/overlapgroup")
local ImageWidget     = require("ui/widget/imagewidget")
local Widget          = require("ui/widget/widget")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local Size            = require("ui/size")
local InputContainer  = require("ui/widget/container/inputcontainer")
local Screen          = require("device").screen

-- Shadow geometry shared by both render paths.
local SHADOW_OFFSET   = Screen:scaleBySize(4)       -- shadow offset in dp
local CARD_RADIUS     = Screen:scaleBySize(4)       -- rounded corner radius
local CARD_BORDER     = Screen:scaleBySize(1)       -- 1dp border on the card
-- Selected-state border thickness: matches SHADOW_OFFSET so the border's
-- outer perimeter sits exactly where the unselected-state drop shadow's
-- outer edge sits. The selected→unselected transition is then just a
-- colour swap (black border → grey shadow) in the same pixel band, with
-- no change in the slot's outer footprint.
local SELECTED_BORDER = SHADOW_OFFSET
local SHADOW_GRAY     = Blitbuffer.gray(0.5)        -- grey level for the shadow

-- A simple Widget subclass that paints a rounded rectangle in a fixed grey.
-- Used as the shadow layer behind every cover. Has its own dimen so
-- OverlapGroup positioning containers can size it correctly.
local ShadowRect = Widget:extend{
    width  = nil,
    height = nil,
}
function ShadowRect:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
end
function ShadowRect:paintTo(bb, x, y)
    bb:paintRoundedRect(x, y, self.width, self.height, SHADOW_GRAY, CARD_RADIUS)
end

-- Solid rounded-rect "backdrop" used as the selected-state cue. Sits
-- BEHIND the cover in an OverlapGroup; paints a filled rounded black
-- rectangle that extends `thickness` pixels in every direction outside
-- the cover's bounds. The cover then paints on top with its normal
-- (untouched) rendering — image, rounded corners, thin border. The
-- visible "thick border ring" is whatever pixels of this backdrop
-- aren't overpainted by the cover, framed by the cover's own
-- consistently-rasterised rounded outer edge. Dual-rasterisation
-- artefacts (paintBorder's Bresenham inner arc vs the corner mask's
-- distance test) are avoided because the inner edge of the visible
-- ring is defined SOLELY by the cover's render path.
local BorderOverlay = Widget:extend{
    width     = nil,
    height    = nil,
    thickness = nil,
    radius    = 0,
    color     = nil,    -- defaults to COLOR_BLACK
}
function BorderOverlay:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
end
function BorderOverlay:paintTo(bb, x, y)
    local t = self.thickness
    bb:paintRoundedRect(x - t, y - t,
                        self.width + 2 * t, self.height + 2 * t,
                        self.color or Blitbuffer.COLOR_BLACK,
                        (self.radius or 0) + t)
end

-- A card that paints its inner widget (typically an ImageWidget for the
-- cover) and CLIPS the four corners to a rounded shape, then paints a
-- rounded border on top. KOReader's FrameContainer paints children as
-- rectangles with no clipping, so a cover image inside a rounded
-- FrameContainer would visibly jut past the rounded corners. This widget
-- masks the overflow with white pixels so the image visually conforms to
-- the rounded shape.
--
-- Algorithm: paint the inner widget, then for each of the four corner
-- squares (radius × radius), paint white pixels where they fall outside
-- the inscribed quarter-disc. Finally paint the rounded border on top so
-- the arc reads cleanly. Per-pixel cost is 4 × radius² operations per
-- card paint — negligible at the radii we use.
local RoundedCornerCard = Widget:extend{
    inner        = nil,                       -- widget to paint inside (image)
    width        = nil,
    height       = nil,
    radius       = 0,
    border_size  = 0,
    border_color = nil,                       -- defaults to COLOR_BLACK
    bg_color     = nil,                       -- page bg (default COLOR_WHITE)
    -- Shadow restoration: when the card sits over a drop-shadow, mask pixels
    -- in the card's corner overflow that fall inside the shadow's rounded
    -- shape need to be painted shadow-grey (not bg) so the shadow stays
    -- visible at the rounded corners. Set these to the enclosing shadow's
    -- offset (relative to this card's top-left) and color/radius.
    shadow_color    = nil,
    shadow_offset_x = 0,
    shadow_offset_y = 0,
    shadow_radius   = 0,
}

function RoundedCornerCard:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
end

function RoundedCornerCard:getSize() return self.dimen end

function RoundedCornerCard:free(...)
    if self.inner and self.inner.free then self.inner:free(...) end
end

-- Returns true if the card-local pixel (px, py) falls inside the enclosing
-- shadow's painted area (i.e., the shadow color was drawn there before the
-- card overpainted it). Used so the corner mask restores shadow grey
-- instead of stamping bg-white over visible shadow.
function RoundedCornerCard:_pixelInShadow(px, py)
    if not self.shadow_color then return false end
    local sox, soy = self.shadow_offset_x, self.shadow_offset_y
    local sw, sh   = self.width, self.height           -- shadow same size as card
    if px < sox or py < soy
       or px >= sox + sw or py >= soy + sh then
        return false
    end
    local sr = self.shadow_radius or 0
    if sr <= 0 then return true end
    local sx, sy   = px - sox, py - soy
    local cx, cy
    if sx < sr and sy < sr then
        cx, cy = sr, sr                                -- shadow TL corner area
    elseif sx >= sw - sr and sy < sr then
        cx, cy = sw - sr, sr                           -- shadow TR
    elseif sx < sr and sy >= sh - sr then
        cx, cy = sr, sh - sr                           -- shadow BL
    elseif sx >= sw - sr and sy >= sh - sr then
        cx, cy = sw - sr, sh - sr                      -- shadow BR
    end
    if not cx then return true end                     -- straight-edge area
    local ddx, ddy = sx - cx, sy - cy
    return ddx * ddx + ddy * ddy <= sr * sr
end

function RoundedCornerCard:paintTo(bb, x, y)
    if self.inner then
        self.inner:paintTo(bb, x + self.border_size, y + self.border_size)
    end
    if self.radius and self.radius > 0 then
        local r       = self.radius
        local w, h    = self.width, self.height
        local bg      = self.bg_color or Blitbuffer.COLOR_WHITE
        local r_sq    = r * r
        -- For each row dy in [0, r), the arc test is monotonic in dx — there's
        -- exactly one transition from "outside arc" (paint) to "inside arc"
        -- (skip). We binary-search-equivalent it with a forward scan and emit
        -- a single paintRect strip per corner-row instead of r per-pixel
        -- setPixel calls. Cost drops from 4·r² FFI calls to ~4·r.
        --
        -- TL/TR/BL corners are guaranteed to lie outside the enclosing
        -- shadow (their pixels have either px < shadow_offset_x or
        -- py < shadow_offset_y), so they paint pure bg. BR can intersect
        -- the shadow's painted area; it falls back to per-pixel.
        for dy = 0, r - 1 do
            -- Top half (dy small): arc center is at (r, r). cutoff_top is the
            -- smallest dx such that (dx-r)² + (dy-r)² ≤ r² — i.e. inside arc.
            -- Pixels [0, cutoff_top) are outside.
            local cutoff_top = 0
            local dy_top_sq = (dy - r) * (dy - r)
            while cutoff_top < r and (cutoff_top - r) * (cutoff_top - r) + dy_top_sq > r_sq do
                cutoff_top = cutoff_top + 1
            end
            if cutoff_top > 0 then
                bb:paintRect(x, y + dy, cutoff_top, 1, bg)                  -- TL
                bb:paintRect(x + w - cutoff_top, y + dy, cutoff_top, 1, bg) -- TR
            end
            -- Bottom half (dy near h): arc center same, but our local dy
            -- iterator runs 0..r-1 while the actual row is h-r+dy. The arc
            -- test for BL at row (h-r+dy) is (dx-r)² + dy² > r².
            local cutoff_bot = 0
            local dy_bot_sq = dy * dy
            while cutoff_bot < r and (cutoff_bot - r) * (cutoff_bot - r) + dy_bot_sq > r_sq do
                cutoff_bot = cutoff_bot + 1
            end
            if cutoff_bot > 0 then
                bb:paintRect(x, y + h - r + dy, cutoff_bot, 1, bg)          -- BL
                -- BR may overlap the enclosing shadow — keep per-pixel for
                -- correct shadow-color restoration. cutoff_bot pixels at the
                -- right edge of this row need painting.
                if self.shadow_color then
                    for dx = 0, cutoff_bot - 1 do
                        local px = w - cutoff_bot + dx
                        local py = h - r + dy
                        local color = self:_pixelInShadow(px, py)
                                          and self.shadow_color or bg
                        bb:setPixel(x + px, y + py, color)
                    end
                else
                    bb:paintRect(x + w - cutoff_bot, y + h - r + dy,
                                 cutoff_bot, 1, bg)                         -- BR
                end
            end
        end
    end
    if self.border_size and self.border_size > 0 then
        bb:paintBorder(x, y, self.width, self.height,
                       self.border_size,
                       self.border_color or Blitbuffer.COLOR_BLACK,
                       self.radius, true)
    end
end

local SpineWidget = InputContainer:extend{
    book        = nil,
    width       = nil,
    height      = nil,
    on_tap      = nil,
    on_hold     = nil,
    -- When true, the card paints WITHOUT its drop shadow and gains a
    -- thick black border at the cover perimeter. The cover image's
    -- pixel position and size are identical to the unselected state —
    -- only the perimeter pixels change — so the e-ink controller
    -- doesn't redraw the cover bitmap on (de)selection. Set by
    -- ShelfRow when the spine's filepath matches the BookshelfWidget's
    -- preview filepath.
    is_selected = false,
    -- Cover rendering mode. Mutually exclusive:
    --   cover_fill   = true (default)  → stretch to fill (object-fit: fill)
    --   cover_native = true            → render bb at its native size,
    --                                   center in the slot (no scaling).
    --                                   Used as a safety fallback when bb
    --                                   is smaller than the slot — keeps
    --                                   us out of the upscale path that
    --                                   corrupts on Kindle.
    --   neither                        → aspect-preserving fit
    --                                   (object-fit: contain, scale_factor=0)
    cover_fill   = true,
    cover_native = false,
    -- Optional bb override. When set, takes precedence over book.cover_bb.
    -- Lifetime defaults to caller-owned: the bb is reused across renders
    -- and must NOT be freed by ImageWidget. When the caller owns a one-shot
    -- copy (e.g. series_stack making per-layer copies for a single-book
    -- series), it sets cover_bb_disposable=true so ImageWidget can free
    -- the copy via scaleBlitBuffer / on widget free — without this flag
    -- the copies leak across chip rebuilds.
    cover_bb            = nil,
    cover_bb_disposable = false,
}

function SpineWidget:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    local effective_bb = self.cover_bb or (self.book and self.book.cover_bb)
    if self.book and self.book.has_cover and effective_bb then
        self[1] = self:_renderCover(effective_bb)
    else
        self[1] = self:_renderFallback()
    end
    self.ges_events = {
        Tap  = { GestureRange:new{ ges = "tap",  range = self.dimen } },
        Hold = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
end

-- Wraps an inner card widget in a "card with shadow" composition. The inner
-- widget paints at the slot's top-left (0,0); a ShadowRect of the same size
-- is wrapped in a FrameContainer with top+left padding equal to
-- SHADOW_OFFSET so it ends up at (offset, offset). The cover then paints on
-- top, leaving the shadow visible as an L-shape on the right and bottom edges.
--
-- Why this approach instead of nested Top/Bottom/Left/RightContainer:
--   * BottomContainer aligns its child to the bottom only when the child's
--     getSize().h < dimen.h. We had been wrapping a full-slot RightContainer
--     inside it, so the bottom-shift collapsed to zero — only horizontal
--     offset was visible.
--   * FrameContainer's padding directly shifts the inner widget's paint
--     position by exactly the padding amount — straightforward, no centering
--     surprises.
function SpineWidget:_renderShadowedCard(inner)
    local card_w = self.width  - SHADOW_OFFSET
    local card_h = self.height - SHADOW_OFFSET
    -- Selected state: skip the shadow, keep the cover at exactly the
    -- same (0,0)–(card_w, card_h) position as unselected, and overlay
    -- a thick black border at the cover perimeter. The cover image's
    -- pixel position and size do not change between states — the
    -- e-ink diff is only the perimeter pixels (thin border → thick
    -- border) plus the shadow's L-shape disappearing, which avoids
    -- the jarring full-cover redraw a position-shift causes.
    if self.is_selected then
        return OverlapGroup:new{
            dimen = Geom:new{ w = self.width, h = self.height },
            -- Backdrop paints first (behind), cover paints on top with
            -- its untouched rendering. The visible "ring" is the band
            -- of backdrop pixels that the cover doesn't overpaint.
            BorderOverlay:new{
                width     = card_w,
                height    = card_h,
                thickness = SELECTED_BORDER,
                radius    = CARD_RADIUS,
            },
            inner,
        }, card_w, card_h
    end
    local shadow_wrapper = FrameContainer:new{
        bordersize   = 0,
        padding      = 0,
        padding_top  = SHADOW_OFFSET,
        padding_left = SHADOW_OFFSET,
        ShadowRect:new{ width = card_w, height = card_h },
    }
    return OverlapGroup:new{
        dimen = Geom:new{ w = self.width, h = self.height },
        shadow_wrapper,   -- paints first, behind the cover
        inner,            -- paints on top at (0,0), occupies top-left card_w × card_h
    }, card_w, card_h
end

function SpineWidget:_renderCover(bb)
    local card_w, card_h = self.width - SHADOW_OFFSET, self.height - SHADOW_OFFSET
    -- The card-perimeter border stays thin in both states so the cover
    -- image's pixel position and size are identical between selected
    -- and unselected. The selection cue is a thicker BorderOverlay
    -- painted on TOP in _renderShadowedCard.
    local border = CARD_BORDER
    local img_w = card_w - 2 * border
    local img_h = card_h - 2 * border
    local bb_w  = bb:getWidth()
    local bb_h  = bb:getHeight()

    -- RenderImage:scaleBlitBuffer / ImageWidget's internal MuPDF scaler
    -- corrupts on UPSCALE on Kindle (horizontal stripe static); downscale
    -- is clean. Both shelf and hero use the BIM thumbnail (book.cover_bb)
    -- and route any required upscale through bb:scale — Lua-side nearest
    -- neighbour in ffi/blitbuffer.lua, which sidesteps MuPDF entirely.
    -- KOReader exposes the same escape hatch as the legacy_image_scaling
    -- user setting; we pick it surgically here.
    local would_upscale = bb_w < img_w or bb_h < img_h

    -- Disposable: with the cover_bb override the caller owns the bb's
    -- lifetime; with the default path the bb is BookInfoManager's fresh-
    -- from-zstd copy, safe for ImageWidget to free after scaling.
    -- ImageWidget disposes when:
    --   * default path (no override) — bb is BookInfoManager's fresh-from-
    --     zstd copy; safe to free after scaling.
    --   * override + cover_bb_disposable=true — caller hands us an owned
    --     one-shot bb (e.g. a series_stack:copy()); we transfer ownership
    --     to ImageWidget so it can free via scaleBlitBuffer/on free.
    -- Otherwise (override + caller still owns), ImageWidget must NOT free.
    local img_disposable = (self.cover_bb == nil) or self.cover_bb_disposable

    local cover_inner
    if would_upscale and self.cover_fill then
        -- Stretch a small cover to fill the slot. bb:scale is the only
        -- Kindle-safe upscale path (sidesteps MuPDF's broken scaler) but
        -- a ~111k pixel-op pass per render — cache by filepath so chip
        -- switches and page flips that keep the same book on screen reuse
        -- the work. ScaledCoverCache owns the scaled bb's lifetime; we
        -- pass image_disposable=false so ImageWidget doesn't fight it.
        local fp = self.book and self.book.filepath
        local cached = ScaledCoverCache:get(fp, img_w, img_h)
        if cached then
            -- Source bb isn't needed; release if we owned it.
            if img_disposable then bb:free() end
            cover_inner = ImageWidget:new{
                image            = cached,
                image_disposable = false,
                scale_factor     = 1,
            }
        else
            local scaled_bb = bb:scale(img_w, img_h)
            if img_disposable then bb:free() end
            if fp then
                ScaledCoverCache:put(fp, img_w, img_h, scaled_bb)
                cover_inner = ImageWidget:new{
                    image            = scaled_bb,
                    image_disposable = false,    -- cache owns lifetime
                    scale_factor     = 1,
                }
            else
                -- No filepath to key on (rare). Hand ownership to the
                -- ImageWidget so the bb is freed at widget teardown.
                cover_inner = ImageWidget:new{
                    image            = scaled_bb,
                    image_disposable = true,
                    scale_factor     = 1,
                }
            end
        end
    elseif would_upscale then
        -- cover_fill=false (aspect-preserving): keep the bb at native
        -- size and centre it. No scaling = no corruption risk.
        cover_inner = CenterContainer:new{
            dimen = Geom:new{ w = img_w, h = img_h },
            ImageWidget:new{
                image            = bb,
                image_disposable = img_disposable,
                scale_factor     = 1,
            },
        }
    else
        local img_args = {
            image            = bb,
            image_disposable = img_disposable,
            width            = img_w,
            height           = img_h,
        }
        if not self.cover_fill then
            img_args.scale_factor = 0   -- aspect-preserving downscale
        end
        cover_inner = ImageWidget:new(img_args)
    end

    local cover_args = {
        inner       = cover_inner,
        width       = card_w,
        height      = card_h,
        radius      = CARD_RADIUS,
        border_size = border,
    }
    if self.is_selected then
        -- The corner mask normally paints bg-white pixels in the
        -- (0..R, 0..R) corner squares for points OUTSIDE the radius-R
        -- arc, to fake rounded corners on top of a rectangular image.
        -- With the BorderOverlay backdrop those bg-white pixels poke
        -- out into the black ring as four little white teeth. Invert
        -- the mask colour to match the backdrop so the corner squares
        -- merge seamlessly with the surrounding black.
        cover_args.bg_color = Blitbuffer.COLOR_BLACK
    else
        -- The card sits at (0, 0) in the OverlapGroup; the shadow paints
        -- at (SHADOW_OFFSET, SHADOW_OFFSET) with the same w/h and same
        -- radius. Pass these so the corner mask can restore shadow grey
        -- where the shadow would otherwise show through.
        cover_args.shadow_color    = SHADOW_GRAY
        cover_args.shadow_offset_x = SHADOW_OFFSET
        cover_args.shadow_offset_y = SHADOW_OFFSET
        cover_args.shadow_radius   = CARD_RADIUS
    end
    local cover = RoundedCornerCard:new(cover_args)
    return (self:_renderShadowedCard(cover))
end

function SpineWidget:_renderFallback()
    local TextBoxWidget   = require("ui/widget/textboxwidget")
    local TextWidget      = require("ui/widget/textwidget")
    local VerticalGroup   = require("ui/widget/verticalgroup")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan  = require("ui/widget/horizontalspan")
    local VerticalSpan    = require("ui/widget/verticalspan")
    local LineWidget      = require("ui/widget/linewidget")
    local Font            = require("ui/font")

    local card_w = self.width  - SHADOW_OFFSET
    local card_h = self.height - SHADOW_OFFSET
    local border = CARD_BORDER

    -- Vintage-cover layout. Outer card paints a paper-tone background +
    -- thin border (matches the cover-render path so adjacent shelves
    -- stay consistent). An INNER frame inset by inset_h × inset_v
    -- adds a second thin border with a near-white fill — that double-
    -- frame is the "ornate" detail on its own. Inside the inner frame:
    -- title + decorative rule (two short lines flanking a centred ❖
    -- glyph) + author. Each text region caps at a fraction of card_h
    -- so a long title doesn't push the author off the bottom at small
    -- slot sizes.
    local inset_h    = math.max(Screen:scaleBySize(6), math.floor(card_w * 0.06))
    local inset_v    = math.max(Screen:scaleBySize(8), math.floor(card_h * 0.06))
    local outer_inset_w = card_w - inset_h * 2
    local outer_inset_h = card_h - inset_v * 2
    local content_pad   = math.max(Screen:scaleBySize(4), math.floor(card_w * 0.04))
    local content_w     = outer_inset_w - border * 2 - content_pad * 2

    -- Title text: cap height so a 4-line title still leaves room for
    -- the rule + author below.
    local title_text  = (self.book and self.book.title) or "?"
    local author_text = (self.book and self.book.author) or ""

    local title_max_h  = math.max(Screen:scaleBySize(20), math.floor(card_h * 0.40))
    local title = TextBoxWidget:new{
        text                          = title_text,
        face                          = Font:getFace("infofont", 13),
        bold                          = true,
        fgcolor                       = Blitbuffer.COLOR_BLACK,
        width                         = content_w,
        alignment                     = "center",
        height                        = title_max_h,
        height_overflow_show_ellipsis = true,
    }

    -- Decorative rule: ─ ❖ ─ centred. Two short black lines flanking
    -- a glyph; line width sized so they read as filigree, not a
    -- divider line. ❖ (BLACK DIAMOND MINUS WHITE X, U+2756) renders
    -- in the bundled infofont.
    local rule_line_w = math.max(Screen:scaleBySize(10), math.floor(content_w * 0.20))
    local rule_h      = math.max(1, Size.border.thin)
    local function ruleLine()
        return LineWidget:new{
            background = Blitbuffer.COLOR_BLACK,
            dimen      = Geom:new{ w = rule_line_w, h = rule_h },
        }
    end
    local rule_gap = HorizontalSpan:new{ width = Size.padding.small }
    local rule_centerer = CenterContainer:new{
        dimen = Geom:new{ w = content_w, h = math.max(Screen:scaleBySize(20), card_h * 0.10) },
        HorizontalGroup:new{
            align = "center",
            ruleLine(),
            rule_gap,
            TextWidget:new{
                text    = "\xE2\x9D\x96",  -- ❖ U+2756
                face    = Font:getFace("infofont", 12),
                fgcolor = Blitbuffer.COLOR_BLACK,
            },
            HorizontalSpan:new{ width = Size.padding.small },
            ruleLine(),
        },
    }

    -- Author region only renders if there's actually a name to show;
    -- skipping it lets the title centre vertically when alone.
    local stack_children = { align = "center", title, rule_centerer }
    if author_text ~= "" then
        local author_max_h = math.max(Screen:scaleBySize(14), math.floor(card_h * 0.20))
        local author = TextBoxWidget:new{
            text                          = author_text,
            face                          = Font:getFace("infofont", 10),
            fgcolor                       = Blitbuffer.COLOR_BLACK,
            width                         = content_w,
            alignment                     = "center",
            height                        = author_max_h,
            height_overflow_show_ellipsis = true,
        }
        stack_children[#stack_children + 1] = author
    end
    local stack = VerticalGroup:new(stack_children)

    -- Inner frame: thin border around a near-white inner fill. The
    -- second border is what makes it read as "ornate" vs a plain card.
    local inner_frame = FrameContainer:new{
        bordersize = Size.border.thin,
        background = Blitbuffer.COLOR_WHITE,
        padding    = content_pad,
        CenterContainer:new{
            dimen = Geom:new{
                w = content_w,
                h = outer_inset_h - border * 2 - content_pad * 2,
            },
            stack,
        },
    }

    -- Outer card: paper-tone background, rounded corners, thin border.
    local card = FrameContainer:new{
        bordersize = border,
        radius     = CARD_RADIUS,
        padding    = 0,
        background = Blitbuffer.gray(0.08),
        CenterContainer:new{
            dimen = Geom:new{ w = card_w - border * 2, h = card_h - border * 2 },
            inner_frame,
        },
    }
    return (self:_renderShadowedCard(card))
end

-- Only consume the gesture when we actually have a callback to invoke.
-- Otherwise let it bubble so an enclosing widget (e.g. HeroCard) can handle it.
function SpineWidget:onTap(_, ges)
    if not self.on_tap then return false end
    -- Let top-strip taps fall through for the KOReader menu zone.
    if ges and ges.pos and ges.pos.y < Screen:scaleBySize(60) then
        return false
    end
    self.on_tap(self.book)
    return true
end
function SpineWidget:onHold()
    if not self.on_hold then return false end
    self.on_hold(self.book)
    return true
end

return SpineWidget
