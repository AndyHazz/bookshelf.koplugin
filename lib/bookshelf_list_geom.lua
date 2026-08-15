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

-- Cover column target height as a multiple of the text line height. Tall
-- enough for a cover to be recognisable, short enough that a page still shows
-- a useful number of rows.
local COVER_ROW_MULT = 2.4

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

-- rowHeight{ has_cover, font_h, pad, scale } -> pixels
--   font_h  rendered line height of the row's text face
--   pad     vertical padding inside the row, one side
--   scale   Screen:scaleBySize(1)-equivalent factor, for the tap-target floor
function ListGeom.rowHeight(opts)
    opts = opts or {}
    local font_h = opts.font_h or 0
    local pad    = opts.pad or 0
    local scale  = opts.scale or 1
    local h
    if opts.has_cover then
        h = math.floor(font_h * COVER_ROW_MULT) + pad * 2
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
