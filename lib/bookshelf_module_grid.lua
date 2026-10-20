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

-- The collision rule shared by every edit: put `id` at `target`, re-home only
-- what it now overlaps, refuse when anything can't be re-homed.
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
    for _i, b in ipairs(displaced) do
        local placed = rehome(out, b, old, dims)
        if not placed then return nil, "no_room" end
        out[#out + 1] = placed
    end
    return out
end

function M.move(boxes, id, dc, dr, dims)
    local b = find(boxes, id)
    if not b then return nil, "no_room" end
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

--- Grow (+1) or shrink (-1) one axis ("w" or "h") by a cell. Growth goes
--- right/down, or left/up when already at that edge; shrinking takes the cell
--- off the side growth would add to. min_w/min_h clamp to the grid.
function M.resize(boxes, id, axis, delta, dims, min_w, min_h)
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
    if delta > 0 then
        if t[pos] + t[size] - 1 < limit then
            t[size] = t[size] + 1
        elseif t[pos] > 1 then
            t[pos], t[size] = t[pos] - 1, t[size] + 1
        else
            return nil, "no_room"
        end
    else
        if t[size] - 1 < math.max(1, min) then return nil, "no_room" end
        t[size] = t[size] - 1
        if at_far_edge then t[pos] = t[pos] + 1 end
    end
    return apply(boxes, id, t, dims)
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
--- cell each) and gets an equal share of the grid's rows. Everything then
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
        local h = math.max(1, math.floor(dims.rows / #pg.order))
        for _j, r in ipairs(pg.order) do
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
