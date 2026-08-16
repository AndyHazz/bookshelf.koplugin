-- bookshelf_list_geom.lua
-- Row height and row count for list view. Pure arithmetic, no widgets: the
-- cover grid's equivalent maths (_maxRows / _maxShelfRows / _baseShelves) is
-- screen-derived and cannot be reproduced off-device, which is exactly why
-- issue #329's row-count bug was so expensive to find. This half is testable.

local ListGeom = {}

-- Minimum row height in scaled pixels. A list row is a tap target; below
-- roughly 9mm on a 264dpi panel a stray tap opens the neighbouring book.
-- Expressed pre-scale and multiplied by the caller's scale factor.
local MIN_ROW_DP = 42
ListGeom.MIN_ROW_H = MIN_ROW_DP

-- Cover column target height, in dp for the caller to scale (Screen:scaleBySize
-- -- NOT dp * scaleBySize(1), which rounds the factor to an integer and lands
-- 1088- and 1248-wide panels on the same number).
--
-- The COVER anchors a cover-column row; the row is not sized from the font.
-- Deriving it from the font (the first cut multiplied the line height by 2.4)
-- spent ~40% of every row on padding around a thumbnail nobody asked to be
-- small, and left list mode LESS dense than the cover grid it exists as an
-- alternative to -- 9 rows against the grid's 12 books on a 1248x1648 panel,
-- 6 against 8 in landscape. The whole premise of the mode is seeing more at
-- once, so the row is now exactly a cover tall plus the smallest padding that
-- still separates it from its neighbours.
--
-- 44dp puts a 1248x1648 panel at a ~96px row pitch (74px cover + 2*4 pad +
-- 2*7 selection-ring reservation + a 1px hairline), i.e. ~14 rows expanded
-- against the grid's 12 books. Lower and the thumbnail stops being a
-- recognisable cover; higher and the mode stops paying for itself.
ListGeom.COVER_H_DP = 44

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

-- rowHeight{ has_cover, font_h, pad, ring, cover_h, scale } -> pixels
--   font_h   rendered line height of the row's text face
--   pad      vertical padding inside the row, one side
--   ring     selection-ring reservation, one side (SpineWidget.SELECTED_BORDER)
--   cover_h  target thumbnail height, already scaled (COVER_H_DP through
--            Screen:scaleBySize); only consulted when has_cover
--   scale    Screen:scaleBySize(1)-equivalent factor, for the tap-target floor
--
-- The two branches are sized by different things ON PURPOSE. A cover row is
-- cover-anchored (see COVER_H_DP); a text-only row has no cover to anchor to,
-- so it stays font-derived -- that path was already tight, and inventing a
-- height for it would be inventing whitespace.
function ListGeom.rowHeight(opts)
    opts = opts or {}
    local font_h = opts.font_h or 0
    local pad    = opts.pad or 0
    local scale  = opts.scale or 1
    local h
    if opts.has_cover then
        -- ring is added back because ListRow.pageLayout insets it straight out
        -- again (bookshelf_list_row.lua:255-260) before sizing the thumbnail,
        -- so leaving it out here would silently shrink every cover by 2*ring
        -- and put the row height and the cover target out of step.
        h = (opts.cover_h or 0) + pad * 2 + (opts.ring or 0) * 2
        -- A row still has to hold its own text. Only bites if a user's font
        -- scale grows the line past the thumbnail, which is a legitimate
        -- setting rather than a state to clip in.
        local text_h = font_h + pad * 2
        if h < text_h then h = text_h end
    else
        h = font_h + pad * 2
    end
    local floor_h = math.floor(MIN_ROW_DP * scale)
    if h < floor_h then h = floor_h end
    return h
end

-- coverSize(row_h, pad) -> w, h
-- The thumbnail insets by pad top and bottom and keeps the book aspect.
function ListGeom.coverSize(row_h, pad)
    local h = row_h - (pad or 0) * 2
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
