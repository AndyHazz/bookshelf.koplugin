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

local Blitbuffer        = require("ffi/blitbuffer")
local Device            = require("device")
local Font              = require("ui/font")
local FrameContainer    = require("ui/widget/container/framecontainer")
local Geom              = require("ui/geometry")
local OverlapGroup      = require("ui/widget/overlapgroup")
local TextWidget        = require("ui/widget/textwidget")
local Widget            = require("ui/widget/widget")
local ffi               = require("ffi")
local BookshelfSettings = require("lib/bookshelf_settings_store")
local Color            = require("lib/bookshelf_color")

local ColorRGB32_t      = ffi.typeof("ColorRGB32")
local Screen            = Device.screen

local M = {}

-- Glyph code points (KOReader's bundled nerd font).
M.GLYPH_BOOKMARK       = "\u{e7bf}"  -- in-progress
M.GLYPH_BOOKMARK_CHECK = "\u{e7c0}"  -- finished
M.GLYPH_PAUSE_CIRCLE   = "\u{f28b}"  -- on-hold (nf-fa-pause_circle, symbols face)

-- Favourite icon (nerdfont "symbols" face). Heart is the default so the
-- favourite badge reads distinctly from the yellow rating/favourite star.
M.FAV_GLYPH_STAR  = "\u{f005}"  -- nf-fa-star
M.FAV_GLYPH_HEART = "\u{f004}"  -- nf-fa-heart

-- "You already have this file" mark for OPDS cells (nerdfont "symbols" face).
-- Deliberately NOT part of decide()'s vocabulary: decide() answers read-status
-- questions (in progress / finished / on hold) from status + percent, behind
-- the three status toggles, and "the download landed" is neither a read status
-- nor something decide() has inputs for. The renderer reaches for this
-- constant directly, gated on the record's `downloaded` flag.
--
-- Private Use Area only. The bundled symbols face covers U+E000..U+F8FF and
-- nothing else, and a non-PUA codepoint has segfaulted this plugin before --
-- a known trap, not a hypothetical. U+F058 maps to the `ok_sign` glyph in the
-- bundled symbols.ttf cmap (the same cmap lib/bookshelf_nerdfont_names.lua was
-- generated from, where it is entry "ok_sign", code=0xF058).
M.GLYPH_DOWNLOADED = "\u{f058}"  -- nf-fa-check_circle

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
    if need_status_fallback or need_pages_fallback then
        if not _Repo then _Repo = require("lib/bookshelf_book_repository") end
        local p, s, _r, pages = _Repo.readProgress(book.filepath)
        if need_status_fallback then
            pct    = pct or p
            status = s
        end
        -- Mutate book.page_count so the SpineWidget renderer (which
        -- reads self.book.page_count directly) picks it up without a
        -- second lookup, and subsequent decide() calls skip the
        -- readProgress branch entirely.
        if need_pages_fallback and pages then
            book.page_count = pages
        end
    end
    local want_bar      = _toggle("progress_bar_enabled")
    local want_bookmark = _toggle("progress_bookmark_enabled")
    -- Completed-badge style is tri-state: "none" / "bookmark" (the pre-v2.1
    -- outlined dangling check; current default) / "tickbox" (the v2.1
    -- square pill). New key wins when set; otherwise fall back to the
    -- legacy boolean progress_badge_enabled (true / nil -> bookmark,
    -- false -> none) so users who had the badge off stay off, and
    -- everyone else lands on the bookmark style.
    local badge_style = BookshelfSettings.read("progress_badge_style")
    if badge_style == nil then
        local legacy = BookshelfSettings.read("progress_badge_enabled")
        if legacy == false then
            badge_style = "none"
        else
            badge_style = "bookmark"
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
        -- Optional recessed treatment for finished books (#138), reusing the
        -- on-hold fade render path (page-colour blend, no border/shadow).
        -- Defaults OFF; independent of the badge style, mirroring #121's
        -- split-cues lesson for on-hold.
        local fade = BookshelfSettings.read("finished_fade_enabled") == true
        return {
            bar          = false,
            bar_pct      = 0,
            glyph        = glyph_kind,
            on_hold_fade = fade or nil,
            page_count   = want_page_count,
        }
    end
    -- status = "new" or nil: bar / glyph stay off but page count can
    -- still show -- knowing the page count of an unread book is useful.
    return none
end

-- ---------------------------------------------------------------------------
-- Widget: ProgressBarWidget
-- ---------------------------------------------------------------------------

-- Exported so the spine widget's ShadowRect / BorderOverlay paint the user's
-- chosen ring and shadow colors in true color rather than their grey
-- luminance (issue #199); see the dispatch note below.
-- (assigned after the local is defined, further down)

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
M.paintRoundedRect = _paintRoundedRect

local function _paintBorder(bb, x, y, w, h, bw, c, r)
    if not c then return end
    if ffi.istype(ColorRGB32_t, c) then
        bb:paintBorderRGB32(x, y, w, h, bw, c, r)
    else
        bb:paintBorder(x, y, w, h, bw, c, r)
    end
end

local ProgressBarWidget = Widget:extend{
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

-- Build a ProgressBarWidget. `fill`, `track` and `border` are Blitbuffer
-- color objects (Color8 or ColorRGB32); callers resolve them via
-- bookshelf_color.parseColorValue before calling here. `border` is
-- optional and defaults to black inside paintTo when nil.
function M.buildBarWidget(width, height, pct, fill, track, border)
    return ProgressBarWidget:new{
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
-- ── Re-colouring live indicators on a night-mode flip ──────────────────────
--
-- Night mode is a hardware panel flag, so toggling it inverts what is already
-- on screen with no repaint of ours, and every colour baked at build time
-- reads wrong until something repaints it. Rebuilding the shelf to fix that
-- measured ~500ms a toggle on a PW5, ~420ms of it widget construction a colour
-- change does not invalidate.
--
-- This is cheap because TextWidget reads fgcolor at PAINT time
-- (textwidget.lua:338 paintTo -> RenderText:renderUtf8Text(..., self.fgcolor)),
-- so a glyph re-colours by plain assignment with no re-render. The folder
-- card's LABEL is the exception, being a TextBoxWidget that bakes its pixels
-- during _updateLayout -- see FolderCard.refreshColors.
--
-- Roles, not positions: a composed glyph is a stack of halo copies under a
-- centre fill (and sometimes a shadow beneath), and tagging each child says
-- which is which without this walk having to know the build order.
local function _role(widget, name)
    widget._bs_role = name
    return widget
end

local function _recolourGlyphGroup(self, roles)
    for i = 1, #self do
        local child = self[i]
        local glyph = child and child[1]
        local role  = glyph and glyph._bs_role
        if role and roles[role] then
            glyph.fgcolor = roles[role]
        end
    end
end

-- Weak KEYS: an indicator dropped by a rebuild stops being refreshed as soon
-- as it is collected, rather than pinning itself here.
local _recolourable = setmetatable({}, { __mode = "k" })

-- `pick` maps the resolved palette to this widget's roles. That mapping is
-- knowledge only the CALL SITE has: the builders above know their structure
-- (which child is halo, which is centre), while the caller knows which palette
-- entry it handed to each. Returns the widget so it can wrap a build call.
function M.registerRecolour(widget, pick)
    if widget and pick and widget._bs_recolour then
        _recolourable[widget] = pick
    end
    return widget
end

-- Re-apply the current palette to every live indicator. Returns how many were
-- touched, so a caller can tell "nothing on screen" from "the registry lost
-- them", which would silently restore the old delay.
function M.refreshColors()
    local colors = M.resolvedColors()
    local n = 0
    for widget, pick in pairs(_recolourable) do
        local ok, roles = pcall(pick, colors)
        if ok and type(roles) == "table" then
            if pcall(widget._bs_recolour, widget, roles) then n = n + 1 end
        end
    end
    return n
end

function M.buildGlyphWidget(glyph_char, size, color, face_name)
    return TextWidget:new{
        text    = glyph_char,
        -- Default "symbols" face for bookshelf's nerd-font glyphs
        -- (GLYPH_BOOKMARK / GLYPH_BOOKMARK_CHECK). Callers rendering a
        -- standard Unicode codepoint (e.g. the favourites star U+2605)
        -- pass a regular text face like "infofont" since "symbols" is
        -- a narrow subset that may not cover the standard ranges.
        face    = Font:getFace(face_name or "symbols", size),
        fgcolor = color,
        _bs_recolour = function(self, roles)
            local c = roles.fg or roles.centre
            if c then self.fgcolor = c end
        end,
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
                    _role(M.buildGlyphWidget(glyph_char, size, halo_color, face_name), "halo"),
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
        _role(M.buildGlyphWidget(glyph_char, size, centre_color, face_name), "centre"),
    }
    group._bs_recolour = _recolourGlyphGroup
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
        _role(M.buildGlyphWidget(glyph_char, size, shadow_color, face_name), "shadow"),
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
                    _role(M.buildGlyphWidget(glyph_char, size, halo_color, face_name), "halo"),
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
        _role(M.buildGlyphWidget(glyph_char, size, centre_color, face_name), "centre"),
    }
    group._bs_recolour = _recolourGlyphGroup
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
-- The shelf menu's strip and the footer's ground. Its own key rather than
-- reusing badge_bg: they start identical, but sharing would mean recolouring
-- badges silently restyled the chrome, and dark chrome with light badges would
-- be unreachable.
--
-- 0xFF in BOTH modes, which is deliberate. Night mode inverts the frame, so
-- one painted value gives white chrome by day and black chrome at night --
-- exactly what it should be. Badge background does the opposite (0xFF / 0x00)
-- because a badge must stay white on screen in both.
local DEFAULT_CHROME_BG = { grey = 0xFF }
-- Micro-module card fill. Separate from chrome_bg on purpose: the cards sit ON
-- the chrome, so a reader who tints one usually wants the other left alone.
--
-- SOLID, never a tint. The widgets inside a module blit opaque buffers of
-- their own, so over a semi-transparent card every line of text shows as a
-- box -- the card cannot be less opaque than its contents.
--
-- 0xEE, not 0xFF, and that is the value modules have always drawn on: every
-- TextBoxWidget built through the module Kit paints THIS colour as its own
-- background. Card and text background are one decision wearing two names, so
-- the setting drives both (Modules.setCardBg) -- change only the card and
-- every line of text keeps a visible box behind it.
local DEFAULT_MODULE_BG = { grey = 0xEE }
-- The top panel's and footer panel's tint. Separate from chrome_bg because the
-- two do different jobs: chrome_bg is an OPAQUE bar, panel_bg is blended over
-- a picture at the shading strength, so the value that reads well as one is
-- often wrong as the other.
local DEFAULT_PANEL_BG = { grey = 0xFF }
-- The PAGE, which is not the panel. They share a default and nothing else: a
-- reader who sets a panel colour is colouring the strip the chrome sits on,
-- and borrowing panel_bg for the page made that setting repaint the whole
-- screen instead (maintainer). Its own entry so the two can never be the
-- same knob again.
local DEFAULT_PAGE_BG = { grey = 0xFF }
-- Text ink, and the reason it is 0x00 in BOTH modes is the same reason
-- chrome_bg is 0xFF in both: a night frame inverts, so black paint displays
-- white. Every TextWidget in KOReader already defaults to black, which is why
-- text has never needed a palette entry -- the panel did the theming.
--
-- The shelf theme is where that stops working. Dark look on a device that is
-- NOT inverting means the paint itself has to be white, and only a palette
-- entry can be flipped. Text that keeps the widget default stays black on a
-- black panel, which is exactly how the first dark screenshot came out.
local DEFAULT_INK = { grey = 0x00 }
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
-- Selection ring + card shadow (issue #199). Both defaults reproduce EXACTLY
-- what was hard-coded before, so a reader who never opens these rows sees no
-- change: the ring painted COLOR_BLACK in both modes, and the shadow was
-- Blitbuffer.gray(0.5) by day and gray(0.15) at night.
--
-- The ring's night default is black like its day one, NOT the near-white the
-- border uses. That looks inconsistent and is not: the border is drawn from a
-- palette meant to read against the page, while the ring is a solid backdrop
-- the cover sits on, and it was never mode-switched.
local DEFAULT_SELECTION         = { hex = "#000000" }
local DEFAULT_CARD_SHADOW       = { hex = "#808080" }   -- gray(0.5)
local DEFAULT_PLANK             = { hex = "#B08050" }   -- the spine shelf's wood

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
local NIGHT_DEFAULT_CHROME_BG         = { grey = 0xFF }  -- displays black
local NIGHT_DEFAULT_MODULE_BG         = { grey = 0xEE }  -- displays near-black
local NIGHT_DEFAULT_PANEL_BG          = { grey = 0xFF }  -- displays black
local NIGHT_DEFAULT_PAGE_BG           = { grey = 0xFF }  -- displays black
local NIGHT_DEFAULT_INK               = { grey = 0x00 }  -- displays white
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
local NIGHT_DEFAULT_SELECTION         = { hex = "#000000" }
-- PAINT space, like every constant here: 0xD9 painted DISPLAYS 0x26 (a dark
-- grey) once night inverts the frame. Blitbuffer.gray is itself inverted
-- ("0 is white, 1.0 is black"), so gray(0.15) IS 0xD9 -- this matches
-- bookshelf_spine_widget's SHADOW_GRAY_NIGHT rather than contradicting it.
-- Written as 0x26 it painted dark and displayed 0xD9, a bright halo instead
-- of a shadow. The day value cannot catch this slip: gray(0.5) is 0x80, its
-- own inverse.
local NIGHT_DEFAULT_CARD_SHADOW       = { hex = "#D9D9D9" }  -- = gray(0.15)
local NIGHT_DEFAULT_PLANK             = { hex = "#B08050" }  -- light oak, same wood day and night (plank paints constantInNight)
-- The RIBBON and the spine shelf's section badges had no night default, so
-- they fell through to plain black -- which in night mode paints white and
-- DISPLAYS black, leaving the band invisible against the black page. 90%
-- black instead: 0xFF - 0x1A.
--
-- Reached through `ribbon_bg`, NOT `folder_bg`, and that distinction is the
-- whole point. v5.0.1 put this default on folder_bg, which the divider card
-- also reads -- so the card's manilla turned near-black while its label kept
-- its own default of constantInNight(BLACK), leaving author and folder names
-- dark on dark (issue 395). One setting key, two resolutions: the card takes
-- it raw, the ribbon and badges take it with this default behind it.
local NIGHT_DEFAULT_FOLDER_BG         = { grey = 0xE5 }  -- displays 0x1A, 90% black


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
-- ── Two axes, not one ─────────────────────────────────────────────
--
-- "night" has always meant two things here at once:
--
--   LOOK       -- the reader wants a dark shelf
--   INVERTING  -- the panel will flip the whole frame at refresh
--
-- They were always equal, so nothing had to tell them apart. The shelf's own
-- theme setting is exactly the case where they differ: a dark shelf while the
-- rest of KOReader stays light.
--
-- The stored night colours are PRE-INVERTED -- values chosen so that a frame
-- flip lands on the colour intended. So they are correct exactly when the
-- frame is flipping, and need one flip of their own when it is not. Same, in
-- reverse, for the day colours on a device that IS inverting.
--
-- Which is the whole rule: read the wanted look's colours, then invert the
-- palette if and only if look and inverting disagree.
M.THEME_SETTING = "shelf_theme"   -- "auto" (default) | "dark" | "light"

-- theme() -> want_dark, inverting
function M.theme()
    local inverting = G_reader_settings:isTrue("night_mode") or false
    local want = BookshelfSettings.read(M.THEME_SETTING)
    local dark
    if want == "dark" then
        dark = true
    elseif want == "light" then
        dark = false
    else
        dark = inverting        -- auto: follow the device
    end
    return dark, inverting
end

-- True when the palette this look wants is stored for the other one.
local function _needsFlip()
    local dark, inverting = M.theme()
    return dark ~= inverting
end

local function _modeSuffix()
    local dark = M.theme()
    return dark and "_night" or ""
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

-- ink() -> the themed text colour, or nil to leave a widget's own default.
--
-- A one-word change at each call site (`fgcolor = CoverProgress.ink()`), which
-- matters because there are a dozen-odd of them: KOReader's TextWidget
-- defaults to black, and that has always been right, because a night frame
-- inverts it to white. The shelf's own dark theme is where it stops being
-- right -- nothing inverts, so the paint itself has to change.
--
-- nil rather than black when the palette cannot be read: a widget default is
-- a better failure than a colour nobody chose.
function M.ink()
    local ok, colors = pcall(M.resolvedColors)
    return ok and colors and colors.ink or nil
end

function M.resolvedColors()
    local gen      = BookshelfSettings.generation()
    local is_color = Screen:isColorEnabled()
    -- BOTH axes in the key. Keyed on the device flag alone, a shelf pinned to
    -- dark would serve a palette built for the other frame state the moment
    -- the reader toggled night mode underneath it.
    local want_dark, inverting = M.theme()
    local is_night = want_dark
    local flip     = (want_dark ~= inverting)
    if _resolved_cache and _resolved_gen == gen and _resolved_mode == is_color
            and _resolved_night == is_night and _resolved_flip == flip then
        return _resolved_cache
    end
    -- One place, every colour: the raw value is flipped before it is parsed,
    -- so the parse cache and the greyscale luminance path never learn that a
    -- theme exists.
    local function _paint(raw)
        if flip then raw = Color.invertValue(raw) end
        return Color.parseColorValue(raw, is_color)
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
    local chrome_bg_raw    = _readModeColor("chrome_bg", DEFAULT_CHROME_BG,
                                             NIGHT_DEFAULT_CHROME_BG)
    local module_bg_raw    = _readModeColor("module_bg", DEFAULT_MODULE_BG,
                                             NIGHT_DEFAULT_MODULE_BG)
    -- NOT a setting any more (maintainer): the panel is white or black
    -- according to the theme, and Panel shading decides how much of what is
    -- behind it comes through. A colour picker here was the wrong control --
    -- it moved the ground without moving the ink, so choosing one meant
    -- choosing the text colour to match, and getting it wrong meant a shelf
    -- you could not read. The key is no longer read, so an override left by
    -- an earlier build is inert rather than surprising.
    local panel_bg_raw     = is_night and NIGHT_DEFAULT_PANEL_BG
                                      or  DEFAULT_PANEL_BG
    -- NOT keyed to a setting: the page's own colour is picked through the
    -- wallpaper background row, which stores in paint space and is read by
    -- BookshelfWidget:_pageGroundColor. This is only the themed DEFAULT for
    -- when that is unset -- paper by day, and dark when the shelf is.
    local ink_raw          = _readModeColor("ink_color", DEFAULT_INK, NIGHT_DEFAULT_INK)
    local border_raw       = _readModeColor("border_color", DEFAULT_BORDER, NIGHT_DEFAULT_BORDER)
    local selection_raw    = _readModeColor("selection_color",
                                             DEFAULT_SELECTION, NIGHT_DEFAULT_SELECTION)
    local card_shadow_raw  = _readModeColor("card_shadow_color",
                                             DEFAULT_CARD_SHADOW, NIGHT_DEFAULT_CARD_SHADOW)
    local plank_raw        = _readModeColor("spine_plank_color",
                                             DEFAULT_PLANK, NIGHT_DEFAULT_PLANK)
    -- Raw for the divider card, which keeps its own manilla default.
    local folder_bg_raw    = _readModeColor("folder_overlay_bg", nil)
    -- Night-defaulted for the ribbon and the shelf badges. Same key, so an
    -- explicit choice still wins for both.
    local ribbon_bg_raw    = _readModeColor("folder_overlay_bg", nil,
                                             NIGHT_DEFAULT_FOLDER_BG)
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
        fill              = _paint(fill_raw),
        track             = _paint(track_raw),
        bookmark          = _paint(bookmark_raw),
        complete_bookmark = _paint(complete_raw),
        favorite_star     = _paint(star_raw),
        favorite_heart    = _paint(heart_raw),
        badge_fg          = _paint(badge_fg_raw),
        badge_bg          = _paint(badge_bg_raw),
        chrome_bg         = _paint(chrome_bg_raw),
        module_bg         = _paint(module_bg_raw),
        panel_bg          = _paint(panel_bg_raw),
        page_bg           = _paint(is_night and NIGHT_DEFAULT_PAGE_BG
                                            or DEFAULT_PAGE_BG),
        ink               = _paint(ink_raw),
        border            = _paint(border_raw),
        -- The ring a selected / current-book cover sits on, and the drop
        -- shadow behind every card. Distinct from `shadow` below, which is the
        -- offset shadow on GLYPHS and stays hard-coded for the reason given
        -- there.
        selection         = _paint(selection_raw),
        card_shadow       = _paint(card_shadow_raw),
        -- The spine shelf's plank wood; its lit/shaded faces are tinted
        -- from this one pick in bookshelf_spine_shelf.
        plank             = _paint(plank_raw),
        shadow            = _paint({ hex = shadow_hex }),
        folder_bg         = folder_bg_raw and _paint(folder_bg_raw) or nil,
        ribbon_bg         = ribbon_bg_raw and _paint(ribbon_bg_raw) or nil,
        folder_fg         = folder_fg_raw and _paint(folder_fg_raw) or nil,
    }
    _resolved_gen   = gen
    _resolved_mode  = is_color
    _resolved_night = is_night
    _resolved_flip  = flip
    return _resolved_cache
end

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
        chrome_bg         = _readModeColor("chrome_bg", DEFAULT_CHROME_BG, NIGHT_DEFAULT_CHROME_BG),
        module_bg         = _readModeColor("module_bg", DEFAULT_MODULE_BG, NIGHT_DEFAULT_MODULE_BG),
        panel_bg          = _readModeColor("panel_bg", DEFAULT_PANEL_BG, NIGHT_DEFAULT_PANEL_BG),
        ink               = _readModeColor("ink_color", DEFAULT_INK, NIGHT_DEFAULT_INK),
        plank             = _readModeColor("spine_plank_color", DEFAULT_PLANK, NIGHT_DEFAULT_PLANK),
        border            = _readModeColor("border_color", DEFAULT_BORDER, NIGHT_DEFAULT_BORDER),
        -- NO night defaults here, deliberately, unlike the resolved colours
        -- above. rawColors() is what the settings menu reads to label a row,
        -- and a value the reader has not set must read as "default" rather
        -- than as a percentage they never chose.
        folder_bg         = _readModeColor("folder_overlay_bg", nil),
        folder_fg         = _readModeColor("folder_overlay_fg", nil),
        -- Selected chip (#294). Unset = the chip bar inverts as before, so no
        -- default here: nil is meaningful ("use the fast invert path").
        -- bookshelf_chip_bar reads the same keys directly when it paints; these
        -- entries exist so the settings menu's valueLabel/pickColor helpers can
        -- show and edit them like every other colour.
        chip_selected_bg  = _readModeColor("chip_selected_bg", nil),
        chip_selected_fg  = _readModeColor("chip_selected_fg", nil),
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
