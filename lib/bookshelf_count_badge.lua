-- bookshelf_count_badge.lua
-- Tiny shared renderer for the "N books" badge that appears on the
-- top-right of stack covers (SeriesStack, FolderStack). Three formats,
-- in priority order:
--   1. "K/N" when selected_count is set (Venn-diagram partial-selection
--      mode: K of N books in this stack are in the current selection).
--      Always wins so the user can see selection state at a glance.
--   2. "F/N" when finished_count is set (out-of-selection format
--      controlled by stack_count_badge_format = "finished_total").
--   3. "×N" otherwise (the default).
--
-- Returns a FrameContainer. Callers position it via overlap_offset
-- relative to their slot — this module is layout-agnostic.

local Blitbuffer     = require("ffi/blitbuffer")
local FrameContainer = require("ui/widget/container/framecontainer")
local TextWidget     = require("ui/widget/textwidget")
local Size           = require("ui/size")
local Font           = require("ui/font")
local Screen         = require("device").screen
local BookshelfSettings = require("lib/bookshelf_settings_store")

local CountBadge = {}

-- Single source of truth for the cover-badge font scale. Affects the
-- count badge here AND the page-count / series-num badges painted by
-- SpineWidget. Default 100 preserves pre-v2.2.x behaviour.
local function _badgeSize(base)
    local scale = BookshelfSettings.read("cover_badge_font_scale") or 100
    return math.floor(base * scale / 100 + 0.5)
end

-- render(total, selected_count, finished_count, finished_total) → FrameContainer | nil
--   total          : visible stack size (post-filter). N denominator for
--                    ×N and K/N. nil/<=0 → no badge.
--   selected_count : integer or nil. When set, renders "K/total".
--                    (assumes caller already filtered to 0 < K < total).
--   finished_count : integer or nil. F numerator when selected_count
--                    is nil; renders "F/finished_total". 0 is valid.
--   finished_total : integer, the unfiltered N for F/F mode. Falls back
--                    to `total` when nil. Separate from `total` so a
--                    filtered view still surfaces the stack-wide
--                    "finished out of all" statistic.
function CountBadge.render(total, selected_count, finished_count, finished_total)
    if not total or total <= 0 then return nil end
    local text
    if selected_count then
        text = tostring(selected_count) .. "/" .. tostring(total)
    elseif finished_count then
        text = tostring(finished_count) .. "/" .. tostring(finished_total or total)
    else
        text = "\xc3\x97" .. tostring(total)  -- × (UTF-8 U+00D7)
    end
    return FrameContainer:new{
        bordersize     = Size.border.thin,
        background     = Blitbuffer.COLOR_WHITE,
        radius         = Screen:scaleBySize(3),
        padding_left   = Size.padding.default,
        padding_right  = Size.padding.default,
        padding_top    = Size.padding.small,
        padding_bottom = Size.padding.small,
        TextWidget:new{
            text = text,
            face = Font:getFace("smallinfofont", _badgeSize(12)),
            bold = true,
        },
    }
end

return CountBadge
