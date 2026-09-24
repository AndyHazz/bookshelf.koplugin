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
  * "bookmarks": open KOReader's bookmark browser for the quote's book and
    land directly on this quote's note detail (issue #186) -- the full,
    untruncated highlight + note, with the list behind it (prev/next to
    browse the rest). Falls back to the plain list if the row can't be found.
  * "open_book": open the book and jump to the quote.

Open-at-quote uses ReaderUI:showReader's after_open_callback (the bookmark
browser's "View in book" hook): ui.bookmark:gotoBookmark(page_or_xp, pos0) --
GotoXPointer for rolling docs, GotoPage for paged. Legacy paged highlights jump
to the PAGE (pos0 is a position table, not an xpointer). The bookmark browser
reads only the modern "annotations" array, so a legacy-only sidecar surfaces a
brief notification instead of an empty browser.
]]
local _ = require("lib/bookshelf_i18n").gettext
local T = require("ffi/util").template
local Quotes = require("lib/bookshelf_quotes")

local TAP_KEY = "micromodule_quote_of_day_tap" -- "new" | "bookmarks" | "open_book"

local function readTap()
    local Store = require("lib/bookshelf_settings_store")
    local v = Store.read(TAP_KEY, "new")
    if v ~= "bookmarks" and v ~= "open_book" then v = "new" end
    return v
end

-- Match a quote against a bookmark-browser row: highlights are uniquely
-- identified by page + selection start (pos0), the same pair the quote
-- carries from the annotation. pos0 is a table for paged docs (x/y/page) and
-- absent/string for some rolling highlights, so compare by value.
local function posEqual(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k, v in pairs(a) do if b[k] ~= v then return false end end
    for k, v in pairs(b) do if a[k] ~= v then return false end end
    return true
end

-- Module settings dialog (long-press > "Module settings…"): two radio groups
-- under greyed header rows, then what to leave out -- the current quote's
-- book, and each highlight colour in use (issue 368). Each pick saves, reloads
-- the menu beneath and re-opens the dialog so the checkmark refreshes. Switching refresh mode needs
-- no explicit invalidation -- the shared cache key changes shape.
local function showSettings(ctx)
    local ButtonDialog = require("ui/widget/buttondialog")
    local UIManager    = require("ui/uimanager")
    local Store        = require("lib/bookshelf_settings_store")
    local Kit          = require("lib/bookshelf_module_kit")
    local dialog
    local function radio(label, store_key, read, value)
        return Kit.radioRow{
            label = label, active = read() == value,
            on_pick = function()
                Store.save(store_key, value)
                Kit.settingsReopen(ctx, dialog, showSettings)
            end,
        }
    end
    local function header(label)
        return { text = label, enabled = false }
    end
    local function source(label, value)
        return Kit.radioRow{
            label = label, active = Quotes.readSource() == value,
            on_pick = function()
                Quotes.setSource(value)
                Kit.settingsReopen(ctx, dialog, showSettings)
            end,
        }
    end
    local dirs = Quotes.quotesDirs()
    local rows = {
        -- Issue 258: SimpleUI's quote file format, read from bookshelf's own
        -- folder and from SimpleUI's.
        { header(_("Quotes from")) },
        { source(_("Your highlights"), "highlights") },
        { source(_("Quotes files"), "files") },
        { source(_("Both"), "both") },
        { { text = T(_("Quotes files go in %1"), dirs[1] or "?"), enabled = false } },
        { header(_("Refresh")) },
        { radio(_("Once per day"), Quotes.REFRESH_KEY, Quotes.readRefresh, "daily") },
        { radio(_("Every menu open"), Quotes.REFRESH_KEY, Quotes.readRefresh, "open") },
        { header(_("Tap action")) },
        { radio(_("New quote"), TAP_KEY, readTap, "new") },
        { radio(_("Open bookmark list"), TAP_KEY, readTap, "bookmarks") },
        { radio(_("Open book at quote"), TAP_KEY, readTap, "open_book") },
    }
    -- Issue 368: leave a book, or a highlight colour, out of the pool.
    local function row(text, fn)
        rows[#rows + 1] = { {
            text = text,
            callback = function() fn(); Kit.settingsReopen(ctx, dialog, showSettings) end,
        } }
    end
    local cur = Quotes.current()
    local skipped = Quotes.skippedBookCount()
    -- Colours only mean anything for highlights, and finding them walks the
    -- sidecars, so neither when the quotes come from files alone.
    local colours = Quotes.readSource() ~= "files" and Quotes.coloursInUse() or {}
    if (cur and cur.filepath) or skipped > 0 then
        rows[#rows + 1] = { header(_("Leave out")) }
        if cur and cur.filepath then
            row(T(_("Quotes from %1"), cur.title or "?"),
                function() Quotes.skipBook(cur.filepath) end)
        end
        if skipped > 0 then
            row(T(_("Bring back skipped books (%1)"), skipped), Quotes.unskipAllBooks)
        end
    end
    if #colours > 0 then
        -- KOReader's own names for its colours, already translated there.
        local ko_ = require("gettext")
        local NAMES = { red = "Red", orange = "Orange", yellow = "Yellow",
            green = "Green", olive = "Olive", cyan = "Cyan", blue = "Blue",
            purple = "Purple", gray = "Gray" }
        rows[#rows + 1] = { header(_("Highlight colors")) }
        for _i, c in ipairs(colours) do
            local name = NAMES[c] and ko_(NAMES[c]) or (c:gsub("^%l", string.upper))
            rows[#rows + 1] = { Kit.radioRow{
                label = name, active = not Quotes.isColorSkipped(c), toggle = true,
                on_pick = function()
                    Quotes.setColorSkipped(c, not Quotes.isColorSkipped(c))
                    Kit.settingsReopen(ctx, dialog, showSettings)
                end,
            } }
        end
    end
    dialog = ButtonDialog:new{
        title        = _("Quote of the day"),
        title_align  = "center",
        width_factor = 0.65,
        buttons      = rows,
    }
    UIManager:show(dialog)
end

return {
    key   = "quote_of_day", -- stable id stored in user menus; never change it
    title = _("Quote of the day"),
    summary = _("From your highlights. Works offline."),
    -- preview (3rd) / avail_h (4th): the Add-picker renders a preview=true
    -- thumbnail and passes the cell height as avail_h, so we truncate the quote
    -- to fit it at a readable size (issue #183). The hero grid passes neither
    -- preview nor a clamp, so the quote keeps its natural height for the fit
    -- engine to shrink to the cell.
    -- ctx.max_height is a ceiling WITHOUT a cell height: the start menu has no
    -- fit engine, so it caps a card at what the panel can show while leaving
    -- ctx.height nil (absent height is what marks "no height constraint", which
    -- is also how layout shape is decided -- see Kit.shape). Either source
    -- serves as the room to clamp into.
    render = function(ctx)
        local width, scale_pct, preview = ctx.width, ctx.scale, ctx.preview
        local avail_h = ctx.height or ctx.max_height
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
                text = Quotes.readSource() == "highlights" and _("No highlights yet")
                       or _("No quotes yet"),
                face = Fonts:getFace("cfont", sc(15)),
                fgcolor = SM.COLOR_MUTED,
                max_width = mw,
            }
        end
        local Kit = require("lib/bookshelf_module_kit")
        local quote_text = "\xE2\x80\x9C" .. q.text .. "\xE2\x80\x9D" -- "…"

        -- "— <book title>, <author>". A quote from a quotes file may have only
        -- an author, or neither (issue 258).
        local parts = {}
        if q.title and q.title ~= "" then parts[#parts + 1] = q.title end
        if q.author and q.author ~= "" then parts[#parts + 1] = q.author end
        local attribution = #parts > 0 and ("\xE2\x80\x94 " .. table.concat(parts, ", ")) or ""
        -- Attribution at the same font size as the quote (size 15), muted,
        -- wraps in a narrow cell so the author still shows.
        local attr = attribution ~= "" and Kit.fitText{ text = attribution, size = 15,
            scale_pct = scale_pct, width = mw, fgcolor = Kit.COLOR_MUTED,
            opts = { italic = true } } or nil
        -- In the picker preview, truncate the quote to the room left after the
        -- attribution so it fits the cell on a few lines at a readable size
        -- (issue #183). Everywhere else the quote body reports its NATURAL height
        -- (no max_h / ellipsis clamp) so the hero fit engine (_renderFitted)
        -- shrinks the font until quote + attribution fit, instead of truncating.
        -- ctx.clamp is the fit engine's last resort (issue #249): the quote
        -- still overflows at the smallest legible size, so ellipsise the QUOTE
        -- to the remaining room -- the attribution is the part that must
        -- never be lost to the cell's bottom clip.
        local max_h = ((preview or ctx.clamp) and avail_h and avail_h > 0)
            and math.max(1, avail_h - (attr and attr:getSize().h or 0)) or nil
        local quote_box = Kit.fitText{ text = quote_text, size = 15, scale_pct = scale_pct,
            width = mw, max_h = max_h }
        if not attr then return quote_box end
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
            -- FileManager may be torn down when the quote is opened from an
            -- in-reader launcher, leaving FileManager.instance nil. Bail rather
            -- than hand BookmarkBrowser a nil parent UI.
            local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
            local parent_ui = (ok_fm and FileManager and FileManager.instance) or nil
            if not parent_ui then return end
            -- files must be a SET keyed by filepath: getBookList iterates
            -- `for file in pairs(files)` and uses the KEY as the path.
            BookmarkBrowser:show({ [q.filepath] = true }, parent_ui)
            -- Land directly on this quote's note (issue #186): locate its row
            -- in the freshly-built list and open KOReader's own detail panel on
            -- top, reusing its rendering + prev/next + "View in book". show()
            -- populates bm_list.item_table synchronously. We mirror the
            -- browser's _showBookmarkDetails(idx) flow -- updateBookmarkList(i)
            -- positions the list at the row (which assigns item.idx, needed by
            -- the detail panel's prev/next buttons) before showing the detail.
            -- If the row can't be matched (annotation since deleted, etc.) we
            -- leave the plain list as-is. Guarded so a browser-internals change
            -- can never break the tap action.
            pcall(function()
                local list  = BookmarkBrowser.bm_list
                local items = list and list.item_table
                if not items then return end
                for i = 1, #items do
                    local it = items[i]
                    if it and not it.file and it.page == q.page
                            and posEqual(it.pos0, q.pos0) then
                        BookmarkBrowser:updateBookmarkList(i)
                        BookmarkBrowser:showBookmarkDetails(
                            BookmarkBrowser.bm_list.item_table[i])
                        break
                    end
                end
            end)
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
