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
local BookshelfSettings = require("lib/bookshelf_settings_store")
local ScaledCoverCache = require("lib/bookshelf_scaled_cover_cache")
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
local CoverProgress   = require("lib/bookshelf_cover_progress")

local FADED_FINISHED_AMOUNT = 0.5

local function fadeFinishedBooksEnabled()
    return BookshelfSettings.isTrue("fade_finished_books")
end

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

-- Glyph sizing for the in-progress / finished badge on covers.
-- Scaled with cover width but floored so tiny columns don't render
-- a glyph too small to read. 80% of the original sizing so the glyph
-- doesn't crowd the title text in expanded (title-view) mode.
local function _glyphSize(card_w)
    local px = math.max(Screen:scaleBySize(9), math.floor(card_w * 0.132))
    return px
end

-- Vertical placement of the in-progress glyph relative to the card.
-- The glyph's top sits at (card_h - widget_h * GLYPH_TOP_LIFT_*),
-- where widget_h is the TextWidget's MEASURED height (accounts for
-- font ascent/descent + line-height overhead, ~1.3-1.4 × face size).
--   * < 1.0 -> glyph dangles below the card (1 - lift fraction of widget_h)
--   * = 1.0 -> glyph bottom touches card bottom
--   * > 1.0 -> glyph fully inside card, (lift-1) fraction above bottom
--
-- Both regular and expanded (3-row) modes share the same 0.50 lift:
-- the progress bar paints on top of the glyph, hiding the in-card
-- portion, so visibility relies entirely on the dangle. 50% of the
-- widget below card_h gives a recognisable bookmark shape (V-cut tip
-- + a slab of the rectangular body) at every DPI, in every mode.
local GLYPH_TOP_LIFT_REGULAR  = 0.50
local GLYPH_TOP_LIFT_EXPANDED = 0.50
local function _glyphTopLift(show_titles)
    if show_titles then return GLYPH_TOP_LIFT_EXPANDED end
    return GLYPH_TOP_LIFT_REGULAR
end

-- Horizontal inset of the glyph from the card's left edge.
local function _glyphLeftInset()
    return Size.padding.small + Screen:scaleBySize(2)
end

-- Cover-badge font scale. Affects the page-count "pN" badge, the
-- series "#N" badge, and the completed-tickbox glyph. Read inline
-- (not memoised) so settings menu nudge dialogs see the new value
-- without a fresh require.
local function _badgeSize(base)
    local scale = BookshelfSettings.read("cover_badge_font_scale") or 100
    return math.floor(base * scale / 100 + 0.5)
end

-- Pixel thickness of the progress bar (rounded pill on top of cover).
-- Bookends-style rounded look needs more vertical room than a stripe.
local function _barHeight()
    return Screen:scaleBySize(8)
end

-- Padding between the bar's bottom edge and the card's inside-border.
-- Matches the horizontal side margin so the bar reads as evenly inset
-- from all three nearby cover edges (left, right, bottom).
local function _barBottomPadding()
    return Screen:scaleBySize(3)
end

-- Horizontal margin between the bar and the card sides (inset from the
-- card's inside-border so the rounded bar doesn't kiss the cover edges).
local function _barSideMargin()
    return Screen:scaleBySize(3)
end

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
    fade_amount     = nil,
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
    if self.fade_amount and self.fade_amount > 0 then
        local bs = self.border_size or 0
        bb:lightenRect(x + bs, y + bs,
                       math.max(0, self.width - 2 * bs),
                       math.max(0, self.height - 2 * bs),
                       self.fade_amount)
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

-- _renderCornerFlag helper widget: paints the top-left bulk-select
-- corner flag (black isoceles triangle) with a concentric badge
-- (white ring, black dot). Returns a widget the caller can append to
-- the SpineWidget's overlap group.
--
-- Geometry: the triangle's legs are min(scaleBySize(28), 0.18*card_w)
-- so the flag scales sanely on PW5 grid covers (~110px wide → ~20px
-- leg) and never dominates a small thumbnail.
local CornerFlag = Widget:extend{
    width  = nil,   -- card width
    height = nil,   -- card height
}

function CornerFlag:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function CornerFlag:paintTo(bb, x, y)
    -- Flag scaled so the black "glass corner" reads from across the room
    -- on e-ink. Cap raised to 64dp; the 0.28 ratio scales down sanely on
    -- small thumbnails.
    local leg = math.min(Screen:scaleBySize(64), math.floor(self.width * 0.28))
    -- Fill the triangle by rasterising one horizontal line per row,
    -- shrinking the line width as we move down. Row i (0..leg-1) fills
    -- pixels from x..x+(leg-1-i) at y+i.
    for i = 0, leg - 1 do
        bb:paintRect(x, y + i, leg - i, 1, Blitbuffer.COLOR_BLACK)
    end
    -- Badge: concentric white outer / black inner discs along the
    -- right-angle bisector (y=x). r_max is the largest disc that fits
    -- exactly inscribed in the triangle (tangent to all three sides
    -- with a 1px margin):
    --   r_max = (leg - 2) / (2 + sqrt(2))
    -- We render at ~80% of r_max so there's a visible black "glass
    -- corner" between the white ring and the triangle's edges.
    --
    -- Center positioned so the white ring has a 1px margin from the
    -- cover's left/top edges — closer to the corner than the geometric
    -- incentre (which sits too far inside the triangle visually) but
    -- not so close that the circle bleeds out into the cover's frame.
    local r_max = math.max(2, math.floor((leg - 2) / 3.41421))
    local r_out = math.max(2, math.floor(r_max * 0.80))
    local cx    = x + r_out + 1
    local cy    = y + r_out + 1
    local r_in  = math.max(1, math.floor(r_out * 0.5))
    bb:paintCircle(cx, cy, r_out, Blitbuffer.COLOR_WHITE)
    bb:paintCircle(cx, cy, r_in,  Blitbuffer.COLOR_BLACK)
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
    -- When true, the card additionally paints a black diagonal
    -- corner flag in the top-left with a concentric white/black
    -- target badge. The flag distinguishes "this is in the bulk
    -- selection" from "this is the currently-open document" --
    -- both share the thick black border via is_selected, but only
    -- bulk-selected carries the flag. See spec §2.
    is_bulk_selected = false,
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
    -- Cover-level progress indicators (top-edge bar + bottom-left
    -- bookmark glyph) are a grid-cell affordance only. Hero card,
    -- folder stacks, and series stacks reuse SpineWidget for the
    -- underlying cover but should NOT show indicators -- they'd
    -- appear above/around overlay graphics. Opt-in from ShelfRow.
    show_progress       = false,
    suppress_badges     = false,
    -- ShelfRow's expanded mode renders book titles BELOW each cover.
    -- The bookmark glyph at the bottom-left would clash with the title
    -- if it dangled; lift it fully inside the cover when titles are
    -- visible. Regular grid: glyph can dangle for character.
    show_titles         = false,
    -- True when this cover renders inside a single-series view (drilled
    -- into a series stack OR a chip whose source.kind = "single_series").
    -- Consumed by _showSeriesNum's "in_series" three-state choice so the
    -- "#N" badge can be scoped to series folders. ShelfRow passes the
    -- flag through from BookshelfWidget's row_opts.
    in_series           = false,
}

-- Gate the "#N" series-number badge. Three-state setting:
--   "always" / true / nil  -> show on every cover with a series_num
--   "in_series"            -> only when caller is inside a single series
--                             (drilled into a series stack, or a chip
--                             with source.kind = "single_series"). Other
--                             shelf views suppress the badge because the
--                             surrounding books are mixed and the number
--                             reads as noise.
--   "never" / false        -> suppress everywhere
-- Default is "always", matching the original boolean-true behaviour.
local function _showSeriesNum(in_series)
    local v = BookshelfSettings.read("show_series_num")
    if v == nil or v == true or v == "always" then return true end
    if v == "in_series"                       then return in_series == true end
    return false
end

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

function SpineWidget.newStatusBadge(args)
    args = args or {}
    local size = args.size or Screen:scaleBySize(16)
    if args.state == "read" then
        return CoverProgress.buildOutlinedGlyphWidget(
            CoverProgress.GLYPH_BOOKMARK_CHECK, size, 1)
    end
    return CoverProgress.buildGlyphWidget(
        CoverProgress.GLYPH_BOOKMARK, size, Blitbuffer.COLOR_BLACK)
end

function SpineWidget.newStatusGlyphOverlay(args)
    args = args or {}
    local card_w = args.card_w or 0
    local card_h = args.card_h or 0
    if card_w <= 0 or card_h <= 0 then return nil end

    if args.state == "read" then
        local TextWidget = require("ui/widget/textwidget")
        local Font       = require("ui/font")
        local check_widget = TextWidget:new{
            text = "\xEF\x90\xAE",   -- U+F42E nerd-font check
            face = Font:getFace("smallinfofont", 12),
            bold = true,
        }
        local pill = FrameContainer:new{
            bordersize     = Size.border.thin,
            background     = Blitbuffer.COLOR_WHITE,
            radius         = Screen:scaleBySize(3),
            padding_left   = Size.padding.small,
            padding_right  = Size.padding.small,
            padding_top    = Screen:scaleBySize(2),
            padding_bottom = 0,
            check_widget,
        }
        local sz       = pill:getSize()
        local pill_h   = sz.h
        local bar_pad  = _barBottomPadding()
        local side     = _barSideMargin()
        local pill_y   = card_h - CARD_BORDER - bar_pad - pill_h
        local pill_x   = CARD_BORDER + side
        if pill_y < CARD_BORDER then pill_y = CARD_BORDER end
        return FrameContainer:new{
            bordersize   = 0,
            padding      = 0,
            padding_top  = pill_y,
            padding_left = pill_x,
            pill,
        }
    end

    local glyph_h = _glyphSize(card_w)
    local glyph_w = glyph_h
    if glyph_w > card_w * 0.4 then return nil end

    local halo_w = 0
    local glyph = CoverProgress.buildGlyphWidget(
        CoverProgress.GLYPH_BOOKMARK, glyph_h, args.colour or Blitbuffer.COLOR_BLACK)

    local lift = _glyphTopLift(args.show_titles)
    local y_offset = card_h - math.floor(glyph_h * lift + 0.5)
    return FrameContainer:new{
        bordersize   = 0,
        padding      = 0,
        padding_top  = y_offset - halo_w,
        padding_left = _glyphLeftInset() - halo_w,
        glyph,
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
    local card_w, card_h = self:_cardDimensions()
    local indicators     = (self.show_progress and not self.suppress_badges)
        and CoverProgress.decide(self.book)
        or  { bar = false, bar_pct = 0, glyph = nil }

    local children = {}

    -- 1. Shadow OR selection-border backdrop (z-order: bottom)
    if self.is_selected then
        children[#children + 1] = BorderOverlay:new{
            width     = card_w,
            height    = card_h,
            thickness = SELECTED_BORDER,
            radius    = CARD_RADIUS,
        }
    else
        children[#children + 1] = FrameContainer:new{
            bordersize   = 0,
            padding      = 0,
            padding_top  = SHADOW_OFFSET,
            padding_left = SHADOW_OFFSET,
            ShadowRect:new{ width = card_w, height = card_h },
        }
    end

    -- 2. In-progress glyph (IN FRONT of inner): anchored so its top is
    --    GLYPH_TOP_LIFT * glyph_h above the card bottom (i.e. the entire
    --    glyph sits inside the cover, bottom at card_h - 0.35*glyph_h).
    if indicators.glyph == "in_progress" then
        local colours = CoverProgress.resolvedColours()
        local glyph_h = _glyphSize(card_w)
        local glyph_w = self:_glyphWidth(glyph_h)
        if glyph_w <= card_w * 0.4 then
            local glyph = CoverProgress.buildGlyphWidget(
                CoverProgress.GLYPH_BOOKMARK, glyph_h, colours.fill)
            -- Use the TextWidget's ACTUAL rendered height for the
            -- offset math, not the nominal face size. A
            -- Font:getFace("symbols", N) widget paints at roughly
            -- N * 1.3-1.4 (ascent + descent + line-height padding),
            -- so a lift computed from N alone over-shoots and the
            -- glyph dangles below the card. Measuring after build
            -- keeps the lift math accurate at any DPI.
            local widget_h = glyph:getSize().h
            local lift = _glyphTopLift(self.show_titles)
            local y_offset = card_h - math.floor(widget_h * lift + 0.5)
            children[#children + 1] = FrameContainer:new{
                bordersize   = 0,
                padding      = 0,
                padding_top  = y_offset,
                padding_left = _glyphLeftInset(),
                glyph,
            }
        end
    end

    -- 3. Inner card (image or fallback) at (0,0)
    children[#children + 1] = inner

    -- 4a. Finished badge, bookmark style (IN FRONT of inner): SAME position
    --     as the in-progress glyph (bottom-left, lifted by GLYPH_TOP_LIFT),
    --     a hollow check-bookmark with a black halo for legibility against
    --     any cover. This is the pre-v2.1 design, restored as an opt-in
    --     after Reddit feedback that the v2.1 tickbox was too heavy.
    if indicators.glyph == "complete_bookmark" then
        local glyph_h = _glyphSize(card_w)
        local glyph_w = self:_glyphWidth(glyph_h)
        if glyph_w <= card_w * 0.4 then
            local halo_w = 1
            -- Match the in-progress glyph's positioning exactly. The
            -- in-progress branch (above) bases its lift on
            -- TextWidget:getSize().h (actual rendered height,
            -- ~glyph_h * 1.35 after font line metrics) rather than
            -- glyph_h itself, because Font:getFace("symbols", N) paints
            -- taller than N. Critically, buildOutlinedGlyphWidget's
            -- OverlapGroup carries a SYNTHETIC dimen of glyph_h+2*halo_w
            -- (see bookshelf_cover_progress.lua), which understates the
            -- real paint footprint -- using outlined:getSize() here
            -- under-shoots the lift the same way glyph_h does. Build a
            -- throwaway bare glyph to measure the true height, then
            -- offset by -halo_w so the inner glyph's centre lands on
            -- the in-progress glyph's centre.
            local probe = CoverProgress.buildGlyphWidget(
                CoverProgress.GLYPH_BOOKMARK_CHECK, glyph_h,
                Blitbuffer.COLOR_BLACK)
            local widget_h = probe:getSize().h
            probe:free()
            local outlined = CoverProgress.buildOutlinedGlyphWidget(
                CoverProgress.GLYPH_BOOKMARK_CHECK, glyph_h, halo_w)
            local lift = _glyphTopLift(self.show_titles)
            local y_offset = card_h - math.floor(widget_h * lift + 0.5)
            children[#children + 1] = FrameContainer:new{
                bordersize   = 0,
                padding      = 0,
                padding_top  = y_offset - halo_w,
                padding_left = _glyphLeftInset() - halo_w,
                outlined,
            }
        end
    end

    -- 4b. Finished badge, tickbox style (IN FRONT of inner): a flat square
    --     pill at bottom-LEFT containing the nerd-font check glyph
    --     (U+F42E). Sized as ~55% of the page-count pill's natural height
    --     so the badge reads as a small mark rather than a heavy block.
    --     Width forced equal to height for a square; check glyph centred
    --     via CenterContainer plus a small downward VerticalSpan bias to
    --     compensate for the glyph's no-descender bbox skew.
    if indicators.glyph == "complete_tickbox" then
        local TextWidget = require("ui/widget/textwidget")
        local Font       = require("ui/font")

        -- Reference widget measures the page-count pill's natural inner
        -- height. Built with identical face spec to the page-count pill
        -- (smallinfofont 12 bold) and freed immediately after measure.
        -- Finished pill is a smaller square sitting alongside the
        -- page-count pill: ~half the outer height for a subtler badge
        -- now that the heavy v2.1 design got Reddit pushback.
        local ref = TextWidget:new{
            text = "p1",
            face = Font:getFace("smallinfofont", _badgeSize(12)),
            bold = true,
        }
        local page_count_h = ref:getSize().h
        ref:free()
        local inner_h = math.floor(page_count_h * 0.55)

        -- Check glyph at 10pt: a touch larger than the conservative 8pt
        -- so the tick has more presence inside the small square. The
        -- nerd-font check has no descender, so a naked CenterContainer
        -- centres the TextWidget bbox -- which leaves the visible glyph
        -- riding high in the pill. A small VerticalSpan above the glyph
        -- inside a VerticalGroup biases the bbox-centred placement
        -- downward, so the rendered check lands at the pill's visual
        -- centre.
        local check_widget = TextWidget:new{
            text = "\xEF\x90\xAE",   -- U+F42E nerd-font check
            face = Font:getFace("smallinfofont", _badgeSize(10)),
            bold = true,
        }
        local VerticalGroup = require("ui/widget/verticalgroup")
        local VerticalSpan  = require("ui/widget/verticalspan")
        local centred = VerticalGroup:new{
            align = "center",
            VerticalSpan:new{ width = Screen:scaleBySize(1) },
            check_widget,
        }
        local pill = FrameContainer:new{
            bordersize     = Size.border.thin,
            background     = Blitbuffer.COLOR_WHITE,
            radius         = Screen:scaleBySize(3),
            padding_left   = 0,
            padding_right  = 0,
            padding_top    = 0,
            padding_bottom = 0,
            CenterContainer:new{
                dimen = Geom:new{ w = inner_h, h = inner_h },
                centred,
            },
        }
        local sz       = pill:getSize()
        local pill_h   = sz.h
        local bar_pad  = _barBottomPadding()
        local side     = _barSideMargin()
        local pill_y   = card_h - CARD_BORDER - bar_pad - pill_h
        local pill_x   = CARD_BORDER + side
        if pill_y < CARD_BORDER then pill_y = CARD_BORDER end
        children[#children + 1] = FrameContainer:new{
            bordersize   = 0,
            padding      = 0,
            padding_top  = pill_y,
            padding_left = pill_x,
            pill,
        }
    end

    -- 5. Page count and / or progress bar at the bottom of the cover.
    --    Page count (when enabled) sits bottom-RIGHT as a "p<N>" white
    --    rounded pill (same visual style as the series-number badge so
    --    the two badges read as a family). Bottom-right keeps it clear
    --    of the in-progress / completed glyph that anchors bottom-left.
    --    The progress bar (when enabled) takes the remaining width to
    --    the LEFT of the badge. Either indicator can show alone.
    local want_page_count = indicators.page_count and self.book and self.book.page_count
    if indicators.bar or want_page_count then
        local colours = CoverProgress.resolvedColours()
        local bar_h   = _barHeight()
        local bar_pad = _barBottomPadding()
        local side    = _barSideMargin()
        local bottom_y = card_h - CARD_BORDER - bar_pad - bar_h
        local left_x   = CARD_BORDER + side
        local row_w    = card_w - 2 * CARD_BORDER - 2 * side

        local badge_widget, badge_w, badge_h = nil, 0, 0
        if want_page_count then
            local TextWidget = require("ui/widget/textwidget")
            local Font       = require("ui/font")
            -- Same face + weight as the "#N" series badge so the two
            -- badges read as a matched pair when both are present on a
            -- cover. Vertical padding is dropped to zero (the border
            -- alone provides breathing room) so the pill height stays
            -- close to the bar height.
            badge_widget = FrameContainer:new{
                bordersize     = Size.border.thin,
                background     = Blitbuffer.COLOR_WHITE,
                radius         = Screen:scaleBySize(3),
                padding_left   = Size.padding.small,
                padding_right  = Size.padding.small,
                padding_top    = 0,
                padding_bottom = 0,
                TextWidget:new{
                    text = "p" .. tostring(self.book.page_count),
                    face = Font:getFace("smallinfofont", _badgeSize(12)),
                    bold = true,
                },
            }
            local sz = badge_widget:getSize()
            badge_w, badge_h = sz.w, sz.h
            -- Bottom-right corner, inset from the cover border. Anchor
            -- the badge BOTTOM to the bar's bottom-edge so it sits
            -- flush inside the cover (no overlap of the inside border)
            -- while still hovering above the cover's lower edge. The
            -- badge top protrudes upward into the cover image since
            -- the pill is taller than the bar -- expected and visually
            -- consistent with the "#N" series badge at top-right.
            local badge_y = bottom_y + bar_h - badge_h
            local badge_x = card_w - CARD_BORDER - side - badge_w
            if badge_y < CARD_BORDER then badge_y = CARD_BORDER end
            if badge_x < CARD_BORDER then badge_x = CARD_BORDER end
            children[#children + 1] = FrameContainer:new{
                bordersize   = 0,
                padding      = 0,
                padding_top  = badge_y,
                padding_left = badge_x,
                badge_widget,
            }
        end

        if indicators.bar then
            local gap = badge_w > 0 and Screen:scaleBySize(4) or 0
            local bar_w = row_w - badge_w - gap
            if bar_w > 0 then
                local bar = CoverProgress.buildBarWidget(
                    bar_w, bar_h,
                    indicators.bar_pct, colours.fill, colours.track)
                children[#children + 1] = FrameContainer:new{
                    bordersize   = 0,
                    padding      = 0,
                    padding_top  = bottom_y,
                    padding_left = left_x,
                    bar,
                }
            end
        end
    end

    -- 6. Series-number badge. White rounded pill with "#N" at top-right,
    --    sitting proud of the cover by SHADOW_OFFSET -- matches the
    --    SeriesStack "xN" count badge style. Shown on any cover whose
    --    book has a series_num (regardless of which chip / drilldown the
    --    user got here from), gated by:
    --      * self.show_progress -- grid-only surface (hero / folder /
    --        series stacks reuse SpineWidget but opt out).
    --      * Setting bookshelf_show_series_num (default ON).
    if self.show_progress and not self.suppress_badges and _showSeriesNum(self.in_series)
            and self.book and self.book.series_num then
        local TextWidget     = require("ui/widget/textwidget")
        local Font           = require("ui/font")
        local badge = FrameContainer:new{
            bordersize     = Size.border.thin,
            background     = Blitbuffer.COLOR_WHITE,
            radius         = Screen:scaleBySize(3),
            padding_left   = Size.padding.default,
            padding_right  = Size.padding.default,
            padding_top    = Size.padding.small,
            padding_bottom = Size.padding.small,
            TextWidget:new{
                text = "#" .. tostring(self.book.series_num),
                face = Font:getFace("smallinfofont", _badgeSize(12)),
                bold = true,
            },
        }
        local badge_w       = badge:getSize().w
        local cover_right_x = card_w
        local badge_x       = math.max(0, math.min(self.width - badge_w,
                                  cover_right_x - math.floor(badge_w / 2)))
        badge.overlap_offset = { badge_x, -SHADOW_OFFSET }
        children[#children + 1] = badge
    end

    -- Bulk-select corner flag (top-left). Appended last so it paints
    -- ABOVE the cover artwork. The flag's size is fully contained
    -- within the cover's footprint (top-left corner only) and does
    -- not collide with the top-right series badge / bottom-left
    -- bookmark glyph / bottom-right page count.
    if self.is_bulk_selected then
        children[#children + 1] = CornerFlag:new{
            width  = card_w,
            height = card_h,
        }
    end

    return OverlapGroup:new{
        dimen = Geom:new{ w = self.width, h = self.height },
        unpack(children),
    }, card_w, card_h
end

-- Cheap approximation of the rendered width of a single nerd-font glyph at
-- the given height: nerd-font glyphs are roughly square at this face, so
-- glyph_w ≈ glyph_h. Used only to suppress the glyph on very narrow cards.
function SpineWidget:_glyphWidth(glyph_h)
    return glyph_h
end

-- Computed card dimensions taking the in-progress glyph's dangle into
-- account. Both _renderCover and _renderFallback must use this when
-- sizing their inner card widget so the card doesn't overlap the
-- dangle zone that _renderShadowedCard reserves on the bottom edge.
function SpineWidget:_cardDimensions()
    -- Glyph is now fully INSIDE the card (no dangle), so no extra
    -- bottom-margin reservation needed.
    return self.width - SHADOW_OFFSET, self.height - SHADOW_OFFSET
end

function SpineWidget:_renderCover(bb)
    local card_w, card_h = self:_cardDimensions()
    -- The card-perimeter border stays thin in both states so the cover
    -- image's pixel position and size are identical between selected
    -- and unselected. The selection cue is a thicker BorderOverlay
    -- painted on TOP in _renderShadowedCard.
    local border = CARD_BORDER
    local img_w = card_w - 2 * border
    local img_h = card_h - 2 * border

    -- Bar overlays the cover artwork (rounded pill on top); no image
    -- shrinking required. The image fills the card normally.

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
    local status_source = self.book and self.book.status
    if not status_source and self.book and self.book.filepath then
        local ok_repo, Repo = pcall(require, "lib/bookshelf_book_repository")
        if ok_repo and Repo and Repo.readProgress then
            local _, status = Repo.readProgress(self.book.filepath)
            status_source = status
        end
    end
    if self.show_progress
            and (status_source == "finished" or status_source == "complete")
            and fadeFinishedBooksEnabled() then
        cover_args.fade_amount = FADED_FINISHED_AMOUNT
    end
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

    local card_w, card_h = self:_cardDimensions()
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
    local inset_h        = math.max(Screen:scaleBySize(6), math.floor(card_w * 0.06))
    local inset_v_top    = math.max(Screen:scaleBySize(8), math.floor(card_h * 0.06))
    -- Bottom inset grows to contain the progress bar (when shown) so the
    -- rounded pill sits within the paper-tone bottom strip with the same
    -- breathing room above the bar as below it (bar_pad on each side).
    local inset_v_bottom = inset_v_top
    if self.show_progress and CoverProgress.decide(self.book).bar then
        local needed = CARD_BORDER + 2 * _barBottomPadding() + _barHeight()
        if needed > inset_v_bottom then inset_v_bottom = needed end
    end
    local outer_inset_w = card_w - inset_h * 2
    local outer_inset_h = card_h - inset_v_top - inset_v_bottom
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
    -- VerticalGroup composes [top spacer | inner_frame | bottom spacer]
    -- so the inner-frame sits in the upper portion when the bottom inset
    -- is enlarged for the progress bar (asymmetric insets).
    local card = FrameContainer:new{
        bordersize = border,
        radius     = CARD_RADIUS,
        padding    = 0,
        background = Blitbuffer.gray(0.08),
        VerticalGroup:new{
            align = "center",
            VerticalSpan:new{ width = inset_v_top - border },
            CenterContainer:new{
                dimen = Geom:new{ w = card_w - border * 2, h = outer_inset_h },
                inner_frame,
            },
            VerticalSpan:new{ width = inset_v_bottom - border },
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
