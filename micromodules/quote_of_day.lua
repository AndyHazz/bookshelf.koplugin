--[[
Start-menu module: quote of the day, sourced from the user's own highlights.
See README.md in this directory for the module spec contract.

Storage shape (KOReader DocSettings sidecars, accessed ONLY via the
DocSettings API — never by statting sibling .sdr paths):
  * modern: "annotations" array — highlights carry `drawer` + `text` (the
    highlighted passage) + page (xpointer for rolling docs, number for
    paged) + pos0/pos1; page bookmarks have NO `drawer` and their `text`
    is auto-filler ("in <chapter>"), so we require `drawer`.
  * legacy: "highlight" table keyed by page number → array of { text,
    pos0, ... } (pos0 is an xpointer string for rolling docs, a position
    table for paged ones).
Both shapes are handled; note-less bookmarks without highlight text are
skipped. Each collected quote carries the source book's filepath and the
highlight's position so the tap actions can act on it.

Settings (long-press the card > "Module settings…"; stored under the
micromodule_quote_of_day_* keys — the module-settings convention):
  * refresh: "daily" (default — the original once-per-day behaviour) or
    "open" (a fresh quote on every menu open, keyed on the loader's
    menu-open generation counter; see the README).
  * tap: "new" (default — roll a new quote, menu stays open via the
    keep_open function), "bookmarks" (open KOReader's bookmark browser
    for the quote's book; menu closes first) or "open_book" (open the
    book and jump to the quote; menu closes first).

Open-at-quote mechanism: ReaderUI:showReader's after_open_callback (the
same hook the bookmark browser's "View in book" uses) runs with the ready
ReaderUI, then ui.bookmark:gotoBookmark(page_or_xp, pos0) navigates —
GotoXPointer for rolling docs, GotoPage for paged ones. Legacy paged
highlights jump to the PAGE (their pos0 is a position table, not an
xpointer); legacy rolling highlights use pos0's xpointer, matching
ReaderAnnotation:migrateToAnnotations. A legacy quote with no usable
target still opens the book, just without the jump.

Bookmark-list limitation: BookmarkBrowser:getBookList reads only the
modern "annotations" array, so a legacy-only sidecar (book never reopened
since KOReader's annotations refactor) has nothing to show — we surface a
brief notification instead of an empty browser.
]]
local _ = require("lib/bookshelf_i18n").gettext
local SafeText = require("lib/bookshelf_text_safe")

local MAX_BOOKS  = 25  -- most-recent ReadHistory entries walked
local MAX_QUOTES = 200 -- total highlights collected across those books
local MAX_CHARS  = 280 -- long quotes truncated on a word boundary

local REFRESH_KEY = "micromodule_quote_of_day_refresh" -- "daily" | "open"
local TAP_KEY     = "micromodule_quote_of_day_tap"     -- "new" | "bookmarks" | "open_book"

local function readRefresh()
    local Store = require("lib/bookshelf_settings_store")
    local v = Store.read(REFRESH_KEY, "daily")
    if v ~= "open" then v = "daily" end
    return v
end

local function readTap()
    local Store = require("lib/bookshelf_settings_store")
    local v = Store.read(TAP_KEY, "new")
    if v ~= "bookmarks" and v ~= "open_book" then v = "new" end
    return v
end

-- Cache keyed by a refresh-mode string (see cacheKey): the sidecar walk
-- runs once per key. data = { text, title, filepath, page, pos0, legacy }
-- or false for "no highlights". The key is stable across the menu's
-- focus-step rebuilds in BOTH modes, so the shown quote never changes
-- under a key-nav step.
local _cache -- { key = <string>, data = <quote table> | false }
-- Session nonce mixed into the daily pick seed and the per-open cache
-- key; "New quote" bumps it so the deterministic daily pick re-rolls to
-- a different quote without waiting for the date to change. In-memory
-- only: a restart returns daily mode to its canonical date pick.
local _nonce = 0
-- Untruncated text of the last shown quote; the per-open random pick
-- skips it (when alternatives exist) so consecutive opens / re-rolls
-- always show something new.
local _last_text

local function cacheKey()
    if readRefresh() == "open" then
        local Modules = require("lib/bookshelf_start_menu_modules")
        return "g" .. tostring(Modules.menu_generation) .. ":" .. _nonce
    end
    return "d" .. os.date("%Y-%m-%d") .. ":" .. _nonce
end

local function truncateQuote(s)
    if #s <= MAX_CHARS then return s end
    local cut = s:sub(1, MAX_CHARS)
    cut = cut:match("^(.-)%s+%S*$") or cut -- back off to a word boundary
    return cut .. "\xE2\x80\xA6"
end

-- Walk ReadHistory newest-first (same require the book repository wraps),
-- collect highlight texts + positions from each book's sidecar. Every file
-- access is inside the caller's pcall; caps keep the walk bounded.
local function collectQuotes()
    local quotes = {}
    local DocSettings = require("docsettings")
    local rh = require("readhistory")
    local n_books = 0
    for _i, entry in ipairs(rh.hist or {}) do
        if n_books >= MAX_BOOKS or #quotes >= MAX_QUOTES then break end
        local fp = entry.file
        -- hasSidecarFile gates the heavier DocSettings:open and is correct
        -- for all three metadata locations (doc/dir/hash) — never stat a
        -- sibling .sdr path directly.
        if fp and DocSettings:hasSidecarFile(fp) then
            n_books = n_books + 1
            local ok_ds, ds = pcall(DocSettings.open, DocSettings, fp)
            if ok_ds and ds then
                local title
                local ok_p, props = pcall(ds.readSetting, ds, "doc_props")
                if ok_p and type(props) == "table"
                        and type(props.title) == "string"
                        and props.title ~= "" then
                    title = props.title
                end
                if not title then
                    title = (fp:match("([^/]+)$") or fp):gsub("%.[^.]+$", "")
                end
                local function add(text, page, pos0, legacy)
                    if #quotes < MAX_QUOTES and type(text) == "string"
                            and text ~= "" then
                        quotes[#quotes + 1] = {
                            -- Highlight text and book title come from file
                            -- metadata (untrusted); sanitise before render to
                            -- avoid a shaper crash on bad UTF-8 (issue #163).
                            text = SafeText.safe(text), title = SafeText.safe(title),
                            filepath = fp,
                            page = page, pos0 = pos0, legacy = legacy,
                        }
                    end
                end
                local ok_a, ann = pcall(ds.readSetting, ds, "annotations")
                if ok_a and type(ann) == "table" and #ann > 0 then
                    for _j, a in ipairs(ann) do
                        -- `drawer` set = real highlight; bookmarks (no
                        -- drawer) carry auto-filler text we must not quote.
                        if type(a) == "table" and a.drawer then
                            add(a.text, a.page, a.pos0)
                        end
                    end
                else
                    -- Legacy pre-annotations sidecar. Sort page keys so the
                    -- collection order (and thus the daily pick) is stable.
                    local ok_h, hl = pcall(ds.readSetting, ds, "highlight")
                    if ok_h and type(hl) == "table" then
                        local pages = {}
                        for page in pairs(hl) do pages[#pages + 1] = page end
                        table.sort(pages, function(a, b)
                            return tostring(a) < tostring(b)
                        end)
                        for _p, page in ipairs(pages) do
                            local list = hl[page]
                            if type(list) == "table" then
                                for _j, h in ipairs(list) do
                                    if type(h) == "table" then
                                        add(h.text, tonumber(page) or page,
                                            h.pos0, true)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return quotes
end

-- Pick one quote from the collection.
--   daily: deterministic seed (date + count, the original formula) plus
--     the session nonce — stable all day and across restarts, but each
--     "New quote" bump steps to the NEXT quote, so it always changes when
--     more than one exists.
--   open: random per pick, skipping the last shown quote when any
--     alternative exists, so consecutive menu opens differ.
local function pickQuote(quotes)
    local n = #quotes
    if readRefresh() == "open" then
        local idx = math.random(n)
        if n > 1 and _last_text and quotes[idx].text == _last_text then
            idx = idx % n + 1
        end
        return quotes[idx]
    end
    local seed = (tonumber(os.date("%Y%m%d")) or 0) + n + _nonce
    return quotes[(seed % n) + 1]
end

-- KOReader does not seed math.random globally; without this the per-open
-- pick sequence would repeat after every restart.
math.randomseed(os.time())

local function quoteOfTheDay()
    local key = cacheKey()
    if _cache and _cache.key == key then
        return _cache.data or nil
    end
    local data = false
    local ok, quotes = pcall(collectQuotes)
    if not ok then
        require("logger").warn("[bookshelf] quote of the day unavailable:",
            quotes)
        quotes = nil
    end
    if quotes and #quotes > 0 then
        local pick = pickQuote(quotes)
        _last_text = pick.text
        data = {
            text = truncateQuote(pick.text), title = pick.title,
            filepath = pick.filepath, page = pick.page, pos0 = pick.pos0,
            legacy = pick.legacy,
        }
    end
    _cache = { key = key, data = data }
    return data or nil
end

-- Module settings dialog (long-press > "Module settings…"): two radio
-- groups under greyed header rows. Each pick saves, reloads the menu
-- beneath and re-opens the dialog so the checkmark refreshes — same
-- close-and-reopen pattern as the clock's format trio. Switching refresh
-- mode needs no explicit invalidation: the cache key changes shape.
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
            { radio(_("Once per day"), REFRESH_KEY, readRefresh, "daily") },
            { radio(_("Every menu open"), REFRESH_KEY, readRefresh, "open") },
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
    render = function(width, scale_pct)
        local Blitbuffer    = require("ffi/blitbuffer")
        local Fonts         = require("lib/bookshelf_fonts")
        local TextWidget    = require("ui/widget/textwidget")
        local VerticalGroup = require("ui/widget/verticalgroup")
        local SM            = require("lib/bookshelf_start_menu_modules")
        local mw = math.max(50, width)
        local function sc(n) return math.max(1, math.floor(n * (scale_pct or 100) / 100 + 0.5)) end
        local q = quoteOfTheDay()
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
        local TextBoxWidget = require("ui/widget/textboxwidget")
        local face_q = Fonts:getFace("cfont", sc(15))
        -- Wrapped quote, capped at ~4 lines (char-truncated above; the
        -- height clamp catches narrow panels). height must be a multiple
        -- of the line height for clean clipping — TextBoxWidget adjusts
        -- via height_adjust.
        local quote_box = TextBoxWidget:new{
            text  = "\xE2\x80\x9C" .. q.text .. "\xE2\x80\x9D", -- "…"
            face  = face_q,
            width = mw,
            height = math.floor(face_q.size * 1.3 + 0.5) * 4,
            height_adjust = true,
            height_overflow_show_ellipsis = true,
            fgcolor = SM.COLOR_PRIMARY,
            -- TextBoxWidget paints an opaque background (unlike TextWidget);
            -- match the module card's grey or the text sits on a white bar.
            bgcolor = require("lib/bookshelf_start_menu_modules").CARD_BG,
        }
        return VerticalGroup:new{
            align = "left",
            quote_box,
            TextWidget:new{
                text = "\xE2\x80\x94 " .. q.title, -- "— <book title>"
                face = Fonts:getFace("cfont", sc(13), {italic=true}),
                fgcolor = SM.COLOR_PRIMARY,
                max_width = mw,
            },
        }
    end,
    show_settings = showSettings,
    -- The menu stays open only for the "New quote" tap action (the reload
    -- that follows re-renders this card with the fresh pick); the bookmark
    -- list and open-at-quote actions need the menu out of the way first.
    keep_open = function() return readTap() == "new" end,
    on_tap = function(ctx)
        local tap = readTap()
        if tap == "new" then
            -- Force a fresh pick. The nonce keys into BOTH modes' cache
            -- keys (and shifts the daily seed), so this overrides the date
            -- key too; _activate's keep_open reload re-renders the card.
            _nonce = _nonce + 1
            _cache = nil
            return
        end
        local q = _cache and _cache.data
        if not (q and q.filepath) then return end
        -- Same stale-record guard as bookshelf_widget._openBook.
        local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
        if ok_lfs and lfs.attributes(q.filepath, "mode") ~= "file" then return end
        if tap == "bookmarks" then
            local UIManager = require("ui/uimanager")
            if q.legacy then
                -- Legacy-only sidecar: the browser reads only the modern
                -- annotations array and would come up empty (see header).
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
            -- `for file in pairs(files)` and uses the KEY as the path —
            -- same gotcha as the book menu's bookmark link.
            BookmarkBrowser:show({ [q.filepath] = true }, FileManager.instance)
            return
        end
        -- tap == "open_book": open the reader, then jump to the quote once
        -- the document is ready (after_open_callback runs with the ready
        -- ReaderUI — the bookmark browser's "View in book" mechanism).
        local function gotoQuote(ui)
            local target = q.page
            if ui.rolling and type(target) ~= "string" then
                -- Legacy rolling sidecar: page is a number but the doc
                -- navigates by xpointer; pos0 carries it (same mapping as
                -- ReaderAnnotation:migrateToAnnotations).
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
            -- The widget path keeps the bookshelf housekeeping (status
            -- timer, rotation save, hero memo drop) in one place.
            bw:_openBook({ filepath = q.filepath }, gotoQuote)
        else
            local ReaderUI = require("apps/reader/readerui")
            ReaderUI:showReader(q.filepath, nil, nil, nil, gotoQuote)
        end
    end,
}
