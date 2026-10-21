--[[
Stored micro-module entries > the boxes a surface draws.

Each entry keeps its grid position on the entry itself: `at` for portrait,
`at_land` for landscape (see Grid.boxesFrom). This module decides, for one
build, where every entry goes and whether any of that is worth saving:

  - placing an entry that has no position yet (a newly added module)  SAVE
  - the one-time upgrade from the old row packer (migration)          SAVE
  - seeding the landscape layout the first time landscape is drawn    SAVE
  - re-homing modules that don't fit a smaller grid than they were
    laid out on (settings restored onto another device, a shorter
    top panel)                                                        NEVER

The last one is render-time only, so growing the grid back restores the
layout exactly as it was. Pure: no KOReader requires, no settings access; the
caller saves `items` when `changed` comes back true.
]]
local Grid = require("lib/bookshelf_module_grid")

local M = {}

function M.key(landscape)
    return landscape and "at_land" or "at"
end

--- resolveFor(items, dims, opts) -> render_boxes, changed
---   opts.landscape  draw the landscape layout
---   opts.migrated   the one-time upgrade already ran for this surface
---   opts.legacy()   -> { {id, page, px_w, px_h}, ... } the old packer's output
---   opts.size_for(item) -> w, h  size for an entry placed fresh
---   opts.page       page a fresh entry should land on first (default 1)
--- Mutates `items` (positions; legacy size/page cleared on migration) only for
--- work that should be saved, and reports it through `changed`.
function M.resolveFor(items, dims, opts)
    opts = opts or {}
    local key = M.key(opts.landscape)
    local size_for = opts.size_for or function() return 1, 1 end
    local boxes, unplaced = Grid.boxesFrom(items, key)
    local changed = false

    if #items > 0 and #boxes == 0 and opts.landscape then
        -- Landscape seed: the portrait layout in reading order (then anything
        -- portrait hasn't placed either), flowed onto the landscape grid. A
        -- device that has only shown landscape since the upgrade has no
        -- portrait layout yet: seed from the old packer's layout instead.
        local pboxes, punplaced = Grid.boxesFrom(items, "at")
        if #pboxes == 0 and not opts.migrated and opts.legacy then
            boxes = Grid.snapLegacy(opts.legacy(), dims)
            Grid.writeBack(items, boxes, key)
            return Grid.resolve(boxes, dims), true
        end
        -- Shrink portrait boxes to this grid's edges first (as drawing them
        -- would), so a module sized to "the rest of the row" stays on its row.
        local seq = Grid.readingOrder((Grid.resolve(pboxes, dims)))
        for _i, it in ipairs(punplaced) do
            local w, h = size_for(it)
            seq[#seq + 1] = { id = it.id, page = 1, col = 1, row = 1, w = w, h = h }
        end
        boxes = Grid.flow(seq, dims, 1)
        Grid.writeBack(items, boxes, key)
        changed = true
    elseif #items > 0 and #boxes == 0 and not opts.landscape
            and not opts.migrated and opts.legacy then
        -- One-time upgrade from the old row packer.
        boxes = Grid.snapLegacy(opts.legacy(), dims)
        Grid.writeBack(items, boxes, key)
        for _i, it in ipairs(items) do it.size, it.page = nil, nil end
        changed = true
    elseif #unplaced > 0 then
        for _i, it in ipairs(unplaced) do
            local w, h = size_for(it)
            local b = Grid.placeNew(boxes, dims, it.id, w, h, opts.page or 1)
            boxes[#boxes + 1] = b
        end
        Grid.writeBack(items, boxes, key)
        changed = true
    end

    local render = Grid.resolve(boxes, dims)
    return render, changed
end

return M
