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

local CHEVRON      = " \xE2\x80\xBA "  -- " ‹ " — actually › U+203A
local ELLIPSIS     = "\xE2\x80\xA6"     -- …

-- Breadcrumb pill rendered as a black-outlined tag (white interior) with
-- an arrow tip on the right. The arrow doubles as the leading chevron —
-- no separate "›" needed after it. Sized to the label's text width plus a
-- small horizontal pad so a long chip name like "FAVOURITES" fits and a
-- short one like "RECENT" doesn't waste space. Outline (rather than
-- filled black) keeps the pill reading as clickable rather than as a
-- selected/active chip. Returns (widget, total_w, tip_w) so the caller
-- can lay out the post-pill gap and record the tap zone.
local function arrowPillFrame(label, h)
    local label_text = (label or ""):upper()
    local face       = Font:getFace("infofont", 16)
    local tw = TextWidget:new{
        text    = label_text,
        face    = face,
        bold    = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local h_pad   = Size.padding.large
    local body_w  = tw:getSize().w + h_pad * 2
    local tip_w   = math.floor(h * 0.4)
    local total_w = body_w + tip_w
    local b       = Size.border.thin

    -- Custom shape painter: paint the outer (black) shape filled, then
    -- knock out an inner (white) shape inset by `b` pixels — leaves a
    -- uniform black outline. Body inner inset is on top, bottom and
    -- left only (right side is the body/tip junction, no border); the
    -- inner tip starts at the same junction so the body and tip
    -- interiors flow continuously and only the outer perimeter draws.
    local ArrowBg = Widget:extend{}
    function ArrowBg:init()
        self.dimen = Geom:new{ w = total_w, h = h }
    end
    function ArrowBg:paintTo(bb, x, y)
        local hh = (h - 1) / 2
        local BLACK = Blitbuffer.COLOR_BLACK
        local WHITE = Blitbuffer.COLOR_WHITE
        -- Outer filled black: body rect + tapered tip strips.
        bb:paintRect(x, y, body_w, h, BLACK)
        for dy = 0, h - 1 do
            local from_center = math.abs(dy - hh)
            local row_w = math.max(0, math.floor(tip_w * (1 - from_center / hh)))
            if row_w > 0 then
                bb:paintRect(x + body_w, y + dy, row_w, 1, BLACK)
            end
        end
        -- Inner filled white (inset by `b`): body shrunk on top/bottom/
        -- left, tip shrunk by ~2*b in width so the slope's outline reads
        -- roughly uniform thickness around the curve.
        local inner_h = h - 2 * b
        if inner_h <= 0 then return end
        local inner_hh = (inner_h - 1) / 2
        local inner_body_w = body_w - b
        if inner_body_w > 0 then
            bb:paintRect(x + b, y + b, inner_body_w, inner_h, WHITE)
        end
        local inner_tip_w = tip_w - 2 * b
        if inner_tip_w > 0 then
            for dy = 0, inner_h - 1 do
                local from_center = math.abs(dy - inner_hh)
                local row_w = math.max(0, math.floor(inner_tip_w * (1 - from_center / inner_hh)))
                if row_w > 0 then
                    bb:paintRect(x + body_w, y + b + dy, row_w, 1, WHITE)
                end
            end
        end
    end

    local pill = OverlapGroup:new{
        dimen = Geom:new{ w = total_w, h = h },
        ArrowBg:new{},
        CenterContainer:new{
            dimen = Geom:new{ w = body_w, h = h },
            tw,
        },
    }
    return pill, total_w, tip_w
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
    -- Match the chip-label size (16) so the breadcrumb reads as
    -- continuous with the chip pill rather than a smaller subtitle.
    -- The crumb is doubling as the heading for the drilled-in view
    -- (e.g. series title), so a heading-equivalent weight matters.
    local face_text  = Font:getFace("infofont", 16)
    local face_chev  = Font:getFace("infofont", 16)
    -- Pill width hugs the label text + arrow tip; no longer a fixed
    -- quarter-width slot. Tap zone covers body+tip — anywhere on the
    -- pill pops back to top level. tip_w is reused below to size the
    -- gap between the arrow and the first crumb so the visual rhythm
    -- of the arrow's lead-in is balanced by an equal trail-out.
    local pill, pill_w, pill_tip_w = arrowPillFrame(self.chip_pill_label or "", self.height)
    self._breadcrumb_zones = {
        { x = 0, w = pill_w, depth = 0 },
    }
    local row = HorizontalGroup:new{ pill }

    -- Helper: append a chevron + a tappable label, growing the cumulative
    -- x range and recording a tap zone for the given depth.
    local cursor_x = pill_w
    local function append_chevron()
        local sep = HorizontalSpan:new{ width = Size.padding.small }
        local chev = TextWidget:new{
            text    = CHEVRON,
            face    = face_chev,
            fgcolor = Blitbuffer.gray(0.4),
        }
        local sep2 = HorizontalSpan:new{ width = Size.padding.small }
        row[#row + 1] = sep
        row[#row + 1] = chev
        row[#row + 1] = sep2
        cursor_x = cursor_x + Size.padding.small + chev:getSize().w + Size.padding.small
    end
    local function append_label(text, depth)
        local tw = TextWidget:new{
            text    = text,
            face    = face_text,
            bold    = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
        local lw = tw:getSize().w
        row[#row + 1] = tw
        self._breadcrumb_zones[#self._breadcrumb_zones + 1] = {
            x = cursor_x, w = lw, depth = depth,
        }
        cursor_x = cursor_x + lw
    end

    -- Truncate-from-left: try the full path first; if it overflows,
    -- keep the deepest crumb and replace older ones with a single
    -- "…" entry until it fits or only the deepest remains.
    local function build_with_path(visible_path, leading_ellipsis)
        row = HorizontalGroup:new{ pill }
        self._breadcrumb_zones = { { x = 0, w = pill_w, depth = 0 } }
        cursor_x = pill_w
        -- Gap right after the arrow tip equal to tip_w — the arrow IS
        -- the leading chevron, so no "›" between pill and first item;
        -- matching the gap to the tip width keeps the visual rhythm
        -- balanced (arrow lead-in distance ≈ trail-out distance).
        local lead_gap = pill_tip_w
        row[#row + 1] = HorizontalSpan:new{ width = lead_gap }
        cursor_x = cursor_x + lead_gap
        local items_in = 0
        if leading_ellipsis then
            local tw = TextWidget:new{
                text    = ELLIPSIS,
                face    = face_text,
                fgcolor = Blitbuffer.gray(0.4),
            }
            local lw = tw:getSize().w
            row[#row + 1] = tw
            -- No tap zone for the ellipsis — it's an indicator, not a target.
            cursor_x = cursor_x + lw
            items_in = 1
        end
        for _, crumb in ipairs(visible_path) do
            if items_in > 0 then append_chevron() end
            append_label(crumb.label or "", crumb._original_depth)
            items_in = items_in + 1
        end
        return cursor_x  -- total width consumed
    end

    -- Each path entry needs its original-depth so a truncated-out
    -- middle crumb's tap (if it ever became tappable again) would
    -- pop to the right depth. We only render visible ones, but we
    -- preserve original depth on each.
    local annotated = {}
    for i, p in ipairs(self.breadcrumb_path) do
        annotated[i] = { label = p.label, _original_depth = i }
    end

    local visible = annotated
    local leading_ellipsis = false
    local total_w = build_with_path(visible, leading_ellipsis)
    while total_w > self.width and #visible > 1 do
        -- Drop the SECOND visible crumb (keep deepest); switch to
        -- leading-ellipsis mode after the first drop.
        table.remove(visible, 1)
        leading_ellipsis = true
        total_w = build_with_path(visible, leading_ellipsis)
    end
    -- If even the chip pill + (ellipsis) + deepest crumb overflows,
    -- there's no clean truncation point — the deepest crumb's TextWidget
    -- will overflow visually, but tap zones still work.

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
