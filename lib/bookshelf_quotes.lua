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
Quotes.SKIP_BOOKS_KEY  = "micromodule_quote_of_day_skip_books"
Quotes.SKIP_COLORS_KEY = "micromodule_quote_of_day_skip_colors"
local FILTER_GEN_KEY   = "micromodule_quote_of_day_filter_gen"

local MAX_BOOKS  = 25  -- most-recent ReadHistory entries walked
local MAX_QUOTES = 200 -- total highlights collected across those books
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

-- Walk ReadHistory newest-first, collecting from each book's sidecar. Caps keep
-- the walk bounded; every file access is guarded inside _collectFromSidecar.
-- Skipped books are passed over before they count against MAX_BOOKS, so
-- leaving one out does not shrink the pool.
local function collectQuotes(colours_seen)
    local quotes = {}
    local DocSettings = require("docsettings")
    local rh = require("readhistory")
    local skip_books  = readSet(Quotes.SKIP_BOOKS_KEY)
    local skip_colors = readSet(Quotes.SKIP_COLORS_KEY)
    local n_books = 0
    for _i, entry in ipairs(rh.hist or {}) do
        if n_books >= MAX_BOOKS or #quotes >= MAX_QUOTES then break end
        local fp = entry.file
        if fp and not skip_books[fp] and DocSettings:hasSidecarFile(fp) then
            n_books = n_books + 1
            _collectFromSidecar(fp, quotes, skip_colors, colours_seen)
        end
    end
    return quotes
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

function Quotes.skipBook(fp)
    if type(fp) ~= "string" then return end
    local Store = require("lib/bookshelf_settings_store")
    local set = readSet(Quotes.SKIP_BOOKS_KEY)
    set[fp] = true
    Store.save(Quotes.SKIP_BOOKS_KEY, set)
    filtersChanged()
end

function Quotes.skippedBookCount()
    local n = 0
    for _fp in pairs(readSet(Quotes.SKIP_BOOKS_KEY)) do n = n + 1 end
    return n
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
local function pickQuote(quotes)
    local n = #quotes
    if Quotes.readRefresh() == "open" then
        local idx = math.random(n)
        if n > 1 and _last_text and quotes[idx].text == _last_text then
            idx = idx % n + 1
        end
        return quotes[idx]
    end
    local seed = (tonumber(os.date("%Y%m%d")) or 0) + n + _nonce
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
function Quotes.ofTheDay()
    local key = cacheKey()
    if _cache and _cache.key == key then
        return _cache.data or nil
    end
    local daily = Quotes.readRefresh() == "daily"
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
    local ok, quotes = pcall(collectQuotes)
    if not ok then
        require("logger").warn("[bookshelf] quote of the day unavailable:", quotes)
        quotes = nil
    end
    if quotes and #quotes > 0 then
        local pick = pickQuote(quotes)
        _last_text = pick.text
        data = {
            text = truncateQuote(pick.text), title = pick.title,
            author = pick.author,
            filepath = pick.filepath, page = pick.page, pos0 = pick.pos0,
            legacy = pick.legacy, chapter = pick.chapter,
            page_display = pick.page_display,
        }
    end
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
