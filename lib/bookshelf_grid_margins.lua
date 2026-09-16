--[[
GridMargins -- how the cover grid's vertical gaps are shared out.

The layout spends one PAD above row 1 and one after every row, the last of
those being the gap to the footer. Spent like that the grid looks bottom-heavy,
because the chrome around it is not symmetric: the top panel bleeds about
PAD/2 down over the top gap, the footer's icons sit inside their reserve, and
whatever the floor() arithmetic leaves over was parked under the last row. A
Paperwhite 5 showed 11px above the grid and 41px below it.

split() keeps the total spend exactly (so shelf_h, hero_h and the row count do
not move for anyone) and redistributes it so the VISIBLE gaps match:

  collapsed  (spread = false): the between-row gaps stay PAD; only the two
             outer gaps trade pixels.
  expanded   (spread = true):  the slack is dealt into every gap, the top one
             included, so the grid reads as evenly spaced; before, the bonus
             went only to the gaps below rows and the top stayed at PAD.

Everything is integer pixels; the bottom span never goes below zero (the
shortfall then stays at the top, which is where the panel is anyway).
]]
local M = {}

-- split(o) -> { top = px, between = px, last = px }
--   o.pad          the standard gap between rows (and after the last one)
--   o.top_base     the span the layout already carries above row 1 (default pad;
--                  the hero-to-rows gap when the chip strip is hidden)
--   o.n_rows       rows on the page (>= 1)
--   o.top_bleed    chrome painted down over the top gap (a panel's bleed), else 0
--   o.foot_offset  from the footer reserve's top to the footer's visible top:
--                  0 with a footer panel, the icons' inset without one
--   o.extra        surplus pixels to distribute (the layout's floor remainder,
--                  or expanded mode's screen slack); negative means overflow
--                  and is treated as 0
--   o.spread       true for expanded mode (see above)
--   o.last_min     the least the last gap may be: whatever hangs below the
--                  last row (a spine row's section badge drops below its
--                  plank) plus a little air. Paid for from the top gap; a
--                  floor the pool cannot afford takes the whole top gap and
--                  no more.
function M.split(o)
    local pad   = math.max(0, math.floor(o.pad or 0))
    local base  = math.max(0, math.floor(o.top_base or pad))
    local n     = math.max(1, math.floor(o.n_rows or 1))
    local bleed = math.max(0, math.floor(o.top_bleed or 0))
    local foot  = math.max(0, math.floor(o.foot_offset or 0))
    local extra = math.max(0, math.floor(o.extra or 0))
    local top, between, last
    if o.spread then
        -- (n + 1) gaps share the pool equally BY EYE: the top one is wider
        -- by the bleed, the last one narrower by the footer inset.
        local total = base + pad * n + extra
        local g = math.max(0, math.floor((total - bleed + foot) / (n + 1)))
        between = g
        top     = g + bleed
        last    = g - foot
        last    = last + (total - (top + (n - 1) * between + last))  -- the remainder
    else
        -- Visible top = base + d - bleed; visible bottom = pad + extra - d + foot.
        between = pad
        local d = math.floor((pad - base + bleed + foot + extra) / 2)
        top     = base + d
        last    = pad + extra - d
    end
    if last < 0 then top = top + last; last = 0 end
    if top < 0 then top = 0 end
    local floor_last = math.max(0, math.floor(o.last_min or 0))
    if last < floor_last then
        local give = math.min(floor_last - last, top)
        top  = top - give
        last = last + give
    end
    return { top = top, between = between, last = last }
end

return M
