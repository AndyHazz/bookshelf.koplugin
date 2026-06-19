--[[
Start-menu module: quote of the day, sourced from the user's own highlights.
See README.md in this directory for the module spec contract.

The quote provider (sidecar walk, daily pick, cache, refresh modes) lives in
lib/bookshelf_quotes.lua so this card and the %quote / %quote_source hero tokens
(issue #174) share one cache and show the same daily quote. This file keeps the
micromodule-specific bits: the settings dialog, render, and tap actions.

Tap actions (long-press > "Module settings…"; stored under
micromodule_quote_of_day_tap):
  * "new" (default): roll a new quote, menu stays open via keep_open.
  * "bookmarks": open KOReader's bookmark browser for the quote's book.
  * "open_book": open the book and jump to the quote.

Open-at-quote uses ReaderUI:showReader's after_open_callback (the bookmark
browser's "View in book" hook): ui.bookmark:gotoBookmark(page_or_xp, pos0) --
GotoXPointer for rolling docs, GotoPage for paged. Legacy paged highlights jump
to the PAGE (pos0 is a position table, not an xpointer). The bookmark browser
reads only the modern "annotations" array, so a legacy-only sidecar surfaces a
brief notification instead of an empty browser.
]]
local _ = require("lib/bookshelf_i18n").gettext
local Quotes = require("lib/bookshelf_quotes")

local TAP_KEY = "micromodule_quote_of_day_tap" -- "new" | "bookmarks" | "open_book"

local function readTap()
    local Store = require("lib/bookshelf_settings_store")
    local v = Store.read(TAP_KEY, "new")
    if v ~= "bookmarks" and v ~= "open_book" then v = "new" end
    return v
end

-- Module settings dialog (long-press > "Module settings…"): two radio groups
-- under greyed header rows. Each pick saves, reloads the menu beneath and
-- re-opens the dialog so the checkmark refreshes. Switching refresh mode needs
-- no explicit invalidation -- the shared cache key changes shape.
local function showSettings(ctx)
    local ButtonDialog = require("ui/widget/buttondialog")
    local UIManager    = require("ui/uimanager")
    local Store        = require("lib/bookshelf_settings_store")
    local dialog
    local function radio(label, store_key, read, value)
        local active = read() == value
        return {
            text = (active and "\xE2\x9C\x93 " or "  ") .. label,
            callback = function()
                if read() == value then return end
                Store.save(store_key, value)
                UIManager:close(dialog)
                if ctx and ctx.menu and ctx.menu._reload then ctx.menu:_reload() end
                showSettings(ctx)
            end,
        }
    end
    local function header(label)
        return { text = label, enabled = false }
    end
    dialog = ButtonDialog:new{
        title        = _("Quote of the day"),
        title_align  = "center",
        width_factor = 0.65,
        buttons      = {
            { header(_("Refresh")) },
            { radio(_("Once per day"), Quotes.REFRESH_KEY, Quotes.readRefresh, "daily") },
            { radio(_("Every menu open"), Quotes.REFRESH_KEY, Quotes.readRefresh, "open") },
            { header(_("Tap action")) },
            { radio(_("New quote"), TAP_KEY, readTap, "new") },
            { radio(_("Open bookmark list"), TAP_KEY, readTap, "bookmarks") },
            { radio(_("Open book at quote"), TAP_KEY, readTap, "open_book") },
        },
    }
    UIManager:show(dialog)
end

return {
    key   = "quote_of_day", -- stable id stored in user menus; never change it
    title = _("Quote of the day"),
    summary = _("From your highlights. Works offline."),
    -- avail_h (4th arg, optional): the cell height a caller (the hero grid)
    -- wants the module to fill. When given, the quote box grows to as many
    -- lines as fit instead of the fixed 4-line clamp used in the start menu.
    render = function(width, scale_pct, _preview, avail_h)
        local Fonts         = require("lib/bookshelf_fonts")
        local TextWidget    = require("ui/widget/textwidget")
        local VerticalGroup = require("ui/widget/verticalgroup")
        local SM            = require("lib/bookshelf_start_menu_modules")
        local mw = math.max(50, width)
        local function sc(n) return math.max(1, math.floor(n * (scale_pct or 100) / 100 + 0.5)) end
        local q = Quotes.ofTheDay()
        if not q then
            -- Muted fallback rather than nil so the card shows a friendly
            -- message instead of the raw module key.
            return TextWidget:new{
                text = _("No highlights yet"),
                face = Fonts:getFace("cfont", sc(15)),
                fgcolor = SM.COLOR_MUTED,
                max_width = mw,
            }
        end
        local Kit = require("lib/bookshelf_module_kit")
        local quote_text = "\xE2\x80\x9C" .. q.text .. "\xE2\x80\x9D" -- "…"

        local attribution = "\xE2\x80\x94 " .. q.title -- "— <book title>"
        if q.author and q.author ~= "" then
            attribution = attribution .. ", " .. q.author
        end
        -- Attribution at the same font size as the quote (size 15), muted,
        -- wraps in a narrow cell so the author still shows.
        local attr = Kit.fitText{ text = attribution, size = 15, scale_pct = scale_pct,
            width = mw, fgcolor = Kit.COLOR_MUTED, opts = { italic = true } }
        -- Quote body reports its NATURAL height (no max_h / ellipsis clamp) so
        -- the parent hero fit engine (_renderFitted) shrinks the font until quote
        -- + attribution fit, instead of the quote truncating. q.text is char-
        -- capped upstream, so the worst case is bounded.
        local quote_box = Kit.fitText{ text = quote_text, size = 15, scale_pct = scale_pct,
            width = mw }
        return VerticalGroup:new{ align = "left", quote_box, attr }
    end,
    show_settings = showSettings,
    -- The menu stays open only for the "New quote" tap action (the reload that
    -- follows re-renders this card with the fresh pick); the bookmark list and
    -- open-at-quote actions need the menu out of the way first.
    keep_open = function() return readTap() == "new" end,
    on_tap = function(ctx)
        local tap = readTap()
        if tap == "new" then
            -- Force a fresh pick; _activate's keep_open reload re-renders the card.
            Quotes.reroll()
            return
        end
        local q = Quotes.current()
        if not (q and q.filepath) then return end
        -- Same stale-record guard as bookshelf_widget._openBook.
        local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
        if ok_lfs and lfs.attributes(q.filepath, "mode") ~= "file" then return end
        if tap == "bookmarks" then
            local UIManager = require("ui/uimanager")
            if q.legacy then
                -- Legacy-only sidecar: the browser reads only the modern
                -- annotations array and would come up empty.
                UIManager:show(require("ui/widget/notification"):new{
                    text = _("No bookmark list for this book"),
                })
                return
            end
            local ok_bb, BookmarkBrowser =
                pcall(require, "ui/widget/bookmarkbrowser")
            if not (ok_bb and BookmarkBrowser) then return end
            local FileManager = require("apps/filemanager/filemanager")
            -- files must be a SET keyed by filepath: getBookList iterates
            -- `for file in pairs(files)` and uses the KEY as the path.
            BookmarkBrowser:show({ [q.filepath] = true }, FileManager.instance)
            return
        end
        -- tap == "open_book": open the reader, then jump to the quote once the
        -- document is ready (after_open_callback runs with the ready ReaderUI).
        local function gotoQuote(ui)
            local target = q.page
            if ui.rolling and type(target) ~= "string" then
                -- Legacy rolling sidecar: page is a number but the doc navigates
                -- by xpointer; pos0 carries it.
                target = type(q.pos0) == "string" and q.pos0 or nil
            elseif ui.paging and type(target) ~= "number" then
                target = nil
            end
            if not target then return end -- open without the jump
            pcall(function()
                ui.link:addCurrentLocationToStack()
                ui.bookmark:gotoBookmark(target, q.pos0)
            end)
        end
        local bw = ctx and ctx.bw
        if bw and bw._openBook then
            -- The widget path keeps the bookshelf housekeeping (status timer,
            -- rotation save, hero memo drop) in one place.
            bw:_openBook({ filepath = q.filepath }, gotoQuote)
        else
            local ReaderUI = require("apps/reader/readerui")
            ReaderUI:showReader(q.filepath, nil, nil, nil, gotoQuote)
        end
    end,
}
