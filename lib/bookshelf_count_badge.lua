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

local FrameContainer = require("ui/widget/container/framecontainer")
local TextWidget     = require("ui/widget/textwidget")
local Size           = require("ui/size")
local Font           = require("ui/font")
local BFont          = require("lib/bookshelf_fonts")
local Screen         = require("device").screen
local CoverProgress  = require("lib/bookshelf_cover_progress")

local CountBadge = {}

-- Cover-badge font scale lives in bookshelf_cover_progress as the single
-- source of truth shared with SpineWidget. Localise the function so the
-- call site below stays terse.
local _badgeSize = CoverProgress.badgeSize

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
    -- HAIR SPACE (U+200A, "\xe2\x80\x8a") between the separator and
    -- the adjacent digits: matches the page-count "p" pill and the
    -- series "#" pill (see lib/bookshelf_spine_widget.lua) where a
    -- full word-space split the pill visually but no space ran the
    -- glyphs together at smallinfofont(12) bold. Hair space gives a
    -- hairline gap without breaking the compact pill silhouette.
    local HAIR = "\xe2\x80\x8a"
    local text
    if selected_count then
        text = tostring(selected_count) .. HAIR .. "/" .. HAIR .. tostring(total)
    elseif finished_count then
        text = tostring(finished_count) .. HAIR .. "/" .. HAIR
            .. tostring(finished_total or total)
    else
        -- "×N" (UTF-8 U+00D7 multiplication sign + hair + digits)
        text = "\xc3\x97" .. HAIR .. tostring(total)
    end
    local colors = CoverProgress.resolvedColors()
    local face, bold = BFont:getFace("smallinfofont", _badgeSize(12), { bold = true })
    local badge = FrameContainer:new{
        bordersize     = Size.border.thin,
        background     = colors.badge_bg,
        color          = colors.badge_fg,
        radius         = Screen:scaleBySize(3),
        padding_left   = Size.padding.default,
        padding_right  = Size.padding.default,
        padding_top    = Size.padding.small,
        padding_bottom = Size.padding.small,
        TextWidget:new{
            text = text,
            face = face,
            bold = bold,
            fgcolor = colors.badge_fg,
        },
    }
    -- Re-coloured in place on a night-mode flip rather than waiting for the
    -- shelf rebuild. FrameContainer reads background / color at paint time and
    -- TextWidget reads fgcolor at paint time, so all three are assignments.
    badge._bs_recolour = function(self, roles)
        if roles.bg then self.background = roles.bg end
        if roles.fg then
            self.color = roles.fg
            if self[1] then self[1].fgcolor = roles.fg end
        end
    end
    -- Best effort: if registration is unavailable the badge simply waits for
    -- the shelf rebuild, which is what it did before.
    if CoverProgress.registerRecolour then
        CoverProgress.registerRecolour(badge, function(c)
            return { bg = c.badge_bg, fg = c.badge_fg }
        end)
    end
    return badge
end

return CountBadge
