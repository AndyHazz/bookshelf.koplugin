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
-- Full-screen columns in portrait. Six gives halves, thirds and 2x3 cards to
-- arrange with while a 1x1 cell stays big enough to read (about 160px on a
-- PW5); rows then follow the screen's shape.
local FULLSCREEN_COLS = 6

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
---   kind "fullscreen": portrait is always 6 columns with rows for the
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
        local target = (opts.short_side - 2 * gap) / FULLSCREEN_COLS
        cols = math.max(1, math.floor(avail_w / target + 0.5))
        rows = math.max(1, math.floor(avail_h / target + 0.5))
    else
        cols = FULLSCREEN_COLS
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

--- Like cellAt, but a point in a gap between cells snaps to the nearer cell
--- (a finger aimed at a module often lands in the gap beside it). nil only
--- outside the grid.
function M.nearestCell(dims, dx, dy)
    local g = dims.gap
    local gw = dims.cols * dims.cell_w + (dims.cols - 1) * g
    local gh = dims.rows * dims.cell_h + (dims.rows - 1) * g
    if dx < 0 or dy < 0 or dx >= gw or dy >= gh then return nil end
    local function axis(v, cell, n)
        local pitch = cell + g
        local i = math.floor(v / pitch) + 1
        if v - (i - 1) * pitch > cell + g / 2 then i = i + 1 end
        return math.min(i, n)
    end
    return axis(dx, dims.cell_w, dims.cols), axis(dy, dims.cell_h, dims.rows)
end

--- Size for a newly placed module, in proportion to the grid: on a fine grid
--- (5+ columns) a square card starts 2x2 and any other card half the width by
--- two rows; on a coarse one 1x1 and half the width by one row. Never larger
--- than the grid.
function M.defaultSize(dims, square)
    local unit = (dims.cols >= 5) and 2 or 1
    local w = square and unit or math.max(unit, math.floor(dims.cols / 2))
    return math.min(w, dims.cols), math.min(unit, dims.rows)
end

--- Where the editor's floating toolbar goes: the half of the screen the
--- selected module's centre is NOT in.
function M.toolbarSide(sel_y, sel_h, screen_h)
    return (sel_y + sel_h / 2 < screen_h / 2) and "bottom" or "top"
end

--- Page-indicator dots: `count` squares of `size` px, `spacing` px apart
--- centre to centre, centred in a w x h band. Returns { x, y, w, h } each.
function M.dotRects(count, w, h, size, spacing)
    local out = {}
    local first = w / 2 - (count - 1) * spacing / 2
    local y = math.floor((h - size) / 2)
    for i = 1, count do
        local cx = first + (i - 1) * spacing
        out[i] = { x = math.floor(cx - size / 2), y = y, w = size, h = size }
    end
    return out
end

--- Index of the dot whose slot (spacing wide, centred on it) holds x, or nil.
function M.dotAt(rects, spacing, x)
    for i, r in ipairs(rects) do
        if math.abs(r.x + r.w / 2 - x) <= spacing / 2 then return i end
    end
    return nil
end

-- ── Boxes ────────────────────────────────────────────────────────────────────
-- Every function below is pure: inputs are never mutated, results are fresh
-- arrays of fresh box tables.

local function copyBox(b)
    return { id = b.id, page = b.page, col = b.col, row = b.row, w = b.w, h = b.h }
end

local function copyAll(boxes)
    local out = {}
    for i, b in ipairs(boxes) do out[i] = copyBox(b) end
    return out
end

local function clampSize(b, dims)
    b.w = math.max(1, math.min(b.w or 1, dims.cols))
    b.h = math.max(1, math.min(b.h or 1, dims.rows))
    return b
end

local function fits(b, dims)
    return b.col >= 1 and b.row >= 1
        and b.col + b.w - 1 <= dims.cols
        and b.row + b.h - 1 <= dims.rows
end

function M.overlaps(a, b)
    return a.page == b.page
        and a.col < b.col + b.w and b.col < a.col + a.w
        and a.row < b.row + b.h and b.row < a.row + a.h
end

local function clashes(list, b, skip_id)
    for _i, o in ipairs(list) do
        if o.id ~= skip_id and o.id ~= b.id and M.overlaps(o, b) then return true end
    end
    return false
end

local function find(list, id)
    for i, b in ipairs(list) do if b.id == id then return b, i end end
end

function M.readingOrder(boxes)
    local out = copyAll(boxes)
    table.sort(out, function(a, b)
        if a.page ~= b.page then return a.page < b.page end
        if a.row ~= b.row then return a.row < b.row end
        if a.col ~= b.col then return a.col < b.col end
        return tostring(a.id) < tostring(b.id)
    end)
    return out
end

--- First top-left (reading order) on `page` where a w x h box fits without
--- overlapping anything in `boxes` (ignoring skip_id), or nil.
function M.firstFree(boxes, dims, page, w, h, skip_id)
    local probe = { id = skip_id, page = page, w = w, h = h }
    for r = 1, dims.rows - h + 1 do
        for c = 1, dims.cols - w + 1 do
            probe.col, probe.row = c, r
            if not clashes(boxes, probe, skip_id) then return c, r end
        end
    end
    return nil
end

-- Place b at the first free spot on page p or any later page. Never fails:
-- pages are unbounded here (spill is never dropped).
local function placeFrom(out, b, dims, p)
    while true do
        local c, r = M.firstFree(out, dims, p, b.w, b.h, b.id)
        if c then
            b.page, b.col, b.row = p, c, r
            return b
        end
        p = p + 1
    end
end

--- A new box of w x h for `id`, at the first free spot on start_page or any
--- later page (unbounded). Doesn't add it to `boxes`.
function M.placeNew(boxes, dims, id, w, h, start_page)
    local b = clampSize({ id = id, w = w, h = h }, dims)
    return placeFrom(boxes, b, dims, math.max(1, start_page or 1))
end

--- Place every box, in input order, at the first free spot starting on
--- max(start_page, box.page). Sizes clamp to the grid; pages are unbounded.
function M.flow(boxes, dims, start_page)
    local out = {}
    for _i, src in ipairs(boxes) do
        local b = clampSize(copyBox(src), dims)
        out[#out + 1] = placeFrom(out, b, dims, math.max(start_page or 1, b.page or 1))
    end
    return out
end

--- Make a stored layout drawable on `dims`: keep each box (reading order) that
--- fits and doesn't overlap an earlier kept one; re-place the rest from their
--- own page onwards. Returns the boxes and the ids that had to move.
function M.resolve(boxes, dims)
    local out, pending, moved = {}, {}, {}
    for _i, b in ipairs(M.readingOrder(boxes)) do
        clampSize(b, dims)
        -- A box that starts on the grid but hangs off its right or bottom edge
        -- shrinks to the edge rather than moving page.
        if b.col <= dims.cols then b.w = math.min(b.w, dims.cols - b.col + 1) end
        if b.row <= dims.rows then b.h = math.min(b.h, dims.rows - b.row + 1) end
        if fits(b, dims) and not clashes(out, b) then
            out[#out + 1] = b
        else
            pending[#pending + 1] = b
        end
    end
    for _i, b in ipairs(pending) do
        out[#out + 1] = placeFrom(out, b, dims, b.page or 1)
        moved[#moved + 1] = b.id
    end
    return out, moved
end

-- Re-home one displaced box: the space the moved box vacated first (own
-- column first), then the nearest free spot on the same page.
local function rehome(out, b, vacated, dims)
    local function try(c, r)
        local probe = { id = b.id, page = b.page, col = c, row = r, w = b.w, h = b.h }
        if fits(probe, dims) and not clashes(out, probe) then return probe end
    end
    for r = vacated.row, vacated.row + vacated.h - 1 do
        local p = try(b.col, r)
        if p then return p end
    end
    for r = vacated.row, vacated.row + vacated.h - 1 do
        for c = vacated.col, vacated.col + vacated.w - 1 do
            local p = try(c, r)
            if p then return p end
        end
    end
    local best, best_d
    for r = 1, dims.rows - b.h + 1 do
        for c = 1, dims.cols - b.w + 1 do
            local d = math.abs(c - b.col) + math.abs(r - b.row)
            if not best_d or d < best_d then
                local p = try(c, r)
                if p then best, best_d = p, d end
            end
        end
    end
    return best
end

-- Swap the box `id` (now at `old`) with whatever fills `block`, a rectangle
-- the mover's size: valid only when every module touching the block lies
-- wholly inside it and there is at least one (two stacked 2x1 cards beside a
-- 2x2 clock swap with it as a pair). nil otherwise.
local function swapBlock(boxes, id, old, block)
    if block.w ~= old.w or block.h ~= old.h or not fits(block, { cols = math.huge, rows = math.huge })
            or M.overlaps(block, old) then
        return nil
    end
    local dc, dr = old.col - block.col, old.row - block.row
    local out, moved, area = {}, 0, 0
    for _i, b in ipairs(M.readingOrder(boxes)) do
        if b.id == id then
            b.page, b.col, b.row = block.page, block.col, block.row
        elseif M.overlaps(b, block) then
            if b.col < block.col or b.row < block.row
                    or b.col + b.w > block.col + block.w
                    or b.row + b.h > block.row + block.h then
                return nil
            end
            b.page, b.col, b.row = old.page, b.col + dc, b.row + dr
            moved = moved + 1
            area = area + b.w * b.h
        end
        out[#out + 1] = b
    end
    -- Only a block the modules fill completely: one with a gap in it is not
    -- the mover's equal, and the ordinary move (into the gap) is what's meant.
    if moved == 0 or area ~= block.w * block.h then return nil end
    return out
end

-- A move whose target lands on a block of modules that is exactly the mover's
-- size: swap with the whole block (see swapBlock).
local function groupSwap(boxes, id, old, target, displaced)
    if #displaced == 0 or target.w ~= old.w or target.h ~= old.h then return nil end
    local c1, r1, c2, r2 = math.huge, math.huge, -math.huge, -math.huge
    for _i, b in ipairs(displaced) do
        c1, r1 = math.min(c1, b.col), math.min(r1, b.row)
        c2, r2 = math.max(c2, b.col + b.w - 1), math.max(r2, b.row + b.h - 1)
    end
    return swapBlock(boxes, id, old,
        { page = target.page, col = c1, row = r1, w = c2 - c1 + 1, h = r2 - r1 + 1 })
end

-- The collision rule shared by every edit: put `id` at `target`, re-home only
-- what it now overlaps, refuse when anything can't be re-homed (naming the
-- first module that couldn't be: nil, "no_room", blocker_id).
local function apply(boxes, id, target, dims)
    local old = find(boxes, id)
    if not old then return nil, "no_room" end
    target.id = id
    if not fits(target, dims) then return nil, "no_room" end
    local out = {}
    local displaced = {}
    for _i, b in ipairs(M.readingOrder(boxes)) do
        if b.id == id then
            out[#out + 1] = target
        elseif M.overlaps(b, target) then
            displaced[#displaced + 1] = b
        else
            out[#out + 1] = b
        end
    end
    local swapped = groupSwap(boxes, id, old, target, displaced)
    if swapped then return swapped end
    for _i, b in ipairs(displaced) do
        local placed = rehome(out, b, old, dims)
        if not placed then return nil, "no_room", b.id end
        out[#out + 1] = placed
    end
    return out
end

function M.move(boxes, id, dc, dr, dims)
    local b = find(boxes, id)
    if not b then return nil, "no_room" end
    -- A free cell that way: just step into it.
    local step = copyBox(b)
    step.col, step.row = b.col + dc, b.row + dr
    if fits(step, dims) and not clashes(boxes, step, id) then
        local out = copyAll(boxes)
        local nb = find(out, id)
        nb.col, nb.row = step.col, step.row
        return out
    end
    -- An arrow press next to a same-size block (one module, or several that
    -- fill it exactly) swaps with that block in one press.
    local block = { page = b.page, col = b.col + dc * b.w, row = b.row + dr * b.h, w = b.w, h = b.h }
    if fits(block, dims) then
        local swapped = swapBlock(boxes, id, copyBox(b), block)
        if swapped then return swapped end
    end
    local t = copyBox(b)
    t.col, t.row = b.col + dc, b.row + dr
    return apply(boxes, id, t, dims)
end

function M.moveTo(boxes, id, col, row, dims)
    local b = find(boxes, id)
    if not b then return nil, "no_room" end
    local t = copyBox(b)
    t.col, t.row = col, row
    return apply(boxes, id, t, dims)
end

-- Growing into neighbours: make every module the grown box now overlaps
-- narrower (or shorter) on the side facing it, so nothing has to move. nil
-- when any of them would go below its minimum (mins_for(id) -> w, h).
local function squeeze(boxes, id, t, axis, dims, mins_for)
    local pos, size = (axis == "w") and "col" or "row", (axis == "w") and "w" or "h"
    local limit = (axis == "w") and dims.cols or dims.rows
    local out = {}
    for _i, b in ipairs(boxes) do
        local nb = copyBox(b)
        if b.id == id then
            nb = copyBox(t)
            nb.id = id
        elseif M.overlaps(b, t) then
            local t1, t2 = t[pos], t[pos] + t[size] - 1
            local cut
            if b[pos] >= t1 then
                cut = t2 - b[pos] + 1          -- b is after t: take its near cells
                nb[pos] = b[pos] + cut
            else
                cut = b[pos] + b[size] - t1    -- b is before t: take its far cells
            end
            nb[size] = b[size] - cut
            local mw, mh = 1, 1
            if mins_for then mw, mh = mins_for(b.id) end
            local min = math.min(((axis == "w") and mw or mh) or 1, limit)
            if nb[size] < math.max(1, min) then return nil end
        end
        out[#out + 1] = nb
    end
    return out
end

--- Grow (+1) or shrink (-1) one axis ("w" or "h") by a cell. Growth goes
--- right/down, or left/up when already at that edge; shrinking takes the cell
--- off the side growth would add to. min_w/min_h clamp to the grid. Growing
--- first squeezes the neighbours it runs into (mins_for(id) -> their minimum
--- w, h), and only moves them aside when they can't give up a cell.
function M.resize(boxes, id, axis, delta, dims, min_w, min_h, mins_for)
    local b = find(boxes, id)
    if not b then return nil, "no_room" end
    local t = copyBox(b)
    local pos, size, limit, min
    if axis == "w" then
        pos, size, limit = "col", "w", dims.cols
        min = math.min(min_w or 1, dims.cols)
    else
        pos, size, limit = "row", "h", dims.rows
        min = math.min(min_h or 1, dims.rows)
    end
    local at_far_edge = (t[pos] + t[size] - 1 >= limit) and t[pos] > 1
    if delta < 0 then
        if t[size] - 1 < math.max(1, min) then return nil, "no_room" end
        t[size] = t[size] - 1
        if at_far_edge then t[pos] = t[pos] + 1 end
        return apply(boxes, id, t, dims)
    end
    -- Growing: the cell can come from either side (right/down first, then
    -- left/up). Least disruption wins: free space on either side, then
    -- squeezing the neighbours there, then moving them aside.
    local sides = {}
    if t[pos] + t[size] - 1 < limit then
        local g = copyBox(t); g[size] = g[size] + 1; sides[#sides + 1] = g
    end
    if t[pos] > 1 then
        local g = copyBox(t); g[pos], g[size] = g[pos] - 1, g[size] + 1; sides[#sides + 1] = g
    end
    if #sides == 0 then return nil, "no_room" end
    for _i, g in ipairs(sides) do
        g.id = id
        if not clashes(boxes, g, id) then
            local out = copyAll(boxes)
            local nb = find(out, id)
            nb[pos], nb[size] = g[pos], g[size]
            return out
        end
    end
    for _i, g in ipairs(sides) do
        local squeezed = squeeze(boxes, id, g, axis, dims, mins_for)
        if squeezed then return squeezed end
    end
    local out, why, blocker
    for _i, g in ipairs(sides) do
        out, why, blocker = apply(boxes, id, g, dims)
        if out then return out end
    end
    return nil, why, blocker
end

--- Move a box to the first free spot on another page.
function M.toPage(boxes, id, page, dims)
    local b = find(boxes, id)
    if not b then return nil, "no_room" end
    if b.page == page then return copyAll(boxes) end
    local c, r = M.firstFree(boxes, dims, page, b.w, b.h, id)
    if not c then return nil, "no_room" end
    local out = copyAll(boxes)
    local nb = find(out, id)
    nb.page, nb.col, nb.row = page, c, r
    return out
end

--- Pages holding at least one box, ascending, plus keep_page when given.
function M.pages(boxes, keep_page)
    local set = {}
    for _i, b in ipairs(boxes) do set[b.page] = true end
    if keep_page then set[keep_page] = true end
    local out = {}
    for p in pairs(set) do out[#out + 1] = p end
    table.sort(out)
    return out
end

--- Entry ids on one page grouped by their top-left row, in column order: the
--- row/col map HeroModules.navMove walks for d-pad focus.
function M.navRows(boxes, page)
    local rows, by_row = {}, {}
    for _i, b in ipairs(M.readingOrder(boxes)) do
        if b.page == page then
            if not by_row[b.row] then
                by_row[b.row] = {}
                rows[#rows + 1] = by_row[b.row]
            end
            local r = by_row[b.row]
            r[#r + 1] = b.id
        end
    end
    return rows
end

--- Upgrade path: snap the old row-packed layout onto the grid. `legacy` is the
--- old layout in reading order, { id, page, row, px_w, px_h } per module, row
--- being the module's row on its old page. The old packer gave every row on a
--- page the same height and filled each row's width exactly, so each old row
--- shares the grid's columns out by width (largest remainders, at least one
--- cell each) and gets an equal share of the grid's rows (the remainder going
--- one apiece to the first rows). Everything then
--- flows in order with its old page as the earliest it may land on, so a page
--- that fit one screen still fits one page, page order survives, and nothing
--- is dropped (a row with more modules than columns spills on).
function M.snapLegacy(legacy, dims)
    local pages, by_page = {}, {}
    for _i, l in ipairs(legacy) do
        local p = math.max(1, l.page or 1)
        if not by_page[p] then by_page[p] = { rows = {}, order = {} }; pages[#pages + 1] = p end
        local pg = by_page[p]
        local r = l.row or 1
        if not pg.rows[r] then pg.rows[r] = {}; pg.order[#pg.order + 1] = r end
        local row = pg.rows[r]
        row[#row + 1] = l
    end
    table.sort(pages)
    local boxes = {}
    for _i, p in ipairs(pages) do
        local pg = by_page[p]
        table.sort(pg.order)
        -- Every grid row goes to some old row: an equal share each, and the
        -- remainder one apiece to the first rows (7 rows over 4 old rows =
        -- 2, 2, 2, 1), so the page is filled rather than bunched at the top.
        local share = math.floor(dims.rows / #pg.order)
        local extra = (share >= 1) and (dims.rows - share * #pg.order) or 0
        for j, r in ipairs(pg.order) do
            local h = math.max(1, share + ((j <= extra) and 1 or 0))
            local row = pg.rows[r]
            local total = 0
            for _k, l in ipairs(row) do total = total + math.max(0, l.px_w or 0) end
            local ws, rems, used = {}, {}, 0
            for k, l in ipairs(row) do
                local ideal = (total > 0) and (math.max(0, l.px_w or 0) / total * dims.cols)
                    or (dims.cols / #row)
                ws[k] = math.max(1, math.floor(ideal))
                rems[k] = ideal - math.floor(ideal)
                used = used + ws[k]
            end
            while used < dims.cols do
                local best
                for k = 1, #row do
                    if not best or rems[k] > rems[best] then best = k end
                end
                ws[best], rems[best] = ws[best] + 1, -1
                used = used + 1
            end
            for k, l in ipairs(row) do
                boxes[#boxes + 1] = { id = l.id, page = p, col = 1, row = 1, w = ws[k], h = h }
            end
        end
    end
    return M.flow(boxes, dims, 1)
end

-- ── Stored positions ─────────────────────────────────────────────────────────
-- Entries carry their position as entry[key] = { page, col, row, w, h }, with
-- key "at" (portrait) or "at_land" (landscape).

local FIELDS = { "page", "col", "row", "w", "h" }

function M.validAt(at)
    if type(at) ~= "table" then return false end
    for _i, f in ipairs(FIELDS) do
        local v = at[f]
        if type(v) ~= "number" or v < 1 or v ~= math.floor(v) then return false end
    end
    return true
end

--- Sanitiser helper for the models: the entry with any malformed "at" /
--- "at_land" dropped (a shallow copy when something was), plus whether it was.
function M.cleanPositions(entry)
    local bad = {}
    for _i, k in ipairs({ "at", "at_land" }) do
        if entry[k] ~= nil and not M.validAt(entry[k]) then bad[k] = true end
    end
    if not next(bad) then return entry, false end
    local e = {}
    for k, v in pairs(entry) do if not bad[k] then e[k] = v end end
    return e, true
end

--- Boxes for the items that have a valid position under `key`, plus the items
--- that don't (in their list order).
function M.boxesFrom(items, key)
    local boxes, unplaced = {}, {}
    for _i, it in ipairs(items) do
        local at = it[key]
        if M.validAt(at) then
            boxes[#boxes + 1] = { id = it.id, page = at.page, col = at.col,
                row = at.row, w = at.w, h = at.h }
        else
            unplaced[#unplaced + 1] = it
        end
    end
    return boxes, unplaced
end

--- Write box positions back onto the items with matching ids (mutates items).
function M.writeBack(items, boxes, key)
    local by_id = {}
    for _i, b in ipairs(boxes) do by_id[b.id] = b end
    for _i, it in ipairs(items) do
        local b = by_id[it.id]
        if b then
            it[key] = { page = b.page, col = b.col, row = b.row, w = b.w, h = b.h }
        end
    end
end

return M
