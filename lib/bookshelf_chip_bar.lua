-- bookshelf_chip_bar.lua
-- Two render modes:
--
--   1. Default (chips list): segmented control of N chips (Recent / Latest /
--      Series / ★ etc). Active chip inverts (black fill, paper text); tap
--      dispatches on_change(key).
--
--   2. Breadcrumb (drill-down): when `breadcrumb_path` is a non-empty array
--      of { label } records, the strip renders as a chip-shaped "pill" for
--      the current chip type followed by ">"-separated crumbs:
--
--         [Series] > Foundation > Asimov, Isaac
--
--      Tap dispatch:
--         * the chip pill         → on_breadcrumb(0)  (pop to top level)
--         * a crumb at index i    → on_breadcrumb(i)  (pop to that depth)
--
--      Truncation: when the assembled width would exceed self.width, older
--      crumbs are replaced from the left with a single "…" entry until it
--      fits, keeping the chip pill + (optionally) ellipsis + the deepest
--      crumb visible. Tapping the ellipsis is a no-op (resolves to the
--      first non-truncated crumb's depth in practice — but the deepest
--      crumb stays a clear target).
--
-- Border-butting approach (chips mode): chips are joined by giving each
-- chip (after the first) a padding_left = -Size.border.thin. If KOReader's
-- FrameContainer clamps negative padding to zero, the visual gap is a 1px
-- double-border rather than a seamless join — still readable.

local FrameContainer = require("ui/widget/container/framecontainer")
local BookshelfSettings = require("lib/bookshelf_settings_store")
local InputContainer = require("ui/widget/container/inputcontainer")
local HorizontalGroup= require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local TextWidget     = require("ui/widget/textwidget")
local CenterContainer= require("ui/widget/container/centercontainer")
local OverlapGroup   = require("ui/widget/overlapgroup")
local Widget         = require("ui/widget/widget")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local Size           = require("ui/size")
local Font           = require("ui/font")
local BFont          = require("lib/bookshelf_fonts")
local Blitbuffer     = require("ffi/blitbuffer")
local UIManager      = require("ui/uimanager")
local Device         = require("device")
local Screen         = Device.screen
local TextSegments   = require("lib/bookshelf_text_segments")
local Pages          = require("lib/bookshelf_chip_pages")
local PageWipe       = require("lib/bookshelf_page_wipe")
local BandMetrics    = require("lib/bookshelf_band_metrics")

-- Tab-bar font size scale (percent). 100 = built-in baseline; nudge dialog
-- accepts 50-300.
-- Applied to every font in the strip and to the externally-supplied height
-- (the widget scales chip_h by the same key through the same declaration).
-- Read on demand so changes from the settings nudge dialog take effect on the
-- next rebuild without restarting KOReader.
--
-- CHIP_KEY, and only CHIP_KEY. List rows once shared this scale and no longer
-- do; the key is named rather than spelled out here so the two surfaces cannot
-- drift back together through a copied string literal.
local function _scaled(n)
    return BandMetrics.scaled(n, BandMetrics.CHIP_KEY)
end

-- A TextWidget's max_width must be STRICTLY POSITIVE: KOReader's text layout
-- (TextWidget -> makeLine) aborts with "width must be strictly positive" on a
-- zero or negative width. At a very large chip-bar font on a narrow screen the
-- per-chip text budget can collapse to <= 0 (a font-scaled icon glyph eats the
-- whole chip allotment, or the chip width itself shrinks), so coerce any
-- non-positive width to nil -- render at natural width (clipped by the cell)
-- rather than crash. The crash was fatal here: Bookshelf is the home screen, so
-- the paint error recurred on every launch and locked the user out (issue #94).
local function _maxWidthOrNil(w)
    if w and w > 0 then return w end
    return nil
end

-- Build the cell-content widget for a chip label. Returns either a single
-- TextWidget (when the label is all-text or all-icon) or a HorizontalGroup
-- of TextWidgets with mixed bold settings (text bold, icons regular).
-- ink (optional): text colour. nil = COLOR_BLACK, which is what the default
-- selected-chip path needs because InvertedFrame flips the whole rect after
-- painting. A custom chip colour (#294) paints for real instead, so it passes
-- its own ink and skips the inversion.
-- Chip-bar label casing. Uppercase is the plugin's house style and stays the
-- default; the "Uppercase labels" toggle under Bookshelf chips turns it off for
-- users who prefer their own capitalisation (a chip labelled "Sci-Fi" reading
-- as typed rather than "SCI-FI"). Applies to chip labels AND the drill
-- breadcrumb crumbs, which are the same strip. Unicode-aware either way:
-- TextSegments.upper runs through utf8proc, and the pass-through still fixes
-- invalid UTF-8, which a label typed on-device can contain.
local function _chipCase(label)
    label = label or ""
    if BookshelfSettings.nilOrTrue("chip_uppercase_labels") then
        return TextSegments.upper(label)
    end
    local ok_util, util = pcall(require, "util")
    return (ok_util and util.fixUtf8) and util.fixUtf8(label, "?") or label
end

-- Icon glyphs ALWAYS render in the passthrough "symbols" face, never the
-- user's Bookshelf UI font: the nerd-font PUA codepoints (search, the
-- currently-reading book, chip icons) only exist in glyph fonts, and a
-- custom text font without them painted its missing-glyph box in their
-- place (user report, via a shared screenshot). Text segments keep
-- following the UI font -- that is what the setting is for.
local function _iconFace(size)
    return BFont:getFace("symbols", size)
end

-- The chip label's default colour.
--
-- Black, except on a manually dark shelf -- where the strip below is filled
-- with chrome_bg, which the dark theme flips to black, and a black label on it
-- is simply invisible. Only the ACTIVE chip showed, because that one inverts
-- itself to white-on-black; every other chip, the currently-reading glyph and
-- the search icon were all painted and unreadable.
--
-- In device night mode the frame inversion handles this, which is why the
-- default has stood for so long.
-- _memoised(name, fn) -> fn's answer, kept until the settings generation or
-- the night flag moves. These four helpers are asked ~15 times per chip-bar
-- build and each did a pcall(require ...) plus a palette resolve per call.
local _memo = {}
local function _memoised(name, fn)
    local gen   = BookshelfSettings.generation and BookshelfSettings.generation() or 0
    local night = require("lib/bookshelf_night_mode_sync").active()
    local m = _memo[name]
    if m and m.gen == gen and m.night == night then return m.v end
    local v = fn()
    _memo[name] = { gen = gen, night = night, v = v }
    return v
end

-- The look and the frame disagree (dark ~= inverting): the strip colours its
-- own labels, because the panel will not do it. Both halves, see
-- BookshelfWidget:_themeFlipsRaw.
local function _chipThemeFlipsRaw()
    local ok, CP = pcall(require, "lib/bookshelf_cover_progress")
    if not (ok and CP and CP.theme) then return false end
    local ok_t, dark, inverting = pcall(CP.theme)
    if not ok_t then return false end
    return (dark and true or false) ~= (inverting and true or false)
end

local function _chipThemeFlips() return _memoised("theme_flips", _chipThemeFlipsRaw) end

local function _chipInkRaw()
    local ok, CP = pcall(require, "lib/bookshelf_cover_progress")
    if not (ok and CP and CP.theme and CP.ink) then return Blitbuffer.COLOR_BLACK end
    local ok_t, dark, inverting = pcall(CP.theme)
    if not ok_t then return Blitbuffer.COLOR_BLACK end
    if (dark and true or false) == (inverting and true or false) then
        return Blitbuffer.COLOR_BLACK          -- the panel paints it right
    end
    return CP.ink() or Blitbuffer.COLOR_WHITE
end

local function _chipInk() return _memoised("chip_ink", _chipInkRaw) end

local function _buildLabelContent(label, size, max_w, ink)
    ink = ink or _chipInk()
    local segments = TextSegments.labelSegments(_chipCase(label))
    if #segments == 0 then
        local empty_face, empty_bold = BFont:getFace("infofont", size)
        return TextWidget:new{
            text    = "",
            face    = empty_face,
            bold    = empty_bold,
            fgcolor = ink,
        }
    end
    if #segments == 1 then
        local one_face, one_bold
        if segments[1].class == "text" then
            one_face, one_bold = BFont:getFace("infofont", size, { bold = true })
        else
            one_face, one_bold = _iconFace(size)
        end
        return TextWidget:new{
            text      = segments[1].text,
            face      = one_face,
            bold      = one_bold,
            fgcolor   = ink,
            max_width = _maxWidthOrNil(max_w),
        }
    end
    -- Mixed: HorizontalGroup. Icons (class != "text") render at their
    -- natural width — truncating mid-glyph reads badly. Text segments
    -- DO honour max_width so a label like "📖 NEW CHIP" truncates the
    -- text portion cleanly with an ellipsis when the chip is too
    -- narrow, instead of clipping pixels off the right edge.
    --
    -- The max_width budget for text is whatever's left after icons +
    -- inter-segment spacing have claimed their natural widths.
    local icon_w = 0
    for _i, seg in ipairs(segments) do
        if seg.class ~= "text" then
            local iw_face, iw_bold = _iconFace(size)
            local tw = TextWidget:new{
                text = seg.text,
                face = iw_face,
                bold = iw_bold,
            }
            icon_w = icon_w + tw:getSize().w
            tw:free()
        end
    end
    local text_budget = math.max(0, max_w - icon_w)
    local hg = HorizontalGroup:new{ align = "center" }
    for _i, seg in ipairs(segments) do
        local is_text = (seg.class == "text")
        local seg_face, seg_bold
        if is_text then
            seg_face, seg_bold = BFont:getFace("infofont", size, { bold = true })
        else
            seg_face, seg_bold = _iconFace(size)
        end
        hg[#hg + 1] = TextWidget:new{
            text      = seg.text,
            face      = seg_face,
            bold      = seg_bold,
            fgcolor   = ink,
            max_width = is_text and _maxWidthOrNil(text_budget) or nil,
        }
    end
    return hg
end

-- Sum of per-segment widths. Used by flex-width measurement to get the
-- chip's natural content width. Builds + frees throw-away TextWidgets
-- (no max_width) so the returned size reflects actual glyph metrics.
local function _measureLabel(label, size)
    local total = 0
    local segments = TextSegments.labelSegments(_chipCase(label))
    for _i, seg in ipairs(segments) do
        local m_face, m_bold
        if seg.class == "text" then
            m_face, m_bold = BFont:getFace("infofont", size, { bold = true })
        else
            m_face, m_bold = _iconFace(size)
        end
        local tw = TextWidget:new{
            text = seg.text,
            face = m_face,
            bold = m_bold,
        }
        total = total + tw:getSize().w
        tw:free()
    end
    return total
end

-- FrameContainer that pixel-inverts its own rect after painting. Used for
-- selected chips: renders black-on-white then flips via a blitbuffer primitive
-- so the inversion is device-independent (avoids TextWidget fgcolor, which
-- some Kindle builds do not honour).
local InvertedFrame = FrameContainer:extend{}
function InvertedFrame:paintTo(bb, x, y)
    FrameContainer.paintTo(self, bb, x, y)
    if self._invert then
        bb:invertRect(x, y, self.dimen.w, self.dimen.h)
    end
end

-- ─── Custom chip colours (#294) ───────────────────────────────────────────────
-- The selected chip is normally rendered by painting black-on-white and then
-- INVERTING the rect (see InvertedFrame): device-independent, and the fastest
-- path -- no per-glyph colour work. That stays the default.
--
-- When the user sets a colour we cannot invert (there is nothing to invert TO),
-- so that chip is painted for real: fill as the frame background, label in the
-- ink colour, inversion off. Only chips with an explicit colour take that path,
-- so everyone else keeps the fast, device-independent rendering.
--
-- One bar-wide pair (chip_selected_bg / chip_selected_fg); unset -> invert as
-- before. A per-chip override briefly existed in the chip editor (#294) and was
-- dropped before release: two more rows in the editor was too much surface for
-- something nobody had asked for.
-- Both keys are mode-suffixed by the store helper so day and night themes stay
-- independent, exactly like the cover/progress colours.
local function _modeSuffix()
    local ok, CP = pcall(require, "lib/bookshelf_cover_progress")
    if ok and CP and CP.modeSuffix then return CP.modeSuffix() end
    return ""
end

local function _readBarColor(base_key)
    local suffix = _modeSuffix()
    if suffix ~= "" then
        -- Night overrides do NOT inherit the day value (same reasoning as
        -- _readModeColor in bookshelf_cover_progress): inheriting a day colour
        -- into night showed the inverted day appearance, not the night theme.
        return BookshelfSettings.read(base_key .. suffix)
    end
    return BookshelfSettings.read(base_key)
end

-- Returns fill, ink (Blitbuffer colours) or nil when the chip should invert.
-- The separator to draw BETWEEN two filled chips: whichever of white/black
-- actually shows against the fill.
--
-- A black separator between two black chips is invisible and the pair merges,
-- which is why this was white -- but that assumed the fill was always black.
-- With a custom selected colour (#294) a light fill got a WHITE separator, so
-- the line vanished exactly where it was needed: reported on a light mauve
-- chip set, where the currently-reading chip ran straight into Home.
--
-- Decided on the fill's own luminance rather than "is a custom colour set", so
-- a custom DARK fill still gets the white line it needs. Color8's .a is that
-- luminance; a colour that cannot answer falls back to the historical white.
local function _separatorOnFill(fill)
    if type(fill) == "nil" then return Blitbuffer.COLOR_WHITE end
    local ok, c8 = pcall(function() return fill:getColor8() end)
    local lum = ok and c8 and c8.a or nil
    if type(lum) ~= "number" then return Blitbuffer.COLOR_WHITE end
    return lum < 128 and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
end

-- _stripGround() -> the strip's own fill, for a rule that has to merge into
-- it on one side and show on the other.
local function _stripGroundRaw()
    local ok, CP = pcall(require, "lib/bookshelf_cover_progress")
    if not (ok and CP and CP.resolvedColors) then return Blitbuffer.COLOR_WHITE end
    local ok_c, colors = pcall(CP.resolvedColors)
    if not (ok_c and colors) or type(colors.chrome_bg) == "nil" then
        return Blitbuffer.COLOR_WHITE
    end
    return colors.chrome_bg
end

-- _stripInk() -> the colour a LINE on the strip has to be to be seen.
--
-- Decided on the strip's own luminance, not on the theme. _chipInk answers
-- "what colour is this shelf's text", which is right for a label and wrong
-- for the strip's own outline and separators: a reader who has set Shelf menu
-- background to white while running the dark theme gets a white strip, and a
-- themed white rule on it is no rule at all (maintainer, on device -- the
-- border between the shelf button and the currently-reading button went
-- missing). Same reasoning, and the same helper, as the line between two
-- filled chips.
local function _stripGround() return _memoised("strip_ground", _stripGroundRaw) end

local function _stripInkRaw()
    local ok, CP = pcall(require, "lib/bookshelf_cover_progress")
    if not (ok and CP and CP.resolvedColors) then return Blitbuffer.COLOR_BLACK end
    local ok_c, colors = pcall(CP.resolvedColors)
    if not (ok_c and colors) then return Blitbuffer.COLOR_BLACK end
    return _separatorOnFill(colors.chrome_bg)
end

local function _stripInk() return _memoised("strip_ink", _stripInkRaw) end

local function _selectedChipColors()
    local raw_bg = _readBarColor("chip_selected_bg")
    local raw_fg = _readBarColor("chip_selected_fg")
    if not raw_bg and not raw_fg then return nil end
    local ok, Color = pcall(require, "lib/bookshelf_color")
    if not ok or not Color then return nil end
    local is_color = Screen.isColorEnabled and Screen:isColorEnabled() or false
    -- A fill with no ink set (or vice versa) still needs a readable pair, so
    -- fall back to the inverted-default equivalents: white text on the fill,
    -- black text on the default (white) background.
    local fill = raw_bg and Color.parseColorValue(raw_bg, is_color) or nil
    local ink  = raw_fg and Color.parseColorValue(raw_fg, is_color) or nil
    if fill and not ink then ink = Blitbuffer.COLOR_WHITE end
    if ink and not fill then fill = Blitbuffer.COLOR_BLACK end
    if not fill or not ink then return nil end
    return fill, ink
end

-- _activeChipColors() -> fill, ink  (nil = "no pair, invert yourself")
--
-- What a SELECTED chip paints with. The reader's own choice first (#294);
-- failing that, on a manually dark shelf, the theme's. An active chip normally
-- renders by INVERTING its own rect, and a dark strip gives it nothing to
-- invert -- the fill is cleared under a wallpaper -- so it vanishes or comes
-- back the wrong way round. An explicit pair paints for real: the bar's own
-- colour as ink on the theme's ink as fill, which is the inversion the strip
-- cannot perform for itself.
--
-- BOTH layouts ask here. Breadcrumb mode used to ask only for the reader's
-- custom pair, so with none set on a dark shelf the currently-reading button
-- and its pointer fell back to inverting: a black cell with a white glyph and
-- a black roof, against the white cell, dark glyph and white roof the same
-- button shows at top level. Reported on a drilled-in shelf.
local function _activeChipColors()
    local fill, ink = _selectedChipColors()
    if type(fill) ~= "nil" then return fill, ink end
    if not _chipThemeFlips() then return nil end
    local ok, CP = pcall(require, "lib/bookshelf_cover_progress")
    if not (ok and CP and CP.resolvedColors) then return nil end
    local ok_c, colors = pcall(CP.resolvedColors)
    if not (ok_c and colors and colors.chrome_bg) then return nil end
    return _chipInk(), colors.chrome_bg
end

local ChipBar = InputContainer:extend{
    -- Set by the shelf when something is painted behind the strip.
    has_wallpaper = false,
    -- Paint an opaque ground behind the strip? See ChipBar:paintTo.
    solid_ground = false,
    chips             = nil,   -- list of { key, label } (chips mode)
    active            = nil,   -- key of the currently-selected chip
    selected_key      = nil,   -- the active chip key for pagination; defaults to self.active
    focused_key       = nil,   -- D-pad cursor: chip with focus ring in chips mode (nil = none)
    focused_depth     = nil,   -- D-pad cursor: zone depth with focus ring in breadcrumb mode (nil = none)
    breadcrumb_path   = nil,   -- list of { label } — when non-empty, breadcrumb mode
    chip_pill_label   = nil,   -- label for the chip pill in breadcrumb mode (e.g. "Series")
    chip_pill_glyph   = nil,   -- nerd-font glyph for the chip pill (overrides label)
    back_label        = nil,   -- when set, prepend a Back pill (depth -1) before the chip pill
    width             = nil,
    height            = nil,
    on_change         = nil,   -- function(key) — chips mode tap
    on_breadcrumb     = nil,   -- function(depth) — breadcrumb mode tap
    on_pill_hold      = nil,   -- function() — long-press the chip pill (breadcrumb mode)
    on_hold           = nil,   -- function(key) — chips mode long-press
    on_page_change    = nil,   -- function() — chip page changed (for pre-warm)
    show_parent       = nil,   -- window-level widget, used as setDirty target
}

-- Small triangular pointer that protrudes ABOVE the chip body, base on
-- the chip's top edge, apex pointing upward. Used by selected action
-- chips (currently-reading) so the chip "points at" what it represents
-- in the hero region above the strip. Same color as the chip's bg, so
-- the triangle reads as an extension of the chip's silhouette rather
-- than a separate marker. Painted via OverlapGroup overlap_offset with
-- a negative y so the pixels land in the area above the chip strip's
-- top edge — within the bookshelf widget's bounds, so refreshes work.
local UpTrianglePointer = require("ui/widget/widget"):extend{
    width   = nil,
    height  = nil,
    color   = nil,
    -- Outline colour for the two sloped edges, matching the strip's own
    -- border. nil draws the bare fill, which is what a black chip on a black
    -- border wants (the outline would be invisible either way).
    outline = nil,
    border  = 1,
}
function UpTrianglePointer:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
end
function UpTrianglePointer:paintTo(bb, x, y)
    local w, h = self.width, self.height
    -- paintRect flattens a colour to the buffer's native format, which on a
    -- colour panel means the Rec.601 LUMINANCE of the fill -- a custom teal
    -- chip pointer came out grey (#294). paintRectRGB32 preserves the real
    -- colour and is correct on B&W buffers too, so it is used unconditionally
    -- when available -- the same lesson as the cover progress bar (#184).
    local function rgb32Of(c)
        return bb.paintRectRGB32 and c and c.getColorRGB32 and c:getColorRGB32() or nil
    end
    local fill_rgb32    = rgb32Of(self.color)
    local outline_rgb32 = rgb32Of(self.outline)
    local function row(dy, off, wid, c, rgb32)
        if wid <= 0 then return end
        if rgb32 then bb:paintRectRGB32(x + off, y + dy, wid, 1, rgb32)
        else          bb:paintRect(x + off, y + dy, wid, 1, c) end
    end
    -- Linear taper: apex (1px wide) at the top, full base at bottom.
    local function span(dy)
        local row_w   = math.max(1, math.floor(w * (dy + 1) / h + 0.5))
        return math.floor((w - row_w) / 2), row_w
    end
    if not self.outline then
        for dy = 0, h - 1 do
            local off, wid = span(dy)
            row(dy, off, wid, self.color, fill_rgb32)
        end
        return
    end
    -- Outlined: the whole taper in the outline colour, then the fill as the
    -- SAME taper shifted down and inset by the border width. Drawing the edge
    -- per-row instead would leave a dotted staircase, because this triangle is
    -- far wider than it is tall and each row steps several pixels sideways.
    local b = math.max(1, self.border or 1)
    for dy = 0, h - 1 do
        local off, wid = span(dy)
        row(dy, off, wid, self.outline, outline_rgb32)
    end
    for dy = b, h - 1 do
        local off, wid = span(dy - b)
        row(dy, off + b, wid - 2 * b, self.color, fill_rgb32)
    end
end

-- A short rule in a chip's own fill, painted over the top border row of the
-- frame a pointer sits on. Only the breadcrumb currently-reading button needs
-- it: its pointer is lifted from the FRAME's top rather than from a cell's
-- content top, so it lands one border clear and the border shows through as a
-- line across the join. `inset` keeps that many pixels at each end, so the
-- frame's corners survive and the pointer's outline still meets the box's.
local PointerJoin = require("ui/widget/widget"):extend{
    width  = nil,
    height = nil,
    color  = nil,
    inset  = 0,
}
function PointerJoin:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
end
function PointerJoin:paintTo(bb, x, y)
    local w = self.width - 2 * self.inset
    if w <= 0 then return end
    -- paintRectRGB32 where it exists, for the reason the pointer uses it:
    -- paintRect flattens a custom fill to its luminance (#294), and this rule
    -- has to be the SAME colour as the pointer above it or the join shows.
    local rgb32 = bb.paintRectRGB32 and self.color and self.color.getColorRGB32
                  and self.color:getColorRGB32() or nil
    if rgb32 then bb:paintRectRGB32(x + self.inset, y, w, self.height, rgb32)
    else          bb:paintRect(x + self.inset, y, w, self.height, self.color) end
end

-- The roof's height. Shared, because the refresh that repaints a tapped chip
-- has to cover it: scoped to the cell alone, the rectangle repainted in one
-- frame and the triangle above it in the next.
local function _pointerHeight(h)
    return math.max(Screen:scaleBySize(5), math.floor(h * 0.25))
end

-- _EdgeRing -- the outline around a chip that is a BUTTON.
--
-- Not a FrameContainer, because the four sides do not all belong in the same
-- place. A button inside the strip has the strip's own edge immediately
-- outside it, and an outline drawn within the cell leaves that edge showing
-- as a second, lighter line around the first -- "a white border outside the
-- black border". So a side whose neighbour is the STRIP's edge is pushed out
-- onto it and replaces it, while a side whose neighbour is another chip stays
-- at the cell's edge, leaving the separator to keep its contrasting line
-- between the two. Both were reported from a PW5, one after the other.
--
-- out_l / out_r / out_t / out_b say how far each side is pushed out.
local EdgeRing = require("ui/widget/widget"):extend{
    width  = nil,
    height = nil,
    color  = nil,
    bw     = 1,
    out_l  = 0, out_r = 0, out_t = 0, out_b = 0,
    -- ...and a side can be left undrawn, where the neighbour is another
    -- button. Both drawing at that boundary makes three columns of it -- the
    -- two outlines and the separator between them - where one is wanted.
    no_l   = false, no_r = false,
}
function EdgeRing:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
end
function EdgeRing:paintTo(bb, x, y)
    local bw = self.bw
    local x0, y0 = x - self.out_l, y - self.out_t
    local x1     = x + self.width  + self.out_r   -- exclusive
    local y1     = y + self.height + self.out_b
    local rw, rh = x1 - x0, y1 - y0
    if rw <= 0 or rh <= 0 or bw <= 0 then return end
    -- paintRectRGB32 for the reason the pointer gives (#294): paintRect
    -- flattens a custom colour to its luminance.
    local rgb32 = bb.paintRectRGB32 and self.color and self.color.getColorRGB32
                  and self.color:getColorRGB32() or nil
    local function rect(rx, ry, rww, rhh)
        if rww <= 0 or rhh <= 0 then return end
        if rgb32 then bb:paintRectRGB32(rx, ry, rww, rhh, rgb32)
        else          bb:paintRect(rx, ry, rww, rhh, self.color) end
    end
    rect(x0, y0, rw, bw)            -- top
    rect(x0, y1 - bw, rw, bw)       -- bottom
    if not self.no_l then rect(x0, y0, bw, rh) end
    if not self.no_r then rect(x1 - bw, y0, bw, rh) end
end

-- _actionButton(o) -> a widget exactly o.w by o.h
--
-- The currently-reading and micro-modules buttons, in ONE place. Both chip
-- layouts draw them: the strip as a cell in the row, the breadcrumb as a
-- fixed-width box before the pills. They were built twice and drifted three
-- times in a week -- the theme colours, the outline, the roof's join -- so
-- they are built here instead and the callers pass only what actually
-- differs between them.
--
--   o.content   the glyph / icon / label that sits in the middle
--   o.w, o.h    the OUTER size, border included
--   o.fill      body background; nil leaves the ground (or a wallpaper) showing
--   o.invert    invert the body's rect, which is the default selected look
--   o.border    the outline's colour
--   o.pointer   nil, or { color =, outline = } to put a roof on it
local function _actionButton(o)
    local b   = Size.border.thin
    local out = o.out or {}
    local ol, ort = out.l or 0, out.r or 0
    local ot, ob  = out.t or 0, out.b or 0
    -- The body fills the cell; the outline is painted ON its edge by the ring
    -- below, and pushed outward only where the strip's own edge is what lies
    -- beyond. bordersize 0 here for its own reason: an InvertedFrame that
    -- inverts its own border leaves a white ring on a KT6.
    local body = InvertedFrame:new{
        _invert    = o.invert and true or false,
        bordersize = 0,
        margin     = 0,
        padding    = 0,
        background = o.fill,
        CenterContainer:new{
            dimen = Geom:new{ w = o.w, h = o.h },
            o.content,
        },
    }
    local ring = EdgeRing:new{
        width = o.w, height = o.h, color = o.border, bw = b,
        out_l = ol, out_r = ort, out_t = ot, out_b = ob,
        no_l  = out.no_l and true or false,
        no_r  = out.no_r and true or false,
    }
    local group = OverlapGroup:new{
        dimen = Geom:new{ w = o.w, h = o.h },
        body,
        ring,
    }
    if not o.pointer then return group end
    -- The roof, pointing up at the hero slot this button controls. Anchored
    -- with a negative y so it paints above the button without taking layout
    -- space, and NOT lifted clear of the outline: the join below covers that
    -- top edge so the two read as one silhouette rather than a triangle
    -- stacked on a box.
    local pointer_h = _pointerHeight(o.h)
    local pointer = UpTrianglePointer:new{
        width   = o.w + ol + ort,
        height  = pointer_h,
        color   = o.pointer.color,
        outline = o.pointer.outline,
        border  = b,
    }
    pointer.overlap_offset = { -ol, -pointer_h - ot }
    -- Over the ring's top edge, wherever that landed, and a border short at
    -- each end so the ring still turns its two top corners. After the
    -- pointer, because an outlined pointer draws its whole taper in the
    -- outline colour before insetting the fill: its base row would otherwise
    -- leave a few dark pixels at each end of the join.
    local join = PointerJoin:new{
        width  = o.w + ol + ort,
        height = b,
        inset  = b,
        color  = o.pointer.color,
    }
    join.overlap_offset = { -ol, -ot }
    group[#group + 1] = pointer
    group[#group + 1] = join
    return group
end

-- Breadcrumb pill rendered as a black-outlined tag (white interior) with
-- an arrow tip on the right. Pills CHAIN by overlapping the right tip
-- of one with the left "notch" (empty space) of the next. The widget's
-- placement_w deliberately EXCLUDES the right tip — when a chained next
-- pill is laid out adjacently in a HorizontalGroup, its notch occupies
-- exactly the same x-range as the previous tip, and because the next
-- pill (chained=true) paints nothing in the notch area, the previous
-- tip remains visible.
--
-- Text labels in chained pills get an extra `tip_w` of left padding so
-- the text doesn't visually sit on top of the previous tip's apex.
--
-- Returns (widget, placement_w, tip_w). `placement_w` is what
-- HorizontalGroup uses for layout (notch + body, NOT including tip);
-- the tip overhangs into the next slot.
local function arrowPillFrame(label, h, chained, glyph)
    -- glyph (optional): a UTF-8 string (typically a nerd-font icon) shown
    -- in the pill. Three render modes depending on which of label/glyph
    -- are supplied:
    --   * label only        — uppercase text (the standard breadcrumb crumb)
    --   * glyph only        — single icon, point-size 18 to match chip-row
    --   * glyph + label     — icon + text, side-by-side ("[icon] LABEL")
    -- The combined mode is used for the search-mode chip pill so the user
    -- sees "[search] SEARCH RESULTS" instead of just the bare icon.
    local content_widget, content_w, content_h
    if glyph and label and label ~= "" then
        local icon_face, icon_bold = _iconFace(_scaled(18))
        local icon_tw = TextWidget:new{
            text    = glyph,
            face    = icon_face,
            bold    = icon_bold,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
        local lbl_face, lbl_bold = BFont:getFace("infofont", _scaled(16), { bold = true })
        local text_tw = TextWidget:new{
            text    = _chipCase(label),
            face    = lbl_face,
            bold    = lbl_bold,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
        local gap = Size.padding.default
        content_widget = HorizontalGroup:new{
            align = "center",
            icon_tw,
            HorizontalSpan:new{ width = gap },
            text_tw,
        }
        content_w = icon_tw:getSize().w + gap + text_tw:getSize().w
        content_h = math.max(icon_tw:getSize().h, text_tw:getSize().h)
    else
        local label_text, face, bold
        if glyph then
            label_text = glyph
            face, bold = _iconFace(_scaled(18))
        else
            label_text = _chipCase(label)
            face, bold = BFont:getFace("infofont", _scaled(16), { bold = true })
        end
        content_widget = TextWidget:new{
            text    = label_text,
            face    = face,
            bold    = bold,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
        content_w = content_widget:getSize().w
        content_h = content_widget:getSize().h
    end
    local text_w = content_w  -- keep historical names so the layout maths below stay readable
    local text_h = content_h
    local h_pad  = Size.padding.large
    local tip_w  = math.floor(h * 0.4)
    -- For chained pills the body has a TRIANGULAR NOTCH carved into
    -- its LEFT side (matching the previous pill's tip shape) AND extra
    -- tip_w of left padding inside so text doesn't sit on the apex.
    -- The body's footprint is the same width regardless of where the
    -- text falls — the notch is just a paint-time exclusion.
    local left_text_pad = h_pad + (chained and tip_w or 0)
    local body_w        = text_w + left_text_pad + h_pad
    -- HorizontalGroup placement width = body_w only. The right tip
    -- overhangs into the NEXT pill's notch footprint, so successive
    -- pills overlap by tip_w in absolute coords.
    local placement_w = body_w
    local b = Size.border.thin

    -- notch_x_at(dy): right edge of the notch at row dy. Triangular,
    -- 0 at top/bottom, tip_w at the vertical centre. Used by both the
    -- BLACK body fill and the WHITE inner-knockout so the body's
    -- silhouette respects the notch shape — the previous pill's tip
    -- (painted into our notch area) remains visible.
    local hh = (h - 1) / 2
    local function notch_x_at(dy)
        if not chained then return 0 end
        local from_center = math.abs(dy - hh)
        local x = math.floor(tip_w * (1 - from_center / hh) + 0.5)
        if x < 0 then return 0 end
        if x > tip_w then return tip_w end
        return x
    end

    local ArrowBg = Widget:extend{}
    function ArrowBg:init()
        self.dimen = Geom:new{ w = placement_w, h = h }
    end
    function ArrowBg:paintTo(bb, x, y)
        local BLACK = Blitbuffer.COLOR_BLACK
        local WHITE = Blitbuffer.COLOR_WHITE
        -- Black body: per-row, starting at notch_x_at(dy) so the
        -- silhouette has the triangular notch on the left.
        for dy = 0, h - 1 do
            local nl = notch_x_at(dy)
            if body_w > nl then
                bb:paintRect(x + nl, y + dy, body_w - nl, 1, BLACK)
            end
        end
        -- Right tip: tapered triangle past body_w.
        for dy = 0, h - 1 do
            local from_center = math.abs(dy - hh)
            local row_w = math.max(0, math.floor(tip_w * (1 - from_center / hh) + 0.5))
            if row_w > 0 then
                bb:paintRect(x + body_w, y + dy, row_w, 1, BLACK)
            end
        end
        -- Inner WHITE knockout. Per-row: starts at notch_x_at(dy) +
        -- (b for unchained, 0 for chained) so chained pills have no
        -- separate left-border line — the previous pill's tip butts
        -- straight up against pure white interior.
        local inner_h = h - 2 * b
        if inner_h <= 0 then return end
        for dy = b, h - b - 1 do
            local nl = notch_x_at(dy)
            local left_inset = chained and 0 or b
            local row_start = nl + left_inset
            if body_w > row_start then
                bb:paintRect(x + row_start, y + dy, body_w - row_start, 1, WHITE)
            end
        end
        -- Right tip inner. Measured from the OUTER taper less the border,
        -- not from a taper of its own. Two tapers, each rounded on its own
        -- terms, agreed on the row width often enough to leave the outline
        -- with HOLES in it: on a PW5 the rows either side of the apex had no
        -- black at all and the tip was open, with single stray pixels
        -- further up and down the slope. Taking the border off the row the
        -- black actually painted leaves exactly b of it on every row.
        for dy = b, h - b - 1 do
            local from_center = math.abs(dy - hh)
            local outer_w = math.max(0, math.floor(tip_w * (1 - from_center / hh) + 0.5))
            local row_w = outer_w - b
            if row_w > 0 then
                bb:paintRect(x + body_w, y + dy, row_w, 1, WHITE)
            end
        end
    end

    -- Text positioning: x_local = left_text_pad (no notch_w offset
    -- because the body's local origin is at x_local=0 now).
    local text_positioned = FrameContainer:new{
        bordersize   = 0,
        padding      = 0,
        padding_left = left_text_pad,
        padding_top  = math.floor((h - text_h) / 2),
        content_widget,
    }

    local pill = OverlapGroup:new{
        dimen = Geom:new{ w = placement_w, h = h },
        ArrowBg:new{},
        text_positioned,
    }
    return pill, placement_w, tip_w
end

-- The shelf menu's ground, and it is SOLID where the top panel around it is a
-- tint.
--
-- The panel behind this band is semi-transparent on purpose -- it has a
-- photograph to show. The shelf menu cannot afford that: it is a dense row of
-- small labels and glyphs, and over a dark or busy picture the tint alone
-- leaves it the least legible thing on the screen. So this strip opts out and
-- takes the full colour.
--
-- chrome_bg is 0xFF in both modes and night inverts the frame, so this is a
-- white bar by day and a black one at night, with no branch here.
--
-- Skipped entirely at Transparent, which means "let the picture through": a
-- solid bar is exactly what that reader asked not to have.
-- Shared with the page wipe, which composes into its OWN buffer and paints
-- self[1] directly rather than going through paintTo -- so a ground that
-- lived only in paintTo vanished for the length of every swipe.
function ChipBar:_paintGround(bb, x, y, w, h)
    if not self.solid_ground then return false end
    -- Breadcrumb mode has it too, since 2026-09-19. It used to be chips-only,
    -- on the grounds that a breadcrumb is an icon, a pill or two and a folder
    -- name, and a ground for that is a mostly-empty slab. But with the two
    -- modes side by side the maintainer asked for them to match, and half a
    -- bar reads worse than a full one: drilling in changed the whole shape of
    -- the strip and moved the button with it.
    local ok, CoverProgress = pcall(require, "lib/bookshelf_cover_progress")
    if not (ok and CoverProgress and CoverProgress.resolvedColors) then return false end
    local ok_c, colors = pcall(CoverProgress.resolvedColors)
    if not (ok_c and colors and colors.chrome_bg) then return false end
    return pcall(function()
        bb:paintRect(x, y, w or 0, h or 0, colors.chrome_bg)
    end)
end

function ChipBar:paintTo(bb, x, y)
    -- Over what the strip PAINTS, not what it declares. The chips row sits
    -- inside a Size.border.thin FrameContainer, so the paint is 2*border
    -- taller than self.height -- the same discrepancy the page-flip region
    -- has to allow for above (issue 352's ghost line), and the wipe already
    -- lays its ground over the whole region for exactly this reason. A
    -- ground of self.height left the row's last line bare: a hairline of
    -- wallpaper between an unfilled chip and the strip's bottom edge,
    -- spotted on a PW5.
    local painted = self[1] and self[1].getSize and self[1]:getSize() or nil
    -- _band_w, when the breadcrumb layout set one, stops the ground at the
    -- end of the pill trail: the deepest crumb is the name of where you are,
    -- and it sits on the shelf rather than on a slab of its own.
    self:_paintGround(bb, x, y,
        self._band_w or math.max(self.width or 0, painted and painted.w or 0),
        math.max(self.height or 0, painted and painted.h or 0))
    InputContainer.paintTo(self, bb, x, y)
end

function ChipBar:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    if self.breadcrumb_path and #self.breadcrumb_path > 0 then
        self:_initBreadcrumb()
    elseif self.chips and #self.chips > 0 then
        self:_initChips()
    else
        self[1] = require("ui/widget/widget"):new{ dimen = self.dimen }
    end
    self.ges_events = {
        TapStrip   = { GestureRange:new{ ges = "tap",   range = self.dimen } },
        HoldStrip  = { GestureRange:new{ ges = "hold",  range = self.dimen } },
        SwipeStrip = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
end

-- ─── Default chips mode ─────────────────────────────────────────────────────

-- Nerd-font fa-chevron-left (U+F053) and fa-chevron-right (U+F054).
local CHEVRON_PREV = "\xEF\x81\x93"
local CHEVRON_NEXT = "\xEF\x81\x94"

-- Measure the natural pixel width of a flex chip (no max_width constraint).
-- Used both for pagination planning and proportional flex allocation.
local function measureNatural(chip, height, scaled_fn)
    local pad = Size.padding.large
    if chip.nerd_glyph then
        local ng_face, ng_bold = _iconFace(scaled_fn(18))
        local tw = TextWidget:new{
            text = chip.nerd_glyph,
            face = ng_face,
            bold = ng_bold,
        }
        local w = tw:getSize().w + 2 * pad
        tw:free()
        return w
    elseif chip.icon then
        return math.floor(height * 0.75) + 2 * pad
    else
        return _measureLabel(chip.label or "", scaled_fn(16)) + 2 * pad
    end
end

function ChipBar:_initChips()
    self._chip_dimens = {}

    local paper       = Blitbuffer.COLOR_WHITE
    local LineWidget  = require("ui/widget/linewidget")
    local separator_w = Size.border.thin

    -- Fixed-width action chips (search, currently-reading, etc.).
    -- 1.6x strip height so the tap target is comfortable on touch.
    local action_w = math.floor(self.height * 1.6)
    local flex_indices = {}   -- indices into self.chips of non-action chips, in order
    for i, c in ipairs(self.chips) do
        if not c.action then flex_indices[#flex_indices + 1] = i end
    end
    local action_count = #self.chips - #flex_indices

    -- Measure every flex chip's natural width (used for pagination + flex allocation).
    local flex_naturals = {}   -- flex_naturals[j] = natural width of flex_indices[j]-th chip
    for j, idx in ipairs(flex_indices) do
        flex_naturals[j] = measureNatural(self.chips[idx], self.height, _scaled)
    end

    -- Page chevrons are narrower than the action buttons: a chevron glyph
    -- needs far less width than search/current, and a slimmer cell keeps the
    -- chip area roomier (a comfortable tap target remains, and swipe also pages).
    local chevron_w = math.floor(self.height * 1.1)
    self._chevron_w = chevron_w

    -- Pagination: avail is the room left for flex chips + any chevrons after
    -- the fixed action slots and their separators. Pages reserves chevron_w on
    -- pages with a neighbour and accounts for inter-chip spacing.
    local avail = self.width - action_w * action_count - separator_w * action_count

    self._pages = Pages.paginate{
        widths    = flex_naturals,
        spacing   = separator_w,
        avail     = avail,
        chevron_w = chevron_w,
    }

    -- Determine current page from selected_key (active chip key).
    -- Derive flex-order index of the selected chip.
    local active_key = self.selected_key or self.active
    local selected_flex_j = nil
    for j, idx in ipairs(flex_indices) do
        if self.chips[idx].key == active_key then
            selected_flex_j = j
            break
        end
    end
    if self._page == nil then
        if selected_flex_j then
            self._page = Pages.pageOf(self._pages, selected_flex_j)
        else
            self._page = 1
        end
    end
    -- Clamp to valid range.
    local num_pages = math.max(1, self._pages.num_pages)
    if self._page < 1 then self._page = 1 end
    if self._page > num_pages then self._page = num_pages end

    self:_buildChipRow(flex_indices, flex_naturals, action_w, separator_w, paper, LineWidget)
end

-- Build (or rebuild) the chip row for the current self._page.
-- Called by _initChips on first build and by _gotoPage on page change.
function ChipBar:_buildChipRow(flex_indices, flex_naturals, action_w, separator_w, paper, LineWidget)
    self._band_w = nil   -- chips fill the strip; only breadcrumb mode narrows it
    -- Allow callers to pass nil when re-entering from _gotoPage, which
    -- stores the computed values on self for reuse.
    if flex_indices == nil then
        flex_indices  = self._flex_indices
        flex_naturals = self._flex_naturals
        action_w      = self._action_w
        separator_w   = Size.border.thin
        paper         = Blitbuffer.COLOR_WHITE
        LineWidget    = require("ui/widget/linewidget")
    else
        -- Stash for later reuse by _gotoPage.
        self._flex_indices  = flex_indices
        self._flex_naturals = flex_naturals
        self._action_w      = action_w
    end

    local page_info  = self._pages
    local cur_page   = self._page or 1
    local show_prev  = page_info.multi and cur_page > 1
    local show_next  = page_info.multi and cur_page < page_info.num_pages

    -- Visible flex range (indices into flex_indices / flex_naturals).
    local vis_first, vis_last
    if page_info.num_pages == 0 then
        vis_first, vis_last = 1, 0  -- empty
    else
        local pg = page_info.pages[cur_page] or { first = 1, last = 0 }
        vis_first = pg.first
        vis_last  = pg.last
    end

    -- Build render_chips: leading action chips, optional prev-chevron,
    -- visible flex chips, optional next-chevron, trailing action chips.
    -- "Leading" = action chips before the first flex chip in self.chips;
    -- "trailing" = action chips after the last flex chip.
    local first_flex_idx = flex_indices[1] or (#self.chips + 1)
    local last_flex_idx  = flex_indices[#flex_indices] or 0
    local render_chips = {}
    -- Leading action chips.
    for i, chip in ipairs(self.chips) do
        if chip.action and i < first_flex_idx then
            render_chips[#render_chips + 1] = chip
        end
    end
    -- Prev-chevron synthetic chip.
    if show_prev then
        render_chips[#render_chips + 1] = {
            key       = "__chip_prevpage",
            nerd_glyph = CHEVRON_PREV,
            action    = true,
            _page_dir = "prev",
        }
    end
    -- Visible flex chips.
    for j = vis_first, vis_last do
        local chip_idx = flex_indices[j]
        if chip_idx then
            render_chips[#render_chips + 1] = self.chips[chip_idx]
        end
    end
    -- Next-chevron synthetic chip.
    if show_next then
        render_chips[#render_chips + 1] = {
            key       = "__chip_nextpage",
            nerd_glyph = CHEVRON_NEXT,
            action    = true,
            _page_dir = "next",
        }
    end
    -- Trailing action chips.
    for i, chip in ipairs(self.chips) do
        if chip.action and i > last_flex_idx then
            render_chips[#render_chips + 1] = chip
        end
    end

    -- Chevron cells are narrower than the action buttons (see _initChips).
    local chevron_w = self._chevron_w or action_w
    -- Sum the fixed (action + chevron) widths so the visible flex chips can
    -- claim exactly the rest. Chevrons (chip._page_dir) use chevron_w; real
    -- action chips use action_w.
    local n_render  = #render_chips
    local fixed_total = 0
    for _, chip in ipairs(render_chips) do
        if chip._page_dir then
            fixed_total = fixed_total + chevron_w
        elseif chip.action then
            fixed_total = fixed_total + action_w
        end
    end

    -- Flex width available to visible flex chips in render_chips.
    local sep_total_render = separator_w * (n_render - 1)
    local flex_render_total = self.width - sep_total_render - fixed_total

    -- Per-chip widths for rendered entries. Chevrons get chevron_w, other
    -- action chips action_w; visible flex chips share flex_render_total using
    -- the same equal-share / proportional logic as before.
    local render_widths = {}
    local flex_render_indices = {}  -- indices into render_chips of flex entries
    for ri, chip in ipairs(render_chips) do
        if chip._page_dir then
            render_widths[ri] = chevron_w
        elseif chip.action then
            render_widths[ri] = action_w
        else
            flex_render_indices[#flex_render_indices + 1] = ri
        end
    end

    local use_flex = BookshelfSettings.isTrue("chip_flex_widths")
    local n_flex_r = math.max(1, #flex_render_indices)

    if use_flex and #flex_render_indices > 0 then
        -- Proportional allocation using the natural widths of the visible
        -- flex chips (already measured in flex_naturals).
        local vis_naturals = {}
        local total_nat = 0
        for ri_pos, ri in ipairs(flex_render_indices) do
            -- Find the flex_naturals index for this chip.
            local chip_key = render_chips[ri].key
            local nat = 0
            for j, idx in ipairs(flex_indices) do
                if self.chips[idx].key == chip_key then
                    nat = flex_naturals[j] or 0
                    break
                end
            end
            vis_naturals[ri_pos] = nat
            total_nat = total_nat + nat
        end
        if total_nat > 0 then
            local scale = flex_render_total / total_nat
            local accumulated = 0
            for pos, ri in ipairs(flex_render_indices) do
                if pos == #flex_render_indices then
                    render_widths[ri] = flex_render_total - accumulated
                else
                    local w = math.floor(vis_naturals[pos] * scale + 0.5)
                    render_widths[ri] = w
                    accumulated = accumulated + w
                end
            end
        else
            -- Fallback to equal share.
            local equal = math.floor(flex_render_total / n_flex_r)
            for pos, ri in ipairs(flex_render_indices) do
                if pos == #flex_render_indices then
                    render_widths[ri] = flex_render_total - equal * (n_flex_r - 1)
                else
                    render_widths[ri] = equal
                end
            end
        end
    else
        -- Equal share.
        local equal = math.floor(flex_render_total / n_flex_r)
        for pos, ri in ipairs(flex_render_indices) do
            if pos == #flex_render_indices then
                render_widths[ri] = flex_render_total - equal * (n_flex_r - 1)
            else
                render_widths[ri] = equal
            end
        end
    end

    -- Resolve a chip's fill-state — action chips invert via .selected,
    -- navigable chips via key-equals-active. Used to color separators
    -- between adjacent inverted chips (otherwise a black separator
    -- between two black chips is invisible and they merge).
    -- Chevron chips are never filled.
    local function isFilled(c)
        if c._page_dir then return false end  -- chevrons never fill
        if c.action then return c.selected and true or false end
        return c.key == self.active
    end

    local row = HorizontalGroup:new{}
    self._chip_dimens = {}

    -- A chip that draws an outline of its own. Its neighbours need to know:
    -- two of them meeting would otherwise draw two outlines and a separator
    -- into the one boundary.
    local function _isButton(c)
        return (c and isFilled(c) and not c._page_dir) and true or false
    end
    for i, chip in ipairs(render_chips) do
        if i > 1 then
            -- Between two filled chips the separator has to contrast with
            -- the FILL, which is not always black (see _separatorOnFill);
            -- anywhere else it sits on paper and is black.
            local prev_filled = isFilled(render_chips[i - 1])
            local cur_filled  = isFilled(chip)
            -- THREE CASES, because a 1px column between two chips can only
            -- be one colour and its neighbours are not always the same.
            --
            --   both filled   contrast with the FILL (see _separatorOnFill).
            --   neither       contrast with the STRIP: a white rule on a dark
            --                 bar, black on a light one.
            --   one of each   the strip's OWN colour. The active chip is an
            --                 inversion of the frame, so it is always the
            --                 opposite of the strip. A strip-coloured line
            --                 merges into the unfilled neighbour -- which IS
            --                 the strip, so there is nothing to divide there
            --                 -- and shows against the filled one, which is
            --                 where the edge is actually wanted. Taking the
            --                 ink here painted white onto the white active
            --                 chip, and the border beside Home went missing
            --                 (maintainer, on device).
            -- A separator next to the chip being tapped is part of that
            -- tap's ring, not a division. The ring already reaches over the
            -- column on both sides, but the separator BEFORE a chip is
            -- painted before it and the one after is painted after -- so on
            -- the right the separator won and showed as a second edge beside
            -- the ring. Only when selecting leftwards, which is how it came
            -- in (maintainer, on a PW5). Colouring it settles it whichever
            -- way round the two are painted.
            local function _touchesTap(c)
                if not c then return false end
                return c.key == self._pending_key or c.key == self.focused_key
            end
            local sep_color
            if _touchesTap(render_chips[i - 1]) or _touchesTap(chip) then
                sep_color = _stripInk()
            elseif prev_filled and cur_filled then
                -- _separatorOnFill answers WHITE for a nil fill, which is the
                -- DEFAULT case: no custom chip colour set. That was right
                -- while a filled chip could only be black, and wrong the
                -- moment the shelf could be dark -- on device it painted a
                -- white rule between two white chips, which is where the
                -- border beside Home went (maintainer; the probe read
                -- sep_lum=255 with strip_ground_lum=0).
                --
                -- With no custom colour the fill is an INVERSION of the
                -- frame, so it is always the opposite of the strip -- which
                -- makes the strip's own colour the line that shows on it,
                -- the same answer the one-filled case reaches.
                --
                -- Both are BUTTONS since 2026-09-19 and neither draws the
                -- side facing this column (no_l / no_r below), so this one
                -- pixel IS the line between them. It still has to CONTRAST
                -- with the fill rather than match the outline: taking the
                -- outline's black put black between two inverted chips,
                -- which are black themselves, and the line vanished
                -- (maintainer, on a PW5). The two answers below already
                -- solve exactly that, one per kind of fill.
                local custom = _selectedChipColors()
                sep_color = (type(custom) ~= "nil")
                            and _separatorOnFill(custom)
                            or  _stripGround()
            elseif prev_filled or cur_filled then
                sep_color = _stripGround()
            else
                sep_color = _stripInk()
            end
            row[#row + 1] = LineWidget:new{
                background = sep_color,
                dimen = Geom:new{ w = separator_w, h = self.height },
            }
        end
        local is_active  = isFilled(chip)
        local is_pending = self._pending_key == chip.key
        local w = render_widths[i]
        local cell_content
        -- Custom colour (#294) only applies to the SELECTED state -- that is
        -- the black fill the request is about; unselected chips already render
        -- as plain black-on-paper and need no colour work.
        local is_cursor_pre = (self.focused_key == chip.key)
        local want_custom = is_active and not is_cursor_pre
        local fill_c, ink_c
        if want_custom then fill_c, ink_c = _activeChipColors() end
        -- Plain boolean, NOT `fill_c == nil`: Blitbuffer colours are ffi cdata
        -- with an __eq metamethod, and comparing one to nil routes through it
        -- and crashes indexing the nil operand (same trap bookshelf_color's
        -- parseColorValue documents).
        local has_custom = (type(fill_c) ~= "nil")
        -- _chipInk(), not hard black: on a manually dark shelf the strip below
        -- is filled with chrome_bg, which the theme flips to black, and a
        -- black label on it is invisible. Only the ACTIVE chip showed, because
        -- that one inverts itself; every other chip, the currently-reading
        -- glyph and the search icon were painted and unreadable.
        local ink = ink_c or _chipInk()
        if chip.nerd_glyph then
            local cc_face, cc_bold = _iconFace(_scaled(18))
            cell_content = TextWidget:new{
                text    = chip.nerd_glyph,
                face    = cc_face,
                bold    = cc_bold,
                fgcolor = ink,
            }
        elseif chip.icon then
            local IconWidget = require("ui/widget/iconwidget")
            local icon_size  = math.floor(self.height * 0.75)
            cell_content = IconWidget:new{
                icon   = chip.icon,
                width  = icon_size,
                height = icon_size,
            }
        else
            cell_content = _buildLabelContent(
                chip.label or "",
                _scaled(16),
                w - 2 * Size.padding.small,
                ink)
        end
        local is_cursor = is_cursor_pre
        -- An action chip that points at the hero (currently reading, micro
        -- modules) is a BUTTON, and the breadcrumb layout draws that same
        -- button inside a frame of its own. Here it had none: on a
        -- wallpapered shelf, where the strip's own edge is the theme's
        -- near-white ink, the filled cell simply ended -- a white block with
        -- no edge, next to a drilled-in copy of itself that was cleanly
        -- outlined. Reported from a PW5 with both on screen.
        --
        -- Same frame, same colour rule, so the two cannot drift: black once
        -- the cell is painted for real, the strip's own ink otherwise.
        -- An action chip that points at the hero (currently reading, micro
        -- modules) is a BUTTON, and the breadcrumb layout draws that same
        -- button with a frame of its own. Here the cell had none and leaned
        -- on the strip's outline for its edge -- which on a wallpapered
        -- shelf is the theme's near-white ink, so a filled cell simply
        -- ended. Reported from a PW5 with the drilled-in copy, cleanly
        -- outlined, on the same screen.
        --
        -- Same builder, so there is nothing left to drift. It is placed a
        -- border OUTSIDE the cell, over the strip's own edge, rather than
        -- inside it: a frame within the cell leaves that edge showing as a
        -- second, lighter line around the first -- "a white border outside
        -- the black border". Landing on the edge replaces it, and the body
        -- inside still measures exactly w by self.height.
        -- EVERY filled chip, not just the ones with a roof. The selected
        -- shelf reads as a button in exactly the way the currently-reading
        -- one does, and the maintainer asked for the same border on it.
        local wants_button = is_active and not chip._page_dir
        local chip_body
        if wants_button then
            local bb = Size.border.thin
            chip_body = _actionButton{
                content = cell_content,
                w       = w,
                h       = self.height,
                fill    = has_custom and fill_c
                          or ((is_active and not is_cursor) and paper or nil),
                invert  = is_active and not is_cursor and not has_custom,
                border  = has_custom and Blitbuffer.COLOR_BLACK or _stripInk(),
                -- Top and bottom always touch the strip's edge; left only for
                -- the first chip and right only for the last. Anywhere else a
                -- SEPARATOR lies beyond, and it has to keep its contrasting
                -- line -- without that the button and the chip beside it run
                -- together whenever both are filled the same way (maintainer,
                -- currently reading against a selected shelf on a PW5).
                out     = {
                    t = bb, b = bb,
                    l = (i == 1) and bb or 0,
                    r = (i == #render_chips) and bb or 0,
                    -- and where the neighbour is another button, leave the
                    -- facing side to the separator between them
                    no_l = _isButton(render_chips[i - 1]),
                    no_r = _isButton(render_chips[i + 1]),
                },
                -- ...but only an ACTION chip points at the hero. A shelf chip
                -- is a destination, not a control over what is above.
                pointer = chip.action and {
                    -- The pointer is an extension of the chip's silhouette,
                    -- so it follows the chip's own fill (#294). Black is what
                    -- the invert path produces, hence the default.
                    color   = has_custom and fill_c or Blitbuffer.COLOR_BLACK,
                    -- Only for a custom fill: the default fill is the same
                    -- black as the border, so an outline would draw black on
                    -- black and change nothing.
                    outline = has_custom and Blitbuffer.COLOR_BLACK or nil,
                } or nil,
            }
        else
            chip_body = InvertedFrame:new{
                -- A custom colour is painted for real, so the inversion that
                -- normally produces the selected look must be off for this chip.
                _invert    = is_active and not is_cursor and not has_custom,
                bordersize = 0,
                margin     = 0,
                padding    = 0,
                -- An inactive chip has no fill: the strip's ground shows
                -- through, a wallpaper included. The ACTIVE chip keeps a real
                -- one: its selected look is an INVERSION of the frame, so it
                -- needs an opaque ground to invert -- inverting the wallpaper
                -- would give a negative-photo chip. A custom colour is kept
                -- for the same reason.
                --
                -- (a99989f meant inactive chips to stay white off a wallpaper,
                -- through a local of _initChips; the split into _buildChipRow
                -- in 95e7496 left it out of scope, so since v5.1.2 they have
                -- had no fill everywhere, and later work was tuned to that.)
                background = has_custom and fill_c
                             or ((is_active and not is_cursor) and paper or nil),
                CenterContainer:new{
                    dimen = Geom:new{ w = w, h = self.height },
                    cell_content,
                },
            }
        end
        local chip_slot = chip_body
        if is_pending or is_cursor then
            local pb = Size.border.thick
            local rb = Size.border.thin
            -- The "we heard you" ring while a chip loads. It has to be seen,
            -- and black on a dark strip is not: it was drawing, it just
            -- matched the bar (maintainer). _stripInk is black on a light
            -- strip, which is what it always was.
            --
            -- Laid on the strip's own edge, like a button's outline, rather
            -- than inside the cell. Inside it, drawn flush, its top and
            -- bottom ran into that edge and the two read as one fat line;
            -- held a border clear of it instead, the gap between them showed
            -- as a thin light line all the way round. Landing on the edge
            -- REPLACES it, which is neither.
            local ring = EdgeRing:new{
                width  = w,
                height = self.height,
                color  = _stripInk(),
                bw     = pb,
                out_t  = rb, out_b = rb,
                -- Out to the strip's edge at the ends of the row, and over
                -- the SEPARATOR everywhere else. Stopped at the cell, the
                -- separator stayed visible as an extra line between the ring
                -- and the chip before it -- two edges where the tap should
                -- read as one (maintainer, on a PW5). Taking the column in
                -- butts the ring straight up against the neighbour.
                out_l  = (i == 1) and rb or separator_w,
                out_r  = (i == #render_chips) and rb or separator_w,
            }
            chip_slot = OverlapGroup:new{
                dimen = Geom:new{ w = w, h = self.height },
                chip_body,
                ring,
            }
        end
        row[#row + 1] = chip_slot
        local prev_chip = render_chips[i - 1]
        local prev_d = prev_chip and self._chip_dimens[prev_chip.key]
        local x = prev_d and (prev_d.x + prev_d.w + separator_w) or 0
        self._chip_dimens[chip.key] = { x = x, w = w }
    end
    -- The strip's outline. FrameContainer defaults its border to BLACK,
    -- which on a manually dark shelf is a black line on a black ground --
    -- the strip lost its edge entirely (maintainer, on device).
    self[1] = FrameContainer:new{
        bordersize = Size.border.thin,
        color      = _stripInk(),
        margin     = 0,
        padding    = 0,
        row,
    }
end

-- Navigate to a specific page. Rebuilds the chip row in place and marks
-- the strip dirty. Clamps p to [1, num_pages].
function ChipBar:_gotoPage(p)
    if not self._pages then return end
    local num_pages = math.max(1, self._pages.num_pages)
    if p < 1 then p = 1 end
    if p > num_pages then p = num_pages end
    if p == self._page then return end
    local old_page = self._page
    self._page = p
    self:_buildChipRow()

    -- Page-turn wipe animation, matching the shelf (e-ink only, same setting).
    -- Screen.bb still holds the OLD strip here (building the row above only
    -- swapped the in-memory widget tree, nothing painted), so copy it, paint
    -- the rebuilt row in, copy that, and wipe between. forward = paging to a
    -- higher page reveals from the right, matching the shelf and the chevron
    -- directions. Paint ONLY self[1] (the chip strip) — never the parent, which
    -- would re-paint the hero's one-shot cover_bb (freed after first paint).
    -- Any failure falls through to the plain scoped refresh below.
    local anim_steps = PageWipe.resolveSteps()
    local wiped = false
    -- The refresh region must cover the PAINTED strip, not self.dimen: the
    -- row sits inside a Size.border.thin FrameContainer, so the paint is
    -- 2*border wider AND taller than the declared box. A region built from
    -- self.dimen left the border band - including the bottom rows of the
    -- previously selected (inverted) chip - showing the old frame after a
    -- page flip: issue 352's ghost line.
    local painted = self[1] and self[1].getSize and self[1]:getSize() or nil
    local region_w = math.max(self.dimen and self.dimen.w or 0, painted and painted.w or 0)
    local region_h = math.max(self.dimen and self.dimen.h or 0, painted and painted.h or 0)
    if anim_steps and self.show_parent and self.dimen
            and region_w > 0 then
        local region = Geom:new{
            x = self.dimen.x, y = self.dimen.y,
            w = region_w, h = region_h }
        wiped = pcall(function()
            -- Offscreen, for the reason the shelf wipe gives: the screen keeps
            -- the outgoing row so the wipe can reveal over it, and no page has
            -- to be read back out of the framebuffer. Painted at the strip's
            -- own position, so source and destination coincide; the rest of
            -- the buffer is never read.
            local new_bb = Blitbuffer.new(Screen.bb:getWidth(), Screen.bb:getHeight(),
                                          Screen.bb:getType())
            -- Blitbuffer.new callocs, so this starts BLACK, and the strip does
            -- not cover every pixel of the region the wipe reveals. That never
            -- showed while chips were opaque white cards on a white page; over
            -- a wallpaper it swiped the bar to black. Lay the backdrop down
            -- first -- the wallpaper if there is one, the page ground if not.
            local ok_wp, Wallpaper = pcall(require, "lib/bookshelf_wallpaper")
            if not (ok_wp and Wallpaper.backdrop and Wallpaper.backdrop(new_bb, region)) then
                new_bb:paintRect(region.x, region.y, region.w, region.h,
                                 Blitbuffer.COLOR_WHITE)
            end
            -- Then the strip's own ground, exactly as paintTo lays it down.
            -- The backdrop above is the raw wallpaper; without this the bar
            -- loses its fill for the length of the swipe and the chips wipe
            -- across bare picture. Over the whole REGION, not just the strip:
            -- the region runs 2*border wider on each side, and filling only
            -- the strip would leave that band a different colour mid-wipe.
            self:_paintGround(new_bb, region.x, region.y, region.w, region.h)
            self[1]:paintTo(new_bb, self.dimen.x, self.dimen.y)
            PageWipe.run(Screen, new_bb, region, p > old_page, anim_steps)
            new_bb:free()
        end)
    end
    if not wiped and self.show_parent and self.dimen then
        UIManager:setDirty(self.show_parent, function()
            return "ui", Geom:new{
                x = self.dimen.x, y = self.dimen.y,
                w = region_w, h = region_h }
        end)
    end
    -- Let the host pre-warm the chips this page (and the next) just revealed.
    if self.on_page_change then self.on_page_change() end
end

-- setCurrentSelected(sel): flip the currently-reading action chip's fill
-- (and its up-pointer) in place, rebuilding just this bar's row -- the
-- same in-place pattern _gotoPage uses. Lets the host restyle the strip
-- at a preview boundary without a full shelf rebuild, in the SAME cycle
-- as the hero swap (the deferred rebuild made the chip visibly lag the
-- hero). Does NOT paint or refresh; the caller owns that.
-- Returns true when the row was re-rendered, false when the state already
-- matched (nothing to paint), nil when this bar has no such chip or was
-- never rendered in a re-enterable mode (caller should fall back to a
-- full restyle).
function ChipBar:setCurrentSelected(sel)
    sel = sel and true or false
    local target
    for _, c in ipairs(self.chips or {}) do
        if c.action and c.key == "current" then
            target = c
            break
        end
    end
    if not target then return nil end
    if (target.selected and true or false) == sel then return false end
    target.selected = sel
    if self.breadcrumb_path and #self.breadcrumb_path > 0 then
        self:_initBreadcrumb()
    elseif self._flex_indices then
        self:_buildChipRow()
    else
        target.selected = not sel
        return nil
    end
    return true
end

-- warmKeys(): nav (flex) chip keys worth pre-warming from where we are now --
-- the current page plus the next one (forward-swipe bias). Single-page bars
-- return every nav chip (same set the old all-chips warm used). Action chips
-- and chevrons are excluded (no shelf to build). Used by the host's page-bounded
-- pre-warm so warm cost is O(page), not O(total chips).
function ChipBar:warmKeys()
    if not self._pages or not self._flex_indices then return {} end
    local out, seen = {}, {}
    local function addPage(p)
        local range = self._pages.pages[p]
        if not range then return end
        for j = range.first, range.last do
            local idx  = self._flex_indices[j]
            local chip = idx and self.chips[idx]
            if chip and chip.key and not seen[chip.key] then
                seen[chip.key] = true
                out[#out + 1] = chip.key
            end
        end
    end
    addPage(self._page or 1)
    addPage((self._page or 1) + 1)
    return out
end

-- ─── Breadcrumb mode ────────────────────────────────────────────────────────
--
-- Layout: [chip_pill] > crumb1 > crumb2 > … > crumbN
--
-- Pill has the same metrics as a normal chip cell (single-chip width).
-- Crumbs render with a chevron separator. We track each tappable region's
-- x-range in self._breadcrumb_zones (which the unified TapStrip handler
-- resolves) so the existing tap pipeline keeps working in both modes.

function ChipBar:_initBreadcrumb()
    -- Layout: [optional currently-reading icon] + chip pill + (parents
    -- as CHAINED, OVERLAPPING arrow pills) + small gap + the deepest
    -- crumb as plain text. When parents are truncated to fit the strip
    -- width, an ELLIPSIS pill (also chained) replaces the dropped run
    -- between the chip pill and the first visible parent.
    --
    -- The currently-reading icon (action chip key = "current") stays
    -- visible across both modes — in drilldown the user otherwise has
    -- to back out to top level before they can reach it (#55). Tap
    -- routes to on_change("current") which clears the drill path AND
    -- resets the hero to the lastfile.
    local face_text, face_text_bold = BFont:getFace("infofont", _scaled(16), { bold = true })
    local n         = #self.breadcrumb_path
    -- Everything in this band is this tall, and the band has no frame of its
    -- own. The chips band's frame is what gives its rows an edge, because a
    -- chip only draws one when it is filled; here the button and every pill
    -- carry their own. A frame around them put its line immediately outside
    -- theirs and the border came out 2px, against 1px everywhere else
    -- (maintainer, on a PW5). The +2*border keeps the band's painted height
    -- equal to the chips band's, so the button does not move between modes.
    local band_b = Size.border.thin
    local band_h = self.height + 2 * band_b

    -- Pull the currently-reading chip from the chips list. Renders as
    -- a fixed-width icon box matching the chips-mode action width so
    -- the affordance has the same visual weight in both modes.
    local current_chip
    for _i, c in ipairs(self.chips or {}) do
        if c.action and c.key == "current" then
            current_chip = c
            break
        end
    end
    local current_widget, current_w
    if current_chip then
        current_w = math.floor(self.height * 1.6)
        local glyph_face, glyph_bold = _iconFace(_scaled(18))
        -- Action chips (currently reading / search / micro-modules) use the same
        -- selected language as the chips, so they honour the same colour (#294).
        local act_fill, act_ink
        if current_chip.selected then
            act_fill, act_ink = _activeChipColors()
        end
        local act_has = (type(act_fill) ~= "nil") -- see has_custom above (ffi __eq)
        -- The same button the strip draws, from the same builder -- the two
        -- have to be indistinguishable, and building them separately is what
        -- let them drift apart before. Only the ground differs: here it is
        -- the shelf, so an unfilled button still wants an opaque cell.
        current_widget = _actionButton{
            content = TextWidget:new{
                text    = current_chip.nerd_glyph or "",
                face    = glyph_face,
                bold    = glyph_bold,
                fgcolor = act_ink or Blitbuffer.COLOR_BLACK,
            },
            w       = current_w,
            h       = band_h,
            fill    = act_has and act_fill or Blitbuffer.COLOR_WHITE,
            invert  = current_chip.selected and not act_has,
            border  = act_has and Blitbuffer.COLOR_BLACK or _stripInk(),
            -- Its outline IS the band's edge here, so it reaches nowhere.
            -- The pill to its right carries one too, and one of the two has
            -- to give way or the divider between them comes out 2px.
            out     = { no_r = true },
            pointer = current_chip.selected and {
                color   = act_has and act_fill or Blitbuffer.COLOR_BLACK,
                outline = act_has and Blitbuffer.COLOR_BLACK or nil,
            } or nil,
        }
    end

    -- Arrow-left prefix is reserved for the explicit Back pill in search
    -- mode — the chevron separator between chained pills already implies
    -- hierarchy, so prefixing every crumb with another arrow read as
    -- visual noise without adding meaning. Nerdfont fa-arrow-left
    -- (U+F060), threaded through the same xtext font-fallback path that
    -- renders the search glyph.
    local ARROW_LEFT = "\xEF\x81\xA0"

    -- Optional Back pill before the chip pill — fires on_breadcrumb(-1)
    -- so the parent widget can interpret "user wants out of this drill"
    -- as something different from "user wants to tap the chip pill"
    -- (which in search mode now means "edit the query"). Used only by
    -- search mode today; non-search drilldowns leave back_label nil and
    -- the strip starts straight with the chip pill as before.
    local back_pill, back_pill_w
    local has_back = type(self.back_label) == "string" and self.back_label ~= ""
    if has_back then
        local back_text = ARROW_LEFT .. " " .. self.back_label
        back_pill, back_pill_w = arrowPillFrame(back_text, band_h, false)
    end

    -- Chip pill at depth 0 (e.g. "HOME"). chained=true when there's a
    -- Back pill before it so the two visually butt together; otherwise
    -- the chip pill is chained=false (full border) as the strip's leftmost
    -- element. chip_pill_glyph wins over chip_pill_label when set: search
    -- mode replaces the chip name with the search icon so the user sees
    -- they're in a separate "search" context, not nested under their
    -- previously-active chip.
    local pill, pill_w, pill_tip_w = arrowPillFrame(
        self.chip_pill_label or "", band_h, has_back, self.chip_pill_glyph)

    -- Chained pills for parent entries (1..n-1).
    local crumb_pills = {}
    for i = 1, n - 1 do
        local label = (self.breadcrumb_path[i].label or ""):gsub("/$", "")
        local cp_widget, cp_w, cp_tip_w = arrowPillFrame(label, band_h, true)
        crumb_pills[#crumb_pills + 1] = {
            widget = cp_widget,
            width  = cp_w,
            tip_w  = cp_tip_w,
            depth  = i,
        }
    end

    -- Plain-text widget for the deepest crumb (the current folder).
    local deepest_widget, deepest_w
    if n >= 1 then
        local deepest_label = (self.breadcrumb_path[n].label or ""):gsub("/$", "")
        deepest_widget = TextWidget:new{
            text    = deepest_label,
            face    = face_text,
            bold    = face_text_bold,
            -- Themed, now this sits on the panel rather than on a white bar:
            -- hard black would vanish on a dark shelf.
            fgcolor = (function()
                local ok, CP = pcall(require, "lib/bookshelf_cover_progress")
                if ok and CP and CP.ink then
                    local c = CP.ink()
                    if c then return c end
                end
                return Blitbuffer.COLOR_BLACK
            end)(),
        }
        deepest_w = deepest_widget:getSize().w
    end

    -- Layout helper. Pills lay out adjacently in HorizontalGroup but
    -- the chained pills' placement_w EXCLUDES the right tip, so each
    -- pill's tip overhangs into the next pill's notch area — pills
    -- visually overlap by tip_w and chain together.
    local function build(visible_pills)
        -- The BAND: the currently-reading button and the pill trail, inside
        -- the same framed, grounded strip the chips row gets. The deepest
        -- crumb is NOT in it -- it is the name of where you are, not another
        -- control, and the maintainer asked for it to sit on the shelf the
        -- way the status line does rather than on a slab of its own.
        local band   = HorizontalGroup:new{}
        local row    = band
        local zones  = {}
        local cursor = 0
        if current_widget then
            row[#row + 1] = current_widget
            -- depth = -2 is the sentinel for "currently reading" action.
            -- The TapStrip handler dispatches it via on_change("current")
            -- so the same code path runs in both chip-bar modes.
            zones[#zones + 1] = { x = cursor, w = current_w, depth = -2 }
            cursor = cursor + current_w
        end
        if has_back then
            row[#row + 1] = back_pill
            zones[#zones + 1] = { x = cursor, w = back_pill_w, depth = -1 }
            cursor = cursor + back_pill_w
        end
        row[#row + 1] = pill
        zones[#zones + 1] = { x = cursor, w = pill_w, depth = 0 }
        cursor = cursor + pill_w
        for _i, cp in ipairs(visible_pills) do
            row[#row + 1] = cp.widget
            zones[#zones + 1] = { x = cursor, w = cp.width, depth = cp.depth }
            cursor = cursor + cp.width
        end
        local band_w = cursor             -- where the trail ends
        local outer = HorizontalGroup:new{ band }
        if deepest_widget then
            -- Plain text for the active folder. Gap = tip_w + large
            -- inset so the text sits well clear of the last pill's
            -- tip apex, mirroring the breathing room a chained pill
            -- gives its own text via the extra-tip_w left padding.
            local gap_w = pill_tip_w + Size.padding.large
            outer[#outer + 1] = HorizontalSpan:new{ width = gap_w }
            cursor = cursor + gap_w
            outer[#outer + 1] = deepest_widget
            -- Register a tap zone for the deepest crumb. The previous
            -- behaviour left it inert (depth = #path was a no-op for
            -- _drillBackTo), but search mode now uses this as a second
            -- "edit query" affordance alongside the chip pill.
            zones[#zones + 1] = { x = cursor, w = deepest_w, depth = n }
            cursor = cursor + deepest_w
        end
        -- the band's width, so paintTo can keep its ground off the crumb
        return outer, zones, cursor, band_w
    end

    -- Try to fit all parents. If the chain overflows, drop the
    -- earliest parent and replace the dropped run with a SINGLE
    -- ellipsis pill (chained, label "…"). Repeat until the chain
    -- fits the strip. The ellipsis pill, when present, taps to the
    -- depth of the FIRST hidden parent so the user can pop back into
    -- the truncated middle.
    local first_visible = 1
    local row, zones, total_w, band_w
    while true do
        local visible = {}
        if first_visible > 1 then
            local ep, ew, etw = arrowPillFrame("…", band_h, true)
            visible[1] = {
                widget = ep,
                width  = ew,
                tip_w  = etw,
                depth  = first_visible - 1,
            }
        end
        for i = first_visible, #crumb_pills do
            visible[#visible + 1] = crumb_pills[i]
        end
        row, zones, total_w, band_w = build(visible)
        if total_w <= self.width then break end
        if first_visible > #crumb_pills then break end
        first_visible = first_visible + 1
    end

    -- D-pad focus ring: overlay a thick border on the focused zone.
    -- The ring is a transparent-interior FrameContainer placed via
    -- overlap_offset so it doesn't alter layout dimensions.
    if self.focused_depth ~= nil then
        for _i, z in ipairs(zones) do
            if z.depth == self.focused_depth then
                local pb = Size.border.thick
                local ring = FrameContainer:new{
                    bordersize = pb,
                    color      = Blitbuffer.COLOR_BLACK,
                    margin     = 0, padding = 0,
                    Widget:new{ dimen = Geom:new{ w = z.w - 2*pb, h = band_h - 2*pb } },
                }
                ring.overlap_offset = { z.x, 0 }
                row = OverlapGroup:new{
                    dimen = Geom:new{ w = self.width, h = band_h },
                    row, ring,
                }
                break
            end
        end
    end
    self._breadcrumb_zones = zones
    -- How far the ground reaches. Chips mode fills the strip; here it stops
    -- at the end of the trail so the deepest crumb keeps the shelf behind it.
    self._band_w = band_w
    self[1] = row
end

-- ─── Pre-paint feedback ─────────────────────────────────────────────────────
-- flashPending(key): paint a black border around the named chip RIGHT
-- NOW, before the caller's heavy work runs. Use this when a tap or swipe
-- is about to trigger a slow tab switch — gives the user instant visual
-- confirmation that their input was received.
--
-- Must be called before the work that will trigger _rebuild (which
-- destroys this strip instance). The border clears automatically when
-- the rebuild swaps in a fresh strip.
--
-- Why each step is here:
--   * _initChips rebuilds the widget tree because chip colors are
--     baked into the FrameContainer at build time, not read at paint
--     time — flipping _pending_key alone would repaint the same baked
--     bg/border.
--   * setDirty must target show_parent (the window-level widget);
--     ChipBar itself is a subwidget so setDirty(self, ...) is a
--     no-op for the dirty flag.
--   * "fast" = A2 binary waveform (~100ms vs ~450ms for "ui" / GC16).
--     Safe because the pending border is pure black on paper — no
--     greys to crush.
--   * Refresh region narrowed to the chip's screen rect so only that
--     chip flashes, not the whole strip. d.x is row-local; the row
--     sits inside the strip's outer FrameContainer at offset
--     (Size.border.thin, Size.border.thin), so we shift by that.
--   * forceRePaint drains the paint queue immediately — without it,
--     the repaint would only run after the caller's heavy work
--     returns, by which point the strip has been replaced.
function ChipBar:flashPending(key)
    if not key or not self._chip_dimens then return end
    local d = self._chip_dimens[key]
    if not d or not self.show_parent or not self.dimen then return end
    self._pending_key = key
    self:_buildChipRow()
    -- The chip's cell plus the border band around it: a button's outline is
    -- drawn a border outside the cell and a region scoped to the cell alone
    -- left it unrepainted.
    --
    -- And no further. It is tempting to take in the roof above the strip as
    -- well, but "fast" is A2 -- two tones, nothing in between -- and that is
    -- only safe over the strip's own solid ground. Extended over the band
    -- above it, the wallpaper up there came back as a white block on a PW5.
    -- The roof does not need it anyway: it appears when the chip's selected
    -- state changes, which is the rebuild's business, not this flash's.
    local b = Size.border.thin
    UIManager:setDirty(self.show_parent, "fast", Geom:new{
        x = self.dimen.x + d.x,          -- cell x, less the outline's border
        y = self.dimen.y,                -- the strip's own top edge
        w = d.w + 2 * b,
        h = self.height + 2 * b,         -- ...to its painted bottom
    })
    UIManager:forceRePaint()
end

-- Rebuild the strip in place after a bar-wide colour change: same chips, same
-- page, same geometry -- only the paint decisions differ. The colours resolve at
-- BUILD time (_selectedChipColors, from _buildChipRow), so a plain repaint won't
-- pick them up; but asking the shelf for a full _rebuild() re-reads the library
-- and re-renders every cover, which is what made the colour nudges crawl (each
-- -/+ press was a whole regrid for a change confined to one strip).
--
-- Returns the strip's screen rect so the caller can scope its refresh to it, or
-- nil when there is no strip to recolour (caller should fall back to a rebuild).
function ChipBar:recolour()
    if self.breadcrumb_path and #self.breadcrumb_path > 0 then
        self:_initBreadcrumb()
    elseif self.chips and #self.chips > 0 then
        self:_buildChipRow()
    else
        return nil
    end
    -- dimen carries the painted position (InputContainer:paintTo stamps x/y),
    -- so it is only trustworthy once the strip has been on screen.
    local d = self.dimen
    if not (d and d.x and d.w and d.w > 0) then return nil end
    return Geom:new{ x = d.x, y = d.y, w = d.w, h = d.h }
end

function ChipBar:focusCursor(key)
    if not self._chip_dimens then return end
    local prev_key = self.focused_key
    self.focused_key = key
    self:_buildChipRow()
    if not self.show_parent or not self.dimen then return end
    -- Re-focusing the same chip changes nothing, so skip the (unscoped) full
    -- refresh -- it needlessly repainted the whole widget, including the hero,
    -- which flashed the cover on panels that lay dithering down with a strong
    -- waveform (issue #124, fix found by the reporter @jospalau).
    if prev_key == key then return end
    UIManager:setDirty(self.show_parent, "ui")
end

function ChipBar:focusCrumb(depth)
    if not self._breadcrumb_zones then return end
    self.focused_depth = depth
    self:_initBreadcrumb()
    if not self.show_parent or not self.dimen then return end
    UIManager:setDirty(self.show_parent, "ui")
end

-- ─── Unified tap dispatch ───────────────────────────────────────────────────

function ChipBar:onTapStrip(_, ges)
    local x = ges.pos.x - self.dimen.x
    if self._breadcrumb_zones then
        for _i, zone in ipairs(self._breadcrumb_zones) do
            if x >= zone.x and x < zone.x + zone.w then
                -- depth = -2 is the currently-reading action sentinel;
                -- route through on_change so the chip behaves the same
                -- way it does in chips mode (clear preview, restore
                -- hero, pop drilldown). All other depths fall through
                -- to on_breadcrumb as before.
                if zone.depth == -2 then
                    if self.on_change then self.on_change("current") end
                else
                    if self.on_breadcrumb then self.on_breadcrumb(zone.depth) end
                end
                return true
            end
        end
        return false
    end
    -- Chips mode: check page-chevron hits first.
    if self._chip_dimens then
        local prev_d = self._chip_dimens["__chip_prevpage"]
        if prev_d and x >= prev_d.x and x < prev_d.x + prev_d.w then
            self:_gotoPage(self._page - 1)
            return true
        end
        local next_d = self._chip_dimens["__chip_nextpage"]
        if next_d and x >= next_d.x and x < next_d.x + next_d.w then
            self:_gotoPage(self._page + 1)
            return true
        end
        -- Regular chip hit-test (self.chips, not render_chips, so we
        -- only ever dispatch on real chips — not synthetic chevrons).
        for _i, chip in ipairs(self.chips) do
            local d = self._chip_dimens[chip.key]
            if d and x >= d.x and x < d.x + d.w then
                if chip.action then
                    -- Action chips (current, search): single-tap fires
                    -- on_change unconditionally; they handle their own
                    -- toggle / activate semantics. No flashPending --
                    -- they don't trigger a rebuild, so the border would
                    -- have nothing to clear it.
                    if self.on_change then self.on_change(chip.key) end
                elseif chip.key == self.active then
                    -- Tapping the already-active chip does nothing. Editing is
                    -- long-press only (on_hold); a stray tap on the focused
                    -- chip used to open the editor, which was easy to trigger
                    -- by accident (#224). Consume the tap so it's a clean no-op.
                else
                    -- Switch to a different tab.
                    if self.on_change then
                        self:flashPending(chip.key)
                        self.on_change(chip.key)
                    end
                end
                return true
            end
        end
    end
    return false
end

function ChipBar:onSwipeStrip(_, ges)
    -- Only intercept swipes when there is more than one page of chips.
    if not (self._pages and self._pages.multi) then return false end
    local dir = ges.direction
    if dir == "west" then
        self:_gotoPage(self._page + 1)
        return true
    elseif dir == "east" then
        self:_gotoPage(self._page - 1)
        return true
    end
    return false
end

function ChipBar:onHoldStrip(_, ges)
    local x = ges.pos.x - self.dimen.x
    -- Breadcrumb mode: the chip pill (depth 0) is the one holdable element --
    -- in search mode it opens the results' view-mode picker. Other crumbs
    -- have no hold behaviour, and the miss falls through to nothing rather
    -- than to the chips-mode path below (those dimens are stale here).
    if self._breadcrumb_zones then
        for _i, zone in ipairs(self._breadcrumb_zones) do
            if x >= zone.x and x < zone.x + zone.w then
                if zone.depth == 0 and self.on_pill_hold then
                    self.on_pill_hold()
                    return true
                end
                return false
            end
        end
        return false
    end
    if self._chip_dimens then
        for _i, chip in ipairs(self.chips) do
            local d = self._chip_dimens[chip.key]
            if d and x >= d.x and x < d.x + d.w then
                -- Skip action chips (search, currently-reading) -- they have
                -- no editable settings; long-press there is a no-op. An action
                -- chip can opt back in with chip.holdable (e.g. the modules
                -- chip, whose long-press opens the micro-module options menu).
                if (not chip.action or chip.holdable) and self.on_hold then
                    self.on_hold(chip.key)
                end
                return true
            end
        end
    end
    return false
end

return ChipBar
