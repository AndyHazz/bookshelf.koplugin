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

local function chipPillFrame(label, w, h)
    return FrameContainer:new{
        bordersize = Size.border.thin,
        margin     = 0,
        padding    = 0,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = w, h = h },
            TextWidget:new{
                text    = (label or ""):upper(),
                face    = Font:getFace("infofont", 16),
                bold    = true,
                fgcolor = Blitbuffer.COLOR_BLACK,
            },
        },
    }
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
    local face_text  = Font:getFace("infofont", 14)
    local face_chev  = Font:getFace("infofont", 14)
    local pill_w     = math.floor(self.width / 4)  -- match a 4-chip cell width
    local pill       = chipPillFrame(self.chip_pill_label or "", pill_w, self.height)
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
        if leading_ellipsis then
            append_chevron()
            local tw = TextWidget:new{
                text    = ELLIPSIS,
                face    = face_text,
                fgcolor = Blitbuffer.gray(0.4),
            }
            local lw = tw:getSize().w
            row[#row + 1] = tw
            -- No tap zone for the ellipsis — it's an indicator, not a target.
            cursor_x = cursor_x + lw
        end
        for _, crumb in ipairs(visible_path) do
            append_chevron()
            append_label(crumb.label or "", crumb._original_depth)
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
