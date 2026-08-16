-- bookshelf_list_geom.lua
-- Row height and row count for list view. Pure arithmetic, no widgets: the
-- cover grid's equivalent maths (_maxRows / _maxShelfRows / _baseShelves) is
-- screen-derived and cannot be reproduced off-device, which is exactly why
-- issue #329's row-count bug was so expensive to find. This half is testable.
--
-- Everything the density model decides is declared HERE, in dp, and scaled by
-- the callers (bookshelf_list_row.lua and bookshelf_widget.lua through
-- Screen:scaleBySize, tests/_test_list_geom.lua through its own reproduction of
-- the same formula). No caller carries its own copy of a number: a value the
-- test hardcodes alongside the widget rather than reading from it is a value
-- the widget can change while the suite stays green -- which is how a half of
-- this model went unpinned once already.

local ListGeom = {}

-- Minimum row height in scaled pixels, for TEXT-ONLY rows (no cover column).
-- A list row is a tap target; below roughly 9mm a stray tap opens the
-- neighbouring book. Expressed pre-scale and multiplied by the caller's
-- Screen:scaleBySize(1).
--
-- Deliberately NOT applied to cover-bearing rows -- see rowHeight.
local MIN_ROW_DP = 42
ListGeom.MIN_ROW_H = MIN_ROW_DP

-- ROW_RING_DP -- the list row's selection-ring thickness, one side, pre-scale.
--
-- NOT SpineWidget.SELECTED_BORDER. That is 7px on a 1248x1648 panel, sized to
-- read around a small cover among many in the grid; reserved on all four sides
-- of a table row it would spend 14 of the row's 49 pixels on a band that is
-- page-white whenever the row isn't selected. A row is a full-width rectangle,
-- so a 2px box round it reads as clearly as a 7px box round a thumbnail, and
-- it is still double the inter-row rule below so the two never read as the
-- same mark.
--
-- 1dp, i.e. exactly Size.border.default. The ring's reserved band IS the row's
-- vertical padding: rowHeight adds it, the content box sits inside it, and the
-- ring paints into it when selected -- so selecting a row changes only the
-- perimeter pixels and never moves a pixel of its content, the same invariant
-- SpineWidget's own selection ring keeps, at a tenth of the cost.
ListGeom.ROW_RING_DP = 1

-- ROW_GAP_DP -- the vertical gap between two list rows, pre-scale.
--
-- A hairline, not the PAD the cover grid uses between shelves. Covers need PAD
-- because a shelf row is a block of art that has to read as separate from the
-- one below it; list rows are a table, and a table's rows are separated by a
-- rule, not by a 37px band.
--
-- 0.5dp, i.e. exactly Size.line.thin -- the plugin's established hairline, and
-- the height ListRow.divider paints. The gap IS the divider, so there is no
-- whitespace to account for on top of it, which is what keeps the row-count
-- arithmetic (n * (row_h + gap)) honest. Both the divider and the row-count
-- budget read this one number, so they cannot drift.
ListGeom.ROW_GAP_DP = 0.5

-- Book cover aspect. true_cover_aspect is deliberately NOT consulted:
-- variable-width thumbnails would give the table a ragged left edge, which
-- costs more than uncropped covers gain at thumbnail size.
local COVER_ASPECT = 1.5

function ListGeom.hasCover(active)
    if type(active) ~= "table" then return false end
    for _i, c in ipairs(active) do
        if c and c.id == "cover" then return true end
    end
    return false
end

-- rowHeight{ has_cover, font_h, ring, scale } -> pixels
--   font_h   rendered line height of the row's text face
--   ring     selection-ring reservation, one side (ROW_RING_DP, scaled)
--   scale    Screen:scaleBySize(1)-equivalent factor, for the tap-target floor
--
-- THE TEXT sets the height. A list row is a spreadsheet row: its own line of
-- text plus the ring band on each side, and nothing else. The cover fits the
-- row, not the reverse -- thumbSize below takes the row apart again to size the
-- thumbnail, so there is no second number to keep in step and no way for the
-- height reserved for a row and the art drawn in it to disagree.
--
-- Two earlier models are worth naming so neither comes back. font_h * 2.4 spent
-- ~40% of every row on padding and left list mode LESS dense than the cover
-- grid it exists as an alternative to (9 rows against 12 books on a 1248x1648
-- panel). Anchoring the row to a fixed 44dp cover instead bought 14 rows, still
-- only two more than the grid. Text-tight gets 27.
--
-- The tap-target floor applies to the text-only branch ONLY, and that is a
-- ruling rather than an oversight. Measured: a stock Paperwhite 5 renders a
-- 61px row, which on its 300ppi panel is 5.2mm, against the ~9mm usually
-- quoted for a touch target; a stock Paperwhite 3 gets 4.4mm and a 600x800
-- Kindle 4.3mm. Excel density and a comfortable tap target are not both
-- achievable on these screens. The decision is to take the density, because in
-- collapsed list mode a tap PREVIEWS rather than opens (double tap opens), so
-- a mis-tap costs a preview rather than the wrong book.
--
-- The text-only path keeps the floor untouched: it has no thumbnail to shrink
-- and nobody has asked it to get tighter. The visible consequence is that
-- turning the cover column OFF now makes rows TALLER, not shorter.
function ListGeom.rowHeight(opts)
    opts = opts or {}
    local font_h = opts.font_h or 0
    local ring   = opts.ring or 0
    local h = font_h + ring * 2
    if not opts.has_cover then
        local floor_h = math.floor(MIN_ROW_DP * (opts.scale or 1))
        if h < floor_h then h = floor_h end
    end
    if h < 1 then h = 1 end
    return h
end

-- thumbSize(row_h, ring) -> w, h
-- The cover-column thumbnail for a row of `row_h` pixels: the content box
-- inside the ring reservation, at the book aspect, with nothing else taken off
-- it. Takes the ROW height rather than the content height so that every
-- caller -- the row itself, and the two BIM/preload sites that warm covers
-- before a row exists -- subtracts the ring exactly once, here. Passing the
-- row height and forgetting the ring is how the preloader came to warm 88px
-- covers for a 74px thumbnail; there is now no signature that lets it.
function ListGeom.thumbSize(row_h, ring)
    local h = (row_h or 0) - (ring or 0) * 2
    if h < 1 then h = 1 end
    local w = math.floor(h / COVER_ASPECT)
    if w < 1 then w = 1 end
    return w, h
end

-- rowsThatFit(available_h, row_h, gap) -> count >= 1
-- n rows occupy n*row_h + (n-1)*gap. Always returns at least 1: zero rows
-- would render an empty shelf under a live pagination footer, which reads as
-- a bug rather than a tight screen.
function ListGeom.rowsThatFit(available_h, row_h, gap)
    gap = gap or 0
    if type(row_h) ~= "number" or row_h < 1 then return 1 end
    if type(available_h) ~= "number" or available_h < row_h then return 1 end
    local n = math.floor((available_h + gap) / (row_h + gap))
    if n < 1 then n = 1 end
    return n
end

return ListGeom
