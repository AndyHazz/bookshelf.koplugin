-- chip_strip.lua
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
local Blitbuffer     = require("ffi/blitbuffer")

local ChipStrip = InputContainer:extend{
    chips             = nil,   -- list of { key, label } (chips mode)
    active            = nil,   -- key of the currently-selected chip
    breadcrumb_path   = nil,   -- list of { label } — when non-empty, breadcrumb mode
    chip_pill_label   = nil,   -- label for the chip pill in breadcrumb mode (e.g. "Series")
    width             = nil,
    height            = nil,
    on_change         = nil,   -- function(key) — chips mode tap
    on_breadcrumb     = nil,   -- function(depth) — breadcrumb mode tap
}

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
local function arrowPillFrame(label, h, chained)
    local label_text = (label or ""):upper()
    local face       = Font:getFace("infofont", 16)
    local tw = TextWidget:new{
        text    = label_text,
        face    = face,
        bold    = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local text_w = tw:getSize().w
    local text_h = tw:getSize().h
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
        tw,
    }

    local pill = OverlapGroup:new{
        dimen = Geom:new{ w = placement_w, h = h },
        ArrowBg:new{},
        text_positioned,
    }
    return pill, placement_w, tip_w
end

function ChipStrip:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    if self.breadcrumb_path and #self.breadcrumb_path > 0 then
        self:_initBreadcrumb()
    elseif self.chips and #self.chips > 0 then
        self:_initChips()
    else
        self[1] = require("ui/widget/widget"):new{ dimen = self.dimen }
    end
    self.ges_events = {
        TapStrip = { GestureRange:new{ ges = "tap", range = self.dimen } },
    }
end

-- ─── Default chips mode ─────────────────────────────────────────────────────

function ChipStrip:_initChips()
    local n = #self.chips
    local row = HorizontalGroup:new{}
    self._chip_dimens = {}

    local paper       = Blitbuffer.COLOR_WHITE
    local LineWidget  = require("ui/widget/linewidget")
    local separator_w = Size.border.thin
    local sep_total   = separator_w * (n - 1)
    local cell_w      = (self.width - sep_total) / n

    for i, chip in ipairs(self.chips) do
        if i > 1 then
            row[#row + 1] = LineWidget:new{
                background = Blitbuffer.COLOR_BLACK,
                dimen = Geom:new{ w = separator_w, h = self.height },
            }
        end
        local is_active = (chip.key == self.active)
        local w = (i == n) and (self.width - sep_total - math.floor(cell_w) * (n - 1))
                 or math.floor(cell_w)
        row[#row + 1] = FrameContainer:new{
            bordersize = 0,
            margin     = 0,
            padding    = 0,
            background = is_active and Blitbuffer.COLOR_BLACK or paper,
            CenterContainer:new{
                dimen = Geom:new{ w = w, h = self.height },
                TextWidget:new{
                    text      = (chip.label or ""):upper(),
                    face      = Font:getFace("infofont", 16),
                    bold      = true,
                    fgcolor   = is_active and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK,
                    -- Truncate with ellipsis at extreme DPI / font scale
                    -- rather than letting "FAVOURITES" overflow into the
                    -- adjacent chip's cell. Some inner padding (Size.
                    -- padding.small per side) keeps the text from
                    -- touching the chip border.
                    max_width = w - 2 * Size.padding.small,
                },
            },
        }
        local prev = self._chip_dimens[self.chips[i - 1] and self.chips[i - 1].key]
        local x = prev and (prev.x + prev.w + separator_w) or 0
        self._chip_dimens[chip.key] = { x = x, w = w }
    end
    self[1] = FrameContainer:new{
        bordersize = Size.border.thin,
        margin     = 0,
        padding    = 0,
        row,
    }
end

-- ─── Breadcrumb mode ────────────────────────────────────────────────────────
--
-- Layout: [chip_pill] > crumb1 > crumb2 > … > crumbN
--
-- Pill has the same metrics as a normal chip cell (single-chip width).
-- Crumbs render with a chevron separator. We track each tappable region's
-- x-range in self._breadcrumb_zones (which the unified TapStrip handler
-- resolves) so the existing tap pipeline keeps working in both modes.

function ChipStrip:_initBreadcrumb()
    -- Layout: chip pill + (parents as CHAINED, OVERLAPPING arrow pills)
    -- + small gap + the deepest crumb as plain text. When parents are
    -- truncated to fit the strip width, an ELLIPSIS pill (also chained)
    -- replaces the dropped run between the chip pill and the first
    -- visible parent.
    local face_text = Font:getFace("infofont", 16)
    local n         = #self.breadcrumb_path

    -- Chip pill at depth 0 (e.g. "HOME") — chained=false (full border).
    local pill, pill_w, pill_tip_w = arrowPillFrame(self.chip_pill_label or "", self.height, false)

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
            bold    = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
        deepest_w = deepest_widget:getSize().w
    end

    -- Layout helper. Pills lay out adjacently in HorizontalGroup but
    -- the chained pills' placement_w EXCLUDES the right tip, so each
    -- pill's tip overhangs into the next pill's notch area — pills
    -- visually overlap by tip_w and chain together.
    local function build(visible_pills)
        local row    = HorizontalGroup:new{ pill }
        local zones  = { { x = 0, w = pill_w, depth = 0 } }
        local cursor = pill_w
        for _, cp in ipairs(visible_pills) do
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

    self._breadcrumb_zones = zones
    self[1] = row
end

-- ─── Unified tap dispatch ───────────────────────────────────────────────────

function ChipStrip:onTapStrip(_, ges)
    local x = ges.pos.x - self.dimen.x
    if self._breadcrumb_zones then
        for _, zone in ipairs(self._breadcrumb_zones) do
            if x >= zone.x and x < zone.x + zone.w then
                if self.on_breadcrumb then self.on_breadcrumb(zone.depth) end
                return true
            end
        end
        return false
    end
    -- Chips mode
    if self._chip_dimens then
        for _, chip in ipairs(self.chips) do
            local d = self._chip_dimens[chip.key]
            if d and x >= d.x and x < d.x + d.w then
                if self.on_change and chip.key ~= self.active then
                    self.on_change(chip.key)
                end
                return true
            end
        end
    end
    return false
end

return ChipStrip
