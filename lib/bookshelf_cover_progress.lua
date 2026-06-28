-- bookshelf_cover_progress.lua
-- Pure decision logic for per-book progress indicators (bar + glyphs).
--
-- decide(book) maps a book's KOReader sidecar status + percent to a render
-- intent: whether to draw a top-edge progress bar, what fill ratio, and
-- which (if any) status glyph to overlay. Master toggle from
-- G_reader_settings["bookshelf_progress_enabled"].
--
-- Widget builders (buildBarWidget, buildGlyphWidget) live in this file
-- alongside the decision logic so SpineWidget has a single require to
-- pull in everything it needs.

local BookshelfSettings = require("lib/bookshelf_settings_store")
local Color            = require("lib/bookshelf_color")

local Blitbuffer
local Device
local Font
local FrameContainer
local Geom
local OverlapGroup
local TextWidget
local Widget
local ffi
local ColorRGB32_t
local Screen
local ProgressBarWidget

local function _ensureWidgetDeps()
    if Screen then return end
    Blitbuffer     = require("ffi/blitbuffer")
    Device         = require("device")
    Font           = require("ui/font")
    FrameContainer = require("ui/widget/container/framecontainer")
    Geom           = require("ui/geometry")
    OverlapGroup   = require("ui/widget/overlapgroup")
    TextWidget     = require("ui/widget/textwidget")
    Widget         = require("ui/widget/widget")
    local ok_ffi, ffi_mod = pcall(require, "ffi")
    ffi = ok_ffi and ffi_mod or {
        typeof = function(name) return name end,
        istype = function(kind, value)
            return kind == "ColorRGB32"
                and type(value) == "table"
                and value._kind == "ColorRGB32"
        end,
    }
    ColorRGB32_t = ffi.typeof("ColorRGB32")
    Screen = Device.screen
end

local M = {}

-- Glyph code points (KOReader's bundled nerd font).
M.GLYPH_BOOKMARK       = "\u{e7bf}"  -- in-progress
M.GLYPH_BOOKMARK_CHECK = "\u{e7c0}"  -- finished
M.GLYPH_PAUSE_CIRCLE   = "\u{f28b}"  -- on-hold (nf-fa-pause_circle, symbols face)

-- Favourite icon (nerdfont "symbols" face). Heart is the default so the
-- favourite badge reads distinctly from the yellow rating/favourite star.
M.FAV_GLYPH_STAR  = "\u{f005}"  -- nf-fa-star
M.FAV_GLYPH_HEART = "\u{f004}"  -- nf-fa-heart

-- favoriteIcon(): "heart" (default) or "star", from the fav_icon setting.
function M.favoriteIcon()
    return BookshelfSettings.read("fav_icon") == "star" and "star" or "heart"
end

-- Cover-badge font scale. Single source of truth for the page-count
-- pill, series-number pill, ×N count badge, and completed-tickbox
-- glyph. Read inline (not memoised) so settings menu nudge dialogs see
-- the new value on the next paint without a require cycle.
function M.badgeSize(base)
    local scale = BookshelfSettings.read("cover_badge_font_scale") or 100
    return math.floor(base * scale / 100 + 0.5)
end

-- Read a per-element toggle. All three default ON (true) when unset.
-- Setting keys (within the bookshelf settings store):
--   progress_bar_enabled       -- the rounded pill at cover bottom
--   progress_bookmark_enabled  -- the in-progress glyph
--   progress_badge_enabled     -- the complete (badged) glyph
local function _toggle(key)
    local v = BookshelfSettings.read(key)
    if v == nil then return true end
    return v == true
end

-- Lazy reference to bookshelf_book_repository for the readProgress fallback
-- below. Required so chip paths that use the light book constructor
-- (buildBookMeta -> no DocSettings read) still get status/pct without the
-- expensive eager attachment.
local _Repo

-- Pure decision with a lazy filepath-based fallback for status/pct.
-- Each output element is independently gated by its own toggle.
-- @param book table|nil with keys `status` (string|nil), `book_pct` (number|nil)
--             and optionally `filepath` (string|nil)
-- @return table { bar=bool, bar_pct=number, glyph=..., page_count=bool }
--   page_count is independent of status -- the page total is meaningful
--   for any book the user might browse, not just one that's been opened.
function M.decide(book)
    -- progress_page_count_enabled defaults OFF, distinct from the other
    -- three indicators which default ON via _toggle. _toggle returns true
    -- on nil — wrong default here — so read the raw value and only treat
    -- an explicit `true` as on.
    local want_page_count = BookshelfSettings.read("progress_page_count_enabled") == true
    local none = { bar = false, bar_pct = 0, glyph = nil, page_count = want_page_count }
    if not book then return none end
    local status = book.status
    local pct    = book.book_pct
    -- Most shelf chips (getRecent, getLatest, getAll, ...) use the
    -- light book constructor and don't open DocSettings -- book.status
    -- arrives nil. Same goes for book.page_count on EPUBs: BIM only
    -- knows page counts for pre-paginated formats (PDF / CBR / CBZ);
    -- for reflowed EPUBs the count lives in the sdr sidecar
    -- (pagemap_doc_pages or stats.pages). Repo.readProgress reads
    -- both summary + page count from a single cached DocSettings open,
    -- so the per-cover cost stays bounded by the TTL.
    local need_status_fallback = (status == nil and book.filepath)
    local need_pages_fallback  =
        (want_page_count and not book.page_count and book.filepath)
    local prefer_doc_pages = false
    if want_page_count and book.page_count and book.filepath then
        if not _Repo then _Repo = require("lib/bookshelf_book_repository") end
        prefer_doc_pages = _Repo.prefersDocSettingsPageCount
            and _Repo.prefersDocSettingsPageCount(book)
    end
    if need_status_fallback or need_pages_fallback or prefer_doc_pages then
        if not _Repo then _Repo = require("lib/bookshelf_book_repository") end
        local p, s, _r, pages = _Repo.readProgress(book.filepath)
        if need_status_fallback then
            pct    = pct or p
            status = s
        end
        -- Mutate book.page_count so the SpineWidget renderer (which
        -- reads self.book.page_count directly) picks up the sidecar value
        -- without a second lookup in the render path.
        if (need_pages_fallback or prefer_doc_pages) and pages then
            book.page_count = pages
        end
    end
    local want_bar      = _toggle("progress_bar_enabled")
    local want_bookmark = _toggle("progress_bookmark_enabled")
    -- Completed-badge style is tri-state: "none" / "bookmark" (the pre-v2.1
    -- outlined dangling check) / "tickbox" (the v2.1 square pill, default
    -- in this fork). New key wins when set; otherwise fall back to the
    -- legacy boolean progress_badge_enabled (true / nil -> tickbox,
    -- false -> none) so users who had the badge off stay off, and existing
    -- fork installs keep the same finished-cover look after merging upstream.
    local badge_style = BookshelfSettings.read("progress_badge_style")
    if badge_style == nil then
        local legacy = BookshelfSettings.read("progress_badge_enabled")
        if legacy == false then
            badge_style = "none"
        else
            badge_style = "tickbox"
        end
    end
    -- Status vocabulary is normalised upstream (Repo.readProgress /
    -- Repo.buildBook). KOReader stores 'complete' / 'abandoned' in the
    -- sidecar; bookshelf treats those as 'finished' / 'on_hold' across
    -- the filter UI, sort engine, and cover indicators. Either name
    -- accepted here for back-compat with any cached records that
    -- predate the normalisation.
    if status == "abandoned" or status == "on_hold" then
        -- On-hold gets its own treatment, split into two independently
        -- selectable cues (issue #121 -- one reporter wants fade-only for
        -- DNF books, another wants badge-only because they do intend to
        -- return to the book): the centred pause-circle badge and the
        -- faded/recessed cover (both rendered by SpineWidget). Four-state
        -- on_hold_display: "none" / "pause" / "fade" / "both" (default).
        -- Legacy boolean on_hold_badge_enabled is honoured as a fallback
        -- when the new key is unset -- it used to gate BOTH cues, so
        -- false -> "none", true / nil -> "both". The settings menu runs
        -- the same migration so the rendering side and the menu agree.
        -- Either cue REPLACES the bottom-left in-progress bookmark so the
        -- cover carries one clear "on hold" signal; with both off we fall
        -- back to the old reading-style bookmark. The top-edge bar + page
        -- count keep their own toggles.
        local mode = BookshelfSettings.read("on_hold_display")
        if mode ~= "none" and mode ~= "pause" and mode ~= "fade" and mode ~= "both" then
            local legacy = BookshelfSettings.read("on_hold_badge_enabled")
            mode = (legacy == false) and "none" or "both"
        end
        local badge = mode == "pause" or mode == "both"
        local fade  = mode == "fade"  or mode == "both"
        return {
            bar          = want_bar and (pct ~= nil),
            bar_pct      = pct or 0,
            glyph        = mode == "none" and want_bookmark and "in_progress" or nil,
            on_hold      = badge or nil,
            on_hold_fade = fade or nil,
            page_count   = want_page_count,
        }
    elseif status == "reading" then
        return {
            bar        = want_bar and (pct ~= nil),
            bar_pct    = pct or 0,
            glyph      = want_bookmark and "in_progress" or nil,
            page_count = want_page_count,
        }
    elseif status == "complete" or status == "finished" then
        local glyph_kind = nil
        if     badge_style == "bookmark" then glyph_kind = "complete_bookmark"
        elseif badge_style == "tickbox"  then glyph_kind = "complete_tickbox"
        end
        return {
            bar        = false,
            bar_pct    = 0,
            glyph      = glyph_kind,
            page_count = want_page_count,
        }
    end
    -- status = "new" or nil: bar / glyph stay off but page count can
    -- still show -- knowing the page count of an unread book is useful.
    return none
end

-- ---------------------------------------------------------------------------
-- Widget: ProgressBarWidget
-- ---------------------------------------------------------------------------

-- Blitbuffer's plain paintRoundedRect / paintBorder flatten their color
-- argument to luminance via getColor8() before painting, so a ColorRGB32
-- like red goes down as its grey luminance on a color buffer. KOReader
-- exposes parallel *RGB32 variants that preserve true color; dispatch by
-- type so the call sites stay shape-agnostic. (Same pattern bookends uses
-- in bookends_overlay_widget.lua.)
local function _paintRoundedRect(bb, x, y, w, h, c, r)
    if not c then return end
    if ffi.istype(ColorRGB32_t, c) then
        bb:paintRoundedRectRGB32(x, y, w, h, c, r)
    else
        bb:paintRoundedRect(x, y, w, h, c, r)
    end
end

local function _paintBorder(bb, x, y, w, h, bw, c, r)
    if not c then return end
    if ffi.istype(ColorRGB32_t, c) then
        bb:paintBorderRGB32(x, y, w, h, bw, c, r)
    else
        bb:paintBorder(x, y, w, h, bw, c, r)
    end
end

local function _getProgressBarWidget()
    if ProgressBarWidget then return ProgressBarWidget end
    _ensureWidgetDeps()
    ProgressBarWidget = Widget:extend{
        width  = 0,
        height = 0,
        pct    = 0,        -- 0..1
        fill   = nil,      -- Blitbuffer color
        track  = nil,      -- Blitbuffer color
        border = nil,      -- Blitbuffer color (outline; defaults to black)
    }

    function ProgressBarWidget:init()
        self.dimen = Geom:new{ w = self.width, h = self.height }
    end

    function ProgressBarWidget:paintTo(bb, x, y)
        -- Bookends-style rounded pill: track background + dark border outline,
        -- with an inner rounded fill inset by border + small padding. Inner
        -- fill is a smaller pill whose right edge moves with progress.
        local w, h = self.width, self.height
        if w < 1 or h < 1 then return end
        local border = math.max(1, Screen:scaleBySize(1))
        local radius = math.floor(h / 2)
        -- 1. Track background (rounded rect, full bar)
        _paintRoundedRect(bb, x, y, w, h, self.track, radius)
        -- 2. Border outlining the track (follows the shared Border color
        --    setting; falls back to black for callers that don't pass one)
        _paintBorder(bb, x, y, w, h, border, self.border or Blitbuffer.COLOR_BLACK, radius)
        -- 3. Inner fill (rounded), inset by border + padding, width scales with pct
        local clamped = self.pct
        if clamped < 0 then clamped = 0 end
        if clamped > 1 then clamped = 1 end
        if clamped <= 0 or not self.fill then return end
        local padding     = math.max(1, math.floor(h * 0.15))
        local inset       = border + padding
        local inner_max_w = w - 2 * inset
        local inner_h     = h - 2 * inset
        if inner_max_w < 1 or inner_h < 1 then return end
        local inner_w = math.floor(inner_max_w * clamped + 0.5)
        if inner_w < 1 then return end
        local inner_r = math.max(0, radius - inset)
        _paintRoundedRect(bb, x + inset, y + inset, inner_w, inner_h, self.fill, inner_r)
    end

    return ProgressBarWidget
end

-- Build a ProgressBarWidget. `fill`, `track` and `border` are Blitbuffer
-- color objects (Color8 or ColorRGB32); callers resolve them via
-- bookshelf_color.parseColorValue before calling here. `border` is
-- optional and defaults to black inside paintTo when nil.
function M.buildBarWidget(width, height, pct, fill, track, border)
    return _getProgressBarWidget():new{
        width  = width,
        height = height,
        pct    = pct,
        fill   = fill,
        track  = track,
        border = border,
    }
end

-- ---------------------------------------------------------------------------
-- Widget: PauseBadgeWidget (on-hold indicator)
-- ---------------------------------------------------------------------------

-- A drawn "pause button": a filled circle matching the page-count badge
-- (badge_bg fill + badge_fg thin border) with two SOLID bars in badge_fg.
-- Drawn rather than using the nf pause-circle glyph because the glyph (a)
-- sat off-centre inside its font cell, so CenterContainer couldn't centre
-- it; (b) had its bars as negative space, so the cover showed through them;
-- (c) didn't share the other badges' colours. The widget's dimen is exactly
-- the circle's bounding box, so a CenterContainer centres it precisely.
_ensureWidgetDeps()
local PauseBadgeWidget = Widget:extend{
    diameter = 0,
    fill     = nil,    -- circle fill   (badge_bg)
    fg       = nil,    -- border + bars (badge_fg)
    border   = nil,    -- border width in px (optional)
}

function PauseBadgeWidget:init()
    self.dimen = Geom:new{ w = self.diameter, h = self.diameter }
end

function PauseBadgeWidget:paintTo(bb, x, y)
    local d = self.diameter
    if d < 2 then return end
    local r  = math.floor(d / 2)
    local bw = self.border or math.max(1, Screen:scaleBySize(1))
    -- 1. Filled circle (square + radius = half-side) and its border.
    _paintRoundedRect(bb, x, y, d, d, self.fill, r)
    _paintBorder(bb, x, y, d, d, bw, self.fg or Blitbuffer.COLOR_BLACK, r)
    -- 2. Two solid, centred, symmetric pause bars in the foreground colour.
    local bar_h  = math.floor(d * 0.40)
    local bar_w  = math.max(2, math.floor(d * 0.13))
    local gap    = math.max(2, math.floor(d * 0.12))
    local bar_r  = math.max(1, math.floor(bar_w * 0.35))
    local bars_w = 2 * bar_w + gap
    local bx     = x + math.floor((d - bars_w) / 2)
    local by     = y + math.floor((d - bar_h) / 2)
    local fg     = self.fg or Blitbuffer.COLOR_BLACK
    _paintRoundedRect(bb, bx,               by, bar_w, bar_h, fg, bar_r)
    _paintRoundedRect(bb, bx + bar_w + gap, by, bar_w, bar_h, fg, bar_r)
end

-- Build a PauseBadgeWidget. `fill` and `fg` are Blitbuffer colors (resolve
-- via resolvedColors().badge_bg / badge_fg to match the page-count badge);
-- `border` is the border width in px (optional, defaults to ~1px scaled).
function M.buildPauseBadgeWidget(diameter, fill, fg, border)
    return PauseBadgeWidget:new{
        diameter = diameter,
        fill     = fill,
        fg       = fg,
        border   = border,
    }
end

-- ---------------------------------------------------------------------------
-- Widget: GlyphWidget (status indicator)
-- ---------------------------------------------------------------------------

-- Build a single-glyph TextWidget for the in-progress / finished badges.
-- @param glyph_char  one of GLYPH_BOOKMARK / GLYPH_BOOKMARK_CHECK
-- @param size        target glyph height in pixels (already scaled)
-- @param color      Blitbuffer color (resolved via bookshelf_color)
-- @return TextWidget
function M.buildGlyphWidget(glyph_char, size, color, face_name)
    _ensureWidgetDeps()
    return TextWidget:new{
        text    = glyph_char,
        -- Default "symbols" face for bookshelf's nerd-font glyphs
        -- (GLYPH_BOOKMARK / GLYPH_BOOKMARK_CHECK). Callers rendering a
        -- standard Unicode codepoint (e.g. the favourites star U+2605)
        -- pass a regular text face like "infofont" since "symbols" is
        -- a narrow subset that may not cover the standard ranges.
        face    = Font:getFace(face_name or "symbols", size),
        fgcolor = color,
    }
end

-- Memoized rendered height of a bare glyph. The status-badge paths each
-- built a throwaway TextWidget PER SPINE PER PAINT just to measure a
-- height that's constant for a given (glyph, size, face) -- a full page
-- repaint did up to 16 spines x ~3 probes of shaping work for values
-- that never change. Font metrics are fixed at runtime, and the user's
-- badge-scale setting feeds into `size`, so the key self-invalidates
-- when the scale changes. Colour doesn't affect metrics, so the probe
-- always measures in BLACK.
local _glyph_h_memo = {}
function M.glyphRenderedH(glyph_char, size, face_name)
    local key = (face_name or "symbols") .. "\1" .. size .. "\1" .. glyph_char
    local h = _glyph_h_memo[key]
    if not h then
        local probe = M.buildGlyphWidget(glyph_char, size,
            Blitbuffer.COLOR_BLACK, face_name)
        h = probe:getSize().h
        probe:free()
        _glyph_h_memo[key] = h
    end
    return h
end

-- Build a halo'd glyph. The glyph is painted in `halo_color` at every
-- cell of a (2*halo_w + 1) x (2*halo_w + 1) offset grid (skipping the
-- centre), then in `centre_color` at the centre. The offset paints
-- create the outline; the centre paint fills the strokes. Used for the
-- 'completed' indicator so the bookmark-check stays legible against any
-- cover artwork without the heavy 'sticker' look of the old badge.
-- `halo_color` / `centre_color` are Blitbuffer color objects; both
-- default to the legacy BLACK halo / WHITE centre pair so callers that
-- don't pass them keep their existing render.
function M.buildOutlinedGlyphWidget(glyph_char, size, halo_w, halo_color, centre_color, face_name)
    _ensureWidgetDeps()
    halo_w = halo_w or 1
    halo_color   = halo_color   or Blitbuffer.COLOR_BLACK
    centre_color = centre_color or Blitbuffer.COLOR_WHITE
    local widget_w = size + 2 * halo_w
    local widget_h = size + 2 * halo_w
    local group = OverlapGroup:new{
        dimen = Geom:new{ w = widget_w, h = widget_h },
    }
    -- Halo offsets in all 8 directions around the centre.
    for dy = -halo_w, halo_w do
        for dx = -halo_w, halo_w do
            if dx ~= 0 or dy ~= 0 then
                group[#group + 1] = FrameContainer:new{
                    bordersize   = 0,
                    padding      = 0,
                    padding_top  = halo_w + dy,
                    padding_left = halo_w + dx,
                    M.buildGlyphWidget(glyph_char, size, halo_color, face_name),
                }
            end
        end
    end
    -- Centre glyph.
    group[#group + 1] = FrameContainer:new{
        bordersize   = 0,
        padding      = 0,
        padding_top  = halo_w,
        padding_left = halo_w,
        M.buildGlyphWidget(glyph_char, size, centre_color, face_name),
    }
    return group
end

-- Like buildOutlinedGlyphWidget but with an additional directional drop
-- shadow underneath the halo'd glyph. Paint order is: shadow → halo →
-- centre fill. The shadow lands at offset (shadow_x, shadow_y) relative
-- to the centre glyph; for it to peek out from behind the halo, pick
-- shadow_x / shadow_y > halo_w (otherwise the halo covers it entirely).
function M.buildHaloShadowedGlyphWidget(glyph_char, size, halo_w,
                                        shadow_x, shadow_y,
                                        halo_color, centre_color, shadow_color,
                                        face_name)
    _ensureWidgetDeps()
    halo_w       = halo_w or 1
    shadow_x     = shadow_x or 2
    shadow_y     = shadow_y or 2
    halo_color   = halo_color   or Blitbuffer.COLOR_BLACK
    centre_color = centre_color or Blitbuffer.COLOR_WHITE
    shadow_color = shadow_color or Blitbuffer.COLOR_BLACK
    -- Bounding box: union of the halo's extent (size + 2*halo_w from
    -- origin) and the shadow's extent (size + halo_w + max(0, shadow_x/y)
    -- from origin). Negative shadow offsets are clamped to 0 so the box
    -- doesn't shift the centre off-origin.
    local halo_extent_x = size + 2 * halo_w
    local halo_extent_y = size + 2 * halo_w
    local shadow_extent_x = halo_w + math.max(0, shadow_x) + size
    local shadow_extent_y = halo_w + math.max(0, shadow_y) + size
    local widget_w = math.max(halo_extent_x, shadow_extent_x)
    local widget_h = math.max(halo_extent_y, shadow_extent_y)
    local group = OverlapGroup:new{
        dimen = Geom:new{ w = widget_w, h = widget_h },
    }
    -- Shadow (painted first, sits under everything).
    group[#group + 1] = FrameContainer:new{
        bordersize   = 0,
        padding      = 0,
        padding_top  = halo_w + math.max(0, shadow_y),
        padding_left = halo_w + math.max(0, shadow_x),
        M.buildGlyphWidget(glyph_char, size, shadow_color, face_name),
    }
    -- Halo: 8 offset glyphs in halo_color around the centre.
    for dy = -halo_w, halo_w do
        for dx = -halo_w, halo_w do
            if dx ~= 0 or dy ~= 0 then
                group[#group + 1] = FrameContainer:new{
                    bordersize   = 0,
                    padding      = 0,
                    padding_top  = halo_w + dy,
                    padding_left = halo_w + dx,
                    M.buildGlyphWidget(glyph_char, size, halo_color, face_name),
                }
            end
        end
    end
    -- Centre fill (top layer).
    group[#group + 1] = FrameContainer:new{
        bordersize   = 0,
        padding      = 0,
        padding_top  = halo_w,
        padding_left = halo_w,
        M.buildGlyphWidget(glyph_char, size, centre_color, face_name),
    }
    return group
end

-- ---------------------------------------------------------------------------
-- Resolved-settings accessor
-- ---------------------------------------------------------------------------

local DEFAULT_FILL     = { grey = 0x40 }
-- Track defaults to pure white so the bar stays clearly distinct from
-- the cover's drop shadow (mid-grey) on monochrome devices.
local DEFAULT_TRACK    = { grey = 0xFF }
-- Bookmark (in-progress glyph) keeps the pre-2.2.5 look — same dark-grey
-- value the glyph picked up when it used to read from progress_fill.
local DEFAULT_BOOKMARK = { grey = 0x40 }
-- Badge defaults preserve the existing hard-coded pill look (black text on
-- a white fill, thin black border) and the halo'd completed-bookmark look
-- (black outline around a white check). Mapping:
--   pill  : background = badge_bg, text + border = badge_fg
--   check : halo       = badge_fg, centre        = badge_bg
local DEFAULT_BADGE_FG = { grey = 0x00 }
local DEFAULT_BADGE_BG = { grey = 0xFF }
-- Finished-badge centre defaults to pure white; favourites star defaults
-- to yellow (resolves to luminance on B&W e-ink).
local DEFAULT_COMPLETE_BOOKMARK = { hex = "#FFFFFF" }
local DEFAULT_FAVORITE_STAR     = { hex = "#FFD700" }
-- Heart favourite defaults to light pink, so it reads distinctly from the
-- yellow rating/favourite star. Night default is the channel-wise inverse
-- (#FFB6C1 -> #00493E) so the framebuffer inversion lands back on pink.
local DEFAULT_FAVORITE_HEART    = { hex = "#FFB6C1" }
-- Border color shared by the cover frame outline + pill / page-count
-- badge borders. Defaults to pure black; users can shift to a softer
-- grey for less contrast, or pick a tinted border on color panels.
local DEFAULT_BORDER            = { hex = "#000000" }

-- Night-mode defaults: chosen so the on-screen appearance approximates
-- the day defaults AFTER KOReader's framebuffer inversion. The framework
-- inverts each painted pixel at refresh time (grey N → 0xFF-N, RGB
-- inverts per channel), so a day default of "black border" paints black
-- and displays black, while the corresponding night default paints WHITE
-- and the framework inverts it to display black. Net effect: a user who
-- toggles night mode without setting any night overrides still sees
-- borders / progress / badges that look ~the same as in day mode.
-- Storing the inverted RAW value (not the day value) so the picker's
-- "% black on screen" math stays mode-consistent.
local NIGHT_DEFAULT_FILL              = { grey = 0xBF }  -- 0xFF - 0x40
local NIGHT_DEFAULT_TRACK             = { grey = 0x00 }  -- 0xFF - 0xFF
local NIGHT_DEFAULT_BOOKMARK          = { grey = 0xBF }
local NIGHT_DEFAULT_BADGE_FG          = { grey = 0xFF }  -- 0xFF - 0x00
local NIGHT_DEFAULT_BADGE_BG          = { grey = 0x00 }
local NIGHT_DEFAULT_COMPLETE_BOOKMARK = { hex = "#000000" }
-- Yellow inverted RGB-wise: 0xFF→0x00, 0xD7→0x28, 0x00→0xFF → #0028FF.
-- Re-inverted by the framework lands back on the yellow the user sees
-- in day mode. B&W devices land on the same luminance.
local NIGHT_DEFAULT_FAVORITE_STAR     = { hex = "#0028FF" }
local NIGHT_DEFAULT_FAVORITE_HEART    = { hex = "#00493E" }
-- Night border default = 98% black ON SCREEN (not 100%): a black-cover book
-- on the black night background still shows a faint frame instead of bleeding
-- into the background. 98% black -> displayed grey ~0x05; night inverts the
-- framebuffer, so paint the inverse 0xFA (#FAFAFA) to land there.
local NIGHT_DEFAULT_BORDER            = { hex = "#FAFAFA" }

-- Memoised resolvers. resolvedColors() is called multiple times per
-- cover paint (once per active indicator type per cover), and each call
-- used to do seven BookshelfSettings.reads + five parseColorValue calls
-- + a fresh table allocation. With a 20-cover grid that's ~100+ rebuilds
-- per repaint of an unchanged setting state. Cache keyed on:
--
--   * settings generation (bumped by BookshelfSettings.save / .delete)
--   * Screen:isColorEnabled() (hex resolves differently under color vs
--     greyscale; the parseColorValue hex cache also self-flushes on
--     mode change, but we have to invalidate too or we'd return a
--     ColorRGB32 on a now-greyscale screen)
--
-- Returned tables are SHARED, not freshly allocated — callers must not
-- mutate them. Every current consumer is read-only.
--
-- folder_bg / folder_fg differ from the other fields: they return nil
-- when the setting is unset so the FolderCard render path can fall back
-- to its existing device-aware defaults (manilla on color panels, dark
-- grey on B&W e-ink, see lib/bookshelf_folder_card.lua's CARDBOARD
-- constant). A static hex default here can't represent that split.
local _resolved_cache, _resolved_gen, _resolved_mode, _resolved_night
local _raw_cache, _raw_gen, _raw_night

-- Day / night mode have independent color sets. The suffix is "_night"
-- for the keys that store the night-mode overrides; "" for day. Falling
-- through to the un-suffixed key (the day-mode setting) when a night-
-- mode override is unset gives users a sensible default rather than the
-- baked-in DEFAULT_* values (so a user who only customises day colors
-- gets the same look in night mode by default).
local function _modeSuffix()
    return G_reader_settings:isTrue("night_mode") and "_night" or ""
end

local function _readModeColor(base_key, default_day, default_night)
    local suffix = _modeSuffix()
    if suffix ~= "" then
        -- Night mode: explicit override wins, otherwise fall through to
        -- the dedicated night default. Crucially we do NOT fall back to
        -- the user's day setting — day and night colors are independent
        -- themes, and inheriting a day-side override into night ended up
        -- showing the inverted day appearance instead of the intended
        -- night palette. Users who want matching colors can set the
        -- night override explicitly.
        local night = BookshelfSettings.read(base_key .. suffix)
        if night then return night end
        return default_night or default_day
    end
    return BookshelfSettings.read(base_key) or default_day
end

function M.resolvedColors()
    _ensureWidgetDeps()
    local gen      = BookshelfSettings.generation()
    local is_color = Screen:isColorEnabled()
    local is_night = G_reader_settings:isTrue("night_mode") or false
    if _resolved_cache and _resolved_gen == gen and _resolved_mode == is_color
            and _resolved_night == is_night then
        return _resolved_cache
    end
    local fill_raw         = _readModeColor("progress_fill",  DEFAULT_FILL, NIGHT_DEFAULT_FILL)
    local track_raw        = _readModeColor("progress_track", DEFAULT_TRACK, NIGHT_DEFAULT_TRACK)
    local bookmark_raw     = _readModeColor("bookmark_color", DEFAULT_BOOKMARK, NIGHT_DEFAULT_BOOKMARK)
    local complete_raw     = _readModeColor("complete_bookmark_color",
                                             DEFAULT_COMPLETE_BOOKMARK,
                                             NIGHT_DEFAULT_COMPLETE_BOOKMARK)
    local star_raw         = _readModeColor("favorite_star_color",
                                             DEFAULT_FAVORITE_STAR,
                                             NIGHT_DEFAULT_FAVORITE_STAR)
    local heart_raw        = _readModeColor("favorite_heart_color",
                                             DEFAULT_FAVORITE_HEART,
                                             NIGHT_DEFAULT_FAVORITE_HEART)
    local badge_fg_raw     = _readModeColor("badge_fg", DEFAULT_BADGE_FG, NIGHT_DEFAULT_BADGE_FG)
    local badge_bg_raw     = _readModeColor("badge_bg", DEFAULT_BADGE_BG, NIGHT_DEFAULT_BADGE_BG)
    local border_raw       = _readModeColor("border_color", DEFAULT_BORDER, NIGHT_DEFAULT_BORDER)
    local folder_bg_raw    = _readModeColor("folder_overlay_bg", nil)
    local folder_fg_raw    = _readModeColor("folder_overlay_fg", nil)
    -- Shadow color is hard-coded so it always paints DARK ON SCREEN
    -- regardless of mode. KOReader's night mode inverts the framebuffer
    -- at refresh time, so the shadow color in code is BLACK in day mode
    -- (paints black, displays black) and WHITE in night mode (paints
    -- white, gets inverted, displays black). Without this, the shadow
    -- inherited the user's Border color which inverts in night mode and
    -- ended up appearing light — looking like a second halo rather than
    -- a shadow.
    local shadow_hex = is_night and "#FFFFFF" or "#000000"
    _resolved_cache = {
        fill              = Color.parseColorValue(fill_raw,     is_color),
        track             = Color.parseColorValue(track_raw,    is_color),
        bookmark          = Color.parseColorValue(bookmark_raw, is_color),
        complete_bookmark = Color.parseColorValue(complete_raw, is_color),
        favorite_star     = Color.parseColorValue(star_raw,     is_color),
        favorite_heart    = Color.parseColorValue(heart_raw,    is_color),
        badge_fg          = Color.parseColorValue(badge_fg_raw, is_color),
        badge_bg          = Color.parseColorValue(badge_bg_raw, is_color),
        border            = Color.parseColorValue(border_raw,   is_color),
        shadow            = Color.parseColorValue({ hex = shadow_hex }, is_color),
        folder_bg         = folder_bg_raw and Color.parseColorValue(folder_bg_raw, is_color) or nil,
        folder_fg         = folder_fg_raw and Color.parseColorValue(folder_fg_raw, is_color) or nil,
    }
    _resolved_gen   = gen
    _resolved_mode  = is_color
    _resolved_night = is_night
    return _resolved_cache
end
M.resolvedColours = M.resolvedColors

-- Returns the raw setting values (storage shape, not Blitbuffer). For
-- the settings menu's "currently set to..." label rendering. Folder
-- colors return the raw value or nil (no static default) so the menu's
-- valueLabel helper can show "default" when unset. Memoised on the same
-- generation counter as resolvedColors().
function M.rawColors()
    local gen      = BookshelfSettings.generation()
    local is_night = G_reader_settings:isTrue("night_mode") or false
    if _raw_cache and _raw_gen == gen and _raw_night == is_night then
        return _raw_cache
    end
    _raw_cache = {
        fill              = _readModeColor("progress_fill",  DEFAULT_FILL, NIGHT_DEFAULT_FILL),
        track             = _readModeColor("progress_track", DEFAULT_TRACK, NIGHT_DEFAULT_TRACK),
        bookmark          = _readModeColor("bookmark_color", DEFAULT_BOOKMARK, NIGHT_DEFAULT_BOOKMARK),
        complete_bookmark = _readModeColor("complete_bookmark_color",
                                            DEFAULT_COMPLETE_BOOKMARK,
                                            NIGHT_DEFAULT_COMPLETE_BOOKMARK),
        favorite_star     = _readModeColor("favorite_star_color",
                                            DEFAULT_FAVORITE_STAR,
                                            NIGHT_DEFAULT_FAVORITE_STAR),
        favorite_heart    = _readModeColor("favorite_heart_color",
                                            DEFAULT_FAVORITE_HEART,
                                            NIGHT_DEFAULT_FAVORITE_HEART),
        badge_fg          = _readModeColor("badge_fg", DEFAULT_BADGE_FG, NIGHT_DEFAULT_BADGE_FG),
        badge_bg          = _readModeColor("badge_bg", DEFAULT_BADGE_BG, NIGHT_DEFAULT_BADGE_BG),
        border            = _readModeColor("border_color", DEFAULT_BORDER, NIGHT_DEFAULT_BORDER),
        folder_bg         = _readModeColor("folder_overlay_bg", nil),
        folder_fg         = _readModeColor("folder_overlay_fg", nil),
        fill_default              = DEFAULT_FILL,
        track_default             = DEFAULT_TRACK,
        bookmark_default          = DEFAULT_BOOKMARK,
        complete_bookmark_default = DEFAULT_COMPLETE_BOOKMARK,
        favorite_star_default     = DEFAULT_FAVORITE_STAR,
        favorite_heart_default    = DEFAULT_FAVORITE_HEART,
        badge_fg_default          = DEFAULT_BADGE_FG,
        badge_bg_default          = DEFAULT_BADGE_BG,
        border_default            = DEFAULT_BORDER,
    }
    _raw_gen   = gen
    _raw_night = is_night
    return _raw_cache
end

-- Exposed for the settings menu's pickColor helper so it writes the
-- same suffixed key resolvedColors reads from. Returns "" or "_night".
function M.modeSuffix()
    return _modeSuffix()
end

return M
