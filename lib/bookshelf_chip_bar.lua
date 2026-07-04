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

-- Tab-bar font size scale (percent). 100 = built-in baseline; nudge dialog
-- accepts 50-300.
-- Applied to every font in the strip and to the externally-supplied height
-- (the widget multiplies chip_h by the same factor). Read on demand so
-- changes from the settings nudge dialog take effect on the next rebuild
-- without restarting KOReader.
local function _fontScale()
    return BookshelfSettings.read("chip_font_scale") or 100
end
local function _scaled(n)
    return math.floor(n * _fontScale() / 100 + 0.5)
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
local function _buildLabelContent(label, size, max_w)
    local segments = TextSegments.labelSegments(TextSegments.upper(label or ""))
    if #segments == 0 then
        local empty_face, empty_bold = BFont:getFace("infofont", size)
        return TextWidget:new{
            text    = "",
            face    = empty_face,
            bold    = empty_bold,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
    end
    if #segments == 1 then
        local one_face, one_bold = BFont:getFace("infofont", size, { bold = segments[1].class == "text" })
        return TextWidget:new{
            text      = segments[1].text,
            face      = one_face,
            bold      = one_bold,
            fgcolor   = Blitbuffer.COLOR_BLACK,
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
            local iw_face, iw_bold = BFont:getFace("infofont", size)
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
        local seg_face, seg_bold = BFont:getFace("infofont", size, { bold = is_text })
        hg[#hg + 1] = TextWidget:new{
            text      = seg.text,
            face      = seg_face,
            bold      = seg_bold,
            fgcolor   = Blitbuffer.COLOR_BLACK,
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
    local segments = TextSegments.labelSegments(TextSegments.upper(label or ""))
    for _i, seg in ipairs(segments) do
        local m_face, m_bold = BFont:getFace("infofont", size, { bold = seg.class == "text" })
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

local ChipBar = InputContainer:extend{
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
    width  = nil,
    height = nil,
    color  = nil,
}
function UpTrianglePointer:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
end
function UpTrianglePointer:paintTo(bb, x, y)
    local w, h = self.width, self.height
    for dy = 0, h - 1 do
        -- Linear taper: apex (1px wide) at the top, full base at bottom.
        local row_w   = math.max(1, math.floor(w * (dy + 1) / h + 0.5))
        local row_off = math.floor((w - row_w) / 2)
        bb:paintRect(x + row_off, y + dy, row_w, 1, self.color)
    end
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
        local icon_face, icon_bold = BFont:getFace("infofont", _scaled(18), { bold = true })
        local icon_tw = TextWidget:new{
            text    = glyph,
            face    = icon_face,
            bold    = icon_bold,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
        local lbl_face, lbl_bold = BFont:getFace("infofont", _scaled(16), { bold = true })
        local text_tw = TextWidget:new{
            text    = TextSegments.upper(label),
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
            face, bold = BFont:getFace("infofont", _scaled(18), { bold = true })
        else
            label_text = TextSegments.upper(label or "")
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
        -- Right tip inner.
        local inner_tip_w = tip_w - 2 * b
        if inner_tip_w > 0 then
            local inner_hh = (inner_h - 1) / 2
            for dy_inner = 0, inner_h - 1 do
                local from_inner = math.abs(dy_inner - inner_hh)
                local row_w = math.max(0, math.floor(inner_tip_w * (1 - from_inner / inner_hh) + 0.5))
                if row_w > 0 then
                    bb:paintRect(x + body_w, y + dy_inner + b, row_w, 1, WHITE)
                end
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
        local ng_face, ng_bold = BFont:getFace("infofont", scaled_fn(18))
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

    for i, chip in ipairs(render_chips) do
        if i > 1 then
            -- White separator when both adjacent chips are inverted,
            -- black otherwise.
            local prev_filled = isFilled(render_chips[i - 1])
            local cur_filled  = isFilled(chip)
            local sep_color   = (prev_filled and cur_filled)
                                and Blitbuffer.COLOR_WHITE
                                or  Blitbuffer.COLOR_BLACK
            row[#row + 1] = LineWidget:new{
                background = sep_color,
                dimen = Geom:new{ w = separator_w, h = self.height },
            }
        end
        local is_active  = isFilled(chip)
        local is_pending = self._pending_key == chip.key
        local w = render_widths[i]
        local cell_content
        if chip.nerd_glyph then
            local cc_face, cc_bold = BFont:getFace("infofont", _scaled(18))
            cell_content = TextWidget:new{
                text    = chip.nerd_glyph,
                face    = cc_face,
                bold    = cc_bold,
                fgcolor = Blitbuffer.COLOR_BLACK,
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
                w - 2 * Size.padding.small)
        end
        local is_cursor = (self.focused_key == chip.key)
        local chip_body = InvertedFrame:new{
            _invert    = is_active and not is_cursor,
            bordersize = 0,
            margin     = 0,
            padding    = 0,
            background = paper,
            CenterContainer:new{
                dimen = Geom:new{ w = w, h = self.height },
                cell_content,
            },
        }
        local chip_slot = chip_body
        if is_pending or is_cursor then
            local pb   = Size.border.thick
            local ring = FrameContainer:new{
                bordersize = pb,
                color      = Blitbuffer.COLOR_BLACK,
                margin     = 0,
                padding    = 0,
                Widget:new{ dimen = Geom:new{ w = w - 2*pb, h = self.height - 2*pb } },
            }
            chip_slot = OverlapGroup:new{
                dimen = Geom:new{ w = w, h = self.height },
                chip_body,
                ring,
            }
        end
        if chip.action and is_active and not chip._page_dir then
            -- Selected action chip points up at the hero cover above.
            local pointer_h = math.max(Screen:scaleBySize(5),
                                       math.floor(self.height * 0.25))
            local pointer = UpTrianglePointer:new{
                width  = w,
                height = pointer_h,
                color  = Blitbuffer.COLOR_BLACK,
            }
            pointer.overlap_offset = { 0, -pointer_h }
            chip_slot = OverlapGroup:new{
                dimen = Geom:new{ w = w, h = self.height },
                chip_slot,
                pointer,
            }
        end
        row[#row + 1] = chip_slot
        local prev_chip = render_chips[i - 1]
        local prev_d = prev_chip and self._chip_dimens[prev_chip.key]
        local x = prev_d and (prev_d.x + prev_d.w + separator_w) or 0
        self._chip_dimens[chip.key] = { x = x, w = w }
    end
    self[1] = FrameContainer:new{
        bordersize = Size.border.thin,
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
    if anim_steps and self.show_parent and self.dimen
            and self.dimen.w and self.dimen.w > 0 then
        local region = Geom:new{
            x = self.dimen.x, y = self.dimen.y,
            w = self.dimen.w, h = self.dimen.h }
        wiped = pcall(function()
            local old_bb = Screen.bb:copy()
            self[1]:paintTo(Screen.bb, self.dimen.x, self.dimen.y)
            local new_bb = Screen.bb:copy()
            PageWipe.run(Screen, old_bb, new_bb, region, p > old_page, anim_steps)
            old_bb:free()
            new_bb:free()
        end)
    end
    if not wiped and self.show_parent and self.dimen then
        UIManager:setDirty(self.show_parent, function()
            return "ui", self.dimen
        end)
    end
    -- Let the host pre-warm the chips this page (and the next) just revealed.
    if self.on_page_change then self.on_page_change() end
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
        local outer_h = self.height
        local b       = Size.border.thin
        local inner_h = outer_h - 2 * b  -- so FrameContainer's borders sit INSIDE outer_h
        current_w = math.floor(outer_h * 1.6)
        local inner_w = current_w - 2 * b
        local glyph_face, glyph_bold = BFont:getFace("infofont", _scaled(18))
        local glyph = TextWidget:new{
            text    = current_chip.nerd_glyph or "",
            face    = glyph_face,
            bold    = glyph_bold,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
        -- Match chips-mode visual exactly: an InvertedFrame body
        -- (bordersize=0 to avoid the KT6 white-ring-after-invert bug,
        -- see chips-mode comment at line ~542) wrapped in a thin
        -- FrameContainer that supplies the visible outline. selected
        -- (hero == lastfile) flips the body inverted; otherwise the
        -- icon sits in a white cell with a thin black border. Inner
        -- body is sized inner_h so the FrameContainer's borders bring
        -- the painted footprint up to outer_h exactly — matches the
        -- breadcrumb segment height to the pixel.
        local body = InvertedFrame:new{
            _invert    = current_chip.selected and true or false,
            bordersize = 0,
            margin     = 0,
            padding    = 0,
            background = Blitbuffer.COLOR_WHITE,
            CenterContainer:new{
                dimen = Geom:new{ w = inner_w, h = inner_h },
                glyph,
            },
        }
        current_widget = FrameContainer:new{
            bordersize = b,
            margin     = 0,
            padding    = 0,
            body,
        }
        -- Selected-state "up triangle" pointer (same affordance as
        -- chips-mode): a black roof pointing at the hero cover above,
        -- anchored via negative y so it paints into the strip's top
        -- margin. Matches chips-mode dimensions so the same visual
        -- weight reads in both modes.
        if current_chip.selected then
            local pointer_h = math.max(Screen:scaleBySize(5),
                                       math.floor(self.height * 0.25))
            local pointer = UpTrianglePointer:new{
                width  = current_w,
                height = pointer_h,
                color  = Blitbuffer.COLOR_BLACK,
            }
            pointer.overlap_offset = { 0, -pointer_h }
            current_widget = OverlapGroup:new{
                dimen = Geom:new{ w = current_w, h = self.height },
                current_widget,
                pointer,
            }
        end
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
        back_pill, back_pill_w = arrowPillFrame(back_text, self.height, false)
    end

    -- Chip pill at depth 0 (e.g. "HOME"). chained=true when there's a
    -- Back pill before it so the two visually butt together; otherwise
    -- the chip pill is chained=false (full border) as the strip's leftmost
    -- element. chip_pill_glyph wins over chip_pill_label when set: search
    -- mode replaces the chip name with the search icon so the user sees
    -- they're in a separate "search" context, not nested under their
    -- previously-active chip.
    local pill, pill_w, pill_tip_w = arrowPillFrame(
        self.chip_pill_label or "", self.height, has_back, self.chip_pill_glyph)

    -- Chained pills for parent entries (1..n-1).
    local crumb_pills = {}
    for i = 1, n - 1 do
        local label = (self.breadcrumb_path[i].label or ""):gsub("/$", "")
        local cp_widget, cp_w, cp_tip_w = arrowPillFrame(label, self.height, true)
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
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
        deepest_w = deepest_widget:getSize().w
    end

    -- Layout helper. Pills lay out adjacently in HorizontalGroup but
    -- the chained pills' placement_w EXCLUDES the right tip, so each
    -- pill's tip overhangs into the next pill's notch area — pills
    -- visually overlap by tip_w and chain together.
    local function build(visible_pills)
        local row    = HorizontalGroup:new{}
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
        if deepest_widget then
            -- Plain text for the active folder. Gap = tip_w + large
            -- inset so the text sits well clear of the last pill's
            -- tip apex, mirroring the breathing room a chained pill
            -- gives its own text via the extra-tip_w left padding.
            local gap_w = pill_tip_w + Size.padding.large
            row[#row + 1] = HorizontalSpan:new{ width = gap_w }
            cursor = cursor + gap_w
            row[#row + 1] = deepest_widget
            -- Register a tap zone for the deepest crumb. The previous
            -- behaviour left it inert (depth = #path was a no-op for
            -- _drillBackTo), but search mode now uses this as a second
            -- "edit query" affordance alongside the chip pill.
            zones[#zones + 1] = { x = cursor, w = deepest_w, depth = n }
            cursor = cursor + deepest_w
        end
        return row, zones, cursor
    end

    -- Try to fit all parents. If the chain overflows, drop the
    -- earliest parent and replace the dropped run with a SINGLE
    -- ellipsis pill (chained, label "…"). Repeat until the chain
    -- fits the strip. The ellipsis pill, when present, taps to the
    -- depth of the FIRST hidden parent so the user can pop back into
    -- the truncated middle.
    local first_visible = 1
    local row, zones, total_w
    while true do
        local visible = {}
        if first_visible > 1 then
            local ep, ew, etw = arrowPillFrame("…", self.height, true)
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
        row, zones, total_w = build(visible)
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
                    Widget:new{ dimen = Geom:new{ w = z.w - 2*pb, h = self.height - 2*pb } },
                }
                ring.overlap_offset = { z.x, 0 }
                row = OverlapGroup:new{
                    dimen = Geom:new{ w = self.width, h = self.height },
                    row, ring,
                }
                break
            end
        end
    end
    self._breadcrumb_zones = zones
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
    local b = Size.border.thin
    UIManager:setDirty(self.show_parent, "fast", Geom:new{
        x = self.dimen.x + b + d.x,
        y = self.dimen.y + b,
        w = d.w,
        h = self.height,
    })
    UIManager:forceRePaint()
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
