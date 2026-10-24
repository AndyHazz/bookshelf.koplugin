--[[
Opening a book from a micro-module's own covers or spines (the Shelf module),
the way the shelf opens one.

- A tap follows the full screen shelves' setting (Store.expandedTapAction): a
  module has no top panel of its own to stage a book in, so it behaves like a
  full screen shelf. "open" opens; "open_double" marks the book first (the
  module re-renders with the cover ringed) and opens on a second tap;
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

--- staged(key) -> the filepath a module has marked, for its render's ring.
function M.staged(key) return key ~= nil and M._staged[key] or nil end

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
    local action = Store().expandedTapAction()
    local bw = ctx and ctx.bw
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
