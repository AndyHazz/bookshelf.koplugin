--[[
Opening a book from a micro-module's own covers or spines (the Shelf module),
the way the shelf opens one.

- In the top panel, or among a shelf's books with the top panel on screen, a
  tap shows the book in the panel and a second tap opens it, as a shelf cover
  does. Elsewhere (the full-screen view, the start menu, a full screen shelf,
  over the reader) there is no panel to show it in, and a tap follows the
  full screen shelves' setting (Store.expandedTapAction). "open" opens;
  "open_double" marks the book first (the module re-renders with the cover
  ringed) and opens on a second tap;
  "show_detail" closes the full-screen view and shows the book in the top
  panel, or marks it like "open_double" where there is no top panel (over
  the reader).
- A double tap opens straight away, when KOReader's double tap is on.
- Opening plays the cover-opening effect on the tapped cover or spine while
  it is still on screen. With the effect on, the shelf leaves out KOReader's
  "Opening file" message (the effect IS the feedback), so closing the
  full-screen view first, as this used to, opened with no feedback at all.
  The full-screen view now goes once the reader is up.
]]
local M = {}

-- key (a module's id) -> the filepath its first tap marked.
M._staged = {}

local function Store() return require("lib/bookshelf_settings_store") end

-- panelShowing(ctx, bw): the module sits in the top panel or on the shelf
-- under it, and the panel is on screen (not a full screen shelf, not over the
-- reader). The full-screen view and the start menu cover it.
local function panelShowing(ctx, bw)
    local surface = ctx and ctx.surface
    return (surface == "hero" or surface == "shelf")
        and bw ~= nil and bw._previewBook ~= nil
        and not bw._expanded and not bw._reader_context
end

--- staged(key, ctx) -> the filepath a module has marked, for its render's
--- ring (covers) or lift (spines). With the top panel on screen that is the
--- module's own book in the panel, noted when it was tapped
--- (bw._module_lifts) so the module redraws when another book takes the
--- panel. Only a module holding a lift redraws: every module re-rendering on
--- every shelf tap slowed the shelf's taps.
function M.staged(key, ctx)
    local bw = ctx and ctx.bw
    if key ~= nil and panelShowing(ctx, bw) then
        local l = bw._module_lifts and bw._module_lifts[key]
        local p = bw._preview_book
        return (l and p and l.fp == p.filepath) and l.fp or nil
    end
    return key ~= nil and M._staged[key] or nil
end

-- A lift moves by flipping two spine slots' flags and repainting them, as
-- the shelf's own does (BookshelfWidget:_repaintSpineSelection), not by
-- re-rendering the module. The slots are looked up in the shelf as it is on
-- screen: the module renders several times while it fits its cell, so rows
-- noted at render time were often not the ones painted.
-- slotsIn(node, fp, depth, out): every spine slot showing fp (from the rows'
-- _slots_by_fp registries). Returns false when one is a face-out book, whose
-- lift is built into the row.
local function slotsIn(node, fp, depth, out)
    if type(node) ~= "table" or depth > 14 then return true end
    local reg = rawget(node, "_slots_by_fp")
    local slot = reg and reg[fp]
    if slot then
        if not slot.entry then return false end
        out[slot] = true
    end
    for _i, c in ipairs(node) do
        if type(c) == "table" and not slotsIn(c, fp, depth + 1, out) then return false end
    end
    return true
end

-- redraw(bw, key, refresh): the module made again in its own cell (a
-- face-out book's lift is built into its row), else its host's refresh.
local function redraw(bw, key, refresh)
    local ok, HM = pcall(require, "lib/bookshelf_hero_modules")
    if ok and HM._reloadShelfCell and HM._reloadShelfCell(bw, key) then return end
    if refresh then refresh() end
end

--- relift(bw, key, old_fp, new_fp) -> true when both moves were made in
--- place (and the two slots repainted); false: the caller redraws.
function M.relift(bw, key, old_fp, new_fp)
    local root = bw and bw._inner_vgroup
    if not root then return false end
    local found = {}
    for _i, fp in ipairs({ old_fp or false, new_fp or false }) do
        if fp then
            local slots = {}
            if not slotsIn(root, fp, 0, slots) or next(slots) == nil then return false end
            for slot in pairs(slots) do found[#found + 1] = { slot = slot, on = (fp == new_fp) } end
        end
    end
    local UIManager = require("ui/uimanager")
    -- Upward by the lift's reach, as the shelf's own repaint does.
    local pad = math.max(require("device").screen:scaleBySize(12), bw._spine_lift_headroom or 0)
    for _i, f in ipairs(found) do
        f.slot.is_selected = f.on
        local d = f.slot.dimen
        if d then
            local r = { x = d.x, y = math.max(0, d.y - pad), w = d.w, h = d.h + pad }
            UIManager:setDirty(bw, function()
                return "ui", require("ui/geometry"):new(r)
            end)
        end
    end
    return true
end

--- previewChanged(bw, fp): the shelf put another book in the top panel; a
--- module lifting the old one redraws without it.
function M.previewChanged(bw, fp)
    local lifts = bw and bw._module_lifts
    if not lifts then return end
    for key, l in pairs(lifts) do
        if l.fp ~= fp then
            lifts[key] = nil
            if not M.relift(bw, key, l.fp, nil) then
                require("ui/uimanager"):nextTick(function() redraw(bw, key, l.refresh) end)
            end
        end
    end
end

local function closeFullscreen(fs)
    if fs and fs.onTapClose then pcall(function() fs:onTapClose() end) end
end

-- playOpening(fp): the shelf's cover-opening effect on the module's own cover
-- (SpineWidget's tap rendezvous) or spine (SpineShelf's), drawn now, before
-- anything closes.
function M.playOpening(fp)
    local SpineWidget = require("lib/bookshelf_spine_widget")
    local SpineShelf  = require("lib/bookshelf_spine_shelf")
    local slot = SpineShelf.last_tapped_slot
    SpineShelf.last_tapped_slot = nil
    local tile = SpineWidget.last_tapped
    if not Store().nilOrTrue("open_cover_effect") then
        SpineWidget.last_tapped = nil
        return
    end
    local UIManager = require("ui/uimanager")
    if tile and tile.book and tile.book.filepath == fp then
        UIManager:forceRePaint()
        local ok, BW = pcall(require, "lib/bookshelf_widget")
        -- Only the tapped-tile branch runs (its own validation passes); the
        -- stub answers the shelf-only question it falls back on otherwise.
        if ok and BW and BW._paintOpeningEffect then
            pcall(BW._paintOpeningEffect, { _isSpineMode = function() return false end }, fp)
        end
        return
    end
    SpineWidget.last_tapped = nil
    if slot and slot.book and slot.book.filepath == fp and SpineShelf.paintOpeningTilt then
        UIManager:forceRePaint()
        local x, y, w, h = SpineShelf.paintOpeningTilt(slot)
        if x and w and w > 0 then
            pcall(function() require("device").screen:refreshUI(x, y, w, h) end)
        end
    end
end

--- open(ctx, book): open it as the shelf does, effect first.
function M.open(ctx, book)
    if not (book and book.filepath) then return end
    M.playOpening(book.filepath)
    local bw = ctx and ctx.bw
    local fs = bw and bw._micro_fullscreen
    if bw and bw._openBook then
        bw:_openBook(book, function() closeFullscreen(fs) end, { no_effect = true })
    else
        require("apps/reader/readerui"):showReader(book.filepath)
    end
end

--- tap(ctx, key, book): a single tap on one of the module's books.
function M.tap(ctx, key, book)
    if not (book and book.filepath) then return end
    local bw = ctx and ctx.bw
    -- In the top panel or among a shelf's books, with the panel on screen, a
    -- tap does what a tap on a shelf cover does: the book goes into the
    -- panel, and a tap on the book already there opens it.
    if panelShowing(ctx, bw) then
        M._staged[key] = nil
        if bw._preview_book and bw._preview_book.filepath == book.filepath then
            M.open(ctx, book)
        else
            -- The book isn't one of the shelf's own: nothing of the shelf's
            -- to re-ring (see _repaintSelectionHighlight's fallback).
            bw._preview_from_module = true
            local ok, err = pcall(bw._previewBook, bw, book)
            bw._preview_from_module = nil
            if not ok then error(err) end
            bw._module_lifts = bw._module_lifts or {}
            bw._module_lifts[key] = { fp = book.filepath, refresh = ctx.refresh }
            -- Lift (or ring) the book here too, as the shelf does. (In the
            -- top panel the module has given way to the book.)
            if ctx.surface == "shelf" and not M.relift(bw, key, nil, book.filepath) then
                redraw(bw, key, ctx.refresh)
            end
        end
        return
    end
    local action = Store().expandedTapAction()
    if action == "show_detail" and bw and bw._previewBook and not bw._reader_context then
        M._staged[key] = nil
        closeFullscreen(bw._micro_fullscreen)
        bw:_previewBook(book)
        return
    end
    if action ~= "open" and M._staged[key] ~= book.filepath then
        M._staged[key] = book.filepath
        if ctx.refresh then ctx.refresh() end
        return
    end
    M._staged[key] = nil
    M.open(ctx, book)
end

--- doubleTap(ctx, key, book): KOReader's double tap opens straight away.
function M.doubleTap(ctx, key, book)
    if not require("lib/bookshelf_gestures").on("double_tap") then return end
    M._staged[key] = nil
    M.open(ctx, book)
end

return M
