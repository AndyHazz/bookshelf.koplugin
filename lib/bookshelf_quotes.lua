--[[
Shared "quote of the day" provider, sourced from the user's own highlights.

Extracted from the quote_of_day micromodule so the %quote / %quote_source hero
tokens (issue #174) and the micromodule draw from ONE cache -- the home screen
and the start-menu card show the same daily quote, and the sidecar walk runs
once per day rather than per consumer.

Storage shape (KOReader DocSettings sidecars, accessed ONLY via the DocSettings
API -- never by statting sibling .sdr paths):
  * modern: "annotations" array -- highlights carry `drawer` + `text` + page
    (xpointer for rolling docs, number for paged) + pos0/pos1; page bookmarks
    have NO `drawer` and their `text` is auto-filler, so we require `drawer`.
  * legacy: "highlight" table keyed by page number -> array of { text, pos0, ... }.

Refresh mode (micromodule_quote_of_day_refresh): "daily" (default -- one pick
per calendar day, stable across restarts) or "open" (a fresh pick each menu
open, keyed on the loader's menu-open generation). reroll() bumps a session
nonce so "New quote" steps to a different pick without waiting for the date.
]]
local SafeText = require("lib/bookshelf_text_safe")

local Quotes = {}

Quotes.REFRESH_KEY = "micromodule_quote_of_day_refresh" -- "daily" | "open"
-- Issue 368: books and highlight colours the reader has left out.
--   skip_books   filepath -> true: never the quote of the day (the book's own
--                %quote token still draws from it: that is asked for by name)
--   skip_colors  KOReader highlight colour name -> true: left out of both (a
--                colour kept for names makes a poor quote anywhere)
-- filter_gen counts changes to either, and is part of the daily cache key, so
-- a pick persisted before a change is never adopted after it.
-- Issue 258: where the quote of the day comes from -- the reader's highlights
-- (the default, as always), quotes files, or both. A quotes file is SimpleUI's
-- format, so a reader moving between the two keeps one:
--   return { { q = "Quote text.", a = "Author", b = "Book (optional)" }, ... }
Quotes.SOURCE_KEY = "micromodule_quote_of_day_source" -- "highlights" | "files" | "both"
Quotes.SKIP_BOOKS_KEY  = "micromodule_quote_of_day_skip_books"
Quotes.SKIP_COLORS_KEY = "micromodule_quote_of_day_skip_colors"
local FILTER_GEN_KEY   = "micromodule_quote_of_day_filter_gen"

local MAX_QUOTES = 200 -- highlights collected from one walk of sidecars
local MAX_CHARS  = 280 -- long quotes truncated on a word boundary

-- Cache keyed by a refresh-mode string (see cacheKey): the sidecar walk runs
-- once per key. data = { text, title, author, filepath, page, pos0, legacy,
--                          chapter, page_display }
-- or false for "no highlights".
local _cache    -- { key = <string>, data = <quote table> | false }
local _nonce    = 0   -- session nonce; reroll() bumps it (in-memory only)
local _last_text      -- untruncated text of the last shown quote
-- Per-book %quote token (issue #174): a separate cache so the token's random
-- per-book pick is independent of the module's daily all-books pick. Keyed by
-- "<filepath>:<book_nonce>"; rerollBook() bumps the nonce so a re-selection of
-- the same book re-rolls, while repaints within one selection stay stable.
local _book_cache
local _book_nonce = 0

function Quotes.readRefresh()
    local Store = require("lib/bookshelf_settings_store")
    local v = Store.read(Quotes.REFRESH_KEY, "daily")
    if v ~= "open" then v = "daily" end
    return v
end

local function readSet(key)
    local Store = require("lib/bookshelf_settings_store")
    local v = Store.read(key)
    return type(v) == "table" and v or {}
end

function Quotes.readSource()
    local Store = require("lib/bookshelf_settings_store")
    local v = Store.read(Quotes.SOURCE_KEY, "highlights")
    if v ~= "files" and v ~= "both" then v = "highlights" end
    return v
end

local function filterGen()
    local Store = require("lib/bookshelf_settings_store")
    return tonumber(Store.read(FILTER_GEN_KEY)) or 0
end

local function cacheKey()
    if Quotes.readRefresh() == "open" then
        local Modules = require("lib/bookshelf_start_menu_modules")
        return "g" .. tostring(Modules.menu_generation) .. ":" .. _nonce
    end
    local key = "d" .. os.date("%Y-%m-%d") .. ":" .. _nonce
    local gen = filterGen()
    if gen > 0 then key = key .. ":f" .. gen end
    return key
end

local function truncateQuote(s)
    if #s <= MAX_CHARS then return s end
    local cut = s:sub(1, MAX_CHARS)
    cut = cut:match("^(.-)%s+%S*$") or cut -- back off to a word boundary
    return cut .. "\xE2\x80\xA6"
end

-- Collect every highlight from ONE book's sidecar into `quotes`. Used by both
-- the all-books daily walk and the per-book token (issue #174). Caller wraps in
-- pcall; this also guards each file access.
-- skip_colors: colour name -> true, highlights to leave out (nil: none).
-- colours_seen: when a table, every highlight colour met is recorded in it,
-- left out or not (the settings dialog lists them).
local function _collectFromSidecar(fp, quotes, skip_colors, colours_seen)
    local DocSettings = require("docsettings")
    -- hasSidecarFile gates the heavier open and is correct for all three
    -- metadata locations (doc/dir/hash) -- never stat a sibling .sdr path.
    if not (fp and DocSettings:hasSidecarFile(fp)) then return end
    local ok_ds, ds = pcall(DocSettings.open, DocSettings, fp)
    if ok_ds and ds then
                local title, author
                local ok_p, props = pcall(ds.readSetting, ds, "doc_props")
                if ok_p and type(props) == "table" then
                    if type(props.title) == "string" and props.title ~= "" then
                        title = props.title
                    end
                    if type(props.authors) == "string" and props.authors ~= "" then
                        author = props.authors:match("^[^\n]+") or props.authors
                    end
                end
                if not title then
                    title = (fp:match("([^/]+)$") or fp):gsub("%.[^.]+$", "")
                end
                -- chapter: KOReader records the TOC title on each annotation,
                -- so %quote_chapter costs nothing to carry. Sanitised like the
                -- rest -- it is book metadata and reaches a TextWidget. Legacy
                -- highlight sidecars predate the field and pass nil, which the
                -- token renders as empty.
                local function add(text, page, pos0, legacy, chapter, page_display)
                    if #quotes < MAX_QUOTES and type(text) == "string"
                            and text ~= "" then
                        quotes[#quotes + 1] = {
                            -- Untrusted file metadata; sanitise before render to
                            -- avoid a shaper crash on bad UTF-8 (issue #163).
                            text = SafeText.safe(text), title = SafeText.safe(title),
                            author = author and SafeText.safe(author) or nil,
                            filepath = fp, page = page, pos0 = pos0,
                            legacy = legacy,
                            chapter = (type(chapter) == "string" and chapter ~= "")
                                      and SafeText.safe(chapter) or nil,
                            -- A page fit to PRINT, which `page` above is not:
                            -- KOReader stores the highlight's LOCATION there,
                            -- and for a reflowable book that is an xPointer
                            -- ("/body/DocFragment[12]/..."), not a number.
                            -- %quote_page rendered it verbatim.
                            --
                            -- pageref is the stable label and pageno the
                            -- continuous number; preferring the label matches
                            -- what %page_count and %page_num report, so a
                            -- template mixing them stays in one scale.
                            -- Number-only, so nothing unprintable can reach a
                            -- template again.
                            page_display = tonumber(page_display),
                        }
                    end
                end
                local ok_a, ann = pcall(ds.readSetting, ds, "annotations")
                if ok_a and type(ann) == "table" and #ann > 0 then
                    for _j, a in ipairs(ann) do
                        -- `drawer` set = real highlight; bookmarks (no drawer)
                        -- carry auto-filler text we must not quote.
                        if type(a) == "table" and a.drawer then
                            local colour = type(a.color) == "string" and a.color or nil
                            if colour and colours_seen then colours_seen[colour] = true end
                            if not (colour and skip_colors and skip_colors[colour]) then
                                add(a.text, a.page, a.pos0, false, a.chapter,
                                    a.pageref or a.pageno)
                            end
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
                                        -- Legacy sidecars key highlights BY
                                        -- page, so the key is the number.
                                        add(h.text, tonumber(page) or page,
                                            h.pos0, true, nil, tonumber(page))
                                    end
                                end
                            end
                        end
                    end
                end
            end
end

-- ── The highlight index ───────────────────────────────────────────────────
--
-- Every highlight in every book can be the quote of the day. It used to be
-- the 25 most recently opened books, their sidecars opened on every pick: a
-- reader who opened many books to test something saw "No highlights yet"
-- (device report). Now each book's highlight COUNT is kept in the facts store
-- (lib/bookshelf_book_facts_db) with its sidecar's mtime, a book is chosen in
-- proportion to its count, and only that one sidecar is opened.
--
-- A sidecar only changes when its book is opened, so a count stands, with no
-- file touched, while the book's last opening (ReadHistory's time) is older
-- than the sidecar it was counted from. Books never counted are opened at
-- most INDEX_BUDGET at a time per pick, which is what the old walk cost, so
-- the index fills over the first few picks; "Scan library for highlights"
-- (scanLibrary) does the lot at once, books outside the history included.
Quotes.INDEX_BUDGET = 25

local function facts()
    local ok, F = pcall(require, "lib/bookshelf_book_facts_db")
    return ok and F or nil
end

-- countHighlights(ds) -> how many highlights an open sidecar holds (the ones
-- _collectFromSidecar takes, before any colour is left out).
function Quotes.countHighlights(ds)
    local n = 0
    local ok_a, ann = pcall(ds.readSetting, ds, "annotations")
    if ok_a and type(ann) == "table" and #ann > 0 then
        for _i, a in ipairs(ann) do
            if type(a) == "table" and a.drawer and type(a.text) == "string" and a.text ~= "" then n = n + 1 end
        end
        return n
    end
    local ok_h, hl = pcall(ds.readSetting, ds, "highlight")
    if ok_h and type(hl) == "table" then
        for _page, list in pairs(hl) do
            if type(list) == "table" then
                for _i, h in ipairs(list) do
                    if type(h) == "table" and type(h.text) == "string" and h.text ~= "" then n = n + 1 end
                end
            end
        end
    end
    return n
end

-- bookCount(fp, st, opened_at) -> the book's highlight count, or nil when it
-- has never been counted and st.budget is spent. opened_at is its last
-- opening (ReadHistory), when known: not opened since the count, it stands.
local function bookCount(fp, st, opened_at)
    local F = facts()
    local f = F and F.get(fp)
    if f and f.hl ~= nil and f.hm and opened_at and opened_at <= f.hm then return f.hl end
    local DocSettings = require("docsettings")
    local sidecar
    if DocSettings.findSidecarFile then
        sidecar = DocSettings:findSidecarFile(fp)
    elseif DocSettings:hasSidecarFile(fp) then
        sidecar = true
    end
    if not sidecar then
        if f and (f.hl or 0) > 0 and F then F.put(fp, { hl = 0, hm = 0 }); st.dirty = true end
        return 0
    end
    -- No time to stamp a count with (no path, no lfs): counted, never kept,
    -- since it could not be checked later.
    local mt
    if type(sidecar) == "string" then
        local ok_l, lfs = pcall(require, "libs/libkoreader-lfs")
        mt = ok_l and lfs and lfs.attributes(sidecar, "modification") or nil
    end
    if mt and f and f.hl ~= nil and f.hm == mt then return f.hl end
    if st.budget then
        if st.budget <= 0 then return nil end
        st.budget = st.budget - 1
    end
    local n = 0
    local ok, ds = pcall(DocSettings.open, DocSettings, fp)
    if ok and ds then n = Quotes.countHighlights(ds) end
    if F and mt then F.put(fp, { hl = n, hm = mt }); st.dirty = true end
    return n
end

-- buildPool(budget) -> { { fp, n }, ... }, total: the books with highlights,
-- history first (newest first), then any the library scan found, left-out
-- books passed over before they cost anything.
local function buildPool(budget)
    local skip = readSet(Quotes.SKIP_BOOKS_KEY)
    local F = facts()
    local seen, fps, opened = {}, {}, {}
    local rh = require("readhistory")
    for _i, e in ipairs(rh.hist or {}) do
        local fp = e.file
        if fp and not seen[fp] then
            seen[fp] = true
            fps[#fps + 1] = fp
            opened[fp] = e.time
        end
    end
    local extra = {}
    for fp in pairs(F and F.highlightBooks() or {}) do
        if not seen[fp] then seen[fp] = true; extra[#extra + 1] = fp end
    end
    table.sort(extra)
    for _i, fp in ipairs(extra) do fps[#fps + 1] = fp; opened[fp] = 0 end
    if F and F.prefetch then pcall(F.prefetch, fps) end
    local st = { budget = budget }
    local pool, total = {}, 0
    for _i, fp in ipairs(fps) do
        if not skip[fp] then
            local n = bookCount(fp, st, opened[fp])
            if n and n > 0 then
                pool[#pool + 1] = { fp = fp, n = n }
                total = total + n
            end
        end
    end
    if st.dirty and F and F.flush then pcall(F.flush) end
    -- st.budget spent: books are left that were never counted.
    return pool, total, st.budget ~= nil and st.budget <= 0
end

-- _pickAt(pool, total, files, k) -> the kth of every highlight and quotes-file
-- quote, or nil: the book holding it found by the running counts, its sidecar
-- opened. A book whose highlights are all in left-out colours (or that has
-- lost them since its count) leaves the pool and the pick moves on, a few
-- times at most.
function Quotes._pickAt(pool, total, files, k, sleep_pick)
    local skip_colors = readSet(Quotes.SKIP_COLORS_KEY)
    files = files or {}
    for _try = 1, 6 do
        local all = total + #files
        if all <= 0 then return nil end
        k = ((k - 1) % all) + 1
        if k > total then return files[k - total] end
        local before = 0
        for i, b in ipairs(pool) do
            if k <= before + b.n then
                local quotes = {}
                _collectFromSidecar(b.fp, quotes, skip_colors)
                if #quotes > 0 then
                    local idx = ((k - before - 1) % #quotes) + 1
                    if not sleep_pick and Quotes.readRefresh() == "open" and #quotes > 1 and _last_text
                            and quotes[idx].text == _last_text then
                        idx = idx % #quotes + 1
                    end
                    return quotes[idx]
                end
                total = total - b.n
                table.remove(pool, i)
                break
            end
            before = before + b.n
        end
    end
    return nil
end

function Quotes._pool(budget) return buildPool(budget) end

-- scanLibrary(fps, progress) -> books with highlights, highlights: count every
-- book in fps (the whole library), past the per-pick budget. progress(i, n)
-- is called between books; returning false stops the scan.
function Quotes.scanLibrary(fps, progress)
    local F = facts()
    if F and F.prefetch then pcall(F.prefetch, fps) end
    local st = {}
    local books, quotes = 0, 0
    for i, fp in ipairs(fps or {}) do
        if progress and progress(i, #fps) == false then break end
        local n = bookCount(fp, st, nil) or 0
        if n > 0 then books = books + 1; quotes = quotes + n end
    end
    if st.dirty and F and F.flush then pcall(F.flush) end
    _cache = nil
    return books, quotes
end

-- collectQuotes(colours_seen) -> highlights from the books in the pool (and
-- the quotes files, by source), for the settings dialog's list of colours.
local function collectQuotes(colours_seen)
    local quotes = {}
    local source = Quotes.readSource()
    if source == "files" and not colours_seen then return Quotes.fileQuotes() end
    local skip_colors = readSet(Quotes.SKIP_COLORS_KEY)
    local pool = buildPool(Quotes.INDEX_BUDGET)
    for _i, b in ipairs(pool) do
        if #quotes >= MAX_QUOTES then break end
        _collectFromSidecar(b.fp, quotes, skip_colors, colours_seen)
    end
    if source == "both" and not colours_seen then
        for _i, q in ipairs(Quotes.fileQuotes()) do quotes[#quotes + 1] = q end
    end
    return quotes
end

-- ── Quotes files (issue 258) ──────────────────────────────────────────────
--
-- Every .lua file in these folders is a list of quotes. Bookshelf's own folder
-- first, then SimpleUI's, read where it is so nothing has to be copied. Read
-- only; neither folder is created here except on request (ensureQuotesDir).
local MAX_FILE_BYTES = 4 * 1024 * 1024

function Quotes.quotesDirs()
    local ok, DataStorage = pcall(require, "datastorage")
    if not (ok and DataStorage) then return {} end
    local base = DataStorage:getSettingsDir()
    return { base .. "/bookshelf/quotes", base .. "/simpleui/sui_quotes" }
end

-- loadQuoteFile(path) -> a list of { text, author, title }, or {} on any
-- failure. The file runs with an EMPTY environment: it is data, and a quotes
-- file shared around should not be able to reach os or io.
local function loadQuoteFile(path)
    local f = io.open(path, "rb")
    if not f then return {} end
    local src = f:read(MAX_FILE_BYTES + 1)
    f:close()
    if not src or #src > MAX_FILE_BYTES then return {} end
    -- load's env argument: LuaJIT has it as a Lua 5.2 extension, so one
    -- call serves the device and the test interpreters. "t": text only, never
    -- a precompiled chunk.
    local chunk = load(src, "=" .. path, "t", {})
    if not chunk then return {} end
    local ok, list = pcall(chunk)
    if not (ok and type(list) == "table") then return {} end
    local out = {}
    for _i, e in ipairs(list) do
        if type(e) == "table" and type(e.q) == "string" and e.q:match("%S") then
            out[#out + 1] = {
                text   = SafeText.safe(e.q),
                author = type(e.a) == "string" and e.a ~= "" and SafeText.safe(e.a) or nil,
                title  = type(e.b) == "string" and e.b ~= "" and SafeText.safe(e.b) or nil,
            }
        end
    end
    return out
end

-- fileQuotes() -> every quote in every quotes file, cached on the files'
-- names, sizes and mtimes so an edit is picked up without a restart.
local _file_cache, _file_key
function Quotes.fileQuotes()
    local ok_l, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_l then return {} end
    local files, key = {}, {}
    for _i, d in ipairs(Quotes.quotesDirs()) do
        if lfs.attributes(d, "mode") == "directory" then
            local names = {}
            pcall(function()
                for name in lfs.dir(d) do
                    if name:match("%.lua$") then names[#names + 1] = name end
                end
            end)
            table.sort(names)
            for _j, name in ipairs(names) do
                local path = d .. "/" .. name
                local attr = lfs.attributes(path)
                if attr and attr.mode == "file" then
                    files[#files + 1] = path
                    key[#key + 1] = path .. ":" .. tostring(attr.size) .. ":" .. tostring(attr.modification)
                end
            end
        end
    end
    key = table.concat(key, "|")
    if _file_cache and _file_key == key then return _file_cache end
    local out = {}
    for _i, path in ipairs(files) do
        for _j, q in ipairs(loadQuoteFile(path)) do out[#out + 1] = q end
    end
    _file_cache, _file_key = out, key
    return out
end

-- Every highlight from a SINGLE book -- backs the per-book %quote token (#174).
local function collectBookQuotes(fp)
    local quotes = {}
    _collectFromSidecar(fp, quotes, readSet(Quotes.SKIP_COLORS_KEY))
    return quotes
end

-- A filter changed: bump the generation (the daily cache key carries it) and
-- drop both in-memory picks so the next render draws from the new pool.
local function filtersChanged()
    local Store = require("lib/bookshelf_settings_store")
    Store.save(FILTER_GEN_KEY, filterGen() + 1)
    Store.flush()
    _cache = nil
    _book_cache = nil
end

function Quotes.setSource(v)
    local Store = require("lib/bookshelf_settings_store")
    Store.save(Quotes.SOURCE_KEY, v)
    filtersChanged()
end

-- skipBook(fp, title): the title is kept with it so the settings can list
-- what was left out by name (an older entry holds just true).
function Quotes.skipBook(fp, title)
    if type(fp) ~= "string" then return end
    local Store = require("lib/bookshelf_settings_store")
    local set = readSet(Quotes.SKIP_BOOKS_KEY)
    set[fp] = (type(title) == "string" and title ~= "") and title or true
    Store.save(Quotes.SKIP_BOOKS_KEY, set)
    filtersChanged()
end

function Quotes.skippedBookCount()
    local n = 0
    for _fp in pairs(readSet(Quotes.SKIP_BOOKS_KEY)) do n = n + 1 end
    return n
end

-- skippedBooks() -> { { fp, title }, ... } sorted by title. A book stored
-- without a title (an older entry) is named from its file.
function Quotes.skippedBooks()
    local out = {}
    for fp, v in pairs(readSet(Quotes.SKIP_BOOKS_KEY)) do
        local title = type(v) == "string" and v
                      or ((fp:match("([^/]+)$") or fp):gsub("%.[^.]+$", ""))
        out[#out + 1] = { fp = fp, title = title }
    end
    table.sort(out, function(a, b) return a.title:lower() < b.title:lower() end)
    return out
end

function Quotes.isBookSkipped(fp)
    return readSet(Quotes.SKIP_BOOKS_KEY)[fp] ~= nil
end

function Quotes.unskipBook(fp)
    local Store = require("lib/bookshelf_settings_store")
    local set = readSet(Quotes.SKIP_BOOKS_KEY)
    if set[fp] == nil then return end
    set[fp] = nil
    if next(set) then Store.save(Quotes.SKIP_BOOKS_KEY, set)
    else Store.delete(Quotes.SKIP_BOOKS_KEY) end
    filtersChanged()
end

function Quotes.unskipAllBooks()
    local Store = require("lib/bookshelf_settings_store")
    Store.delete(Quotes.SKIP_BOOKS_KEY)
    filtersChanged()
end

function Quotes.isColorSkipped(colour)
    return readSet(Quotes.SKIP_COLORS_KEY)[colour] == true
end

function Quotes.setColorSkipped(colour, skipped)
    if type(colour) ~= "string" then return end
    local Store = require("lib/bookshelf_settings_store")
    local set = readSet(Quotes.SKIP_COLORS_KEY)
    set[colour] = skipped and true or nil
    if next(set) then Store.save(Quotes.SKIP_COLORS_KEY, set)
    else Store.delete(Quotes.SKIP_COLORS_KEY) end
    filtersChanged()
end

-- coloursInUse() -> sorted list of the highlight colours in the books the
-- quote of the day draws from, left out or not. A sidecar walk, so for the
-- settings dialog only.
function Quotes.coloursInUse()
    local seen = {}
    pcall(collectQuotes, seen)
    local out = {}
    for c in pairs(seen) do out[#out + 1] = c end
    table.sort(out)
    return out
end

-- Pick one quote from the collection.
--   daily: deterministic seed (date + count) plus the session nonce -- stable
--     all day and across restarts; each reroll() steps to the NEXT quote.
--   open: random per pick, skipping the last shown quote when alternatives
--     exist, so consecutive menu opens differ.
local function pickQuote(quotes, sleep_pick)
    local n = #quotes
    if not sleep_pick and Quotes.readRefresh() == "open" then
        local idx = math.random(n)
        if n > 1 and _last_text and quotes[idx].text == _last_text then
            idx = idx % n + 1
        end
        return quotes[idx]
    end
    local seed = (tonumber(os.date("%Y%m%d")) or 0) + n + (sleep_pick or _nonce)
    return quotes[(seed % n) + 1]
end

-- KOReader does not seed math.random globally; without this the per-open pick
-- sequence would repeat after every restart.
math.randomseed(os.time())

-- Daily-mode persistence (#247): the sidecar walk (up to 25 DocSettings
-- parses) is the slow part of the first quote render after a restart -- the
-- reported "micro-modules menu is slow the first time". The daily pick is
-- stable all day by design, so persist it and adopt the stored copy while
-- its key (date + nonce) still matches; a restart then skips the walk.
-- "open" mode keys on the session's menu-open generation, so persisting it
-- would be meaningless. The no-highlights verdict (data = false) is NOT
-- persisted: a user's first-ever highlight should show the same day, not
-- after midnight.
local DAILY_CACHE_KEY = "quote_of_day_daily_cache"

-- The daily quote (cached). Returns { text, title, author, filepath, page,
-- pos0, legacy } or nil when there are no highlights.
function Quotes.ofTheDay(sleep_pick)
    local key = not sleep_pick and cacheKey()
    if key and _cache and _cache.key == key then
        return _cache.data or nil
    end
    local daily = not sleep_pick and Quotes.readRefresh() == "daily"
    if daily then
        local Store = require("lib/bookshelf_settings_store")
        local stored = Store.read(DAILY_CACHE_KEY)
        if type(stored) == "table" and stored.key == key
                and type(stored.data) == "table" then
            _cache = { key = key, data = stored.data }
            _last_text = stored.data.text
            return stored.data
        end
    end
    local data = false
    local ok, pick = pcall(function()
        local source = Quotes.readSource()
        local files = (source ~= "highlights") and Quotes.fileQuotes() or {}
        if source == "files" then
            return (#files > 0) and pickQuote(files, sleep_pick) or nil
        end
        local pool, total, more = buildPool(Quotes.INDEX_BUDGET)
        -- Nothing found yet, and books left that were never counted: count
        -- on, a budget at a time, rather than say "No highlights yet" while
        -- they sit in the history (the first pick after an upgrade, behind
        -- many books opened without a highlight).
        for _round = 2, 3 do
            if total > 0 or not more then break end
            pool, total, more = buildPool(Quotes.INDEX_BUDGET)
        end
        local all = total + #files
        if all == 0 then return nil end
        local k
        if not sleep_pick and Quotes.readRefresh() == "open" then
            k = math.random(all)
        else
            k = ((tonumber(os.date("%Y%m%d")) or 0) + all + (sleep_pick or _nonce)) % all + 1
        end
        return Quotes._pickAt(pool, total, files, k, sleep_pick)
    end)
    if not ok then
        require("logger").warn("[bookshelf] quote of the day unavailable:", pick)
        pick = nil
    end
    if pick then
        if not sleep_pick then _last_text = pick.text end
        data = {
            text = truncateQuote(pick.text), title = pick.title,
            author = pick.author,
            filepath = pick.filepath, page = pick.page, pos0 = pick.pos0,
            legacy = pick.legacy, chapter = pick.chapter,
            page_display = pick.page_display,
        }
    end
    if sleep_pick then return data or nil end
    _cache = { key = key, data = data }
    if daily and data then
        local Store = require("lib/bookshelf_settings_store")
        Store.save(DAILY_CACHE_KEY, { key = key, data = data })
    end
    return data or nil
end

-- The currently cached quote without forcing a (re)collection -- for tap
-- actions that act on the already-shown pick (open book / bookmark list).
function Quotes.current()
    return _cache and _cache.data or nil
end

-- Force a fresh pick on the next ofTheDay(): bump the nonce (keys into BOTH
-- modes' cache keys and shifts the daily seed) and drop the cache.
function Quotes.reroll()
    _nonce = _nonce + 1
    _cache = nil
end

-- A RANDOM highlight from ONE book (the %quote token, issue #174). Cached by
-- "<filepath>:<book_nonce>": stable across the repaints of one selection, but
-- rerollBook() (called when a book is selected) bumps the nonce so the next
-- render re-rolls -- including re-selecting the same book. Returns the quote
-- table or nil (no highlights / no filepath).
function Quotes.forBook(filepath)
    if not filepath then return nil end
    local key = filepath .. ":" .. _book_nonce
    if _book_cache and _book_cache.key == key then
        return _book_cache.data or nil
    end
    local data = false
    local ok, quotes = pcall(collectBookQuotes, filepath)
    if not ok then
        require("logger").warn("[bookshelf] book quote unavailable:", quotes)
        quotes = nil
    end
    if quotes and #quotes > 0 then
        local pick = quotes[math.random(#quotes)]
        data = {
            text = truncateQuote(pick.text), title = pick.title,
            author = pick.author,
            filepath = pick.filepath, page = pick.page, pos0 = pick.pos0,
            legacy = pick.legacy, chapter = pick.chapter,
            page_display = pick.page_display,
        }
    end
    _book_cache = { key = key, data = data }
    return data or nil
end

-- Re-roll the per-book token quote on the next forBook() (called when a book is
-- selected, so each selection shows a different random highlight).
function Quotes.rerollBook()
    _book_nonce = _book_nonce + 1
end

return Quotes
