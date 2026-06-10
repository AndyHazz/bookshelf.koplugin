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
local BFont           = require("lib/bookshelf_fonts")
local FrameContainer  = require("ui/widget/container/framecontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
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

-- Lazy reference to bookshelf_book_repository for the lazy-cover-decode
-- path (Repo.getCoverBB). Lazy to keep the module load order flexible —
-- same pattern bookshelf_cover_progress uses for its own Repo lookup.
local _Repo
local function _getRepo()
    if not _Repo then _Repo = require("lib/bookshelf_book_repository") end
    return _Repo
end

-- Shadow geometry shared by both render paths.
local SHADOW_OFFSET   = Screen:scaleBySize(4)       -- shadow offset in dp
local CARD_RADIUS     = Screen:scaleBySize(4)       -- rounded corner radius
local CARD_BORDER     = Screen:scaleBySize(1)       -- 1dp border on the card

-- How far an on-hold book's cover is faded toward the page background, as a
-- white-blend opacity for bb:lightenRect. Night mode inverts the framebuffer,
-- so the same white blend reads as a darken toward the black page there — a
-- mode-correct "shelved / paused" de-emphasis either way. Grid covers only
-- (gated on show_progress in _wrapCoverInCard, which the hero / stacks clear).
local ON_HOLD_FADE = 0.6
-- Selected-state border thickness: matches SHADOW_OFFSET so the border's
-- outer perimeter sits exactly where the unselected-state drop shadow's
-- outer edge sits. The selected→unselected transition is then just a
-- color swap (black border → grey shadow) in the same pixel band, with
-- no change in the slot's outer footprint.
local SELECTED_BORDER = SHADOW_OFFSET
-- Drop-shadow grey, mode-aware. KOReader inverts the framebuffer at refresh
-- in night mode, so a fixed mid-grey (gray(0.5) = 0x80) inverts to ~0x7F and
-- reads as a bright halo against the dark night background. Beware gray()'s
-- direction: its arg is *darkness* (gray(level) = 0xFF - level*0xFF), so a
-- LOW level paints a near-white pixel. For a dark shadow ON SCREEN in night
-- mode we must paint near-white (low level) and let the inversion flip it to
-- dark: gray(0.15) = 0xD9 painted → 0x26 displayed. Day stays mid-grey (no
-- inversion). No user control — purely a function of the active mode.
local SHADOW_GRAY_DAY   = Blitbuffer.gray(0.5)
local SHADOW_GRAY_NIGHT = Blitbuffer.gray(0.15)
local function _shadowGray()
    if G_reader_settings:isTrue("night_mode") then
        return SHADOW_GRAY_NIGHT
    end
    return SHADOW_GRAY_DAY
end

-- Placeholder (no-image) cover backgrounds. In day these are near-white
-- paper tones; pure white collapses to pure BLACK under night-mode
-- framebuffer inversion, so the placeholder vanishes against the black
-- page. In night we paint a light grey (low gray() level) so the
-- inversion lands on a *slightly grey* card that stays distinct from the
-- background. Inner stays brighter than outer in both modes (preserving
-- the day relationship): inner ~0x28 / outer ~0x1E displayed in night.
local FALLBACK_OUTER_BG_DAY   = Blitbuffer.gray(0.08)
local FALLBACK_INNER_BG_DAY   = Blitbuffer.COLOR_WHITE
local FALLBACK_OUTER_BG_NIGHT = Blitbuffer.gray(0.12)
local FALLBACK_INNER_BG_NIGHT = Blitbuffer.gray(0.16)
local function _fallbackBgs()
    if G_reader_settings:isTrue("night_mode") then
        return FALLBACK_OUTER_BG_NIGHT, FALLBACK_INNER_BG_NIGHT
    end
    return FALLBACK_OUTER_BG_DAY, FALLBACK_INNER_BG_DAY
end

-- Glyph sizing for the in-progress / finished badge on covers.
-- Scaled with cover width but floored so tiny columns don't render
-- a glyph too small to read. 80% of the original sizing so the glyph
-- doesn't crowd the title text in expanded (title-view) mode.
-- Returns the BASE (100%-scale) status-glyph height. Call sites wrap this
-- in _badgeSize() to apply the user's Cover badge size, and pin overhang to
-- the base via _baseGlyphRenderedH so growth goes inward (issue #92).
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

-- When the Cover badge size enlarges a bottom-anchored bookmark glyph,
-- this fraction of the EXTRA height extends the visible dangle downward;
-- the remainder grows inward (up, under the cover/progress bar). The
-- in-progress bookmark's in-cover portion is hidden by the progress bar,
-- so a pinned dangle (share = 0) would make the glyph appear to vanish
-- upward as it grows. 1.0 = full proportional dangle (overhangs as much
-- as a naively scaled glyph); 0.5 splits the difference — the dangle
-- visibly grows at half the overhang of full proportional (issue #92).
local GLYPH_DANGLE_GROWTH_SHARE = 0.5

-- Horizontal inset of the glyph from the card's left edge.
local function _glyphLeftInset()
    return Size.padding.small + Screen:scaleBySize(2)
end

-- Cover-badge font scale alias: delegates to CoverProgress.badgeSize so
-- the page-count badge, series-number badge, count badge, tickbox glyph
-- AND the status glyphs (in-progress bookmark, finished bookmark,
-- favourite heart/star) share one source of truth for the user's
-- cover_badge_font_scale setting (the "Cover badge size" dialog). Keep
-- the short local alias so the call sites below stay terse.
local _badgeSize = CoverProgress.badgeSize

-- Rendered (measured) height of a glyph at its UNSCALED base size. Status
-- glyphs anchor their overhang to this so enlarging the Cover badge size
-- grows them toward the cover centre rather than further off the edge
-- (issue #92): the off-cover dangle stays pinned to the 100%-scale
-- footprint while the inner edge extends inward. When the user scale is
-- 100% (glyph_h == base_h) the already-measured scaled height is reused;
-- otherwise a throwaway probe at the base size measures it.
local function _baseGlyphRenderedH(glyph_char, base_h, glyph_h, scaled_widget_h, face_name)
    if base_h == glyph_h then return scaled_widget_h end
    return CoverProgress.glyphRenderedH(glyph_char, base_h, face_name)
end

-- Memoized natural height of the page-count pill's reference text
-- ("p" + hair space + digit, smallinfofont bold). Rendered height
-- depends only on the face spec, so one probe per point size suffices;
-- the user's Cover badge size setting feeds into the size argument via
-- _badgeSize, which makes the key self-invalidating on scale changes.
local _page_pill_h_memo = {}
local function _pagePillRefH(size)
    local h = _page_pill_h_memo[size]
    if not h then
        local TextWidget = require("ui/widget/textwidget")
        local ref_face, ref_bold = BFont:getFace("smallinfofont", size, { bold = true })
        local ref = TextWidget:new{
            -- Match the page-count pill's actual text (hair space
            -- between "p" and the digits) so any future width-aware
            -- measurement here stays in sync. Only the height is
            -- consumed today, but the parity guards against drift.
            text = "p\xe2\x80\x8a1",
            face = ref_face,
            bold = ref_bold,
        }
        h = ref:getSize().h
        ref:free()
        _page_pill_h_memo[size] = h
    end
    return h
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

-- _coverFillBB(bb, img_w, img_h) — produce the slot-sized (img_w × img_h)
-- cover bitmap for the cover_fill path. Portrait sources (the norm) are
-- stretched to the slot exactly as before -- a near-2:3 cover stretches
-- imperceptibly. But a SQUARE or LANDSCAPE source (w >= h, e.g. "The Complete
-- Peanuts") would be squashed into a thin portrait, so instead scale it to
-- FILL the slot height (aspect preserved) and centre-crop the horizontal
-- overflow. The grid stays uniform 2:3; off-aspect covers lose a little off
-- the left/right rather than distorting (issue 97).
local function _coverFillBB(bb, img_w, img_h)
    local sw, sh = bb:getWidth(), bb:getHeight()
    if sw < sh then
        return bb:scale(img_w, img_h)
    end
    local scaled_w = math.max(img_w, math.floor(sw * img_h / sh))
    local filled   = bb:scale(scaled_w, img_h)
    if scaled_w <= img_w then
        return filled
    end
    local out   = Blitbuffer.new(img_w, img_h, filled:getType())
    local x_off = math.floor((scaled_w - img_w) / 2)
    out:blitFrom(filled, 0, 0, x_off, 0, img_w, img_h)
    filled:free()
    return out
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
    bb:paintRoundedRect(x, y, self.width, self.height, _shadowGray(), CARD_RADIUS)
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
    fade_by      = nil,                        -- 0..1 white-blend over the inner
                                               -- cover (on-hold de-emphasis); nil = none
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
    -- On-hold fade: blend the page colour over the cover image so the book
    -- reads as shelved. Applied over the inner area only (inside the border),
    -- BEFORE the corner mask + border so the rounded shape and frame stay
    -- crisp on top of the wash.
    local fade_by = self.fade_by or self.fade_amount
    if fade_by and fade_by > 0 then
        local b  = self.border_size
        local iw = self.width  - 2 * b
        local ih = self.height - 2 * b
        if iw > 0 and ih > 0 then
            bb:lightenRect(x + b, y + b, iw, ih, fade_by)
        end
    end
    if self.radius and self.radius > 0 then
        local r       = self.radius
        local w, h    = self.width, self.height
        local bg      = self.bg_color or Blitbuffer.COLOR_WHITE
        local r_sq    = r * r
        -- Resolve the shadow grey LIVE here, not from self.shadow_color
        -- (captured at build time). ShadowRect:paintTo also calls _shadowGray()
        -- live, so the enclosing shadow repaints with the current day/night
        -- grey on every paint. The corner mask captured its colour once at
        -- build, so after a day<->night switch (which repaints the card
        -- without rebuilding it) the masked BR corner kept the OLD grey while
        -- the surrounding shadow had the new one -- the mismatched corner
        -- artifact in night mode (issue #93). self.shadow_color stays as the
        -- "is this card shadowed?" flag + geometry gate; only the painted
        -- value is now live.
        local shadow_paint = self.shadow_color and _shadowGray() or nil
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
                                          and shadow_paint or bg
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
        -- Honour the user's "Border color" setting when the SpineWidget
        -- doesn't set border_color explicitly. resolvedColors().border
        -- defaults to black + adapts to night mode + color panels per
        -- the day/night color split.
        local border_color = self.border_color
        if not border_color then
            local ok_cp, c = pcall(CoverProgress.resolvedColors)
            if ok_cp and c then border_color = c.border end
        end
        bb:paintBorder(x, y, self.width, self.height,
                       self.border_size,
                       border_color or Blitbuffer.COLOR_BLACK,
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
    -- Render-cover conditions:
    --   * book.has_cover (BIM says a cover exists)
    --   * AND either we already hold a bb (eager path: self.cover_bb
    --     override, or book.cover_bb populated by buildBookMeta with the
    --     default want_cover=true) OR we have a filepath to drive the
    --     lazy path (ScaledCoverCache hit or Repo.getCoverBB on miss).
    --   * OR book.cover_image_path is a cached external enrichment cover
    --     (currently Hardcover) for a book whose EPUB has no embedded cover.
    local effective_bb = self.cover_bb or (self.book and self.book.cover_bb)
    local can_lazy     = self.book and self.book.filepath
    local external_cover = self.book and self.book.cover_image_path
    if self.book
            and ((self.book.has_cover and (effective_bb or can_lazy)) or external_cover) then
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

    -- 1. Shadow OR selection-border backdrop (z-order: bottom). FADED
    --    on-hold covers (borderless — see _wrapCoverInCard) also drop the
    --    shadow so they sit flat against the page; same gate as the fade.
    --    Badge-only on-hold covers (on_hold_display = "pause") keep their
    --    border and shadow like any other book (issue #121).
    if self.is_selected then
        children[#children + 1] = BorderOverlay:new{
            width     = card_w,
            height    = card_h,
            thickness = SELECTED_BORDER,
            radius    = CARD_RADIUS,
        }
    elseif not (indicators.on_hold_fade and not self.is_bulk_selected) then
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
        local colors = CoverProgress.resolvedColors()
        local base_h  = _glyphSize(card_w)
        local glyph_h = _badgeSize(base_h)
        local glyph_w = self:_glyphWidth(glyph_h)
        if glyph_w <= card_w * 0.4 then
            local halo_w = 1
            -- Measure the TRUE rendered height (memoized probe) -
            -- Font:getFace("symbols", N) paints at ~N*1.3-1.4 once
            -- ascent / descent / line-height padding are accounted for.
            local widget_h = CoverProgress.glyphRenderedH(
                CoverProgress.GLYPH_BOOKMARK, glyph_h)
            -- White centre on a dark halo, no drop shadow. The
            -- in-progress bookmark sits INSIDE the cover (no overhang),
            -- so it doesn't need the "raised above the surface" cue a
            -- shadow gives the favourite star / completed bookmark
            -- (both of which dangle off the cover edge). Halo alone is
            -- enough to keep it legible against any cover artwork.
            local outlined = CoverProgress.buildOutlinedGlyphWidget(
                CoverProgress.GLYPH_BOOKMARK, glyph_h, halo_w,
                colors.border,      -- halo (shared "Border color")
                colors.bookmark)    -- centre fill (user-tunable bookmark color)
            local lift = _glyphTopLift(self.show_titles)
            -- Pin the below-card dangle to the UNSCALED footprint so a
            -- larger Cover badge size lifts the top inward and the bottom
            -- overhang stays put (issue #92), rather than dangling further.
            local base_widget_h = _baseGlyphRenderedH(
                CoverProgress.GLYPH_BOOKMARK, base_h, glyph_h, widget_h)
            -- Dangle grows partly downward (visible) and partly inward so
            -- the bookmark gets visibly larger without burying itself
            -- behind the cover (issue #92).
            local dangle_h = base_widget_h
                + GLYPH_DANGLE_GROWTH_SHARE * (widget_h - base_widget_h)
            local y_offset = card_h
                + math.floor(dangle_h * (1 - lift) + 0.5) - widget_h
            children[#children + 1] = FrameContainer:new{
                bordersize   = 0,
                padding      = 0,
                padding_top  = y_offset - halo_w,
                padding_left = _glyphLeftInset() - halo_w,
                outlined,
            }
        end
    end

    -- 3. Inner card (image or fallback) at (0,0)
    children[#children + 1] = inner

    -- 3b. On-hold badge (IN FRONT of inner): a centred pause "button" drawn
    --     as a filled circle + two solid bars, sharing the page-count badge's
    --     colours (badge_bg fill, badge_fg border + bars). Shown when decide()
    --     flags the book on-hold; decide() also nulls the corner in-progress
    --     glyph in that case, so the cover carries one clear "on hold" cue.
    --     Drawn (not the nf pause-circle glyph) so it centres exactly, keeps
    --     opaque bars, and matches the other badges -- see buildPauseBadgeWidget.
    if indicators.on_hold and not self.is_bulk_selected then
        local diameter = math.floor(card_w * 0.30)
        if diameter > 0 then
            local colors = CoverProgress.resolvedColors()
            local badge = CoverProgress.buildPauseBadgeWidget(
                diameter,
                colors.badge_bg,   -- circle fill   (matches page-count badge)
                colors.badge_fg,   -- border + bars (matches page-count badge)
                Size.border.thin)
            children[#children + 1] = CenterContainer:new{
                dimen = Geom:new{ w = card_w, h = card_h },
                badge,
            }
        end
    end

    -- 4a. Finished badge, bookmark style (IN FRONT of inner): SAME position
    --     as the in-progress glyph (bottom-left, lifted by GLYPH_TOP_LIFT),
    --     a hollow check-bookmark with a black halo for legibility against
    --     any cover. This is the pre-v2.1 design, restored as an opt-in
    --     after Reddit feedback that the v2.1 tickbox was too heavy.
    if indicators.glyph == "complete_bookmark" then
        local base_h  = _glyphSize(card_w)
        local glyph_h = _badgeSize(base_h)
        local glyph_w = self:_glyphWidth(glyph_h)
        if glyph_w <= card_w * 0.4 then
            local halo_w   = 1
            local shadow_d = math.max(halo_w + 2,
                                      math.floor(glyph_h * 0.10))
            local colors  = CoverProgress.resolvedColors()
            -- Match the in-progress glyph's positioning exactly. The
            -- in-progress branch (above) bases its lift on
            -- TextWidget:getSize().h (actual rendered height,
            -- ~glyph_h * 1.35 after font line metrics) rather than
            -- glyph_h itself, because Font:getFace("symbols", N) paints
            -- taller than N. The halo+shadow group carries a synthetic
            -- dimen that understates the real paint footprint -- using
            -- outlined:getSize() here under-shoots the lift the same
            -- way glyph_h does. Measure the true height (memoized
            -- probe), then offset by -halo_w so the inner glyph's
            -- centre lands on the in-progress glyph's centre.
            local widget_h = CoverProgress.glyphRenderedH(
                CoverProgress.GLYPH_BOOKMARK_CHECK, glyph_h)
            -- Same halo + drop-shadow treatment as the favourites star
            -- (top-left). Halo keeps the glyph legible against the
            -- cover; the offset shadow gives a hint of depth.
            local outlined = CoverProgress.buildHaloShadowedGlyphWidget(
                CoverProgress.GLYPH_BOOKMARK_CHECK, glyph_h, halo_w,
                shadow_d, shadow_d,  -- down-right
                colors.border,             -- halo (shared "Border color")
                colors.complete_bookmark,  -- centre fill (user-tunable)
                colors.shadow)             -- shadow (always dark on screen)
            local lift = _glyphTopLift(self.show_titles)
            -- Same inward-growth anchor as the in-progress glyph: the
            -- below-card dangle is pinned to the unscaled footprint so a
            -- larger Cover badge size grows the check toward the centre,
            -- not further off the bottom edge (issue #92).
            local base_widget_h = _baseGlyphRenderedH(
                CoverProgress.GLYPH_BOOKMARK_CHECK, base_h, glyph_h, widget_h)
            -- Dangle grows partly downward (visible) and partly inward so
            -- the finished bookmark gets visibly larger without burying
            -- itself behind the cover (issue #92).
            local dangle_h = base_widget_h
                + GLYPH_DANGLE_GROWTH_SHARE * (widget_h - base_widget_h)
            local y_offset = card_h
                + math.floor(dangle_h * (1 - lift) + 0.5) - widget_h
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
        local colors    = CoverProgress.resolvedColors()

        -- Natural inner height of the page-count pill (memoized probe
        -- built with identical face spec: smallinfofont 12 bold).
        -- Finished pill is a smaller square sitting alongside the
        -- page-count pill: ~half the outer height for a subtler badge
        -- now that the heavy v2.1 design got Reddit pushback.
        local page_count_h = _pagePillRefH(_badgeSize(12))
        -- 0.65 of the page-count pill: a touch larger than the original
        -- 0.55 so the finished tickbox reads less "tiny" out of the box
        -- (issue #92). Still a subtle bordered pill, well short of the
        -- heavy v2.1 sticker that drew Reddit pushback. Scales further via
        -- the Cover badge size dialog (page_count_h is _badgeSize-derived).
        local inner_h = math.floor(page_count_h * 0.65)

        -- Check glyph at 10pt: a touch larger than the conservative 8pt
        -- so the tick has more presence inside the small square. The
        -- nerd-font check has no descender, so a naked CenterContainer
        -- centres the TextWidget bbox -- which leaves the visible glyph
        -- riding high in the pill. A small VerticalSpan above the glyph
        -- inside a VerticalGroup biases the bbox-centred placement
        -- downward, so the rendered check lands at the pill's visual
        -- centre.
        local check_face, check_bold = BFont:getFace("smallinfofont", _badgeSize(11), { bold = true })
        local check_widget = TextWidget:new{
            text = "\xEF\x90\xAE",   -- U+F42E nerd-font check
            face = check_face,
            bold = check_bold,
            fgcolor = colors.badge_fg,
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
            background     = colors.badge_bg,
            color          = colors.border,
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
        local colors = CoverProgress.resolvedColors()
        local bar_h   = _barHeight()
        local bar_pad = _barBottomPadding()
        local side    = _barSideMargin()
        local bottom_y = card_h - CARD_BORDER - bar_pad - bar_h
        local left_x   = CARD_BORDER + side
        local row_w    = card_w - 2 * CARD_BORDER - 2 * side

        local badge_widget, badge_w, badge_h = nil, 0, 0
        if want_page_count then
            local TextWidget = require("ui/widget/textwidget")
            -- Same face + weight as the "#N" series badge so the two
            -- badges read as a matched pair when both are present on a
            -- cover. Vertical padding is dropped to zero (the border
            -- alone provides breathing room) so the pill height stays
            -- close to the bar height.
            local pc_face, pc_bold = BFont:getFace("smallinfofont", _badgeSize(12), { bold = true })
            badge_widget = FrameContainer:new{
                bordersize     = Size.border.thin,
                background     = colors.badge_bg,
                color          = colors.border,
                radius         = Screen:scaleBySize(3),
                padding_left   = Size.padding.small,
                padding_right  = Size.padding.small,
                padding_top    = 0,
                padding_bottom = 0,
                TextWidget:new{
                    -- HAIR SPACE between "p" and the page count for the
                    -- same readability reason as the series pill above:
                    -- the lowercase "p" and the leading digit otherwise
                    -- collide at smallinfofont(12).
                    text = "p\xe2\x80\x8a" .. tostring(self.book.page_count),
                    face = pc_face,
                    bold = pc_bold,
                    fgcolor = colors.badge_fg,
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
                    indicators.bar_pct, colors.fill, colors.track, colors.border)
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
        local colors        = CoverProgress.resolvedColors()
        local sn_face, sn_bold = BFont:getFace("smallinfofont", _badgeSize(12), { bold = true })
        local badge = FrameContainer:new{
            bordersize     = Size.border.thin,
            background     = colors.badge_bg,
            color          = colors.border,
            radius         = Screen:scaleBySize(3),
            padding_left   = Size.padding.default,
            padding_right  = Size.padding.default,
            padding_top    = Size.padding.small,
            padding_bottom = Size.padding.small,
            TextWidget:new{
                -- "#\u{200A}N": HAIR SPACE between the hash and the
                -- index for readability inside the small bold pill --
                -- full word-space split it visually into two columns,
                -- no space ran them together at smallinfofont(12),
                -- and a THIN SPACE (\u{2009}) read as too wide. HAIR
                -- SPACE is the narrowest standard typographic space
                -- (~half of thin space), giving a hairline separation
                -- that preserves the pill's compact silhouette
                -- (issue #69).
                -- "#\u{200A}N": HAIR SPACE between the hash and the
                -- index for readability inside the small bold pill --
                -- full word-space split it visually into two columns,
                -- no space ran them together at smallinfofont(12),
                -- and a THIN SPACE (\u{2009}) read as too wide. HAIR
                -- SPACE is the narrowest standard typographic space
                -- (~half of thin space), giving a hairline separation
                -- that preserves the pill's compact silhouette
                -- (issue #69). Mirrors the page-count pill below.
                text = "#\xe2\x80\x8a" .. tostring(self.book.series_num),
                face = sn_face,
                bold = sn_bold,
                fgcolor = colors.badge_fg,
            },
        }
        local badge_w       = badge:getSize().w
        local cover_right_x = card_w
        local badge_x       = math.max(0, math.min(self.width - badge_w,
                                  cover_right_x - math.floor(badge_w / 2)))
        badge.overlap_offset = { badge_x, -SHADOW_OFFSET }
        children[#children + 1] = badge
    end

    -- Favourites star (top-left): same halo'd-glyph treatment as the
    -- bookmark-check on the bottom-left, but mirrored to the top edge so
    -- the two indicators (in-progress / finished bookmark below, favourite
    -- star above) don't fight for the same corner. Sized at _glyphSize
    -- to match the bookmark glyph exactly, so a book that's both a
    -- favourite AND in-progress reads as a balanced pair of corner marks
    -- rather than mismatched chrome.
    --
    -- Membership check goes straight to ReadCollection.coll.favorites
    -- because book.in_favorites is only set by Repo.getFavorites -- on
    -- every other fetch path the field is nil and a per-book check is
    -- needed. The table lookup is O(1) (filepath key), so the cost is
    -- negligible per shelf row.
    local fp = self.book and self.book.filepath
    -- `suppress_favorite_badge` lets the hero card opt out — the hero's
    -- size + dedicated ★ button in the long-press menu make the corner
    -- badge feel redundant there.
    if (not self.is_bulk_selected)
            and (not self.suppress_favorite_badge)
            and fp
            and BookshelfSettings.nilOrTrue("show_fav_badge") then
        local rc_ok, rc = pcall(require, "readcollection")
        local in_fav = rc_ok and rc and rc.coll
                       and rc.coll.favorites
                       and rc.coll.favorites[fp] ~= nil
        if in_fav then
            -- 70% of bookmark size: the star glyph is intrinsically wider
            -- than the bookmark at the same point size, so the star reads
            -- as bigger when nominal sizes match. 70% brings the optical
            -- weight roughly in line. base_h is the unscaled footprint
            -- (for the inward-growth anchor); glyph_h applies the user's
            -- Cover badge size (issue #92).
            local base_h  = math.floor(_glyphSize(card_w) * 0.70)
            local glyph_h = _badgeSize(base_h)
            local glyph_w = self:_glyphWidth(glyph_h)
            if glyph_w <= card_w * 0.4 then
                local colors  = CoverProgress.resolvedColors()
                -- Heart (default) or star, each with its own tunable colour;
                -- switching the icon also switches the colour that's read.
                local fav_icon  = CoverProgress.favoriteIcon()
                local fav_glyph = fav_icon == "star"
                    and CoverProgress.FAV_GLYPH_STAR or CoverProgress.FAV_GLYPH_HEART
                local fav_color = fav_icon == "star"
                    and colors.favorite_star or colors.favorite_heart
                local halo_w   = 1
                -- Shadow extent must exceed halo_w to peek out from
                -- behind the outline. ~6% of glyph height keeps it
                -- proportional across DPIs while always landing 1-2 px
                -- beyond the halo.
                local shadow_d = math.max(halo_w + 2,
                                          math.floor(glyph_h * 0.10))
                -- Measure the TRUE rendered height (memoized probe;
                -- Font:getFace at size N renders at ~N*1.3-1.4 once
                -- ascent / descent / line-height padding are accounted for;
                -- the OverlapGroup's synthetic dimen under-reports that).
                local widget_h = CoverProgress.glyphRenderedH(
                    fav_glyph, glyph_h, "symbols")
                local outlined = CoverProgress.buildHaloShadowedGlyphWidget(
                    fav_glyph,
                    glyph_h,
                    halo_w,
                    shadow_d, shadow_d,  -- down-right
                    colors.border,          -- halo (shared "Border color")
                    fav_color,              -- centre fill (per-icon, user-tunable)
                    colors.shadow,          -- shadow (always dark on screen)
                    "symbols")
                -- 35% of the glyph hangs above the cover; 65% sits on the
                -- artwork. More overhang than the previous 25% so the star
                -- clearly nestles into the top edge rather than sitting on
                -- it, but still lighter than the bookmark's 50% dangle.
                -- Pin the above-cover overhang to the UNSCALED footprint so
                -- a larger Cover badge size grows the glyph DOWN into the
                -- artwork rather than further above the top edge (issue #92).
                local top_lift = 0.35
                local base_widget_h = _baseGlyphRenderedH(
                    fav_glyph, base_h, glyph_h, widget_h, "symbols")
                local y_offset = -math.floor(base_widget_h * top_lift + 0.5) - halo_w
                -- Both star and bookmark anchor on _glyphLeftInset(), but
                -- the star is 70% of the bookmark's nominal height so its
                -- centroid falls noticeably to the left of the bookmark's.
                -- Shift right by half the size difference (at the current
                -- scale, so the columns stay aligned as both grow) so the
                -- two glyphs read as visually aligned in the same column.
                local center_shift =
                    math.floor((_badgeSize(_glyphSize(card_w)) - glyph_h) / 2)
                local x_offset = _glyphLeftInset() - halo_w + center_shift
                outlined.overlap_offset = { x_offset, y_offset }
                children[#children + 1] = outlined
            end
        end
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
    local fp = self.book and self.book.filepath
    -- Use the external (Hardcover) cover whenever it's set: enrichBook only
    -- sets cover_image_path when it should be shown -- either the book has no
    -- embedded cover, or "Use Hardcover image" forces the override. The old
    -- `not has_cover` gate here ignored the override for books that DO have an
    -- embedded cover (so it only updated after a heavy deleteBookInfo). This
    -- matches the external_cover check in init().
    local external_cover = self.book and self.book.cover_image_path

    if external_cover then
        local ok_img, ImageSource = pcall(require, "lib/bookshelf_image_source")
        local external_bb = ok_img and ImageSource.loadImage(external_cover, img_w, img_h) or nil
        if external_bb then
            return self:_wrapCoverInCard(
                ImageWidget:new{
                    image            = external_bb,
                    image_disposable = false,
                    scale_factor     = 1,
                },
                card_w, card_h, border)
        end
    end

    -- Cache-first. ScaledCoverCache is keyed by filepath only (one bb
    -- per book at canonical/max-seen dims). On hit, if the cached bb
    -- is at least as large as our slot in BOTH axes, we can paint from
    -- cache directly and let ImageWidget downscale at paint time
    -- (MuPDF, Kindle-safe in this direction). A cached bb smaller than
    -- our slot would require upscale via ImageWidget (Kindle-unsafe);
    -- fall through to the source-bb path which uses bb:scale (Lua
    -- nearest-neighbour, corruption-free in both directions) and the
    -- result will replace the cache entry per the put policy.
    if fp then
        local cached = ScaledCoverCache:get(fp)
        if cached
                and cached:getWidth()  >= img_w
                and cached:getHeight() >= img_h then
            -- Source bb isn't needed; release if we owned it.
            if bb and ((self.cover_bb == nil) or self.cover_bb_disposable) then
                bb:free()
            end
            local img_args = {
                image            = cached,
                image_disposable = false,    -- cache owns lifetime
                width            = img_w,
                height           = img_h,
            }
            if not self.cover_fill then
                img_args.scale_factor = 0   -- aspect-preserving downscale
            end
            return self:_wrapCoverInCard(
                ImageWidget:new(img_args), card_w, card_h, border)
        end
    end

    -- No usable cached bb. We need a source bb to scale or paint at
    -- native size. Lazy path: caller may have skipped buildBookMeta's
    -- cover decode (want_cover=false) because the upstream check saw
    -- a cache hit; recover by asking Repo for the bb synchronously.
    -- We own the returned bb; mark img_disposable accordingly.
    local img_disposable = (self.cover_bb == nil) or self.cover_bb_disposable
    if not bb then
        bb = fp and _getRepo().getCoverBB(fp)
        if not bb then
            -- BIM has no usable cover row. Fall back to the no-cover
            -- render so the slot doesn't crash on bb:getWidth() below.
            return self:_renderFallback()
        end
        img_disposable = true
    end

    -- ImageWidget's internal MuPDF scaler corrupts on UPSCALE on Kindle
    -- (horizontal stripe static); bb:scale is the Lua-side nearest-
    -- neighbour path in ffi/blitbuffer.lua which sidesteps MuPDF
    -- entirely and is corruption-free in BOTH directions. For
    -- cover_fill=true (the standard shelf/hero path) we scale to exactly
    -- (img_w, img_h) and cache the result keyed by filepath; subsequent
    -- consumers at the same OR smaller dims will hit cache, larger
    -- consumers will re-scale and replace per the prefer-larger put
    -- policy.
    local cover_inner
    if self.cover_fill then
        local scaled_bb = _coverFillBB(bb, img_w, img_h)
        if img_disposable then bb:free() end
        if self.skip_cover_cache then
            -- Hero path: large render (~5x a shelf cover), shown one at a
            -- time, and OFF the pagination hot path (the hero isn't rebuilt
            -- by _swapShelvesInPlace). Caching it would pin oversized entries
            -- that crowd out shelf covers and inflate RAM on colour panels.
            -- Instead the freshly-scaled bb is owned by this ImageWidget and
            -- freed at widget teardown (ImageWidget:free, not per-paint), so
            -- it survives in-place hero repaints; the next _buildHero
            -- re-fetches a fresh source bb, so there's no shared-bb reuse.
            cover_inner = ImageWidget:new{
                image            = scaled_bb,
                image_disposable = true,
                scale_factor     = 1,
            }
        elseif fp then
            -- put() returns the bb now serving as the cache entry: our
            -- new scaled_bb if it was inserted/upgraded, or the
            -- existing entry if it was at least as large. In the
            -- "existing kept" case scaled_bb is unused; mark it
            -- disposable on the ImageWidget below ONLY when we use it
            -- (we never do — we always use the return value).
            local effective = ScaledCoverCache:put(fp, scaled_bb)
            local img_args = {
                image            = effective,
                image_disposable = false,  -- cache owns lifetime
                width            = img_w,
                height           = img_h,
            }
            -- Effective bb might be larger than (img_w, img_h) if put
            -- kept an existing canonical-sized entry; ImageWidget
            -- downscales via MuPDF (safe direction). Effective bb at
            -- exactly (img_w, img_h) renders 1:1, no scaling.
            cover_inner = ImageWidget:new(img_args)
            -- If put kept existing and discarded our scaled_bb, the
            -- local scaled_bb has no cache reference and no widget
            -- reference. LuaJIT's FFI finalizer reclaims it after the
            -- local goes out of scope. Don't free explicitly — the
            -- finalizer handles it once truly unreachable, avoiding
            -- the use-after-free risk that explicit frees historically
            -- caused (the bb might transiently be inspected by
            -- consumers we don't track).
        else
            -- No filepath to key on (rare). Hand ownership to the
            -- ImageWidget so the bb is freed at widget teardown.
            cover_inner = ImageWidget:new{
                image            = scaled_bb,
                image_disposable = true,
                scale_factor     = 1,
            }
        end
    else
        -- Aspect-preserving paths skip the cache: the rendered output
        -- depends on per-slot dimensions in a way the cache contract
        -- (single canonical entry per book) doesn't capture cleanly.
        -- Not used by any current bookshelf code path (cover_fill
        -- defaults true; only direct SpineWidget caller overrides flip
        -- it).
        local bb_w = bb:getWidth()
        local bb_h = bb:getHeight()
        local would_upscale = bb_w < img_w or bb_h < img_h
        if would_upscale then
            cover_inner = CenterContainer:new{
                dimen = Geom:new{ w = img_w, h = img_h },
                ImageWidget:new{
                    image            = bb,
                    image_disposable = img_disposable,
                    scale_factor     = 1,
                },
            }
        else
            cover_inner = ImageWidget:new{
                image            = bb,
                image_disposable = img_disposable,
                width            = img_w,
                height           = img_h,
                scale_factor     = 0,
            }
        end
    end

    return self:_wrapCoverInCard(cover_inner, card_w, card_h, border)
end

-- Wrap a cover_inner widget (ImageWidget or CenterContainer of one) in
-- the RoundedCornerCard shell with selection / shadow chrome. Extracted
-- from _renderCover so the cache-hit and bb-rendering paths share the
-- same trailing wrap.
function SpineWidget:_wrapCoverInCard(cover_inner, card_w, card_h, border)
    -- Faded on-hold books are fully recessed: faded toward the page
    -- background, no border, and no drop shadow (the shadow is skipped in
    -- the same condition in _renderShadowedCard). Gated on on_hold_fade,
    -- not the pause badge -- on_hold_display = "pause" keeps normal cover
    -- chrome (issue #121). show_progress is set only on grid covers (the
    -- hero / folder / series stacks reuse SpineWidget but clear it), so this
    -- is grid-only by construction. Excluded while selected (current-book
    -- ring) or bulk-selected, which own their cover chrome.
    local on_hold_fade = self.show_progress
        and not self.is_selected and not self.is_bulk_selected
        and CoverProgress.decide(self.book).on_hold_fade or false
    local cover_args = {
        inner       = cover_inner,
        width       = card_w,
        height      = card_h,
        radius      = CARD_RADIUS,
        border_size = border,
    }
    if on_hold_fade then
        -- Paint the border in PAGE WHITE rather than removing it. Two
        -- subtleties make this the right move (issue #121 follow-ups):
        --   * Geometry: the cover image is sized and inset for a bordered
        --     card, so zeroing border_size painted it border-width up-left
        --     and 2x border smaller than its shelf neighbours. Keeping
        --     border_size keeps the image's exact position and size.
        --   * Corner rounding: the corner MASK only clears pixels outside
        --     the card-radius arc, which (with the image inset by the
        --     border) never reaches the image -- on normal covers it's the
        --     painted hairline's arc band that actually clips the image
        --     corner round. A white band does that same clipping
        --     invisibly. Night mode inverts the framebuffer, so the white
        --     band reads as the black page there -- mode-correct, same as
        --     the lightenRect fade above it.
        cover_args.border_color = Blitbuffer.COLOR_WHITE
        cover_args.fade_by = ON_HOLD_FADE
        -- No shadow_color: with the drop shadow removed the corner mask must
        -- restore plain page bg, not shadow grey.
    else
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
        cover_args.fade_by = FADED_FINISHED_AMOUNT
    end
    end
    if self.is_selected then
        -- The corner mask normally paints bg-white pixels in the
        -- (0..R, 0..R) corner squares for points OUTSIDE the radius-R
        -- arc, to fake rounded corners on top of a rectangular image.
        -- With the BorderOverlay backdrop those bg-white pixels poke
        -- out into the black ring as four little white teeth. Invert
        -- the mask color to match the backdrop so the corner squares
        -- merge seamlessly with the surrounding black.
        cover_args.bg_color = Blitbuffer.COLOR_BLACK
    else
        -- The card sits at (0, 0) in the OverlapGroup; the shadow paints
        -- at (SHADOW_OFFSET, SHADOW_OFFSET) with the same w/h and same
        -- radius. Pass these so the corner mask can restore shadow grey
        -- where the shadow would otherwise show through.
        cover_args.shadow_color    = _shadowGray()
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

    local card_w, card_h = self:_cardDimensions()
    local border = CARD_BORDER
    local colors = CoverProgress.resolvedColors()
    local outer_bg, inner_bg = _fallbackBgs()

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
    local title_face, title_bold = BFont:getFace("infofont", 13, { bold = true })
    local title = TextBoxWidget:new{
        text                          = title_text,
        face                          = title_face,
        bold                          = title_bold,
        fgcolor                       = Blitbuffer.COLOR_BLACK,
        -- TextBoxWidget fills its whole bitmap with bgcolor (default white).
        -- Left at white that fill inverts to a solid black box in night mode,
        -- which doesn't match the dark-grey card. Match the inner card fill
        -- so the text sits flush on the card surface in both modes.
        bgcolor                       = inner_bg,
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
    local diamond_face, diamond_bold = BFont:getFace("infofont", 12)
    local rule_centerer = CenterContainer:new{
        dimen = Geom:new{ w = content_w, h = math.max(Screen:scaleBySize(20), card_h * 0.10) },
        HorizontalGroup:new{
            align = "center",
            ruleLine(),
            rule_gap,
            TextWidget:new{
                text    = "\xE2\x9D\x96",  -- ❖ U+2756
                face    = diamond_face,
                bold    = diamond_bold,
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
        local author_face, author_bold = BFont:getFace("infofont", 10)
        local author = TextBoxWidget:new{
            text                          = author_text,
            face                          = author_face,
            bold                          = author_bold,
            fgcolor                       = Blitbuffer.COLOR_BLACK,
            bgcolor                       = inner_bg,
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
    -- Border color follows the user's "Border color" setting so the
    -- placeholder cover ages with the rest of the chrome.
    local inner_frame = FrameContainer:new{
        bordersize = Size.border.thin,
        color      = colors.border,
        background = inner_bg,
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
        color      = colors.border,
        radius     = CARD_RADIUS,
        padding    = 0,
        background = outer_bg,
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
