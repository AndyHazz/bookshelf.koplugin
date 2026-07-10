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

local MAX_BOOKS  = 25  -- most-recent ReadHistory entries walked
local MAX_QUOTES = 200 -- total highlights collected across those books
local MAX_CHARS  = 280 -- long quotes truncated on a word boundary

-- Cache keyed by a refresh-mode string (see cacheKey): the sidecar walk runs
-- once per key. data = { text, title, author, filepath, page, pos0, legacy }
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

local function cacheKey()
    if Quotes.readRefresh() == "open" then
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

-- Collect every highlight from ONE book's sidecar into `quotes`. Used by both
-- the all-books daily walk and the per-book token (issue #174). Caller wraps in
-- pcall; this also guards each file access.
local function _collectFromSidecar(fp, quotes)
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
                local function add(text, page, pos0, legacy)
                    if #quotes < MAX_QUOTES and type(text) == "string"
                            and text ~= "" then
                        quotes[#quotes + 1] = {
                            -- Untrusted file metadata; sanitise before render to
                            -- avoid a shaper crash on bad UTF-8 (issue #163).
                            text = SafeText.safe(text), title = SafeText.safe(title),
                            author = author and SafeText.safe(author) or nil,
                            filepath = fp, page = page, pos0 = pos0,
                            legacy = legacy,
                        }
                    end
                end
                local ok_a, ann = pcall(ds.readSetting, ds, "annotations")
                if ok_a and type(ann) == "table" and #ann > 0 then
                    for _j, a in ipairs(ann) do
                        -- `drawer` set = real highlight; bookmarks (no drawer)
                        -- carry auto-filler text we must not quote.
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

-- Walk ReadHistory newest-first, collecting from each book's sidecar. Caps keep
-- the walk bounded; every file access is guarded inside _collectFromSidecar.
local function collectQuotes()
    local quotes = {}
    local DocSettings = require("docsettings")
    local rh = require("readhistory")
    local n_books = 0
    for _i, entry in ipairs(rh.hist or {}) do
        if n_books >= MAX_BOOKS or #quotes >= MAX_QUOTES then break end
        local fp = entry.file
        if fp and DocSettings:hasSidecarFile(fp) then
            n_books = n_books + 1
            _collectFromSidecar(fp, quotes)
        end
    end
    return quotes
end

-- Every highlight from a SINGLE book -- backs the per-book %quote token (#174).
local function collectBookQuotes(fp)
    local quotes = {}
    _collectFromSidecar(fp, quotes)
    return quotes
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
            legacy = pick.legacy,
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
            legacy = pick.legacy,
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
