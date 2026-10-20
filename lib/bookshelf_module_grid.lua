--[[
Micro-module grid: the pure layout model behind the top panel and the
full-screen micro-module view.

A surface is a set of pages; each page is a grid of `cols x rows` cells. Every
module occupies a rectangle of whole cells (a "box"):

  Box  = { id, page, col, row, w, h }      -- 1-based, in cells
  Dims = { cols, rows, cell_w, cell_h, gap } -- cell sizes in pixels

Positions are stored in cells, never pixels, so one stored layout renders on
any panel with the same grid dimensions. Nothing here touches KOReader: the
renderer and the layout editor both call in with plain numbers, which is what
lets the whole placement model be tested under a standalone interpreter.
]]

local M = {}

local MAX_ROWS = 12

-- How far a cell is from square: 0 for a perfect square, growing either way.
local function skew(w, h)
    if w <= 0 or h <= 0 then return math.huge end
    return math.abs(math.log(w / h))
end

local function span(avail, n, gap)
    return math.floor((avail - gap * (n - 1)) / n)
end

-- The row count (1..MAX_ROWS) whose cells come out closest to square for a
-- fixed column count. Ties keep the smaller count.
function M.squareRows(avail_w, avail_h, cols, gap)
    local cell_w = span(avail_w, cols, gap)
    local best, best_skew = 1, math.huge
    for r = 1, MAX_ROWS do
        local s = skew(cell_w, span(avail_h, r, gap))
        if s < best_skew then best, best_skew = r, s end
    end
    return best
end

-- The column count (lo..hi) whose cells come out closest to square for a
-- fixed row count. Ties keep the smaller count.
function M.squareCols(avail_w, avail_h, rows, gap, lo, hi)
    local cell_h = span(avail_h, rows, gap)
    local best, best_skew = lo, math.huge
    for c = lo, hi do
        local s = skew(span(avail_w, c, gap), cell_h)
        if s < best_skew then best, best_skew = c, s end
    end
    return best
end

--- Grid dimensions for a surface.
---   kind "fullscreen": portrait is always 4 columns with rows for the
---     squarest cells; landscape picks both counts so cells stay close to the
---     portrait cell size (opts.short_side = the screen's short side).
---   kind "panel" (top panel): 2 rows when the height allows two of at least
---     opts.min_row_h, else 1; columns for the squarest cells.
function M.dims(kind, avail_w, avail_h, gap, opts)
    opts = opts or {}
    gap = gap or 0
    local cols, rows
    if kind == "panel" then
        local min_row_h = opts.min_row_h or 1
        rows = (avail_h >= 2 * min_row_h + gap) and 2 or 1
        cols = M.squareCols(avail_w, avail_h, rows, gap, 2, 8)
    elseif opts.landscape and opts.short_side then
        local target = (opts.short_side - 2 * gap) / 4
        cols = math.max(1, math.floor(avail_w / target + 0.5))
        rows = math.max(1, math.floor(avail_h / target + 0.5))
    else
        cols = 4
        rows = M.squareRows(avail_w, avail_h, cols, gap)
    end
    return {
        cols   = cols,
        rows   = rows,
        cell_w = math.max(1, span(avail_w, cols, gap)),
        cell_h = math.max(1, span(avail_h, rows, gap)),
        gap    = gap,
    }
end

--- Pixel rectangle of a box, relative to the grid's top-left.
function M.rect(dims, box)
    local g = dims.gap
    return (box.col - 1) * (dims.cell_w + g),
           (box.row - 1) * (dims.cell_h + g),
           box.w * dims.cell_w + (box.w - 1) * g,
           box.h * dims.cell_h + (box.h - 1) * g
end

--- The cell under a point relative to the grid's top-left, or nil when the
--- point falls in a gap or outside the grid.
function M.cellAt(dims, dx, dy)
    if dx < 0 or dy < 0 then return nil end
    local pw, ph = dims.cell_w + dims.gap, dims.cell_h + dims.gap
    local col = math.floor(dx / pw) + 1
    local row = math.floor(dy / ph) + 1
    if col > dims.cols or row > dims.rows then return nil end
    if dx - (col - 1) * pw >= dims.cell_w then return nil end
    if dy - (row - 1) * ph >= dims.cell_h then return nil end
    return col, row
end

--- Where the editor's floating toolbar goes: the half of the screen the
--- selected module's centre is NOT in.
function M.toolbarSide(sel_y, sel_h, screen_h)
    return (sel_y + sel_h / 2 < screen_h / 2) and "bottom" or "top"
end

return M
