--[[
Micro-module: the covers of the books you read last, tap one to open it
(PR 188, by rapinoinfeliz, rebuilt to the current module spec).

Books come from KOReader's own reading history (history.lua, what the Recent
shelf shows), newest first, skipping files that are gone. How many is set per
card in its settings: Fit (the default) shows as many as the cell holds at
full height, or pick a number.

Covers are the shelf's own SpineWidget, as list rows draw their thumbnails: it
fetches and caches the scaled cover itself, so nothing here holds a bitmap
across renders (a Book's cover_bb is freed after one paint). Each cover is a
tap region; a tap outside them, or the D-pad centre key, opens the newest.

The key is "last_books", not the PR's "lastbooks", so a copy of the PR's file
left in the user micromodules folder cannot override this one.
]]
local _ = require("lib/bookshelf_i18n").gettext

-- "fit": as many as the cell holds at full height (the default); or a fixed
-- number. With no height to fit (the start menu), "fit" shows three.
local DEFAULT_COUNT = "fit"
local COUNTS = { "fit", 2, 3, 4, 5 }

-- The records for the newest history entries, rebuilt only when the history
-- changes (its newest entry or its length): render runs on every paint, and a
-- record is a metadata read per book.
local _cache = { sig = nil, books = {} }

local function history()
    local ok, ReadHistory = pcall(require, "readhistory")
    if not ok or not ReadHistory then return {} end
    pcall(function() ReadHistory:reload() end)
    return ReadHistory.hist or {}
end

local function recentBooks(n)
    local hist = history()
    local first = hist[1]
    local sig = table.concat({ #hist, first and first.file or "", first and first.time or 0, n }, "|")
    if _cache.sig == sig then return _cache.books end
    local lfs = require("libs/libkoreader-lfs")
    local Repo = require("lib/bookshelf_book_repository")
    local books = {}
    for _i, entry in ipairs(hist) do
        if #books >= n then break end
        local fp = entry.file
        -- A Kobo store book's entry names its decrypted copy, gone after a
        -- restart: it stays, as its Kobo record (issue 546).
        local kobo = fp and Repo._koboRecordFor and Repo._koboRecordFor(fp)
        if kobo then
            books[#books + 1] = kobo
        elseif fp and lfs.attributes(fp, "mode") == "file" then
            local ok, rec = pcall(Repo.buildBookMeta, fp, { want_cover = false })
            if ok and rec then books[#books + 1] = rec end
        end
    end
    _cache = { sig = sig, books = books }
    return books
end

local function countOf(ctx)
    local v = ctx and ctx.config and ctx.config:get("count", DEFAULT_COUNT)
    return tonumber(v) or "fit"
end

local function openBook(ctx, book)
    if not (book and book.filepath) then return end
    local R = require("apps/reader/readerui")
    if R.instance and R.instance.document and R.instance.document.file == book.filepath then
        return  -- already open
    end
    local bw = ctx and ctx.bw
    if bw and bw._openBook then
        bw:_openBook(book)
    else
        R:showReader(book.filepath)
    end
end

local function showSettings(ctx)
    if not (ctx and ctx.config) then return end
    local UIManager    = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")
    local Kit = require("lib/bookshelf_module_kit")
    local cur = countOf(ctx)
    local dialog
    local row = {}
    for _i, n in ipairs(COUNTS) do
        row[#row + 1] = Kit.radioRow{
            label = (n == "fit") and _("Fit") or tostring(n), active = n == cur,
            on_pick = function()
                UIManager:close(dialog)
                ctx.config:set("count", n)
            end,
        }
    end
    dialog = ButtonDialog:new{
        title = _("Books to show"), title_align = "center", width_factor = 0.6,
        buttons = { row },
    }
    UIManager:show(dialog)
end

return {
    key     = "last_books",   -- stable id stored in user menus; never change it
    title   = _("Recently read"),
    summary = _("From your reading history. Works offline."),
    tap_feedback = true,

    render = function(ctx)
        local Kit = require("lib/bookshelf_module_kit")
        local SpineWidget = require("lib/bookshelf_spine_widget")
        local sc = Kit.sc(ctx.scale)
        local gap = sc(10)
        local n = countOf(ctx)
        if n == "fit" then
            local cap = ctx.height
            if cap and cap > 0 then
                -- The status-mark overhang depends on the cover width; take it
                -- for a full-height cover, which is what Fit draws.
                local m = SpineWidget.badgeOverhang(math.floor(cap * 2 / 3))
                n = Kit.coverFit(ctx.width, cap, gap, m)
            else
                n = 3
            end
        end
        -- History is local, so the picker's preview shows the real covers.
        local books = recentBooks(n)
        if #books == 0 then
            local TextWidget = require("lib/bookshelf_colour_text")
            local Fonts = require("lib/bookshelf_fonts")
            return TextWidget:new{
                text = _("No books read yet"),
                face = Fonts:getFace("cfont", sc(15)),
                fgcolor = Kit.COLOR_MUTED,
                max_width = math.max(50, ctx.width),
            }
        end
        local HorizontalGroup = require("ui/widget/horizontalgroup")
        local HorizontalSpan  = require("ui/widget/horizontalspan")
        -- Covers share the width, in the shelf's 2:3, and stop short of the
        -- height the host offers (a hero cell, or the start menu's ceiling).
        -- The status marks hang past the cover (the favourite above, the
        -- bookmarks and tick below), and the card clips to what render
        -- returns, so each cover keeps that much room above and below.
        local FrameContainer = require("ui/widget/container/framecontainer")
        local slots = math.max(n, #books)
        local w = math.floor((ctx.width - gap * (slots - 1)) / slots)
        local m = SpineWidget.badgeOverhang(w)
        local h = math.floor(w * 3 / 2)
        local cap = ctx.height or ctx.max_height
        if cap and cap > 0 and h + 2 * m > cap then
            h = cap - 2 * m
            w = math.floor(h * 2 / 3)
            m = SpineWidget.badgeOverhang(w)
        end
        w, h = math.max(1, w), math.max(1, h)
        local group, regions = HorizontalGroup:new{ align = "top" }, {}
        for i, book in ipairs(books) do
            if i > 1 then group[#group + 1] = HorizontalSpan:new{ width = gap } end
            group[#group + 1] = FrameContainer:new{
                bordersize = 0, margin = 0, padding = 0,
                padding_top = m, padding_bottom = m,
                SpineWidget:new{ book = book, width = w, height = h, show_status = true,
                                 room_below = true },
            }
            regions[#regions + 1] = { id = book.filepath,
                x = (i - 1) * (w + gap), y = m, w = w, h = h }
        end
        if ctx.set_tap_regions then ctx.set_tap_regions(regions) end
        return group
    end,

    on_tap = function(ctx)
        local books = _cache.books or {}
        local target = books[1]
        for _i, book in ipairs(books) do
            if book.filepath == ctx.tapped_region then target = book break end
        end
        openBook(ctx, target)
    end,

    show_settings = showSettings,
}
