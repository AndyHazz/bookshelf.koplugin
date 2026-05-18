-- bookshelf_hardcover.lua
-- Optional integration with hardcoverapp.koplugin.
--
-- Hardcover's KOReader plugin stores the local-file -> Hardcover book link in
-- <settings>/hardcoversync_settings.lua, but it does not persist Hardcover's
-- public book rating there. Bookshelf therefore keeps its own small rating
-- cache, refreshed on demand from Hardcover's API module, and only reads that
-- cache during normal shelf rendering.

local BookshelfSettings = require("lib/bookshelf_settings_store")

local Hardcover = {}

local HC_SETTINGS_FILE = "hardcoversync_settings.lua"
local CACHE_KEY        = "hardcover_ratings"
local CACHE_TIME_KEY   = "hardcover_ratings_fetched_at"

local _hc_settings
local _hc_books
local _ratings_cache

local function _settingsPath()
    local DataStorage = require("datastorage")
    return DataStorage:getSettingsDir() .. "/" .. HC_SETTINGS_FILE
end

local function _openHardcoverSettings()
    if _hc_settings then return _hc_settings end
    local LuaSettings = require("luasettings")
    _hc_settings = LuaSettings:open(_settingsPath())
    return _hc_settings
end

local function _readHardcoverBooks(force)
    if _hc_books and not force then return _hc_books end
    if force then _hc_settings = nil end
    local ok, settings = pcall(_openHardcoverSettings)
    if not ok or not settings then
        _hc_books = {}
        return _hc_books
    end
    local ok_books, books = pcall(settings.readSetting, settings, "books")
    _hc_books = (ok_books and type(books) == "table") and books or {}
    return _hc_books
end

local function _readRatingsCache()
    if _ratings_cache then return _ratings_cache end
    local raw = BookshelfSettings.read(CACHE_KEY, {})
    _ratings_cache = type(raw) == "table" and raw or {}
    return _ratings_cache
end

local function _saveRatingsCache(cache)
    _ratings_cache = cache or {}
    BookshelfSettings.save(CACHE_KEY, _ratings_cache)
    BookshelfSettings.save(CACHE_TIME_KEY, os.time())
end

local function _ratingFromCacheEntry(entry)
    if type(entry) ~= "table" then return nil end
    local rating = entry.rating
    if rating == false then return nil end
    return tonumber(rating)
end

function Hardcover.invalidate()
    _hc_books = nil
    _ratings_cache = nil
    _hc_settings = nil
end

function Hardcover.getCachedAt()
    return tonumber(BookshelfSettings.read(CACHE_TIME_KEY))
end

function Hardcover.getCacheStats()
    local cache = _readRatingsCache()
    local linked, rated = 0, 0
    local books = _readHardcoverBooks(false)
    local seen = {}
    for _filepath, cfg in pairs(books) do
        if type(cfg) == "table" and cfg.book_id then
            local key = tostring(cfg.book_id)
            if not seen[key] then
                seen[key] = true
                linked = linked + 1
                if _ratingFromCacheEntry(cache[key]) then
                    rated = rated + 1
                end
            end
        end
    end
    return {
        linked = linked,
        rated = rated,
        fetched_at = Hardcover.getCachedAt(),
    }
end

function Hardcover.getLink(filepath)
    if not filepath then return nil end
    local books = _readHardcoverBooks(false)
    local link = books[filepath]
    return type(link) == "table" and link or nil
end

function Hardcover.getCachedRating(book_id)
    if not book_id then return nil end
    return _ratingFromCacheEntry(_readRatingsCache()[tostring(book_id)])
end

function Hardcover.enrichBook(book)
    if not book or not book.filepath then return book end
    local link = Hardcover.getLink(book.filepath)
    if not link then return book end

    book.hardcover_book_id = tonumber(link.book_id) or link.book_id
    book.hardcover_edition_id = tonumber(link.edition_id) or link.edition_id
    book.hardcover_title = link.title
    book.hardcover_rating = Hardcover.getCachedRating(link.book_id)
    return book
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
    local ids = _readEmbeddedIdentifiersFromEpub(book.filepath)
    if ids and ids ~= "" then
        book.identifiers = ids
        return ids
    end
    return nil
end

function Hardcover.hasHardcoverIdentifiers(book)
    local ids = Hardcover.getEmbeddedIdentifiers(book)
    return type(ids) == "string" and ids:lower():find("hardcover", 1, true) ~= nil
end

local function _linkPayload(hc_book, Book)
    local delete = {}
    local function field(name, value)
        if value == nil then delete[#delete + 1] = name end
        return value
    end
    local edition_format = hc_book.edition_format or hc_book.filetype
    if Book and type(Book.editionFormatName) == "function" then
        edition_format = Book:editionFormatName(hc_book.edition_format, hc_book.reading_format_id)
                      or edition_format
    end
    return {
        book_id        = field("book_id", hc_book.book_id),
        edition_id     = field("edition_id", hc_book.edition_id),
        edition_format = field("edition_format", edition_format),
        pages          = field("pages", hc_book.pages),
        title          = field("title", hc_book.title),
        _delete        = delete,
    }
end

local function _applyBookSetting(settings, filepath, config)
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
    if HardcoverSettings.settings and HardcoverSettings.settings ~= _hc_settings then
        pcall(_applyBookSetting, HardcoverSettings.settings, filepath, config)
    end
    if type(HardcoverSettings.notify) == "function" then
        pcall(HardcoverSettings.notify, HardcoverSettings, "books", {
            filename = filepath,
            config = config,
        }, original or {})
    end
end

local function _updateBookSetting(filepath, config)
    local ok_settings, settings = pcall(_openHardcoverSettings)
    if not ok_settings or not settings then
        return false, "Could not open Hardcover settings"
    end
    local original = _applyBookSetting(settings, filepath, config)
    _notifyLoadedHardcoverSettings(filepath, config, original)
    Hardcover.invalidate()
    return true
end

function Hardcover.linkBook(filepath, hc_book)
    if not (filepath and hc_book and hc_book.book_id) then
        return false, "Missing book link data"
    end
    local modules = _loadPickerModules()
    local Book = modules and modules.Book or nil
    return _updateBookSetting(filepath, _linkPayload(hc_book, Book))
end

function Hardcover.clearLink(filepath)
    if not filepath then return false, "Missing file path" end
    return _updateBookSetting(filepath, {
        _delete = { "book_id", "edition_id", "edition_format", "pages", "title" },
    })
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

local function _newDialogManager(modules, settings)
    modules.User.settings = settings
    return modules.DialogManager:new{
        settings = settings,
    }
end

local function _parseHardcoverIdentifiers(modules, identifiers)
    if type(identifiers) ~= "string" or identifiers == "" then return nil end
    local parsed = {}
    if modules.Book and type(modules.Book.parseIdentifiers) == "function" then
        local ok, result = pcall(modules.Book.parseIdentifiers, modules.Book, identifiers)
        if ok and type(result) == "table" then parsed = result end
    end
    local lower = identifiers:lower()
    parsed.book_id = parsed.book_id
        or lower:match("hardcover%-book%-id%s*:%s*(%d+)")
        or lower:match("hardcover%-id%s*:%s*(%d+)")
        or lower:match("hardcoverid%s*:%s*(%d+)")
    return next(parsed) and parsed or nil
end

local function _findBookByIdentifiers(modules, identifiers, user_id)
    local parsed = _parseHardcoverIdentifiers(modules, identifiers)
    if not parsed then return nil end

    local ok_lookup, book = pcall(function()
        return modules.Api:findBookByIdentifiers(parsed, user_id)
    end)
    if ok_lookup and book then return book end

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

function Hardcover.linkFromEmbeddedIdentifiers(book, opts)
    opts = opts or {}
    if not (book and book.filepath) then return false, "Missing local book" end
    local identifiers = Hardcover.getEmbeddedIdentifiers(book)
    if not identifiers then return false, "No embedded Hardcover identifier found" end

    local modules, mod_err = _loadPickerModules()
    if not modules then return false, mod_err end
    local settings_ok, settings = pcall(_openHardcoverSettings)
    if not settings_ok or not settings then return false, "Could not open Hardcover settings" end
    local user_id = modules.User:getId()
    local hc_book = _findBookByIdentifiers(modules, identifiers, user_id)
    if not hc_book then return false, "No Hardcover match found for embedded identifier" end

    local ok, link_err = Hardcover.linkBook(book.filepath, hc_book)
    if not ok then return false, link_err end
    if opts.on_linked then opts.on_linked(hc_book) end
    return true, hc_book
end

function Hardcover.showBookPicker(book, opts)
    opts = opts or {}
    if not (book and book.filepath) then return false, "Missing local book" end
    local modules, mod_err = _loadPickerModules()
    if not modules then return false, mod_err end
    local ok_settings, settings = pcall(_openHardcoverSettings)
    if not ok_settings or not settings then return false, "Could not open Hardcover settings" end
    local user_id = modules.User:getId()
    local title = book.title or _filenameTitle(book.filepath)
    local author = _authorString(book)
    local books, err
    local embedded = _findBookByIdentifiers(modules, Hardcover.getEmbeddedIdentifiers(book), user_id)
    if embedded then
        books = { embedded }
    else
        books, err = modules.Api:findBooks(title, author, user_id)
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
            if opts.on_book_selected then opts.on_book_selected(selected) end
        end,
        function(search)
            manager:updateSearchResults(search)
            return true
        end,
        title
    )
    return true
end

function Hardcover.showEditionPicker(book, book_id, opts)
    opts = opts or {}
    if not (book and book.filepath and book_id) then
        return false, "Missing Hardcover book id"
    end
    local modules, mod_err = _loadPickerModules()
    if not modules then return false, mod_err end
    local ok_settings, settings = pcall(_openHardcoverSettings)
    if not ok_settings or not settings then return false, "Could not open Hardcover settings" end
    local user_id = modules.User:getId()
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
            if opts.on_edition_selected then opts.on_edition_selected(selected) end
        end
    )
    return true
end

local function _collectLinkedBookIds()
    local ids, seen = {}, {}
    for _filepath, cfg in pairs(_readHardcoverBooks(true)) do
        if type(cfg) == "table" and cfg.book_id then
            local id = tonumber(cfg.book_id)
            if id and not seen[id] then
                seen[id] = true
                ids[#ids + 1] = id
            end
        end
    end
    table.sort(ids)
    return ids
end

local function _loadApi()
    local ok, Api = pcall(require, "hardcover/lib/hardcover_api")
    if not ok or not Api or type(Api.query) ~= "function" then
        return nil, "Hardcover plugin/API module could not be loaded"
    end
    return Api
end

local function _getUserId(Api, settings)
    local user_id = settings:readSetting("user_id")
    if user_id then return tonumber(user_id) or user_id end
    if not Api.me then return nil, "Hardcover user id is missing" end
    local me = Api:me()
    user_id = me and me.id
    if not user_id then return nil, "Could not fetch Hardcover user id" end
    settings:saveSetting("user_id", user_id)
    settings:flush()
    return tonumber(user_id) or user_id
end

function Hardcover.refreshRatings()
    local Api, api_err = _loadApi()
    if not Api then return false, api_err end

    local ok_settings, settings = pcall(_openHardcoverSettings)
    if not ok_settings or not settings then
        return false, "Could not open Hardcover settings"
    end

    local ids = _collectLinkedBookIds()
    if #ids == 0 then
        _saveRatingsCache({})
        return true, {
            linked = 0,
            rated = 0,
            updated = 0,
        }
    end

    local user_id, user_err = _getUserId(Api, settings)
    if not user_id then return false, user_err end

    local query = [[
        query ($ids: [Int!], $userId: Int!) {
          books(where: { id: { _in: $ids }}) {
            id
            rating
            ratings_count
            user_books(where: { user_id: { _eq: $userId }}) {
              id
              rating
            }
          }
        }
    ]]

    local data, err = Api:query(query, { ids = ids, userId = user_id })
    if not data or type(data.books) ~= "table" then
        return false, err and "Hardcover rating refresh failed" or "No response from Hardcover"
    end

    local now = os.time()
    local cache = {}
    for _, id in ipairs(ids) do
        cache[tostring(id)] = { rating = false, fetched_at = now }
    end

    local rated = 0
    for _, row in ipairs(data.books) do
        if type(row) == "table" and row.id then
            local rating = tonumber(row.rating)
            local user_book = type(row.user_books) == "table" and row.user_books[1] or nil
            local user_rating = user_book and tonumber(user_book.rating) or nil
            if rating then rated = rated + 1 end
            cache[tostring(row.id)] = {
                rating = rating or false,
                ratings_count = tonumber(row.ratings_count) or 0,
                user_book_id = user_book and user_book.id or nil,
                user_rating = user_rating or false,
                fetched_at = now,
            }
        end
    end

    _saveRatingsCache(cache)
    return true, {
        linked = #ids,
        rated = rated,
        updated = #data.books,
    }
end

return Hardcover
