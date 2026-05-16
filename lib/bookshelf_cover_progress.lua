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

local M = {}

-- Glyph code points (KOReader's bundled nerd font).
M.GLYPH_BOOKMARK       = "\u{e7bf}"  -- in-progress
M.GLYPH_BOOKMARK_CHECK = "\u{e7c0}"  -- finished

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
    local want_page_count = _toggle("progress_page_count_enabled") == true
    -- Default for the new page_count toggle is OFF, distinct from the
    -- other three indicators (which default ON). Reads from the same
    -- _toggle helper but `_toggle` returns true on nil; we need false.
    -- Override the default explicitly via direct read.
    do
        local raw = BookshelfSettings.read("progress_page_count_enabled")
        want_page_count = raw == true
    end
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
    local want_badge    = _toggle("progress_badge_enabled")
    -- Status vocabulary is normalised upstream (Repo.readProgress /
    -- Repo.buildBook). KOReader stores 'complete' / 'abandoned' in the
    -- sidecar; bookshelf treats those as 'finished' / 'on_hold' across
    -- the filter UI, sort engine, and cover indicators. Either name
    -- accepted here for back-compat with any cached records that
    -- predate the normalisation.
    if status == "reading" or status == "abandoned" or status == "on_hold" then
        return {
            bar        = want_bar and (pct ~= nil),
            bar_pct    = pct or 0,
            glyph      = want_bookmark and "in_progress" or nil,
            page_count = want_page_count,
        }
    elseif status == "complete" or status == "finished" then
        return {
            bar        = false,
            bar_pct    = 0,
            glyph      = want_badge and "complete" or nil,
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

local Widget         = require("ui/widget/widget")
local Geom           = require("ui/geometry")
local _BlitbufferBar = require("ffi/blitbuffer")
local _ScreenBar     = require("device").screen

local ProgressBarWidget = Widget:extend{
    width  = 0,
    height = 0,
    pct    = 0,        -- 0..1
    fill   = nil,      -- Blitbuffer colour
    track  = nil,      -- Blitbuffer colour
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
    local border = math.max(1, _ScreenBar:scaleBySize(1))
    local radius = math.floor(h / 2)
    -- 1. Track background (rounded rect, full bar)
    if self.track then
        bb:paintRoundedRect(x, y, w, h, self.track, radius)
    end
    -- 2. Dark border outlining the track
    bb:paintBorder(x, y, w, h, border, _BlitbufferBar.COLOR_BLACK, radius)
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
    bb:paintRoundedRect(x + inset, y + inset, inner_w, inner_h, self.fill, inner_r)
end

-- Build a ProgressBarWidget. `fill` and `track` are Blitbuffer colour
-- objects (Color8 or ColorRGB32); callers resolve them via
-- bookshelf_colour.parseColorValue before calling here.
function M.buildBarWidget(width, height, pct, fill, track)
    return ProgressBarWidget:new{
        width  = width,
        height = height,
        pct    = pct,
        fill   = fill,
        track  = track,
    }
end

-- ---------------------------------------------------------------------------
-- Widget: GlyphWidget (status indicator)
-- ---------------------------------------------------------------------------

local TextWidget      = require("ui/widget/textwidget")
local Font            = require("ui/font")
local Blitbuffer      = require("ffi/blitbuffer")
local OverlapGroup    = require("ui/widget/overlapgroup")
local CenterContainer = require("ui/widget/container/centercontainer")

-- Build a single-glyph TextWidget for the in-progress / finished badges.
-- @param glyph_char  one of GLYPH_BOOKMARK / GLYPH_BOOKMARK_CHECK
-- @param size        target glyph height in pixels (already scaled)
-- @param colour      Blitbuffer colour (resolved via bookshelf_colour)
-- @return TextWidget
function M.buildGlyphWidget(glyph_char, size, colour)
    return TextWidget:new{
        text    = glyph_char,
        face    = Font:getFace("symbols", size),
        fgcolor = colour,
    }
end

-- Build a white-with-black-halo glyph. The glyph is painted in BLACK
-- at every cell of a (2*halo_w + 1) x (2*halo_w + 1) offset grid
-- (skipping the centre), then in WHITE at the centre. The offset paints
-- create the outline; the white centre fills the strokes. Used for the
-- 'completed' indicator so the bookmark-check stays legible against any
-- cover artwork without the heavy 'sticker' look of the old badge.
function M.buildOutlinedGlyphWidget(glyph_char, size, halo_w)
    halo_w = halo_w or 1
    local widget_w = size + 2 * halo_w
    local widget_h = size + 2 * halo_w
    local FrameContainer = require("ui/widget/container/framecontainer")
    local group = OverlapGroup:new{
        dimen = Geom:new{ w = widget_w, h = widget_h },
    }
    -- Black offsets in all 8 directions around the centre.
    for dy = -halo_w, halo_w do
        for dx = -halo_w, halo_w do
            if dx ~= 0 or dy ~= 0 then
                group[#group + 1] = FrameContainer:new{
                    bordersize   = 0,
                    padding      = 0,
                    padding_top  = halo_w + dy,
                    padding_left = halo_w + dx,
                    M.buildGlyphWidget(glyph_char, size, Blitbuffer.COLOR_BLACK),
                }
            end
        end
    end
    -- White centre glyph.
    group[#group + 1] = FrameContainer:new{
        bordersize   = 0,
        padding      = 0,
        padding_top  = halo_w,
        padding_left = halo_w,
        M.buildGlyphWidget(glyph_char, size, Blitbuffer.COLOR_WHITE),
    }
    return group
end

-- ---------------------------------------------------------------------------
-- Resolved-settings accessor
-- ---------------------------------------------------------------------------

local Colour   = require("lib/bookshelf_colour")
local Device   = require("device")

local DEFAULT_FILL  = { grey = 0x40 }
-- Track defaults to pure white so the bar stays clearly distinct from
-- the cover's drop shadow (mid-grey) on monochrome devices.
local DEFAULT_TRACK = { grey = 0xFF }

-- Returns colour values resolved to Blitbuffer objects for the current
-- screen mode. Called per cover paint; relies on bookshelf_colour's
-- internal hex cache to keep the work cheap.
function M.resolvedColours()
    local is_colour = Device.screen:isColorEnabled()
    local fill_raw  = BookshelfSettings.read("progress_fill")  or DEFAULT_FILL
    local track_raw = BookshelfSettings.read("progress_track") or DEFAULT_TRACK
    return {
        fill  = Colour.parseColorValue(fill_raw,  is_colour),
        track = Colour.parseColorValue(track_raw, is_colour),
    }
end

-- Returns the raw setting values (storage shape, not Blitbuffer). For the
-- settings menu's "currently set to..." label rendering.
function M.rawColours()
    return {
        fill  = BookshelfSettings.read("progress_fill")  or DEFAULT_FILL,
        track = BookshelfSettings.read("progress_track") or DEFAULT_TRACK,
        fill_default  = DEFAULT_FILL,
        track_default = DEFAULT_TRACK,
    }
end

return M
