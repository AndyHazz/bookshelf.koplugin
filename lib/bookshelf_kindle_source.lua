--[[
bookshelf_kindle_source.lua — surfaces the Kindle native library as a Bookshelf
shelf, so a chip can be pointed at the books that live in Amazon's own catalogue
(issue #355).

Two halves, deliberately kept apart:

  LISTING is ours. Amazon's content catalogue (/var/local/cc.db) is a plain
  SQLite database, world-readable, and holds everything a shelf needs: titles,
  credits, a real cover-thumbnail path, a reading percentage, publisher and
  language. We read it directly. That keeps the shelf independent of any
  plugin's internals, and it surfaces more than kaikozlov/kindle.koplugin's own
  list does (covers for unconverted books, and azw3/mobi8 books its mime filter
  omits).

  OPENING is the plugin's. A KFX book has to be converted to EPUB (and often
  decrypted) before KOReader can read it, which is exactly what
  kindle.koplugin does. We call one function of theirs and let it own the
  progress UI, the error text and the cache. No DRM code lives here.

The plugin does not publish its instances on the UI module (they are file-locals
in its main.lua), but KOReader's PluginLoader leaves every loaded plugin's
modules in package.loaded, and the plugin's lua/open_file_ext IS a singleton
whose .virtual_library / .cache_manager main.lua wires at init. That table is
therefore the single point of contact, shape-checked on every use: if a future
release renames it, isAvailable() goes false, the source kind stops being
offered, and nothing else notices.

Everything here is read-only with respect to the Kindle's files.
]]

local M = {}

-- Amazon's content catalogue. Absent on every non-Kindle device, which is what
-- makes this module inert everywhere else.
M.CC_DB_PATH = "/var/local/cc.db"

-- Smallest thumbnail worth treating as cover art.
--
-- For a book with no cover, Amazon writes a placeholder graphic ("No image
-- available", with its own logo) as the thumbnail rather than leaving the file
-- out, so there is no way to tell from the catalogue that a cover is missing.
-- Rendering it gives a card that says nothing, where Bookshelf's own placeholder
-- would at least show the title and author.
--
-- A size floor separates them cleanly. Measured over a 104-book library: the
-- placeholder is 1015 bytes (byte-identical wherever it appears), while real
-- covers run 11187 to 51896. This threshold sits in the 11x gap between, so it
-- needs no knowledge of the placeholder's content -- a locale or firmware
-- variant with a different image is still caught -- and no extra I/O, since the
-- thumbnail is already stat'ed for its existence.
M.MIN_COVER_BYTES = 4096

-- Debug-level tracing of the detection chain, so a reporter's crash.log shows
-- exactly where it broke (no cc.db / no plugin / no resolver). logger is lazy
-- and pcall-guarded so the headless tests (no KOReader) are unaffected.
local function diag(...)
    local ok, logger = pcall(require, "logger")
    if ok and logger and logger.dbg then logger.dbg("[bookshelf][kindle]", ...) end
end

-- ---------------------------------------------------------------------------
-- Injection seams. Each is replaced wholesale by tests/_test_kindle_source.lua;
-- in normal use they are the real thing.
-- ---------------------------------------------------------------------------

-- lfs.attributes for one path, or nil. One call yields mode + size +
-- modification, which is why this is a stat rather than an exists-check: the
-- listing pass needs all three.
function M._stat(path)
    if type(path) ~= "string" or path == "" then return nil end
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not (ok and lfs and lfs.attributes) then return nil end
    local ok_a, attr = pcall(lfs.attributes, path)
    return (ok_a and type(attr) == "table") and attr or nil
end

local function isFile(path)
    local st = M._stat(path)
    return st ~= nil and st.mode == "file"
end

-- One read-only pass over the catalogue, in lua-ljsqlite3's columnar shape
-- (results[column][row], nrow) — the same shape the Kindle plugin's own scanner
-- consumes. Read-only: we never write to Amazon's database.
--
-- Cloud-only rows are excluded in SQL (p_location is the local file); the mime
-- list deliberately includes x-mobi8-ebook, which the plugin's own query omits.
local QUERY = [[
SELECT
    p_uuid, p_location, p_titles_0_nominal, j_credits, p_mimeType, p_cdeKey,
    p_isDRMProtected, p_diskUsage, p_contentSize, p_thumbnail,
    p_percentFinished, p_languages_0, p_lastAccess
FROM Entries
WHERE p_type = 'Entry:Item'
    AND p_mimeType IN ('application/x-kfx-ebook',
                       'application/x-mobipocket-ebook',
                       'application/x-mobi8-ebook')
    AND p_isVisibleInHome = 1
    AND COALESCE(p_isArchived, 0) = 0
    AND p_location IS NOT NULL
    AND p_location <> ''
]]

function M._query()
    local SQ3 = require("lua-ljsqlite3/init")
    local conn, err = SQ3.open(M.CC_DB_PATH, "ro")
    if not conn then error("cannot open cc.db: " .. tostring(err)) end
    local results, nrow
    local ok, qerr = pcall(function() results, nrow = conn:exec(QUERY) end)
    conn:close()
    if not ok then error("cc.db query failed: " .. tostring(qerr)) end
    return results, nrow
end

-- A file's first three bytes, or nil. Used only to tell a DRM'd mobi-family book
-- from a clear one, which the catalogue cannot do.
function M._magic(path)
    if type(path) ~= "string" or path == "" then return nil end
    local handle = io.open(path, "rb")
    if not handle then return nil end
    local ok, bytes = pcall(function() return handle:read(3) end)
    handle:close()
    return ok and bytes or nil
end

-- Whether KOReader has a document provider for this path. Defaults to TRUE when
-- the registry cannot be reached (headless tests), so a missing registry never
-- blocks a whole library -- that just leaves today's behaviour.
function M._hasProvider(path)
    if type(path) ~= "string" or path == "" then return true end
    local ok, DocumentRegistry = pcall(require, "document/documentregistry")
    if not (ok and DocumentRegistry and DocumentRegistry.hasProvider) then return true end
    local ok_has, has = pcall(function() return DocumentRegistry:hasProvider(path) end)
    if not ok_has then return true end
    return has and true or false
end

-- KOReader's own progress for a path, or nil when it has never been opened
-- here. Returns { percent_finished, status, rating } with KOReader's raw
-- vocabulary.
--
-- The rating comes from the same summary table as the status. The Kindle
-- catalogue has no rating of its own, so without this a Kindle shelf offers a
-- "Rating" sort that silently orders nothing -- every book compares equal.
-- A book rated in KOReader has that rating in its sidecar like any other.
function M._sidecar(path)
    if type(path) ~= "string" or path == "" then return nil end
    local ok, DocSettings = pcall(require, "docsettings")
    if not (ok and DocSettings) then return nil end
    local ok_has, has = pcall(function() return DocSettings:hasSidecarFile(path) end)
    if not (ok_has and has) then return nil end
    local ok_open, out = pcall(function()
        local ds = DocSettings:open(path)
        local summary = ds:readSetting("summary")
        return {
            percent_finished = ds:readSetting("percent_finished"),
            status = type(summary) == "table" and summary.status or nil,
            rating = type(summary) == "table" and summary.rating or nil,
        }
    end)
    return ok_open and out or nil
end

-- The Kindle plugin's open_file_ext singleton, or nil. Never require()d: reading
-- package.loaded means we only ever see a module the plugin itself has already
-- loaded, so a missing plugin can't be half-instantiated by our probe.
function M._plugin()
    local loaded = package.loaded["lua/open_file_ext"]
    if type(loaded) ~= "table" then
        diag("plugin not loaded (no package.loaded['lua/open_file_ext'])")
        return nil
    end
    return loaded
end

function M.invalidate()
    M._cache = nil
end

-- True only when the catalogue is readable AND the plugin can open what we list.
-- Either half missing means no Kindle source kind is offered at all: a shelf of
-- books that cannot be opened would be worse than no shelf.
function M.isAvailable()
    if not isFile(M.CC_DB_PATH) then
        diag("cc.db not present at", M.CC_DB_PATH, "-> not a Kindle, or no catalogue")
        return false
    end
    local plugin = M._plugin()
    if type(plugin) ~= "table" then return false end
    if type(plugin.prepareKnownKindlePath) ~= "function" then
        diag("plugin loaded but exposes no prepareKnownKindlePath -> cannot open Kindle books")
        return false
    end
    diag("AVAILABLE -> Kindle library can be used as a chip source")
    return true
end

-- ---------------------------------------------------------------------------
-- Catalogue row -> Bookshelf Book record
-- ---------------------------------------------------------------------------

-- Author display names out of j_credits. The column is a JSON array of credit
-- objects; only the display names are wanted, and pulling them with a pattern
-- avoids dragging a JSON parser (and its failure modes) into a listing pass.
-- Names are kept exactly as Amazon stores them ("Surname, First") -- Bookshelf's
-- own author-name handling is what decides how they are shown and sorted.
local function parseAuthors(json_str)
    if type(json_str) ~= "string" or json_str == "" then return nil end
    local authors = {}
    for display in json_str:gmatch('"display"%s*:%s*"([^"]*)"') do
        if display ~= "" then authors[#authors + 1] = display end
    end
    return #authors > 0 and authors or nil
end

-- ---------------------------------------------------------------------------
-- Title tidying
--
-- For a book bought from Amazon the catalogue holds a real title. For a
-- side-loaded one it holds whatever the filename said, so a real library is full
-- of "Title - Author", "Author - Title", "NN. Title - Author", scene-site
-- suffixes and underscores standing in for characters a filesystem rejected.
--
-- Author removal is MATCH-BASED, never positional: a name comes off only when it
-- matches a name the catalogue itself credits. An unrecognised trailing phrase
-- might be a subtitle, a translator, or part of the title, so it stays. The
-- numeric prefix on a series ("01. ") is kept deliberately -- it carries the
-- reading order, and it makes a title sort put the series in that order.
-- ---------------------------------------------------------------------------

-- A name as a comparable set of words: lowercased, punctuation dropped, sorted.
-- Makes "Cline, Ernest" and "Ernest Cline" the same name without needing to know
-- which way round either one is.
local function nameKey(s)
    if type(s) ~= "string" then return nil end
    local words = {}
    for w in s:lower():gmatch("[%w']+") do words[#words + 1] = w end
    if #words == 0 then return nil end
    table.sort(words)
    return table.concat(words, " ")
end

-- True when `segment` names one of `authors`. A co-author list ("A & B") counts
-- when its FIRST name is credited: the catalogue often credits only the primary
-- author while the filename listed everyone.
local function isCreditedName(segment, authors)
    if type(segment) ~= "string" or type(authors) ~= "table" then return false end
    local candidates = { segment }
    local first = segment:match("^(.-)%s*&")
    if first and first ~= "" then candidates[#candidates + 1] = first end
    for _c, cand in ipairs(candidates) do
        local key = nameKey(cand)
        if key then
            for _a, author in ipairs(authors) do
                if key == nameKey(author) then return true end
            end
        end
    end
    return false
end

-- Sites that stamp their name into filenames. Matched case-insensitively inside
-- brackets or parentheses.
local JUNK_TAGS = { "z%-lib%.org", "z%-library", "libgen[%w%.%-]*", "annas[%w%s%-]*archive" }

local function cleanTitle(raw, authors)
    if type(raw) ~= "string" or raw == "" then return raw end
    local t = raw

    -- Filename artefacts. "_ " is a character the filesystem could not keep
    -- (almost always a colon); an all-underscore name used them as spaces.
    if t:find("_ ") then t = t:gsub("_ ", ": ") end
    if not t:find(" ") and t:find("_") then t = t:gsub("_", " ") end

    -- Scene-site junk, in either bracket style. Located against a lowercased
    -- copy and cut from the original by index: Lua patterns have no
    -- case-insensitive flag, and "(Z-Library)" is as common as "(z-lib.org)".
    for _i, tag in ipairs(JUNK_TAGS) do
        local pat = "%s*[%(%[]%s*" .. tag .. "%s*[%)%]]"
        local from, to = t:lower():find(pat)
        if from then t = t:sub(1, from - 1) .. t:sub(to + 1) end
    end

    -- A credited author at either end, or introduced by "by".
    local head, tail = t:match("^(.-)%s+%-%s+(.+)$")
    if head and tail then
        if isCreditedName(tail, authors) then
            t = head
        elseif isCreditedName(head, authors) then
            t = tail
        end
    end
    local before_by, by_name = t:match("^(.-)%s+by%s+(.+)$")
    if before_by and by_name and isCreditedName(by_name, authors) then
        t = before_by
    end

    -- A credited author in trailing parentheses -- what scene-site naming leaves
    -- behind once its own tag is gone. A parenthetical that is not a name we can
    -- confirm ("(Maze Runner Trilogy, Book 1)") belongs to the title.
    local before_paren, paren_name = t:match("^(.-)%s*%(([^()]*)%)%s*$")
    if before_paren and paren_name and before_paren ~= ""
            and isCreditedName(paren_name, authors) then
        t = before_paren
    end

    -- A tail cut off mid-parenthesis, or an ellipsis where a long name was
    -- truncated. Only an UNCLOSED trailing "(" qualifies, so a balanced
    -- parenthetical survives.
    local before_open = t:match("^(.-)%s*%([^()]*$")
    if before_open and before_open ~= "" then t = before_open end
    t = t:gsub("%s*%.%.%.$", "")

    t = t:gsub("^%s+", ""):gsub("[%s%-,]+$", "")
    -- Never tidy a title out of existence: a card with no words on it is worse
    -- than one that repeats the author.
    if t == "" then return raw end
    return t
end
M._cleanTitle = cleanTitle

-- Bookshelf's format label comes from the extension, so a Kindle book reports
-- honestly as kfx / azw3 / azw / mobi rather than as the EPUB it converts into.
-- UPPERCASE, matching the repository's own _formatLabel. Everything downstream
-- compares these literally: the Format filter tests a record's `format` against
-- the value stored by the picker, and a lowercase "kfx" against a "KFX" simply
-- never matched, so a Format filter on a Kindle shelf quietly kept nothing.
local function formatFromPath(path)
    local ext = type(path) == "string" and path:lower():match("%.([%w]+)$") or nil
    return ext and ext:upper() or ""
end

-- Bookshelf's status vocabulary is unread / reading / on_hold / finished;
-- KOReader stores 'complete' and 'abandoned'. Same normalisation as
-- Repo.readProgress, so every consumer sees one vocabulary.
local function normaliseStatus(status)
    if status == "complete"  then return "finished" end
    if status == "abandoned" then return "on_hold"  end
    return status
end

local function statusFromPercent(pct)
    if not pct or pct <= 0 then return "unread" end
    if pct >= 1            then return "finished" end
    return "reading"
end

-- cc.db declares p_isDRMProtected as INTEGER, but the Kindle plugin's own
-- scanner compares it against the string "1". Which one arrives depends on how
-- the sqlite binding types the column, so accept either rather than let the
-- classification silently invert.
local function isDrm(value)
    return value == 1 or value == "1" or tonumber(value) == 1
end

local MOBI_MIMES = {
    ["application/x-mobipocket-ebook"] = true,
    ["application/x-mobi8-ebook"] = true,
}

-- Whether this book can be opened at all:
--   KFX            -> the plugin converts (and decrypts) it, DRM or not
--   MOBI/AZW/AZW3  -> KOReader opens it directly, but only without DRM
--
-- p_isDRMProtected cannot answer that second case. On a real device it reads 0
-- for every mobi-family book, including protected ones (6 of 7 in the library
-- this was developed against). The reliable signal is the file itself: Amazon
-- prefixes a protected book's PalmDB database name with "CR!". Getting this
-- wrong is not cosmetic -- the book reaches ReaderUI, which cannot decode it and
-- drops the reader out to the file browser with "file not supported".
-- Returns nil when the book is openable, or a reason key when it is not:
--   "drm"          protected, and not in a way anything here can undo
--   "unsupported"  KOReader has no provider for the file type
local function blockReason(mime, drm, source_path)
    -- KFX is converted to an EPUB before KOReader ever sees it, so neither its
    -- DRM nor its (unsupported) extension matters.
    if mime == "application/x-kfx-ebook" then return nil end
    if isDrm(drm) then return "drm" end
    if MOBI_MIMES[mime] then
        local ok, magic = pcall(M._magic, source_path)
        if ok and magic == "CR!" then return "drm" end
    end
    -- Asked rather than assumed: KOReader registers providers for "azw" and
    -- "mobi" but not "azw3", so a perfectly unprotected .azw3 is still refused
    -- by extension. Guessing that from a mime type would go stale the moment
    -- KOReader adds one.
    if not M._hasProvider(source_path) then return "unsupported" end
    return nil
end

-- Where the plugin would put this book's converted EPUB. Asked of the plugin's
-- own cache_manager rather than derived here, so a change to its cache layout
-- or a user-set cache directory can't leave us pointing somewhere stale.
local function cachedEpubPath(plugin, id, source_path)
    local cm = plugin and plugin.cache_manager
    if type(cm) ~= "table" or type(cm.getCachePaths) ~= "function" then return nil end
    local ok, epub = pcall(function()
        return cm:getCachePaths({ id = id, source_path = source_path, open_mode = "convert" })
    end)
    return (ok and type(epub) == "string" and epub ~= "") and epub or nil
end

-- Map one catalogue row to a Book record, or nil to leave it off the shelf.
local function toRecord(row, plugin)
    local location = row.p_location
    if type(location) ~= "string" or location == "" then return nil end

    local id = "cc:" .. tostring(row.p_uuid)
    local source_stat = M._stat(location)
    local cached = cachedEpubPath(plugin, id, location)
    local prepared = cached ~= nil and isFile(cached)

    -- Nothing openable on disk: the catalogue has outlived the file. Listing it
    -- would only produce an entry that fails when tapped.
    if not prepared and not (source_stat and source_stat.mode == "file") then
        diag("skipping", tostring(row.p_titles_0_nominal), "-- no file at", location)
        return nil
    end

    -- Identity is what KOReader actually opens. Once the conversion exists that
    -- is the cached EPUB, which is what makes the sidecar, BIM, Recent and the
    -- hero line up for free.
    local filepath = prepared and cached or location

    local authors = parseAuthors(row.j_credits)
    local raw_title = row.p_titles_0_nominal
    if type(raw_title) ~= "string" or raw_title == "" then
        raw_title = location:match("([^/]+)$") or "Untitled"
    end
    local title = cleanTitle(raw_title, authors)
    -- p_diskUsage is what the book occupies; p_contentSize is the download
    -- size. Either is a reasonable "how big is this book", and the catalogue
    -- does not always carry both.
    local size_bytes = tonumber(row.p_diskUsage) or tonumber(row.p_contentSize) or 0

    -- The Kindle's own percentage is 0-100 and is only a fallback: once the book
    -- has been read in KOReader, KOReader's position is the truth (the two
    -- measure different content lengths, so they are not comparable).
    local pct = tonumber(row.p_percentFinished)
    pct = pct and (pct / 100) or nil
    local status
    local side = M._sidecar(filepath)
    if side then
        pct = tonumber(side.percent_finished) or pct
        status = normaliseStatus(side.status)
    end
    status = status or statusFromPercent(pct)

    -- A path string, never a decoded cover_bb: this record is painted by the
    -- grid cell AND, unchanged, by the hero, and a cover_bb is one-shot by BIM
    -- convention -- two painters freeing one bb is a use-after-free. See the
    -- long note on the OPDS branch of Repo.getBySource.
    --
    -- Too small to be cover art means it is Amazon's "no cover" placeholder; drop
    -- it so the shelf falls back to Bookshelf's own, which shows title and
    -- author. See MIN_COVER_BYTES.
    local thumb = row.p_thumbnail
    local cover_image_path = nil
    if type(thumb) == "string" and thumb ~= "" then
        local thumb_stat = M._stat(thumb)
        if thumb_stat and thumb_stat.mode == "file"
                and (tonumber(thumb_stat.size) or 0) >= M.MIN_COVER_BYTES then
            cover_image_path = thumb
        end
    end

    local mtime = source_stat and source_stat.modification or nil
    local block_reason = blockReason(row.p_mimeType, row.p_isDRMProtected, location)
    -- A KFX that has not been converted yet will run the converter on its first
    -- open. On a PW5 that took 4m40s for a 1.5MB book, with the screen
    -- unresponsive the whole time (the plugin inhibits input while it works), so
    -- the shelf warns first rather than appearing to have frozen. Directly
    -- openable and blocked books have nothing to prepare.
    local needs_prepare = (not prepared)
        and block_reason == nil
        and row.p_mimeType == "application/x-kfx-ebook"

    return {
        filepath       = filepath,
        filename       = filepath:match("([^/]+)$"),
        title          = title,
        display_title  = title,
        author         = authors and authors[1] or nil,
        authors        = authors,
        format         = formatFromPath(location),
        lang           = (type(row.p_languages_0) == "string" and row.p_languages_0 ~= "")
                            and row.p_languages_0 or nil,
        cover_image_path = cover_image_path,
        -- Progress and recency are carried under BOTH names on purpose. The
        -- rendering layer reads book_pct / last_read_time; SortEngine reads
        -- percent_finished and last_opened (see its effective_percent and the
        -- last_opened comparator) and silently treats every book as equal if
        -- they are absent, which is how a synthetic shelf ends up unsortable.
        book_pct         = pct,
        percent_finished = pct,
        status         = status,
        _status        = status,   -- what the filter reads
        read_status    = status,   -- what the sort engine reads
        -- The catalogue holds no rating; this is KOReader's own, from the
        -- sidecar of the converted file, and nil until the book is rated here.
        -- tonumber here rather than in _sidecar, matching percent_finished
        -- above: _sidecar hands back what the sidecar held, and the record is
        -- where a value becomes the type the sort comparator and star widget
        -- expect. Older sidecars can hold the rating as a string.
        rating         = side and tonumber(side.rating) or nil,
        -- date_added and size are carried at the TOP LEVEL as well as under
        -- attr, and not only for the sort engine's benefit. Its date_added and
        -- size comparators do fall back to attr.modification / attr.size, so
        -- both sorts worked by accident -- but the %added and %size tokens read
        -- b.date_added and b.size with NO fallback, so both rendered empty on a
        -- Kindle shelf while every other shelf filled them in. Same shape as the
        -- rating and the Kobo sorts: nothing errors, the value is just missing.
        added_time     = mtime,    -- when the file landed on the device
        date_added     = mtime,    -- what %added and the Added sort read
        last_read_time = tonumber(row.p_lastAccess) or nil,
        last_opened    = tonumber(row.p_lastAccess) or nil,
        size           = size_bytes,
        attr           = {
            mode = "file",
            size = size_bytes,
            modification = mtime,
        },
        -- Kindle-specific, read by the open path and the file-op guards.
        kindle_book_id     = id,
        kindle_source_path = location,
        kindle_raw_title   = raw_title,   -- the catalogue's own wording, for diagnosis
        kindle_needs_prepare = needs_prepare or nil,
        kindle_blocked     = block_reason ~= nil or nil,
        kindle_block_reason = block_reason,
        is_kindle          = true,
    }
end
M._toRecord = toRecord

-- The Kindle library as Bookshelf Book records. Cached briefly: getBySource is
-- called again for every page of a shelf, and each pass is an SQLite read plus a
-- stat per book. {} on any failure -- a shelf that cannot be listed is an empty
-- shelf, never an error in the middle of a render.
-- The catalogue is cached for the whole session and validated against cc.db
-- itself rather than a clock. Nothing can change that file while KOReader is
-- running with the framework stopped -- you would have to leave KOReader, read
-- in the Kindle's own software, and come back -- and when something DOES change
-- it (a delivery on a keep_framework device) the stamp moves and the next call
-- re-reads. A timer could only ever guess at that: too short and every shelf
-- rebuild re-queries SQLite for an identical answer, too long and a real change
-- is missed anyway.
--
-- Size as well as mtime: mtime has one-second resolution, so a write landing in
-- the same second as the read would otherwise go unnoticed.
--
-- Two things this stamp cannot see, because they are ours rather than Amazon's,
-- are invalidated explicitly instead: a status written to a KOReader sidecar
-- (Repo.invalidateProgressCache) and a conversion changing which file a book IS
-- (realPathForOpen, below).
local function catalogueStamp()
    local st = M._stat(M.CC_DB_PATH)
    if not st then return nil end
    return tostring(st.modification or 0) .. ":" .. tostring(st.size or 0)
end

function M.listBooks()
    local cache = M._cache
    local stamp = catalogueStamp()
    -- No stamp means the catalogue could not be stat'd; re-read rather than
    -- serve a cache we cannot vouch for.
    if cache and stamp and cache.stamp == stamp then return cache.books end

    local plugin = M._plugin()
    local ok, results, nrow = pcall(M._query)
    if not ok or type(results) ~= "table" then
        diag("catalogue read failed:", tostring(results))
        return {}
    end

    local books = {}
    for i = 1, (tonumber(nrow) or 0) do
        -- lua-ljsqlite3 returns columns, not rows: results[column][row].
        local row = {}
        for col, values in pairs(results) do row[col] = values[i] end
        local ok_rec, rec = pcall(toRecord, row, plugin)
        if ok_rec and rec then books[#books + 1] = rec end
    end

    -- Index by BOTH paths a Kindle book answers to: recordFor is asked with
    -- whichever one the caller happens to hold.
    local by_path = {}
    for _i, b in ipairs(books) do
        by_path[b.filepath] = b
        if b.kindle_source_path then by_path[b.kindle_source_path] = b end
    end

    M._cache = { stamp = stamp, books = books, by_path = by_path }
    return books
end

-- The listed record for one path, or nil. Deliberately answers only from what
-- has already been listed: this is called from Repo.buildBook, which runs on a
-- cold start straight into the reader, and turning a single record lookup into a
-- catalogue scan there would be a boot-time cost paid for nothing.
function M.recordFor(filepath)
    if type(filepath) ~= "string" or filepath == "" then return nil end
    local cache = M._cache
    return cache and cache.by_path and cache.by_path[filepath] or nil
end

-- ---------------------------------------------------------------------------
-- Opening
-- ---------------------------------------------------------------------------

-- Resolve a Kindle record to a real, openable file, converting and decrypting
-- on the way if that is what it takes. Returns:
--
--   path                 ready to hand to ReaderUI
--   nil, reason_key      we refused: a short key ("drm", "unavailable") whose
--                        wording lives in Bookshelf's own strings
--   nil, plugin_text     the plugin refused: its own reader-facing sentence,
--                        passed through unchanged (it knows far more about why)
--
-- The plugin owns the whole slow path here -- KFX->EPUB conversion, DRM key
-- extraction, cache freshness, and its own "Preparing…" progress UI -- so this
-- call can block for a while on a first open. Bookshelf calls ReaderUI:showReader
-- directly and so never passes through the plugin's own openFile patch; this is
-- the explicit substitute for it.
function M.realPathForOpen(book)
    if type(book) ~= "table" or not book.is_kindle then return nil end
    if book.kindle_blocked then
        -- Protected, or a file type KOReader has no provider for. Either way
        -- nothing here can open it, so don't start work that is certain to fail
        -- (and never hand it to ReaderUI, which drops the user out to the file
        -- browser).
        return nil, book.kindle_block_reason or "drm"
    end
    local plugin = M._plugin()
    if type(plugin) ~= "table" or type(plugin.prepareKnownKindlePath) ~= "function" then
        diag("realPathForOpen: plugin/resolver gone since the shelf was listed")
        return nil, "unavailable"
    end
    local target = book.filepath or book.kindle_source_path
    local ok, resolved, err = pcall(function()
        return plugin:prepareKnownKindlePath(target)
    end)
    if not ok then
        diag("realPathForOpen: resolver raised:", tostring(resolved))
        return nil, "unavailable"
    end
    if type(resolved) == "string" and resolved ~= "" then
        -- A conversion just changed this book's identity: the record was built
        -- around the .kfx, and from now on the book IS the converted EPUB, which
        -- is what the sidecar, BIM, Recent and the hero all key on. cc.db does
        -- not move for this, so the stamp cannot notice it.
        if resolved ~= target then M.invalidate() end
        return resolved
    end
    return nil, err
end

-- True when a path belongs to the Kindle library, either as the catalogue's
-- source file or as the plugin's converted copy. Answered from the listing we
-- already hold, so the guards can ask cheaply and without touching the plugin.
-- Used to keep destructive file-ops off books that are the user's Kindle
-- library rather than files they put on the device themselves.
function M.isKindlePath(filepath)
    return M.recordFor(filepath) ~= nil
end

return M
