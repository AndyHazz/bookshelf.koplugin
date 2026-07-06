-- bookshelf_hardcover.lua
-- Optional Hardcover enrichment for Bookshelf.
--
-- Normal shelf rendering never talks to the network. This module only reads
-- Bookshelf's local link/enrichment caches there. Network calls happen from
-- explicit user actions: link a book, refresh one book, or refresh all linked
-- books.

local BookshelfSettings = require("lib/bookshelf_settings_store")
local logger = require("logger")

local Hardcover = {}

local HC_SETTINGS_FILE = "hardcoversync_settings.lua"
local LINKS_KEY        = "hardcover_links"
local CACHE_KEY        = "hardcover_enrichment"
local RATINGS_KEY      = "hardcover_ratings"
local RATINGS_TIME_KEY = "hardcover_ratings_fetched_at"
local REVIEWS_KEY      = "hardcover_reviews"
local REVIEWS_TTL      = 24 * 60 * 60

local _links
local _external_links
local _cache_db                 -- SQLite handle for the Hardcover cache (lazy)
local _cache_memo = {}          -- [kind][ckey] -> decoded value (false = known-absent)
local _hc_settings
local _hc_settings_object

local function _settingsPath()
    local DataStorage = require("datastorage")
    return DataStorage:getSettingsDir() .. "/" .. HC_SETTINGS_FILE
end

local function _cacheDir()
    local DataStorage = require("datastorage")
    return DataStorage:getSettingsDir() .. "/bookshelf_hardcover"
end

local function _ensureDir(path)
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs or not lfs or type(lfs.attributes) ~= "function" then return false end
    if lfs.attributes(path, "mode") == "directory" then return true end
    if type(lfs.mkdir) == "function" then
        local ok = pcall(lfs.mkdir, path)
        return ok and lfs.attributes(path, "mode") == "directory"
    end
    return false
end

local function _openExternalSettings()
    if _hc_settings then return _hc_settings end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok_lfs and lfs and lfs.attributes
            and lfs.attributes(_settingsPath(), "mode") ~= "file" then
        return nil
    end
    local LuaSettings = require("luasettings")
    _hc_settings = LuaSettings:open(_settingsPath())
    return _hc_settings
end

local function _readLinks()
    if _links then return _links end
    local raw = BookshelfSettings.read(LINKS_KEY, {})
    _links = type(raw) == "table" and raw or {}
    return _links
end

local function _saveLinks(links)
    _links = links or {}
    BookshelfSettings.save(LINKS_KEY, _links)
end

local function _readExternalLinks(force)
    if _external_links and not force then return _external_links end
    if force then _hc_settings = nil end
    local ok, settings = pcall(_openExternalSettings)
    if not ok or not settings then
        _external_links = {}
        return _external_links
    end
    local ok_books, books = pcall(settings.readSetting, settings, "books")
    _external_links = (ok_books and type(books) == "table") and books or {}
    return _external_links
end

-- ── Hardcover cache (SQLite) ────────────────────────────────────────────────
-- The three caches (enrichment/descriptions, ratings, review text) live in a
-- dedicated SQLite DB, NOT in bookshelf.lua. On a large, heavily-linked
-- library these dwarf everything else; keeping them in the hot settings file
-- meant every settings flush re-serialised the lot and startup dofile'd it
-- (issue #113). SQLite gives per-book lazy reads + single-row writes, so
-- bookshelf.lua stays tiny. We own this file; KOReader's own DBs are untouched.
local function _cacheEncode(v)
    local ok, s = pcall(function() return require("rapidjson").encode(v) end)
    return ok and s or nil
end
local function _cacheDecode(s)
    local ok, v = pcall(function() return require("rapidjson").decode(s) end)
    return (ok and type(v) == "table") and v or nil
end

-- One-time import of the legacy in-bookshelf.lua caches, then drop the keys so
-- bookshelf.lua shrinks. Pre-2.5 installs stored these under
-- CACHE_KEY / RATINGS_KEY / REVIEWS_KEY. Runs on first DB open.
local function _migrateLegacyCaches(db)
    local stmt = db:prepare(
        "INSERT OR REPLACE INTO cache (kind, ckey, data) VALUES (?, ?, ?)")
    local function importKind(legacy_key, kind)
        local legacy = BookshelfSettings.read(legacy_key, nil)
        if type(legacy) ~= "table" then return end
        for ckey, entry in pairs(legacy) do
            if type(entry) == "table" then
                local json = _cacheEncode(entry)
                if json then stmt:bind(kind, tostring(ckey), json):step() end
                stmt:clearbind():reset()
            end
        end
        BookshelfSettings.delete(legacy_key)
    end
    importKind(CACHE_KEY,   "enrich")
    importKind(RATINGS_KEY, "rating")
    importKind(REVIEWS_KEY, "review")
    stmt:close()
end

-- True when the pre-2.5 in-bookshelf.lua caches still hold data that the
-- first DB open would migrate. Settings reads are in-memory, so this is
-- cheap enough for the per-open read gate below.
local function _hasLegacySettingsData()
    return BookshelfSettings.read(CACHE_KEY,   nil) ~= nil
        or BookshelfSettings.read(RATINGS_KEY, nil) ~= nil
        or BookshelfSettings.read(REVIEWS_KEY, nil) ~= nil
end

-- _cacheDb(for_write): lazily open (and on the write path, create) the
-- cache DB. Read-only consumers pass nothing and get nil while the DB
-- file doesn't exist - without that gate, a user who has never touched
-- Hardcover would have bookshelf_hardcover.sqlite3 (+ WAL sidecars)
-- created and an SQLite handle held open just because hasData() runs at
-- every FM menu build and _cacheGet() runs on hero renders. Legacy
-- upgraders (pre-2.5 caches still in bookshelf.lua) are let through so
-- the first read still triggers the one-time migration.
local function _cacheDb(for_write)
    if _cache_db == false then return nil end   -- disabled after a prior failure
    if _cache_db then return _cache_db end
    local DataStorage = require("datastorage")
    local db_path = DataStorage:getSettingsDir() .. "/bookshelf_hardcover.sqlite3"
    if not for_write then
        local lfs = require("libs/libkoreader-lfs")
        if lfs.attributes(db_path, "mode") ~= "file"
                and not _hasLegacySettingsData() then
            return nil   -- nothing stored; don't create the DB to prove it
        end
    end
    local ok, db = pcall(function()
        local SQ3 = require("lua-ljsqlite3/init")
        local d = SQ3.open(db_path)
        d:exec("PRAGMA journal_mode=WAL;")
        d:exec([[CREATE TABLE IF NOT EXISTS cache (
            kind TEXT NOT NULL, ckey TEXT NOT NULL, data TEXT NOT NULL,
            PRIMARY KEY (kind, ckey));]])
        return d
    end)
    if not ok or not db then
        logger.warn("[bookshelf] Hardcover cache DB unavailable:", tostring(db))
        _cache_db = false   -- degrade gracefully: callers see no cached data
        return nil
    end
    _cache_db = db
    pcall(_migrateLegacyCaches, db)  -- migration is idempotent + retry-safe
    return db
end

-- Per-book lazy read (the hot render path). Memoised (false = known-absent).
-- All DB work is pcall-guarded so a SQLite hiccup degrades to "no cached
-- data" rather than crashing a shelf/hero render.
local function _cacheGet(kind, ckey)
    if not ckey then return nil end
    local m = _cache_memo[kind]
    if m and m[ckey] ~= nil then
        local v = m[ckey]
        return v ~= false and v or nil
    end
    local v
    local db = _cacheDb()
    if db then
        local ok, raw = pcall(function()
            local stmt = db:prepare("SELECT data FROM cache WHERE kind = ? AND ckey = ?")
            local row = stmt:bind(kind, ckey):step()
            stmt:clearbind():reset(); stmt:close()
            return row and row[1] or nil
        end)
        if ok and raw then v = _cacheDecode(raw) end
    end
    _cache_memo[kind] = _cache_memo[kind] or {}
    _cache_memo[kind][ckey] = v or false
    return v
end

-- Single-row write.
local function _cachePut(kind, ckey, value)
    if not ckey then return end
    _cache_memo[kind] = _cache_memo[kind] or {}
    _cache_memo[kind][ckey] = value or false
    local json = _cacheEncode(value)
    if not json then return end
    local db = _cacheDb(true)   -- write path: create the DB on demand
    if not db then return end
    pcall(function()
        local stmt = db:prepare(
            "INSERT OR REPLACE INTO cache (kind, ckey, data) VALUES (?, ?, ?)")
        stmt:bind(kind, ckey, json):step()
        stmt:clearbind():reset(); stmt:close()
    end)
end

local function _cacheDelKind(kind)
    _cache_memo[kind] = nil
    local db = _cacheDb()
    if not db then return end
    pcall(function()
        local stmt = db:prepare("DELETE FROM cache WHERE kind = ?")
        stmt:bind(kind):step()
        stmt:clearbind():reset(); stmt:close()
    end)
end

local function _cacheCount(kind)
    local db = _cacheDb()
    if not db then return 0 end
    local ok, n = pcall(function()
        local stmt = db:prepare("SELECT COUNT(*) FROM cache WHERE kind = ?")
        local row = stmt:bind(kind):step()
        stmt:clearbind():reset(); stmt:close()
        return row and tonumber(row[1]) or 0
    end)
    return (ok and n) or 0
end

-- Whole-kind read / replace — used ONLY by the deliberate ratings-refresh
-- sweep, which is inherently set-wide; never on the hot render path.
local function _cacheReadKind(kind)
    local out = {}
    local db = _cacheDb()
    if not db then return out end
    pcall(function()
        local stmt = db:prepare("SELECT ckey, data FROM cache WHERE kind = ?")
        stmt:bind(kind)
        local row = stmt:step()
        while row do
            local v = row[2] and _cacheDecode(row[2]) or nil
            if v then out[tostring(row[1])] = v end
            row = stmt:step()
        end
        stmt:clearbind():reset(); stmt:close()
    end)
    return out
end

local function _cacheReplaceKind(kind, tbl)
    _cacheDelKind(kind)
    local db = _cacheDb(true)   -- write path: create the DB on demand
    if not db then return end
    pcall(function()
        local stmt = db:prepare(
            "INSERT OR REPLACE INTO cache (kind, ckey, data) VALUES (?, ?, ?)")
        for ckey, value in pairs(tbl or {}) do
            local json = _cacheEncode(value)
            if json then stmt:bind(kind, tostring(ckey), json):step() end
            stmt:clearbind():reset()
        end
        stmt:close()
    end)
    _cache_memo[kind] = nil
end

-- Merge a single book's aggregate rating into the ratings cache (per-book).
-- Called after a per-book enrichment fetch so a freshly linked book shows its
-- rating in the hero without a full "Refresh ratings" sweep. Does NOT bump
-- RATINGS_TIME_KEY -- that means "last full sweep". Preserves existing
-- user_rating / user_book_id fields from a prior full refresh.
local function _backfillRatingEntry(book_id, payload)
    if not book_id or type(payload) ~= "table" then return end
    if payload.rating == nil and payload.ratings_count == nil
            and payload.reviews_count == nil then
        return
    end
    local key = tostring(book_id)
    local entry = _cacheGet("rating", key) or {}
    entry.rating = tonumber(payload.rating) or entry.rating or false
    entry.ratings_count = tonumber(payload.ratings_count) or entry.ratings_count or 0
    entry.reviews_count = tonumber(payload.reviews_count) or entry.reviews_count or 0
    entry.fetched_at = os.time()
    _cachePut("rating", key, entry)
end

local function _ratingFromCacheEntry(entry)
    if type(entry) ~= "table" then return nil end
    local rating = entry.rating
    if rating == false then return nil end
    return tonumber(rating)
end

local function _cacheKey(book_id, edition_id)
    if not book_id then return nil end
    if edition_id then
        return tostring(book_id) .. ":" .. tostring(edition_id)
    end
    return tostring(book_id)
end

local function _shallowCopy(t)
    local out = {}
    if type(t) == "table" then
        for k, v in pairs(t) do out[k] = v end
    end
    return out
end

local function _authorString(book)
    if not book then return nil end
    if type(book.authors) == "table" and #book.authors > 0 then
        return table.concat(book.authors, ", ")
    end
    return book.author
end

local function _filenameTitle(filepath)
    local name = tostring(filepath or ""):match("([^/]+)$") or ""
    name = name:gsub("%.[^%.]+$", ""):gsub("_", " ")
    return name ~= "" and name or nil
end

local function _shellQuote(s)
    return "'" .. tostring(s or ""):gsub("'", "'\\''") .. "'"
end

local function _xmlDecode(s)
    if not s then return "" end
    return (s:gsub("&lt;", "<")
             :gsub("&gt;", ">")
             :gsub("&quot;", "\"")
             :gsub("&apos;", "'")
             :gsub("&amp;", "&")
             :gsub("^%s+", "")
             :gsub("%s+$", ""))
end

local function _attr(attrs, name)
    if type(attrs) ~= "string" then return nil end
    local pattern_dq = name .. '%s*=%s*"([^"]+)"'
    local pattern_sq = name .. "%s*=%s*'([^']+)'"
    return attrs:match(pattern_dq) or attrs:match(pattern_sq)
end

local function _normaliseIdentifierToken(attrs, value)
    value = _xmlDecode(value)
    if value == "" then return nil end
    local lower_value = value:lower()
    if lower_value:match("^hardcover[%w_-]*:") or lower_value:match("^isbn[%w_-]*:") then
        return value
    end

    local scheme = _attr(attrs, "opf:scheme") or _attr(attrs, "scheme")
    if not scheme or scheme == "" then return nil end
    scheme = scheme:lower():gsub("_", "-")
    if scheme == "hardcover" or scheme == "hardcover-slug" then
        return "hardcover:" .. value
    elseif scheme == "hardcover-id" or scheme == "hardcover-book-id" then
        return "hardcover-id:" .. value
    elseif scheme == "hardcover-edition" or scheme == "hardcover-edition-id" then
        return "hardcover-edition:" .. value
    elseif scheme == "isbn" or scheme == "isbn10" or scheme == "isbn-10" then
        return "isbn:" .. value
    elseif scheme == "isbn13" or scheme == "isbn-13" then
        return "isbn13:" .. value
    end
    return nil
end

local function _extractIdentifiersFromOpf(opf)
    if type(opf) ~= "string" or opf == "" then return nil end
    local tokens, seen = {}, {}
    local function add(token)
        if token and token ~= "" and not seen[token] then
            seen[token] = true
            tokens[#tokens + 1] = token
        end
    end
    for attrs, value in opf:gmatch("<%s*[%w_%-:]*identifier([^>]*)>(.-)</%s*[%w_%-:]*identifier%s*>") do
        add(_normaliseIdentifierToken(attrs, value))
    end
    for token in opf:gmatch("[Hh][Aa][Rr][Dd][Cc][Oo][Vv][Ee][Rr][%w_-]*%s*:%s*[%w_-]+") do
        add(token:gsub("%s*:%s*", ":"))
    end
    return #tokens > 0 and table.concat(tokens, "\n") or nil
end

local function _readEmbeddedIdentifiersFromEpub(filepath)
    if type(filepath) ~= "string" or not filepath:lower():match("%.epub$") then return nil end

    local list_cmd = "unzip -lqq " .. _shellQuote(filepath) .. " '*.opf'"
    local fh = io.popen(list_cmd, "r")
    if not fh then return nil end
    local opf_path
    for line in fh:lines() do
        opf_path = line:match("%s+%d+%s+%S+%s+%S+%s+(.+%.opf)$")
                or line:match("([^%s].-%.opf)$")
        if opf_path then break end
    end
    fh:close()
    if not opf_path then return nil end

    local read_cmd = "unzip -p " .. _shellQuote(filepath) .. " " .. _shellQuote(opf_path)
    local opf_fh = io.popen(read_cmd, "r")
    if not opf_fh then return nil end
    local chunks, total = {}, 0
    for chunk in opf_fh:lines() do
        total = total + #chunk
        if total > 1024 * 1024 then break end
        chunks[#chunks + 1] = chunk
    end
    opf_fh:close()
    return _extractIdentifiersFromOpf(table.concat(chunks, "\n"))
end

local function _loadPickerModules()
    local ok_api, Api = pcall(require, "hardcover/lib/hardcover_api")
    if not ok_api or not Api then
        return nil, "Hardcover API module could not be loaded"
    end
    local ok_user, User = pcall(require, "hardcover/lib/user")
    if not ok_user or not User then
        return nil, "Hardcover user module could not be loaded"
    end
    local ok_dm, DialogManager = pcall(require, "hardcover/lib/ui/dialog_manager")
    if not ok_dm or not DialogManager then
        return nil, "Hardcover dialog module could not be loaded"
    end
    local ok_book, Book = pcall(require, "hardcover/lib/book")
    if not ok_book then Book = nil end
    return {
        Api = Api,
        User = User,
        DialogManager = DialogManager,
        Book = Book,
    }
end

local function _runWhenOnline(fn, on_error)
    local ok_network, NetworkMgr = pcall(require, "ui/network/manager")
    if ok_network and NetworkMgr and type(NetworkMgr.runWhenOnline) == "function" then
        local ok_run = pcall(function()
            NetworkMgr:runWhenOnline(function()
                local ok, err = pcall(fn)
                if not ok and on_error then on_error(tostring(err)) end
            end)
        end)
        if ok_run then
            return true
        end
    end

    local ok, err = pcall(fn)
    if not ok then
        if on_error then on_error(tostring(err)) end
        return false, err
    end
    return true
end

local function _openHardcoverSettingsObject()
    if _hc_settings_object then return _hc_settings_object end
    local ok, HardcoverSettings = pcall(require, "hardcover/lib/hardcover_settings")
    if not ok or not HardcoverSettings or type(HardcoverSettings.new) ~= "function" then
        return nil, "Hardcover settings module could not be loaded"
    end
    local ok_obj, obj = pcall(function()
        return HardcoverSettings:new(_settingsPath(), { document = { file = nil } })
    end)
    if not ok_obj or not obj then
        return nil, "Could not open Hardcover settings"
    end
    _hc_settings_object = obj
    return _hc_settings_object
end

local function _openPickerContext()
    local modules, mod_err = _loadPickerModules()
    if not modules then return nil, nil, nil, mod_err end
    local settings, settings_err = _openHardcoverSettingsObject()
    if not settings then return nil, nil, nil, settings_err end
    modules.User.settings = settings
    local ok_user, user_id = pcall(modules.User.getId, modules.User)
    if not ok_user or not user_id then
        return nil, nil, nil, "Could not fetch Hardcover user id"
    end
    return modules, settings, user_id
end

local function _linkPayload(hc_book, Book)
    local delete = {}
    local function field(name, value)
        if value == nil then delete[#delete + 1] = name end
        return value
    end
    local book_id = hc_book.book_id or hc_book.id
    local edition_id = hc_book.edition_id
    local edition_format = hc_book.edition_format or hc_book.filetype
    if Book and type(Book.editionFormatName) == "function" then
        edition_format = Book:editionFormatName(hc_book.edition_format, hc_book.reading_format_id)
                      or edition_format
    end
    return {
        book_id        = field("book_id", book_id),
        edition_id     = field("edition_id", edition_id),
        edition_format = field("edition_format", edition_format),
        pages          = field("pages", hc_book.pages),
        title          = field("title", hc_book.title),
        _delete        = delete,
    }
end

local function _applyExternalBookSetting(settings, filepath, config)
    if not settings then return nil end
    local books = settings:readSetting("books") or {}
    books[filepath] = books[filepath] or {}
    local book_setting = books[filepath]
    local original = _shallowCopy(book_setting)
    for k, v in pairs(config or {}) do
        if k == "_delete" then
            for _, name in ipairs(v) do
                book_setting[name] = nil
            end
        else
            book_setting[k] = v
        end
    end
    settings:saveSetting("books", books)
    settings:flush()
    return original
end

local function _notifyLoadedHardcoverSettings(filepath, config, original)
    local HardcoverSettings = package.loaded["hardcover/lib/hardcover_settings"]
    if not HardcoverSettings then return end
    -- Keep the Hardcover app's in-memory book settings in sync so it sees our
    -- link change next time it reads them.
    if HardcoverSettings.settings and HardcoverSettings.settings ~= _hc_settings then
        pcall(_applyExternalBookSetting, HardcoverSettings.settings, filepath, config)
    end
    -- Deliberately do NOT call HardcoverSettings:notify() here. That broadcasts
    -- to the app's subscribers, one of which (onSettingsChanged ->
    -- registerHighlight) dereferences self.ui.highlight -- nil in FileManager
    -- context, where our link writes happen. A single link crashed its handler
    -- (caught), and a bulk auto-link / "Remove all" fired it once per book: a
    -- storm of error handlers that reads as a crash. The mirrored data is
    -- already persisted by _mirrorExternalLink's _applyExternalBookSetting, so
    -- skipping the broadcast loses nothing but the (crashing) live event.
    -- `original` is retained in the signature for callers; intentionally unused.
end

local function _mirrorExternalLink(filepath, config)
    local ok_settings, settings = pcall(_openExternalSettings)
    if not ok_settings or not settings then return end
    local original = _applyExternalBookSetting(settings, filepath, config)
    _notifyLoadedHardcoverSettings(filepath, config, original)
end

function Hardcover.invalidate()
    _links = nil
    _external_links = nil
    _cache_memo = {}
    _hc_settings = nil
    _hc_settings_object = nil
end

function Hardcover.getCachedAt()
    return tonumber(BookshelfSettings.read(RATINGS_TIME_KEY))
end

function Hardcover.getCacheStats()
    local linked = 0
    local seen = {}
    local function countLink(_filepath, link)
        if type(link) ~= "table" or not link.book_id then return end
        local key = tostring(link.book_id)
        if seen[key] then return end
        seen[key] = true
        linked = linked + 1
    end
    for fp, link in pairs(_readExternalLinks(false)) do countLink(fp, link) end
    for fp, link in pairs(_readLinks()) do countLink(fp, link) end
    return {
        linked = linked,
        -- Count of cached rating rows. A hair looser than "linked books with a
        -- usable rating" (the old per-link check), but it's a cosmetic label
        -- and a COUNT avoids N per-book reads.
        rated = _cacheCount("rating"),
        fetched_at = Hardcover.getCachedAt(),
    }
end

-- True when the external Hardcover plugin's API module is loadable -- i.e.
-- the plugin is installed AND enabled. KOReader only adds ENABLED plugins to
-- package.path (pluginloader.lua), so a require of a disabled/uninstalled
-- plugin's module fails. Memoised: the enable-state can't change without a
-- KOReader restart, which reloads this module anyway.
local _available
function Hardcover.isAvailable()
    if _available == nil then
        local ok, Api = pcall(require, "hardcover/lib/hardcover_api")
        _available = (ok and Api ~= nil and type(Api.query) == "function") or false
    end
    return _available
end

-- True when the user has any stored Hardcover data: a linked book, a cached
-- rating, or a prior ratings fetch. Lets cache-backed UI (and the settings
-- menu) persist for someone who used Hardcover and then removed the plugin.
function Hardcover.hasData()
    local ok, stats = pcall(Hardcover.getCacheStats)
    if not ok or type(stats) ~= "table" then return false end
    return (stats.linked or 0) > 0
        or (stats.rated or 0) > 0
        or stats.fetched_at ~= nil
end

-- Gate for the "Hardcover enrichment" settings menu: shown when the plugin is
-- available OR the user already has data, hidden only for someone who has
-- never used Hardcover and doesn't have the plugin installed.
function Hardcover.shouldShowEnrichmentUI()
    return Hardcover.isAvailable() or Hardcover.hasData()
end

function Hardcover.getCachedRating(book_id)
    if not book_id then return nil end
    return _ratingFromCacheEntry(_cacheGet("rating", tostring(book_id)))
end

function Hardcover.clearEnrichmentCache()
    _cacheDelKind("enrich")
    BookshelfSettings.delete(CACHE_KEY)   -- drop any pre-migration copy too
    local dir = _cacheDir()
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok_lfs and lfs and lfs.dir and lfs.attributes
            and lfs.attributes(dir, "mode") == "directory" then
        local ok_iter, iter, dir_obj = pcall(lfs.dir, dir)
        if ok_iter and type(iter) == "function" then
            for entry in iter, dir_obj do
                if entry ~= "." and entry ~= ".." then
                    pcall(os.remove, dir .. "/" .. entry)
                end
            end
        end
    end
end

function Hardcover.clearRatingsCache()
    _cacheDelKind("rating")
    BookshelfSettings.delete(RATINGS_KEY)
    BookshelfSettings.delete(RATINGS_TIME_KEY)
end

function Hardcover.clearReviewsCache()
    _cacheDelKind("review")
    BookshelfSettings.delete(REVIEWS_KEY)
end

function Hardcover.getLink(filepath)
    if not filepath then return nil end
    local link = _readLinks()[filepath]
    if type(link) == "table" and link.book_id then return link end
    link = _readExternalLinks(false)[filepath]
    return type(link) == "table" and link.book_id and link or nil
end

function Hardcover.linkBook(filepath, hc_book)
    if not (filepath and hc_book) then
        return false, "Missing book link data"
    end
    local modules = _loadPickerModules()
    local Book = modules and modules.Book or nil
    local payload = _linkPayload(hc_book, Book)
    if not payload.book_id then
        return false, "Missing Hardcover book id"
    end
    local links = _readLinks()
    links[filepath] = payload
    _saveLinks(links)
    pcall(_mirrorExternalLink, filepath, payload)
    Hardcover.invalidate()
    return true
end

function Hardcover.clearLink(filepath)
    if not filepath then return false, "Missing file path" end
    local links = _readLinks()
    links[filepath] = nil
    _saveLinks(links)
    pcall(_mirrorExternalLink, filepath, {
        _delete = { "book_id", "edition_id", "edition_format", "pages", "title" },
    })
    Hardcover.invalidate()
    return true
end

-- Full reset: undo every Hardcover change so the library looks as it did before
-- any linking. Unlinks every book (Bookshelf's own links + the mirrored
-- Hardcover-app entries), restores any user cover we displaced into a book's
-- .sdr, deletes downloaded covers, and empties all caches. Destructive and
-- irreversible -- the menu guards it with a warning. Returns the count removed.
function Hardcover.removeAllData()
    local fps, seen = {}, {}
    local function collect(fp, link)
        if type(link) == "table" and link.book_id and not seen[fp] then
            seen[fp] = true
            fps[#fps + 1] = fp
        end
    end
    for fp, link in pairs(_readLinks()) do collect(fp, link) end
    for fp, link in pairs(_readExternalLinks(true)) do collect(fp, link) end

    for _, fp in ipairs(fps) do
        local link = Hardcover.getLink(fp)
        -- Undo a sidecar cover we wrote (restores the user's cover.orig backup).
        -- Books we never re-covered (use_cover ~= true) are left untouched.
        if link and link.use_cover == true then
            pcall(Hardcover.disableSidecarCover, fp)
        end
        pcall(Hardcover.clearLink, fp)
    end

    Hardcover.clearEnrichmentCache()  -- descriptions + downloaded cover files
    Hardcover.clearRatingsCache()
    Hardcover.clearReviewsCache()
    Hardcover.invalidate()
    return #fps
end

function Hardcover.linkLabel(filepath)
    local link = Hardcover.getLink(filepath)
    if not link or not link.book_id then return nil end
    local title = link.title or tostring(link.book_id)
    if link.edition_format and link.edition_format ~= "" then
        return title .. " · " .. link.edition_format
    end
    return title
end

-- ─── Per-book enrichment toggles + sidecar cover ─────────────────────────────
-- The link record carries two optional user flags, read by enrichBook:
--   use_description = true -> force the cached Hardcover description (override
--                             the book's own / the "fill when missing" default).
--   use_cover       = true -> use a Hardcover cover stored in the book's .sdr
--                             as KOReader's custom cover (cover.<ext>).
-- The book menu toggles them; linking auto-enables per the quality rules.

-- Per-book toggle state for the link menu. A Hardcover cover/description is
-- only ever shown when the book's explicit flag is true (set by the link-time
-- auto-decision or a manual toggle), so the checkbox is just that flag -- no
-- global default to fold in any more.
function Hardcover.getEnrichmentFlags(filepath)
    local link = Hardcover.getLink(filepath)
    if not link then return nil end
    return {
        use_cover       = link.use_cover == true,
        use_description = link.use_description == true,
    }
end

-- Merge a field into the (internal) link record and persist it. Promotes an
-- external-only link into the internal table so the flag has somewhere to live.
local function _updateLinkField(filepath, key, value)
    local links = _readLinks()
    local link = links[filepath]
    if not link then
        local existing = Hardcover.getLink(filepath)
        if not existing then return false, "Book is not linked to Hardcover" end
        link = existing
        links[filepath] = link
    end
    link[key] = value
    _saveLinks(links)
    Hardcover.invalidate()
    return true
end

function Hardcover.setUseDescription(filepath, enabled)
    -- Store an explicit false (not nil) on disable: nil means "undecided, let
    -- the global fill-when-missing default apply", which would re-assert the
    -- description the user just turned off. False = "user said no".
    return _updateLinkField(filepath, "use_description", enabled and true or false)
end

-- A pre-existing (user-set) custom cover is preserved before Hardcover takes
-- over: renamed to "<sdr>/cover.orig.<ext>" (basename "cover.orig", so
-- KOReader's findCustomCoverFile ignores it) and restored on toggle-off. The
-- Hardcover cover itself is re-fetchable from the cache, so toggle-off just
-- removes it. Nothing the user had is ever deleted.
local function _findUserCoverBackup(dir)
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not (ok_lfs and lfs and lfs.dir and dir) then return nil end
    local ok_iter, iter, dir_obj = pcall(lfs.dir, dir)
    if not ok_iter then return nil end
    for f in iter, dir_obj do
        if f:match("^cover%.orig%.[^.]+$") then return dir .. "/" .. f end
    end
    return nil
end

function Hardcover.enableSidecarCover(filepath)
    local DocSettings = require("docsettings")
    local dir = DocSettings:getSidecarDir(filepath)
    -- Resolve + validate the cached Hardcover cover FIRST, so a missing cover
    -- fails before any file is touched (no backup/undo dance needed).
    local link = Hardcover.getLink(filepath)
    local enrichment = link and Hardcover.getCachedEnrichment(link.book_id, link.edition_id)
    local src = type(enrichment) == "table" and enrichment.cover_path or nil
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not (type(src) == "string" and src ~= ""
            and ok_lfs and lfs and lfs.attributes(src, "mode") == "file") then
        return false, "No cached Hardcover cover -- refresh the link first"
    end
    -- Preserve a pre-existing user cover before we overwrite cover.<ext> --
    -- but only once (if a backup already exists, the active cover is ours).
    local active = DocSettings:findCustomCoverFile(filepath)
    if active and dir and not _findUserCoverBackup(dir) then
        local ext = active:match("%.([^.]+)$") or "jpg"
        os.rename(active, dir .. "/cover.orig." .. ext)
    elseif active then
        -- Backup slot taken -> active wasn't renamed away. Remove it before the
        -- flush: flushCustomCover writes cover.<new-ext> without clearing an
        -- existing cover.<old-ext>, and two cover.* files make
        -- findCustomCoverFile nondeterministic (dir-iterator order).
        pcall(os.remove, active)
    end
    DocSettings:flushCustomCover(filepath, src)
    DocSettings:getCustomCoverFile(true)
    return true
end

function Hardcover.disableSidecarCover(filepath)
    local DocSettings = require("docsettings")
    local dir = DocSettings:getSidecarDir(filepath)
    -- Remove the active (Hardcover) cover -- it's re-fetchable from the cache.
    local active = DocSettings:findCustomCoverFile(filepath)
    if active then os.remove(active) end
    -- Restore the user's original cover, if we displaced one.
    local bak = _findUserCoverBackup(dir)
    if bak then os.rename(bak, (bak:gsub("/cover%.orig%.", "/cover."))) end
    DocSettings:getCustomCoverFile(true)
    return true
end

-- hasCover(filepath) — true only if a Hardcover cover image is actually
-- available on disk for this book (cached file present). Used to grey out the
-- per-book "Use Hardcover image" toggle: with cover download off (issue #111)
-- or a book Hardcover has no cover for, there's nothing to apply.
function Hardcover.hasCover(filepath)
    local link = Hardcover.getLink(filepath)
    if not link or not link.book_id then return false end
    local enrichment = Hardcover.getCachedEnrichment(link.book_id, link.edition_id)
    local src = type(enrichment) == "table" and enrichment.cover_path or nil
    if type(src) ~= "string" or src == "" then return false end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    return (ok_lfs and lfs and lfs.attributes(src, "mode") == "file") or false
end

-- removeDownloadedCovers() — delete every downloaded Hardcover cover without
-- unlinking books or dropping descriptions (issue #111 cleanup, lighter than
-- removeAllData). For each linked book using a Hardcover cover, restore its
-- original cover and clear the use_cover flag; then delete the cached cover
-- image files. The enrichment cache (descriptions/ratings) is left intact, so
-- this only reclaims cover storage. Returns the count of covers undone.
function Hardcover.removeDownloadedCovers()
    local n, seen = 0, {}
    local function undo(fp, link)
        if type(link) == "table" and link.use_cover == true and not seen[fp] then
            seen[fp] = true
            pcall(Hardcover.disableSidecarCover, fp)
            pcall(_updateLinkField, fp, "use_cover", false)
            n = n + 1
        end
    end
    for fp, link in pairs(_readLinks()) do undo(fp, link) end
    for fp, link in pairs(_readExternalLinks(true)) do undo(fp, link) end

    -- Delete the cached cover image files (the cache dir holds only cover
    -- files; descriptions live in the settings store, untouched here).
    local dir = _cacheDir()
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok_lfs and lfs and lfs.dir and lfs.attributes
            and lfs.attributes(dir, "mode") == "directory" then
        local ok_iter, iter, dir_obj = pcall(lfs.dir, dir)
        if ok_iter and type(iter) == "function" then
            for entry in iter, dir_obj do
                if entry ~= "." and entry ~= ".." then
                    pcall(os.remove, dir .. "/" .. entry)
                end
            end
        end
    end
    Hardcover.invalidate()
    return n
end

function Hardcover.setUseCover(filepath, enabled)
    local ok, err
    if enabled then
        ok, err = Hardcover.enableSidecarCover(filepath)
    else
        ok, err = Hardcover.disableSidecarCover(filepath)
    end
    if not ok then return false, err end
    -- Explicit false on disable (see setUseDescription) so the "fill when
    -- missing" default doesn't immediately re-show the cover the user removed.
    return _updateLinkField(filepath, "use_cover", enabled and true or false)
end

-- Flag-only sibling of setUseCover: records the use_cover link field WITHOUT
-- touching the sidecar (no backup, no file removal). The Cover picker manages
-- the actual cover file itself and just needs Hardcover to stop auto-injecting
-- its own cover on the next enrich -- setUseCover(false) would delete/restore
-- files, which the picker has already handled. No-op (returns false) for an
-- unlinked book.
function Hardcover.markUseCover(filepath, enabled)
    return _updateLinkField(filepath, "use_cover", enabled and true or false)
end

-- Parse BIM's cover_sizetag ("1072x1448") into width, height.
local function _parseSizetag(tag)
    if type(tag) ~= "string" then return nil end
    local w, h = tag:match("^(%d+)x(%d+)$")
    return tonumber(w), tonumber(h)
end

-- The sensible defaults, applied whenever a linked book is enriched (single
-- link via refreshBook, or bulk via the paced "Refresh linked data" scan, which
-- also calls refreshBook per file). Runs only on UNDECIDED
-- flags (nil), so it never overrides an explicit user choice and never
-- re-fires once the user (or a previous run) has decided. This is the single
-- source of "should this book use Hardcover's cover/description" -- there is no
-- separate global switch and no live fill; the decision is baked into the
-- per-book flag here. `enrichment` is the just-cached payload.
function Hardcover.autoDecideFlags(book, enrichment)
    if type(book) ~= "table" or not book.filepath then return end
    if type(enrichment) ~= "table" then return end
    local link = Hardcover.getLink(book.filepath)
    if not link then return end

    -- Both decisions are recorded EXPLICITLY (true to adopt Hardcover's, false
    -- to keep the book's own) -- never left nil. A stable true/false is what
    -- lets a later refresh tell "already decided" from "still needs deciding",
    -- and stops the auto-decision re-running forever on keep-own books.

    -- Description: adopt Hardcover's when the book carries none of its own.
    if link.use_description == nil then
        local adopt = type(enrichment.description) == "string"
            and enrichment.description ~= ""
            and (not book.description or book.description == "")
        Hardcover.setUseDescription(book.filepath, adopt)
    end

    -- Cover: adopt Hardcover's when the book has no embedded cover, or its
    -- embedded cover is lower resolution than Hardcover's (compare total
    -- pixels). Unknown dimensions on either side are treated conservatively --
    -- keep the embedded cover rather than swap on a guess.
    if link.use_cover == nil then
        local adopt = false
        if type(enrichment.cover_path) == "string" and enrichment.cover_path ~= "" then
            if not book.has_cover then
                adopt = true
            else
                local ew, eh = _parseSizetag(book.cover_sizetag)
                local hw = tonumber(enrichment.cover_width)
                local hh = tonumber(enrichment.cover_height)
                if ew and eh and hw and hh then
                    adopt = (hw * hh) > (ew * eh)
                end
            end
        end
        if adopt then
            -- enableSidecarCover reads the (just-cached) enrichment and writes
            -- the Hardcover cover into the book's .sdr so KOReader's own UI
            -- picks it up too.
            Hardcover.setUseCover(book.filepath, true)
        else
            -- Record "keep own cover" without touching files. NOT setUseCover
            -- (false): disableSidecarCover would delete a user's own custom
            -- .sdr cover. We only want to persist the decision.
            _updateLinkField(book.filepath, "use_cover", false)
        end
    end
end

function Hardcover.getEmbeddedIdentifiers(book)
    if type(book) ~= "table" then return nil end
    if type(book.identifiers) == "string" and book.identifiers ~= "" then
        return book.identifiers
    end
    if type(book.identifiers) == "table" then
        local parts = {}
        for k, v in pairs(book.identifiers) do
            if type(v) == "string" or type(v) == "number" then
                parts[#parts + 1] = tostring(k) .. ":" .. tostring(v)
            end
        end
        if #parts > 0 then
            book.identifiers = table.concat(parts, "\n")
            return book.identifiers
        end
    end
    local ok_epub_ids, ids = pcall(_readEmbeddedIdentifiersFromEpub, book.filepath)
    if not ok_epub_ids then ids = nil end
    if ids and ids ~= "" then
        book.identifiers = ids
        return ids
    end
    return nil
end

-- Best embedded ISBN for a book (prefer ISBN-13), digits only (trailing X kept
-- for ISBN-10), or nil. Pure -- reuses getEmbeddedIdentifiers (reads the EPUB's
-- OPF), so it works with the external Hardcover plugin absent. Used by the Cover
-- picker's online search for exact-edition matching.
function Hardcover.getEmbeddedIsbn(book)
    local ids = Hardcover.getEmbeddedIdentifiers(book)
    if type(ids) ~= "string" or ids == "" then return nil end
    local lower = ids:lower()
    local function clean(s) return (s:gsub("[^%dxX]", ""):upper()) end
    local i13 = lower:match("isbn13:%s*([%d%s%-]+)")
    if i13 then
        i13 = clean(i13)
        if #i13 == 13 then return i13 end
    end
    local i = lower:match("isbn[%w%-]*:%s*([%dxX%s%-]+)")
    if i then
        i = clean(i)
        if #i == 13 or #i == 10 then return i end
    end
    return nil
end

local function _parseHardcoverIdentifiers(modules, identifiers)
    if type(identifiers) ~= "string" or identifiers == "" then return nil end
    local parsed = {}
    if modules.Book and type(modules.Book.parseIdentifiers) == "function" then
        local ok, result = pcall(modules.Book.parseIdentifiers, modules.Book, identifiers)
        if ok and type(result) == "table" then parsed = result end
    end
    local lower = identifiers:lower()
    for line in lower:gmatch("[^\r\n]+") do
        local key, value = line:match("^%s*([^:%s]+)%s*:%s*([^%s]+)")
        if key and value then
            key = key:gsub("_", "-")
            local digits = value:gsub("[^%dx]", "")
            if key == "hardcover" or key == "hardcover-slug" then
                parsed.book_slug = parsed.book_slug or value
            elseif key == "hardcover-edition" or key == "hardcover-edition-id"
                    or key == "hardcoveredition" or key == "hardcovereditionid" then
                parsed.edition_id = parsed.edition_id or digits
            elseif key == "isbn" or key == "isbn13" or key == "isbn-13"
                    or key == "isbn10" or key == "isbn-10" then
                if #digits == 13 then
                    parsed.isbn_13 = parsed.isbn_13 or digits
                elseif #digits == 10 then
                    parsed.isbn_10 = parsed.isbn_10 or digits
                end
            end
        end
    end
    parsed.book_id = parsed.book_id
        or lower:match("hardcover%-book%-id%s*:%s*(%d+)")
        or lower:match("hardcover%-id%s*:%s*(%d+)")
        or lower:match("hardcoverbookid%s*:%s*(%d+)")
        or lower:match("hardcoverid%s*:%s*(%d+)")
    return next(parsed) and parsed or nil
end

local function _lookupBookByIdentifiers(modules, parsed, user_id)
    if not parsed or not next(parsed) then return nil end
    local ok_lookup, book = pcall(function()
        return modules.Api:findBookByIdentifiers(parsed, user_id)
    end)
    return ok_lookup and book or nil
end

local function _findBookByIdentifiers(modules, identifiers, user_id)
    local parsed = _parseHardcoverIdentifiers(modules, identifiers)
    if not parsed then return nil end

    if parsed.edition_id then
        local book = _lookupBookByIdentifiers(modules, parsed, user_id)
        if book then return book end
    end

    -- ISBN usually resolves to the exact edition, while a Hardcover slug/id
    -- often resolves to the parent work. Prefer ISBN unless an explicit
    -- Hardcover edition id was embedded.
    if parsed.isbn_13 or parsed.isbn_10 then
        local isbn_only = {
            isbn_13 = parsed.isbn_13,
            isbn_10 = parsed.isbn_10,
        }
        local book = _lookupBookByIdentifiers(modules, isbn_only, user_id)
        if book then return book end
    end

    local book = _lookupBookByIdentifiers(modules, parsed, user_id)
    if book then return book end

    local numeric_id = parsed.book_id
    if not numeric_id and parsed.book_slug and tostring(parsed.book_slug):match("^%d+$") then
        numeric_id = parsed.book_slug
    end
    numeric_id = tonumber(numeric_id)
    if numeric_id and type(modules.Api.hydrateBooks) == "function" then
        local ok_hydrate, books = pcall(function()
            return modules.Api:hydrateBooks({ numeric_id }, user_id)
        end)
        if ok_hydrate and type(books) == "table" and books[1] then
            return books[1]
        end
    end
    return nil
end

local function _newDialogManager(modules, settings)
    modules.User.settings = settings
    return modules.DialogManager:new{ settings = settings }
end

function Hardcover.linkFromEmbeddedIdentifiers(book, opts)
    opts = opts or {}
    if not (book and book.filepath) then return false, "Missing local book" end
    local identifiers = Hardcover.getEmbeddedIdentifiers(book)
    if not identifiers then return false, "No embedded Hardcover identifier found" end

    local modules, _settings, user_id, ctx_err = _openPickerContext()
    if not modules then return false, ctx_err end
    local hc_book = _findBookByIdentifiers(modules, identifiers, user_id)
    if not hc_book then return false, "No Hardcover match found for embedded identifier" end

    local ok, link_err = Hardcover.linkBook(book.filepath, hc_book)
    if not ok then return false, link_err end
    if opts.on_linked then opts.on_linked(hc_book) end
    return true, hc_book
end

-- Author / series extraction from a hydrated Hardcover search hit, mirroring
-- the vendored search_dialog.lua (contributions may be a single .author string
-- or an array of { author = { name } }; book_series[1].series.name is series).
local function _candidateAuthor(b)
    local c = b and b.contributions
    if type(c) ~= "table" then return nil end
    if type(c.author) == "string" and c.author ~= "" then return c.author end
    local names = {}
    for _, a in ipairs(c) do
        if type(a) == "table" and type(a.author) == "table"
                and type(a.author.name) == "string" then
            names[#names + 1] = a.author.name
        end
    end
    return #names > 0 and table.concat(names, ", ") or nil
end

local function _candidateSeries(b)
    local bs = b and b.book_series
    if type(bs) == "table" and type(bs[1]) == "table"
            and type(bs[1].series) == "table" then
        return bs[1].series.name
    end
    return nil
end

local function _candidateSeriesPosition(b)
    local bs = b and b.book_series
    if type(bs) == "table" and type(bs[1]) == "table" then
        return bs[1].position
    end
    return nil
end

-- Genres from a book row's `cached_tags`. Hardcover's exact JSON shape is
-- in flux, so parse defensively: handle a category-keyed object
-- ({ Genre = { {tag=...}, ... } }), a flat array of { tag/name, category },
-- and a plain string list. Returns ALL genres found (de-duped, order kept);
-- callers cap how many they actually use. nil when nothing parseable.
local function _candidateGenres(b)
    local ct = b and b.cached_tags
    if type(ct) ~= "table" then return nil end
    local out, seen = {}, {}
    local function add(name)
        if type(name) ~= "string" then return end
        name = name:gsub("^%s+", ""):gsub("%s+$", "")
        local key = name:lower()
        if name ~= "" and not seen[key] then
            seen[key] = true
            out[#out + 1] = name
        end
    end
    -- Category-keyed object: take the Genre bucket only.
    local genre_bucket = ct["Genre"] or ct["genre"] or ct["Genres"]
    if type(genre_bucket) == "table" then
        for _, t in ipairs(genre_bucket) do
            if type(t) == "table" then add(t.tag or t.name)
            elseif type(t) == "string" then add(t) end
        end
    end
    -- Flat array fallback: keep entries whose category is Genre (or absent).
    if #out == 0 then
        for _, t in ipairs(ct) do
            if type(t) == "table" then
                local cat = t.category or t.categorySlug
                if cat == nil or tostring(cat):lower() == "genre" then
                    add(t.tag or t.name)
                end
            elseif type(t) == "string" then
                add(t)
            end
        end
    end
    return #out > 0 and out or nil
end

-- "Best guess" link: full-text search Hardcover by the book's title + author,
-- score the hits with the ebook-enricher heuristics, and link the best
-- confident, canonical match (or nothing). Like linkFromEmbeddedIdentifiers it
-- only links; the caller enriches afterwards. On success returns a details
-- table { title, author, title_score, author_score } for the report.
function Hardcover.bestGuessLink(book)
    if not (book and book.filepath) then return false, "Missing local book" end
    local title = book.title or _filenameTitle(book.filepath)
    local author = _authorString(book)
    if not title or title == "" then return false, "No title to search" end

    local modules, _settings, user_id, ctx_err = _openPickerContext()
    if not modules then return false, ctx_err end
    local ok_search, results = pcall(function()
        return modules.Api:findBooks(title, author or "", user_id)
    end)
    if not ok_search or type(results) ~= "table" then
        return false, "Hardcover search failed"
    end
    if #results == 0 then return false, "no_match" end

    local cands = {}
    for _, b in ipairs(results) do
        cands[#cands + 1] = {
            title       = b.title,
            author      = _candidateAuthor(b),
            series_name = _candidateSeries(b),
            _raw        = b,
        }
    end

    local Match = require("lib/bookshelf_hardcover_match")
    local chosen, t_score, a_score = Match.pickBest(
        { title = title, author = author, series = book.series }, cands)
    if not chosen then return false, "no_confident_match" end

    local ok, link_err = Hardcover.linkBook(book.filepath, chosen._raw)
    if not ok then return false, link_err end
    return true, {
        title        = chosen.title,
        author       = chosen.author,
        title_score  = t_score,
        author_score = a_score,
    }
end

function Hardcover.showBookPicker(book, opts)
    opts = opts or {}
    if not (book and book.filepath) then return false, "Missing local book" end
    local modules, settings, user_id, ctx_err = _openPickerContext()
    if not modules then return false, ctx_err end
    local title = book.title or _filenameTitle(book.filepath)
    local author = _authorString(book)
    local books, err
    local embedded = _findBookByIdentifiers(modules, Hardcover.getEmbeddedIdentifiers(book), user_id)
    if embedded then
        books = { embedded }
    else
        books, err = modules.Api:findBooks(title, author, user_id)
        -- findBooks appends the author to the query, which can skew Hardcover's
        -- fuzzy search badly (e.g. "Katabasis R. F. Kuang" returns database
        -- books). If none of the hits' titles resemble the book's, retry
        -- title-only and merge the new ones in -- "Katabasis" alone tends to
        -- surface the real book.
        if author and author ~= "" and type(books) == "table" then
            local Match = require("lib/bookshelf_hardcover_match")
            local matched = false
            for _, b in ipairs(books) do
                local ts = select(1, Match.scoreMatch(title, "x", b.title or "", "x"))
                if ts and ts >= Match.TITLE_THRESHOLD then matched = true; break end
            end
            if not matched then
                local ok2, more = pcall(function()
                    return modules.Api:findBooks(title, "", user_id)
                end)
                if ok2 and type(more) == "table" and #more > 0 then
                    local seen = {}
                    for _, b in ipairs(books) do
                        local id = b.book_id or b.id
                        if id then seen[id] = true end
                    end
                    for _, b in ipairs(more) do
                        local id = b.book_id or b.id
                        if id and not seen[id] then
                            seen[id] = true
                            books[#books + 1] = b
                        end
                    end
                end
            end
        end
    end
    if not books then return false, err or "No response from Hardcover" end

    local manager = _newDialogManager(modules, settings)
    manager:buildSearchDialog(
        "Select Hardcover book",
        books,
        { book_id = (Hardcover.getLink(book.filepath) or {}).book_id },
        function(selected)
            local ok, link_err = Hardcover.linkBook(book.filepath, selected)
            if not ok then
                if opts.on_error then opts.on_error(link_err) end
                return
            end
            Hardcover.refreshBookOnline(book, { force = true }, function(ok_refresh, refresh_err)
                if opts.on_book_selected then
                    opts.on_book_selected(selected, ok_refresh, refresh_err)
                end
            end)
        end,
        function(search)
            manager:updateSearchResults(search)
            return true
        end,
        title
    )
    -- buildSearchDialog doesn't wire a close_callback for the search variant,
    -- so cancelling the picker returned nowhere. SearchDialog:onClose fires
    -- close_callback on BOTH cancel and selection, so wiring it here lets the
    -- caller (the book menu) reopen on either path. On selection the link is
    -- set synchronously before this reopen runs (only the metadata refresh is
    -- async), so the reopened menu reflects the new link.
    if opts.on_close and manager.search_dialog then
        local prev = manager.search_dialog.close_callback
        manager.search_dialog.close_callback = function()
            if prev then prev() end
            opts.on_close()
        end
    end
    return true
end

function Hardcover.showEditionPicker(book, book_id, opts)
    opts = opts or {}
    if not (book and book.filepath and book_id) then
        return false, "Missing Hardcover book id"
    end
    local modules, settings, user_id, ctx_err = _openPickerContext()
    if not modules then return false, ctx_err end
    local editions = modules.Api:findEditions(book_id, user_id)
    if not editions then return false, "Could not fetch Hardcover editions" end

    local link = Hardcover.getLink(book.filepath) or {}
    local manager = _newDialogManager(modules, settings)
    manager:buildSearchDialog(
        "Select Hardcover edition",
        editions,
        { edition_id = link.edition_id },
        function(selected)
            local ok, link_err = Hardcover.linkBook(book.filepath, selected)
            if not ok then
                if opts.on_error then opts.on_error(link_err) end
                return
            end
            Hardcover.refreshBookOnline(book, { force = true }, function(ok_refresh, refresh_err)
                if opts.on_edition_selected then
                    opts.on_edition_selected(selected, ok_refresh, refresh_err)
                end
            end)
        end
    )
    -- See showBookPicker: wire close_callback so cancel/selection both return.
    if opts.on_close and manager.search_dialog then
        local prev = manager.search_dialog.close_callback
        manager.search_dialog.close_callback = function()
            if prev then prev() end
            opts.on_close()
        end
    end
    return true
end

local function _loadApi()
    local ok, Api = pcall(require, "hardcover/lib/hardcover_api")
    if not ok or not Api or type(Api.query) ~= "function" then
        return nil, "Hardcover plugin/API module could not be loaded"
    end
    return Api
end

local function _errString(err)
    if type(err) == "table" then
        if type(err.errors) == "table" and err.errors[1] then
            local first = err.errors[1]
            if type(first) == "table" and first.message then
                return tostring(first.message)
            end
            return tostring(first)
        end
        if err.error then return tostring(err.error) end
    end
    return tostring(err)
end

local function _collectLinkedBookIds()
    local ids, seen = {}, {}
    local function collect(_filepath, link)
        if type(link) ~= "table" or not link.book_id then return end
        local id = tonumber(link.book_id)
        if id and not seen[id] then
            seen[id] = true
            ids[#ids + 1] = id
        end
    end
    for fp, link in pairs(_readExternalLinks(true)) do collect(fp, link) end
    for fp, link in pairs(_readLinks()) do collect(fp, link) end
    table.sort(ids)
    return ids
end

local function _getUserId(Api, settings)
    if not settings then return nil, "Could not open Hardcover settings" end
    local user_id = settings:readSetting("user_id")
    if user_id then return tonumber(user_id) or user_id end
    if type(Api.me) ~= "function" then return nil, "Hardcover user id is missing" end
    local ok_me, me = pcall(Api.me, Api)
    if not ok_me then
        return nil, "Could not fetch Hardcover user id: " .. _errString(me)
    end
    user_id = me and me.id
    if not user_id then return nil, "Could not fetch Hardcover user id" end
    pcall(settings.saveSetting, settings, "user_id", user_id)
    if type(settings.flush) == "function" then
        pcall(settings.flush, settings)
    end
    return tonumber(user_id) or user_id
end

local function _normaliseUserName(user)
    if type(user) ~= "table" then return nil end
    return user.name or user.username
end

local function _imageUrl(row)
    if type(row) ~= "table" then return nil end
    -- Hardcover's `cached_image` is a JSON object { url, width, height, ... },
    -- NOT a plain string (the vendored plugin reads cached_image.url too).
    -- The string branch is kept only as a defensive fallback for any caller
    -- that pre-flattened it. Missing this object form was why linked books
    -- never got a fallback cover: _imageUrl returned nil, so nothing was
    -- downloaded.
    local ci = row.cached_image
    if type(ci) == "string" and ci ~= "" then
        return ci
    end
    if type(ci) == "table" and type(ci.url) == "string" and ci.url ~= "" then
        return ci.url
    end
    if type(row.image) == "table" and type(row.image.url) == "string" then
        return row.image.url
    end
    return nil
end

-- Like _imageUrl but also returns the cached_image's pixel dimensions when
-- present (the JSON object carries { url, width, height }). Used to compare
-- against the embedded cover's resolution when auto-deciding "Use Hardcover
-- image" at link time. Dimensions are nil when Hardcover only gives a URL.
local function _imageInfo(row)
    if type(row) ~= "table" then return nil end
    local ci = row.cached_image
    if type(ci) == "table" and type(ci.url) == "string" and ci.url ~= "" then
        return ci.url, tonumber(ci.width), tonumber(ci.height)
    end
    if type(ci) == "string" and ci ~= "" then
        return ci
    end
    if type(row.image) == "table" and type(row.image.url) == "string" then
        return row.image.url, tonumber(row.image.width), tonumber(row.image.height)
    end
    return nil
end

-- getEditionCandidates(book_id) -> array<{edition_id,title,cover_url,width,height}>|nil, err
-- Editions for a Hardcover book, each with its cover art -- the Cover picker's
-- "Hardcover" online source. Encapsulates the picker context + findEditions +
-- per-edition cached_image parsing so the API shape stays inside this module.
-- Placed after _imageInfo so it can reuse it. Network-touching; call inside a
-- runWhenOnline wrapper.
function Hardcover.getEditionCandidates(book_id)
    if not book_id then return nil, "Missing Hardcover book id" end
    local modules, _settings, user_id, ctx_err = _openPickerContext()
    if not modules then return nil, ctx_err end
    local ok, editions = pcall(function() return modules.Api:findEditions(book_id, user_id) end)
    if not ok or type(editions) ~= "table" then
        return nil, "Could not fetch Hardcover editions"
    end
    local out = {}
    for _i, ed in ipairs(editions) do
        local url, w, h = _imageInfo(ed)
        if type(url) == "string" and url ~= "" then
            out[#out + 1] = {
                edition_id = ed.id or ed.edition_id,
                title = ed.title,
                cover_url = url, width = w, height = h,
            }
        end
    end
    return out
end

-- searchCoverCandidates(title, author) -> array<{cover_url,width,height,title,book_id}>|nil, err
-- Broader than a linked edition: full-text search Hardcover for the title (with,
-- then without, the author -- Hardcover's search folds the author into a fuzzy
-- query, and dropping it catches author-format mismatches) and return each
-- matching book's cover. Works for unlinked books too. Deduped by URL. Network;
-- call inside a runWhenOnline wrapper.
function Hardcover.searchCoverCandidates(title, author)
    if type(title) ~= "string" or title == "" then return nil, "no title" end
    local modules, _settings, user_id, ctx_err = _openPickerContext()
    if not modules then return nil, ctx_err end
    local out, seen = {}, {}
    local function collect(books)
        if type(books) ~= "table" then return end
        for _i, b in ipairs(books) do
            local url, w, h = _imageInfo(b)
            if type(url) == "string" and url ~= "" and not seen[url] then
                seen[url] = true
                out[#out + 1] = {
                    cover_url = url, width = w, height = h,
                    title = b.title, book_id = b.book_id or b.id,
                }
            end
        end
    end
    local ok1, r1 = pcall(function() return modules.Api:findBooks(title, author, user_id) end)
    if ok1 then collect(r1) end
    if type(author) == "string" and author ~= "" then
        local ok2, r2 = pcall(function() return modules.Api:findBooks(title, nil, user_id) end)
        if ok2 then collect(r2) end
    end
    return out
end

local function _downloadImage(url, key, force)
    if type(url) ~= "string" or url == "" or not key then return nil end
    local ok_network, NetworkMgr = pcall(require, "ui/network/manager")
    if ok_network and NetworkMgr and type(NetworkMgr.isOnline) == "function" then
        local ok_online, is_online = pcall(NetworkMgr.isOnline, NetworkMgr)
        if ok_online and not is_online then
            return nil
        end
    end
    local dir = _cacheDir()
    if not _ensureDir(dir) then return nil end
    local ext = url:match("%.([jJ][pP][eE]?[gG])[%?%#]?") and "jpg"
            or url:match("%.([pP][nN][gG])[%?%#]?") and "png"
            or "jpg"
    local safe_key = tostring(key):gsub("[^%w_.-]", "_")
    local path = dir .. "/" .. safe_key .. "." .. ext

    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok_lfs and lfs and lfs.attributes
            and lfs.attributes(path, "mode") == "file"
            and not force then
        return path
    end

    local ok_require, http, ltn12, socket, socketutil = pcall(function()
        return require("socket/http"),
               require("ltn12"),
               require("socket"),
               require("socketutil")
    end)
    if not ok_require then return nil end

    local tmp = path .. ".tmp"
    local file = io.open(tmp, "wb")
    if not file then return nil end
    local ok_req, code = pcall(function()
        socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
        local c = socket.skip(1, http.request({
            url = url,
            method = "GET",
            headers = { ["User-Agent"] = "KOReader-Bookshelf" },
            sink = ltn12.sink.file(file),
            redirect = true,
        }))
        socketutil:reset_timeout()
        return c
    end)
    pcall(function() socketutil:reset_timeout() end)
    if not ok_req or code ~= 200 then
        pcall(os.remove, tmp)
        return nil
    end
    pcall(os.remove, path)
    local ok_rename = os.rename(tmp, path)
    if not ok_rename then
        pcall(os.remove, tmp)
        return nil
    end
    return path
end

local function _fetchBookEnrichment(book_id, edition_id, opts)
    opts = opts or {}
    local Api, api_err = _loadApi()
    if not Api then return false, api_err end
    book_id = tonumber(book_id) or book_id
    edition_id = tonumber(edition_id) or edition_id
    if not book_id then return false, "Missing Hardcover book id" end

    local data, err
    if edition_id then
        local query = [[
            query ($bookId: Int!, $editionId: Int!) {
              book: books_by_pk(id: $bookId) {
                id
                title
                description
                cached_image
                contributions: cached_contributors
                cached_tags
                book_series { position series { name } }
                rating
                ratings_count
                reviews_count
              }
              edition: editions_by_pk(id: $editionId) {
                id
                title
                cached_image
              }
            }
        ]]
        local ok_query
        ok_query, data, err = pcall(Api.query, Api, query, {
            bookId = book_id,
            editionId = edition_id,
        })
        if not ok_query then
            return false, "Hardcover enrichment failed: " .. _errString(data)
        end
    else
        local query = [[
            query ($bookId: Int!) {
              book: books_by_pk(id: $bookId) {
                id
                title
                description
                cached_image
                contributions: cached_contributors
                cached_tags
                book_series { position series { name } }
                rating
                ratings_count
                reviews_count
              }
            }
        ]]
        local ok_query
        ok_query, data, err = pcall(Api.query, Api, query, { bookId = book_id })
        if not ok_query then
            return false, "Hardcover enrichment failed: " .. _errString(data)
        end
    end
    if not data or type(data.book) ~= "table" then
        return false, err and ("Hardcover enrichment failed: " .. _errString(err))
            or "No response from Hardcover"
    end

    local edition = type(data.edition) == "table" and data.edition or nil
    local image_url, cover_w, cover_h = _imageInfo(edition)
    if not image_url then image_url, cover_w, cover_h = _imageInfo(data.book) end
    local key = _cacheKey(book_id, edition_id)
    -- Cover download is opt-in (issue #111): off by default so linking pulls
    -- descriptions/ratings/metadata without writing cover.jpg into every
    -- book's .sdr (which bloats storage and gets swept up by the library
    -- metadata scan, since KOReader's indexer recurses .sdr and treats .jpg
    -- as a document). With it off, cover_path stays nil and nothing is cached
    -- or applied to the sidecar.
    local cover_path = nil
    if image_url and BookshelfSettings.isTrue("hardcover_download_covers") then
        cover_path = _downloadImage(image_url, key, opts.force)
    end
    return true, {
        book_id = data.book.id or book_id,
        edition_id = edition and (edition.id or edition_id) or edition_id,
        title = (edition and edition.title) or data.book.title,
        description = data.book.description,
        cover_url = image_url,
        cover_path = cover_path,
        cover_width = cover_w,
        cover_height = cover_h,
        rating = tonumber(data.book.rating),
        ratings_count = tonumber(data.book.ratings_count),
        reviews_count = tonumber(data.book.reviews_count),
        -- Bibliographic metadata for the "Use Hardcover metadata" override.
        authors = _candidateAuthor(data.book),
        series_name = _candidateSeries(data.book),
        series_position = _candidateSeriesPosition(data.book),
        genres = _candidateGenres(data.book),
        fetched_at = os.time(),
    }
end

function Hardcover.getCachedEnrichment(book_id, edition_id)
    local entry = _cacheGet("enrich", _cacheKey(book_id, edition_id))
    if type(entry) == "table" then return entry end
    if edition_id then
        entry = _cacheGet("enrich", _cacheKey(book_id))
        if type(entry) == "table" then return entry end
    end
    return nil
end

function Hardcover.refreshBook(book, opts)
    opts = opts or {}
    if not (book and book.filepath) then return false, "Missing local book" end
    local link = Hardcover.getLink(book.filepath)
    if not link or not link.book_id then return false, "Book is not linked to Hardcover" end
    local ok, payload = _fetchBookEnrichment(link.book_id, link.edition_id, opts)
    if not ok then return false, payload end
    _cachePut("enrich", _cacheKey(link.book_id, link.edition_id), payload)
    _backfillRatingEntry(link.book_id, payload)
    -- First-link defaults for the per-book cover/description overrides. Guarded
    -- internally to fire once (only on undecided flags) -- safe to call on every
    -- refresh.
    pcall(Hardcover.autoDecideFlags, book, payload)
    if opts.on_refreshed then opts.on_refreshed(payload) end
    return true, payload
end

function Hardcover.refreshBookOnline(book, opts, callback)
    opts = opts or {}
    return _runWhenOnline(function()
        local ok, payload = Hardcover.refreshBook(book, opts)
        if callback then callback(ok, payload) end
    end, function(err)
        if callback then callback(false, err) end
    end)
end


local function _normaliseReviewsPayload(book)
    if type(book) ~= "table" then return nil end
    local reviews = {}
    for _, row in ipairs(type(book.user_books) == "table" and book.user_books or {}) do
        local text = row.review or row.review_raw
        if type(text) == "string" and text ~= "" then
            reviews[#reviews + 1] = {
                id = row.id,
                rating = tonumber(row.rating),
                text = text,
                spoiler = row.review_has_spoilers == true,
                reviewed_at = row.reviewed_at,
                likes_count = tonumber(row.likes_count) or 0,
                user_name = _normaliseUserName(row.user),
                username = type(row.user) == "table" and row.user.username or nil,
            }
        end
    end
    return {
        book_id = book.id,
        title = book.title,
        rating = tonumber(book.rating),
        ratings_count = tonumber(book.ratings_count) or 0,
        reviews_count = tonumber(book.reviews_count) or 0,
        reviews = reviews,
        fetched_at = os.time(),
    }
end

function Hardcover.fetchReviews(book_id, opts)
    opts = opts or {}
    book_id = tonumber(book_id) or book_id
    if not book_id then return false, "Missing Hardcover book id" end

    local key = tostring(book_id)
    local cached = _cacheGet("review", key)
    local ttl = tonumber(opts.ttl) or REVIEWS_TTL
    if not opts.force and type(cached) == "table" and cached.fetched_at
            and (os.time() - tonumber(cached.fetched_at)) < ttl then
        return true, cached
    end

    -- cache_only: peek the cache without ever hitting the API (lets callers
    -- serve cached reviews synchronously, with no network and no progress UI).
    if opts.cache_only then
        return false, "No cached reviews"
    end

    local Api, api_err = _loadApi()
    if not Api then return false, api_err end

    local limit = tonumber(opts.limit) or 10
    if limit < 1 then limit = 1 end
    if limit > 25 then limit = 25 end

    local query = [[
        query ($id: Int!, $limit: Int!) {
          books_by_pk(id: $id) {
            id
            title
            rating
            ratings_count
            reviews_count
            user_books(
              where: { has_review: { _eq: true }, review_has_spoilers: { _eq: false } },
              order_by: [{ likes_count: desc_nulls_last }, { reviewed_at: desc_nulls_last }],
              limit: $limit
            ) {
              id
              rating
              review
              review_raw
              review_has_spoilers
              reviewed_at
              likes_count
              user {
                id
                name
                username
              }
            }
          }
        }
    ]]

    local ok_query, data, err = pcall(Api.query, Api, query, { id = book_id, limit = limit })
    if not ok_query then
        return false, "Hardcover reviews could not be fetched: " .. _errString(data)
    end
    if not data or type(data.books_by_pk) ~= "table" then
        return false, err and ("Hardcover reviews could not be fetched: " .. _errString(err))
            or "No response from Hardcover"
    end

    local payload = _normaliseReviewsPayload(data.books_by_pk)
    if not payload then return false, "Hardcover reviews could not be parsed" end
    _cachePut("review", key, payload)
    return true, payload
end

function Hardcover.fetchReviewsOnline(book_id, opts, callback)
    opts = opts or {}
    return _runWhenOnline(function()
        local ok, payload = Hardcover.fetchReviews(book_id, opts)
        if callback then callback(ok, payload) end
    end, function(err)
        if callback then callback(false, err) end
    end)
end

function Hardcover.refreshRatings()
    local Api, api_err = _loadApi()
    if not Api then return false, api_err end

    local ok_settings, settings = pcall(_openExternalSettings)
    if not ok_settings or not settings then
        return false, "Could not open Hardcover settings"
    end

    local ids = _collectLinkedBookIds()
    if #ids == 0 then
        _cacheReplaceKind("rating", {})
        BookshelfSettings.save(RATINGS_TIME_KEY, os.time())
        return true, {
            linked = 0,
            rated = 0,
            updated = 0,
        }
    end

    local user_id, user_err = _getUserId(Api, settings)
    if not user_id then return false, user_err end

    local query = [[
        query ($ids: [Int!], $userId: Int!, $limit: Int!) {
          books(where: { id: { _in: $ids }}, limit: $limit) {
            id
            rating
            ratings_count
            reviews_count
            user_books(where: { user_id: { _eq: $userId }}) {
              id
              rating
            }
          }
        }
    ]]

    -- Merge into the existing cache rather than rebuilding from scratch. The
    -- old code pre-seeded EVERY linked id to rating=false and then overwrote
    -- only the ids the API returned -- so a partial/failed fetch (Hasura row
    -- cap, auth hiccup) silently clobbered real ratings to false. Now we keep
    -- prior values for any linked id the response omits, and only entries for
    -- books that are still linked. Querying in batches keeps each response
    -- under any server-side row cap.
    local now = os.time()
    local linked_set = {}
    for _, id in ipairs(ids) do linked_set[tostring(id)] = true end

    local cache = {}
    for key, entry in pairs(_cacheReadKind("rating")) do
        if linked_set[key] then cache[key] = entry end
    end

    local BATCH = 100
    local rated, updated = 0, 0
    local i = 1
    while i <= #ids do
        local batch = {}
        for j = i, math.min(i + BATCH - 1, #ids) do
            batch[#batch + 1] = ids[j]
        end
        local ok_query, data, err = pcall(Api.query, Api, query,
            { ids = batch, userId = user_id, limit = #batch })
        if not ok_query then
            return false, "Hardcover rating refresh failed: " .. _errString(data)
        end
        if not data or type(data.books) ~= "table" then
            return false, err and ("Hardcover rating refresh failed: " .. _errString(err))
                or "No response from Hardcover"
        end
        for _, row in ipairs(data.books) do
            if type(row) == "table" and row.id then
                local rating = tonumber(row.rating)
                local user_book = type(row.user_books) == "table" and row.user_books[1] or nil
                local user_rating = user_book and tonumber(user_book.rating) or nil
                if rating then rated = rated + 1 end
                updated = updated + 1
                cache[tostring(row.id)] = {
                    rating = rating or false,
                    ratings_count = tonumber(row.ratings_count) or 0,
                    reviews_count = tonumber(row.reviews_count) or 0,
                    user_book_id = user_book and user_book.id or nil,
                    user_rating = user_rating or false,
                    fetched_at = now,
                }
            end
        end
        i = i + BATCH
    end

    _cacheReplaceKind("rating", cache)
    BookshelfSettings.save(RATINGS_TIME_KEY, os.time())
    return true, {
        linked = #ids,
        rated = rated,
        updated = updated,
    }
end

function Hardcover.refreshRatingsOnline(callback)
    return _runWhenOnline(function()
        local ok, stats = Hardcover.refreshRatings()
        if callback then callback(ok, stats) end
    end, function(err)
        if callback then callback(false, err) end
    end)
end

-- Apply the global "Use Hardcover metadata" override to `book`: for a linked
-- book, replace its title / author(s) / series + # / genres with Hardcover's --
-- a clean switch, no merging. No-op when the toggle is off, the book isn't
-- linked, or no enrichment is cached. Self-contained (own link + cache reads,
-- all memoized -- no file I/O) so it's cheap enough to also run on the light
-- grouping records, keeping the genre/author/series chips in sync with the
-- per-book tag pills. Cover/description stay under their per-book toggles.
function Hardcover.applyMetadata(book)
    -- Reached directly on the light grouping-record path (not just via
    -- enrichBook), so it needs its own availability gate: with the plugin gone,
    -- the chips/stacks fall back to native title/author/series/genres too.
    if not Hardcover.isAvailable() then return end
    if not BookshelfSettings.isTrue("hardcover_use_metadata") then return end
    if type(book) ~= "table" or not book.filepath then return end
    local link = Hardcover.getLink(book.filepath)
    if not link then return end
    local enrichment = Hardcover.getCachedEnrichment(link.book_id, link.edition_id)
    if type(enrichment) ~= "table" then return end

    book.hardcover_metadata = true
    if type(enrichment.title) == "string" and enrichment.title ~= "" then
        book.title = enrichment.title
    end
    if type(enrichment.authors) == "string" and enrichment.authors ~= "" then
        local list = {}
        for a in enrichment.authors:gmatch("[^,]+") do
            local name = a:gsub("^%s+", ""):gsub("%s+$", "")
            if name ~= "" then list[#list + 1] = name end
        end
        if #list > 0 then book.authors = list end
    end
    if type(enrichment.series_name) == "string" and enrichment.series_name ~= "" then
        book.series_name = enrichment.series_name
        local pos = enrichment.series_position
        if pos ~= nil then
            -- Format like Calibre: integer position with no decimal.
            local n = tonumber(pos)
            local pos_str = (n and n == math.floor(n)) and tostring(math.floor(n))
                or tostring(pos)
            book.series_num = pos_str
            book.series = enrichment.series_name .. " #" .. pos_str
        else
            book.series_num = nil
            book.series = enrichment.series_name
        end
    end
    if type(enrichment.genres) == "table" and #enrichment.genres > 0 then
        local max = tonumber(BookshelfSettings.read("hardcover_max_genres")) or 5
        if max < 0 then max = 0 end
        local g = {}
        for i = 1, math.min(max, #enrichment.genres) do
            g[i] = enrichment.genres[i]
        end
        if #g > 0 then
            -- Apply unless the user explicitly chose a non-Hardcover source for
            -- this book (the Hardcover source itself is exposed to the chip bar
            -- by enrichBook, independent of this sync gate).
            local pref = BookshelfSettings.genreSource and
                BookshelfSettings.genreSource(book.filepath)
            if pref ~= "embedded" and pref ~= "calibre" then
                book.genres = g
            end
        end
    end
end

function Hardcover.enrichBook(book)
    if not book or not book.filepath then return book end
    -- When the Hardcover plugin isn't live (uninstalled/disabled), apply no
    -- enrichment: the record keeps its native title/author/series/genres,
    -- description, rating, review count and cover. Records are rebuilt fresh on
    -- each read, so this reverts cleanly and re-applies automatically if the
    -- plugin returns. Non-destructive -- any downloaded cover stays in the .sdr
    -- (and its cache), we just stop pointing bookshelf at it.
    if not Hardcover.isAvailable() then return book end
    local link = Hardcover.getLink(book.filepath)
    if not link then return book end

    book.hardcover_book_id = tonumber(link.book_id) or link.book_id
    book.hardcover_edition_id = tonumber(link.edition_id) or link.edition_id
    book.hardcover_title = link.title

    local rating_entry = _cacheGet("rating", tostring(link.book_id))
    book.hardcover_rating = Hardcover.getCachedRating(link.book_id)
    if type(rating_entry) == "table" then
        book.hardcover_ratings_count = tonumber(rating_entry.ratings_count) or 0
        book.hardcover_reviews_count = tonumber(rating_entry.reviews_count) or 0
    end

    -- Fallback: a book linked after the last full ratings sweep has no entry
    -- in the ratings cache, so the hero rating row would stay hidden. Its
    -- aggregate rating and counts may already sit in the reviews cache (the
    -- reviews payload carries the same book rating/ratings_count/reviews_count,
    -- populated when the user opened "Reviews..."). Surface that. Read-only:
    -- this never triggers a network fetch.
    if not book.hardcover_rating then
        local review_entry = _cacheGet("review", tostring(link.book_id))
        local review_rating = type(review_entry) == "table"
            and tonumber(review_entry.rating) or nil
        if review_rating then
            book.hardcover_rating = review_rating
            book.hardcover_ratings_count = tonumber(review_entry.ratings_count) or 0
            book.hardcover_reviews_count = tonumber(review_entry.reviews_count) or 0
        end
    end

    local enrichment = Hardcover.getCachedEnrichment(link.book_id, link.edition_id)
    if type(enrichment) ~= "table" then return book end

    -- A Hardcover cover/description is shown only when the per-book flag is
    -- explicitly on. The flag is set by autoDecideFlags (the sensible default,
    -- applied at link/refresh time) or by a manual toggle; there is no live
    -- "fill when missing" path, so what renders here can't disagree with the
    -- toggle the user sees.
    -- Stash BOTH descriptions so the description modal can offer a
    -- File <-> Hardcover toggle when both exist. book.description here is still
    -- the book's OWN (embedded / Calibre) blurb -- capture it before the
    -- override below. hardcover_description_text holds Hardcover's cached blurb
    -- regardless of which is shown by default.
    book.file_description = book.description
    if type(enrichment.description) == "string" and enrichment.description ~= "" then
        book.hardcover_description_text = enrichment.description
    end
    if link.use_description == true and book.hardcover_description_text then
        book.description = book.hardcover_description_text
        book.hardcover_description = true
    end
    -- Expose the Hardcover genre list to the book-detail source chip bar even
    -- when the global "Use Hardcover metadata" toggle is off, so a per-book
    -- source choice can pick Hardcover for one book. Capped like applyMetadata.
    if type(enrichment.genres) == "table" and #enrichment.genres > 0 then
        local max = tonumber(BookshelfSettings.read("hardcover_max_genres")) or 5
        if max < 0 then max = 0 end
        local g = {}
        for i = 1, math.min(max, #enrichment.genres) do g[i] = enrichment.genres[i] end
        if #g > 0 then
            book.genre_sources = book.genre_sources or {}
            book.genre_sources.hardcover = g
            if (BookshelfSettings.genreSource
                    and BookshelfSettings.genreSource(book.filepath)) == "hardcover" then
                book.genres = g
            end
        end
    end
    if link.use_cover == true then
        -- Cover lives in the book's .sdr as KOReader's custom cover; point
        -- bookshelf at it (KOReader's own UI finds it natively). If somehow
        -- absent, fall back to the cached download.
        local DocSettings = require("docsettings")
        local custom = DocSettings:findCustomCoverFile(book.filepath)
        if custom then
            book.cover_image_path = custom
            book.hardcover_cover = true
        elseif type(enrichment.cover_path) == "string" and enrichment.cover_path ~= "" then
            book.cover_image_path = enrichment.cover_path
            book.hardcover_cover = true
        end
    end

    -- "Use Hardcover metadata" override (title/author/series/genres) lives in
    -- Hardcover.applyMetadata so the exact same logic also runs on the lighter
    -- grouping records that back the genre/author/series chips -- not just full
    -- book builds. Otherwise the tag pills (full build) would switch but the
    -- chips/stacks (light build) wouldn't.
    Hardcover.applyMetadata(book)
    return book
end

return Hardcover
