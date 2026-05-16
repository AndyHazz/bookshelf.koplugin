-- bookshelf_book_repository.lua
-- Unified Book record source over KOReader's ReadHistory, ReadCollection,
-- BookInfoManager, DocSettings, and (optionally) statistics.koplugin.
--
-- Design contract: this module produces Book records only — no widget code,
-- no UI imports. All external KOReader modules are reached through getter
-- functions so that pure-Lua tests can stub them via package.loaded before
-- require() is called.

local Repo = {}

local logger = require("logger")
local BookshelfSettings = require("lib/bookshelf_settings_store")
-- Wall-clock timer. Falls back to os.clock() (CPU-only) if LuaSocket absent.
local _gettime
do
    local ok, s = pcall(require, "socket")
    _gettime = (ok and s and type(s.gettime) == "function")
        and function() return s.gettime() end
        or  os.clock
end

-- ─── Module-local helpers ────────────────────────────────────────────────────

-- Split a comma-separated author string into a trimmed array, or return nil.
local function splitAuthors(s)
    if not s or s == "" then return nil end
    local t = {}
    -- BIM stores multi-author values with "\n" separators (KOReader's
    -- metadata convention); Calibre / older sources may use commas. Split
    -- on either so the %authors token expander's `table.concat(t, ", ")`
    -- produces clean comma-joined output instead of preserving newlines
    -- and rendering each author on its own line.
    for part in s:gmatch("[^,\n]+") do
        local cleaned = part:match("^%s*(.-)%s*$")  -- trim whitespace
        if cleaned ~= "" then t[#t + 1] = cleaned end
    end
    return #t > 0 and t or nil
end

-- Split a genre/tag string (or array of strings) on common EPUB delimiters
-- (comma, semicolon, pipe, slash) and return a trimmed array, or nil.
local function splitGenreTags(src)
    local t = {}
    local inputs = type(src) == "table" and src or { src }
    for _, s in ipairs(inputs) do
        for part in s:gmatch("[^,;|/\n]+") do
            local trimmed = part:match("^%s*(.-)%s*$")
            if trimmed and trimmed ~= "" then t[#t + 1] = trimmed end
        end
    end
    return #t > 0 and t or nil
end

-- Supported e-book extensions (used in both getCurrent and walkBooks).
local SUPPORTED_EXT = {
    epub=true, pdf=true, mobi=true, azw=true, azw3=true, fb2=true,
    cbz=true, cbr=true, txt=true, md=true, html=true, htm=true, djvu=true,
    doc=true, docx=true, rtf=true, odt=true,
}

-- ─── Lazy module accessors ───────────────────────────────────────────────────
-- Never require() at module top-level; tests stub via package.loaded.

local function getReadHistory()  return require("readhistory") end
local function getCollections()  return require("readcollection") end
-- BookInfoManager comes from CoverBrowser. When CoverBrowser is disabled
-- (Settings > More plugins), the module isn't on the lua path and the
-- raw require() throws. pcall it instead, cache the result, return nil
-- gracefully. Callers check for nil and bail. Without BIM Bookshelf
-- can't function meaningfully (no covers, no metadata extraction), so
-- main.lua also shows a one-time notification explaining the dependency.
local _bim_cache
local _bim_loaded_ref
local function getBookInfoMgr()
    local loaded = package.loaded["bookinfomanager"]
    if loaded and loaded ~= _bim_loaded_ref then
        _bim_cache = loaded
        _bim_loaded_ref = loaded
        return loaded
    end
    if _bim_cache ~= nil then
        return _bim_cache or nil
    end
    local ok, mod = pcall(require, "bookinfomanager")
    _bim_cache = (ok and mod) or false
    _bim_loaded_ref = (ok and mod) or nil
    return _bim_cache or nil
end

-- Public: true if BookInfoManager is available (CoverBrowser enabled).
-- main.lua queries this at init to decide whether to take over the home
-- screen or bail with a "Bookshelf requires CoverBrowser" notification.
function Repo.hasBookInfoManager()
    return getBookInfoMgr() ~= nil
end
local function getDocSettings()  return require("docsettings") end

-- Resolve the user's library root from G_reader_settings. Returns the
-- configured home_dir, or nil when it is unset / empty. "/" is allowed:
-- some users (rooted devices, manual layouts) legitimately point home_dir
-- at filesystem root. The pseudo-filesystem denylist below keeps walks
-- under "/" off /proc and /sys so the legitimate case doesn't OOM-kill
-- KOReader. Walk-based callers must still treat nil as "no library
-- configured" and short-circuit to an empty result.
local function _resolveLibraryRoot()
    local home = G_reader_settings:readSetting("home_dir")
    if not home or home == "" then return nil end
    return home
end

-- Path-join that doesn't emit "//child" when parent is filesystem root.
-- Walks rooted at "/" (legitimate config on rooted devices) would otherwise
-- produce "//proc", "//mnt", etc. — Linux normalises those at the syscall
-- layer but our walk-cache keys, BIM lookups, and equality comparisons
-- don't, so internal state ends up double-slashed and inconsistent.
local function _joinPath(parent, child)
    if parent == "/" then return "/" .. child end
    return parent .. "/" .. child
end

local function _normalizePath(path)
    if type(path) ~= "string" or path == "" then return nil end
    path = path:gsub("/+$", "")
    if path == "" then return "/" end
    return path
end

local function _scopeRoots(scope)
    if type(scope) ~= "table" or type(scope.roots) ~= "table" then return nil end
    local roots, seen = {}, {}
    for _, root in ipairs(scope.roots) do
        root = _normalizePath(root)
        if root and not seen[root] then
            roots[#roots + 1] = root
            seen[root] = true
        end
    end
    return #roots > 0 and roots or nil
end

local function _cacheKeyForScope(home, depth, scope)
    local roots = _scopeRoots(scope)
    if not roots then return (home or "/") .. ":" .. tostring(depth or 0) end
    return "scope:" .. table.concat(roots, "|") .. ":" .. tostring(depth or 0)
end

-- Basename denylist: directory names that walks must never descend into.
-- These are Linux pseudo-filesystems (/proc, /sys, /dev, /run) plus
-- transient OS scratch (/tmp) and fsck artefacts (lost+found). All have
-- enormous breadth at depth 1-2 and contain zero books, so even a depth-
-- bounded walk turns into thousands of stat() calls and stalls the UI.
-- Match is on basename so it bites whether home_dir is "/" or a parent
-- happens to contain a same-named folder. False-positive risk: a user
-- library folder literally named "proc" / "tmp" etc. would be hidden.
-- That's not a book-collection convention so the trade is acceptable.
local SYSTEM_DIR_NAMES = {
    proc        = true,
    sys         = true,
    dev         = true,
    run         = true,
    tmp         = true,
    ["lost+found"] = true,
}

-- pcall wrapper around Repo.buildBookMeta. A single malformed file's
-- metadata extraction (parser blow-up, corrupt BIM row, unexpected
-- charset) must not kill the entire shelf rebuild — Recent dodges this
-- because its book set is restricted to ones the user has successfully
-- opened, but Home iterates every file under home_dir and so is exposed.
-- Returns the book on success; nil + warn on failure.
local function _safeBuildBookMeta(fp)
    local ok, b = pcall(Repo.buildBookMeta, fp)
    if ok then return b end
    logger.warn("[bookshelf] buildBookMeta failed for", fp, ":", b)
    return nil
end

-- ─── Calibre metadata.calibre loader ─────────────────────────────────────────
-- Calibre desktop, when syncing books to a device, drops a JSON file
-- ("metadata.calibre" or ".metadata.calibre") at the library root with
-- one entry per book — title, authors, tags, series, series_index, etc.
-- For libraries managed via Calibre this gives us full metadata coverage
-- for every book without waiting on BIM extraction. We parse it lazily
-- and cache the resulting filepath→metadata map, refreshing when the
-- file's mtime changes (Calibre just re-synced) or after a 60s TTL.
local CALIBRE_TTL = 60
local _calibre_state = {
    last_check = 0,
    file_path  = nil,
    file_mtime = 0,
    map        = nil,
}

local function _calibreMetadataFor(filepath)
    if not filepath then return nil end
    -- Beta-gated: only fires when the user opts in via Settings →
    -- Beta features. Default OFF so non-Calibre users (the majority)
    -- pay no cost — neither the file probe nor the JSON parse runs.
    -- Truthy check via readSetting (rather than isTrue) so the test
    -- stub for G_reader_settings doesn't need to grow another method.
    if not BookshelfSettings.read("calibre_metadata") then
        return nil
    end
    local now = os.time()
    if (now - _calibre_state.last_check) <= CALIBRE_TTL
            and _calibre_state.map ~= nil then
        return _calibre_state.map[filepath]
    end
    _calibre_state.last_check = now
    local home = G_reader_settings:readSetting("home_dir") or "/"
    local lfs  = require("libs/libkoreader-lfs")
    local meta_path
    for _, name in ipairs({ "metadata.calibre", ".metadata.calibre" }) do
        local p = _joinPath(home, name)
        if lfs.attributes(p, "mode") == "file" then
            meta_path = p
            break
        end
    end
    if not meta_path then
        _calibre_state.file_path = nil
        _calibre_state.map       = nil
        return nil
    end
    local attr  = lfs.attributes(meta_path)
    local mtime = attr and attr.modification or 0
    if _calibre_state.file_path == meta_path
            and _calibre_state.file_mtime == mtime
            and _calibre_state.map then
        return _calibre_state.map[filepath]
    end
    -- (Re)parse the JSON file. Calibre's bundled rapidjson exposes
    -- load_calibre for the metadata.calibre format; fall back to the
    -- generic loader if that's missing.
    local ok_json, rapidjson = pcall(require, "rapidjson")
    if not ok_json then
        _calibre_state.map = nil
        return nil
    end
    local data
    if rapidjson.load_calibre then
        local ok, d = pcall(rapidjson.load_calibre, meta_path)
        if ok then data = d end
    end
    if not data then
        local ok, d = pcall(rapidjson.load, meta_path)
        if ok then data = d end
    end
    if type(data) ~= "table" then
        _calibre_state.map = nil
        return nil
    end
    local lib_root = meta_path:gsub("/[^/]+$", "")
    local map = {}
    for _, book in ipairs(data) do
        if type(book) == "table" and book.lpath then
            map[lib_root .. "/" .. book.lpath] = book
        end
    end
    _calibre_state.file_path  = meta_path
    _calibre_state.file_mtime = mtime
    _calibre_state.map        = map
    return map[filepath]
end

-- ─── buildBook ────────────────────────────────────────────────────────────────
-- Constructs a Book record for a given filepath.
-- Fields follow spec §5.1. Metadata from BookInfoManager; position from
-- DocSettings. Enrichment (stats) is a separate step (see enrichStats).
--
-- Series number strategy: BookInfoManager may return both info.series
-- (formatted as "<name> #<n>") and info.series_index (bare number). We prefer
-- series_index when present to avoid fragile string parsing; fall back to
-- parsing the formatted series string for compatibility with older caches.

-- buildBookMeta(filepath) — BookInfoManager-only Book record (no DocSettings).
-- Used by every shelf-rendering path (getRecent / getLatest / getFavorites /
-- getSeriesGroups), all of which only need cover/title/author/series fields.
-- Skipping the DocSettings sidecar read is the dominant per-rebuild saving on
-- libraries >100 books — DocSettings:open() does a Lua-parse from disk per
-- file. Use buildBook (below) when DocSettings fields (page_num, book_pct,
-- last_xp) are actually needed (i.e. the hero card and the previewed book).
-- ─── per-chip sort settings ──────────────────────────────────────────────────
-- Each chip remembers its own sort dimension via "bookshelf_sort_<chip>".
-- Missing/unknown values fall back to the chip default below. The widget
-- writes via the tab editor (bookshelf_chip_editor); each chip getter
-- reads via Repo.getSortKey(chip).
local _SORT_DEFAULT = {
    all        = "title",
    recent     = "recently_read",  -- not user-changeable; menu shows single row
    latest     = "mtime",
    favorites  = "date_added",
    series     = "latest_read",
    authors    = "latest_read",
    genres     = "latest_read",
    tags       = "latest_read",
    formats    = "name",
}

local _SORT_VALID = {
    all        = {
        title = true, natural = true, date_added = true,
        size  = true, format  = true, last_read  = true,
        percent_unopened_first = true, percent_unopened_last = true,
        percent_natural        = true,
    },
    latest     = { mtime = true },
    favorites  = { date_added = true, title = true, recently_read = true },
    series     = { name = true, latest_read = true, book_count = true },
    authors    = { name = true, latest_read = true, book_count = true },
    genres     = { name = true, latest_read = true, book_count = true },
    tags       = { name = true, latest_read = true, book_count = true },
    formats    = { name = true, latest_read = true, book_count = true },
}

-- getSortPriority(tab_id): returns the priority list for a tab, falling back
-- to the legacy single-key sort if no tab schema is present. This is the
-- bridge function during the v1.2 transition -- once Phase 2's editor lands,
-- the schema will always carry sort_priority and the legacy fallback can
-- be deleted.
local TabModel   = require("lib/bookshelf_tab_model")
local SortEngine = require("lib/bookshelf_sort_engine")

function Repo.getSortPriority(tab_id)
    local tab = TabModel.getById(tab_id)
    if tab and tab.sort_priority and #tab.sort_priority > 0 then
        return tab.sort_priority
    end
    -- Legacy fallback: translate the v1.1 single-string sort key into a
    -- one-level priority. Used only if a user's settings file has a stale
    -- shape (e.g., they downgraded and re-upgraded).
    local legacy = Repo.getSortKey(tab_id)
    local map = {
        title                  = { key = "filename",     reverse = false },
        natural                = { key = "filename",     reverse = false },
        date_added             = { key = "date_added",   reverse = true  },
        last_read              = { key = "last_opened",  reverse = true  },
        recently_read          = { key = "last_opened",  reverse = true  },
        latest_read            = { key = "last_opened",  reverse = true  },
        size                   = { key = "size",         reverse = false },
        percent_unopened_first = { key = "percent_read", reverse = false },
        percent_unopened_last  = { key = "percent_read", reverse = true  },
        percent_natural        = { key = "percent_read", reverse = true  },
        name                   = { key = "filename",     reverse = false },
        book_count             = { key = "book_count",   reverse = true  },
    }
    return { map[legacy] or { key = "title", reverse = false } }
end

function Repo.getSortKey(chip)
    local k = BookshelfSettings.read("sort_" .. chip)
    local valid = _SORT_VALID[chip]
    if k and valid and valid[k] then return k end
    return _SORT_DEFAULT[chip]
end

function Repo.buildBookMeta(filepath)
    if not filepath then return nil end
    local bim  = getBookInfoMgr()
    if not bim then return nil end  -- CoverBrowser disabled (#49)
    local info = bim:getBookInfo(filepath, true) or {}
    -- Calibre is the PRIMARY source for textual metadata when a
    -- metadata.calibre file is available — it already has clean,
    -- user-curated title / authors / series / tags / description that
    -- often come from richer sources (Goodreads, Amazon, manual edits)
    -- than crengine's per-file extractor. BIM stays primary for the
    -- fields Calibre doesn't track: cover_bb (binary), has_cover,
    -- page_count. Where Calibre has no entry for a book (non-Calibre
    -- libraries, or new books not yet imported), we fall back to BIM.
    local cb = _calibreMetadataFor(filepath)

    -- Series — KOReader's BIM stores `info.series` as "<name> #<n>"
    -- with series_index as the bare number; Calibre stores series +
    -- series_index as separate fields. Prefer Calibre when present.
    local series_name, series_num
    local cb_series = cb and type(cb.series) == "string" and cb.series ~= "" and cb.series
    if cb_series then
        series_name = cb_series
    elseif info.series then
        series_name = info.series:gsub(" #%d+$", "")
        series_num  = info.series:match(" #(%d+)$")
    end
    if cb and type(cb.series_index) == "number" then
        series_num = tostring(cb.series_index)
    elseif info.series_index then
        series_num = tostring(info.series_index)
    elseif info.series and not series_num then
        series_num = info.series:match(" #(%d+)$")
    end

    -- Authors
    local authors
    if cb and type(cb.authors) == "table" and #cb.authors > 0 then
        authors = {}
        for _i, name in ipairs(cb.authors) do
            authors[#authors + 1] = name
        end
    else
        authors = splitAuthors(info.authors)
    end

    local filename = (filepath:match("([^/]+)$") or filepath):gsub("%.[^.]+$", "")
    -- Title chain: Calibre → BIM → filename
    local title
    if cb and type(cb.title) == "string" and cb.title ~= "" then
        title = cb.title
    elseif info.title and info.title ~= "" then
        title = info.title
    else
        title = filename
    end

    -- Genres: Calibre `tags` (array) → BIM `keywords` (string) → none.
    local genres
    if cb and type(cb.tags) == "table" and #cb.tags > 0 then
        genres = splitGenreTags(cb.tags)
    elseif info.keywords and info.keywords ~= "" then
        genres = splitGenreTags(info.keywords)
    end

    return {
        filepath    = filepath,
        filename    = filename,
        format      = (filepath:match("%.([^.]+)$") or ""):upper(),
        title       = title,
        author      = authors and authors[1] or nil,
        authors     = authors,
        -- Calibre-curated sort form ("Surname, Forename" or
        -- "Surname1, F1 & Surname2, F2"). The sort engine prefers this
        -- over a derived surname so user-edited author_sort values
        -- (compound surnames "St. Crowe", particles "van der", suffix
        -- handling, inverted naming) are honoured. nil for non-Calibre
        -- libraries; cachedSurname falls back to parsing `author` then.
        author_sort = cb and type(cb.author_sort) == "string"
                       and cb.author_sort ~= "" and cb.author_sort or nil,
        genres      = genres,
        -- `series` is the raw "Foundation #1" string used by some
        -- consumers; reconstruct it from Calibre fields when needed.
        series      = info.series
                       or (cb_series and series_num and (cb_series .. " #" .. series_num))
                       or cb_series,
        series_name = series_name,
        series_num  = series_num,
        -- BIM-only: covers and page count are not in metadata.calibre.
        cover_bb    = info.cover_bb,
        has_cover   = info.has_cover and not info.ignore_cover,
        lang        = (cb and type(cb.languages) == "table" and cb.languages[1])
                       or info.language,
        description = (cb and type(cb.comments) == "string" and cb.comments ~= "")
                       and cb.comments
                       or (info.description and info.description ~= ""
                           and info.description)
                       or nil,
        page_count  = info.pages,
    }
end

-- Text-only metadata for the library walk phases of getSeriesGroups /
-- getAuthors / getGenres. On large libraries (2000+ books), calling
-- buildBookMeta for every candidate and keeping the result in a group
-- table means all BIM cover BlitBuffers stay live simultaneously; for
-- 2000 books at ~60 KB each that peaks at ~120 MB and OOM-kills KOReader.
-- LuaJIT does not track FFI-allocated C memory for GC pressure, so the
-- collector doesn't know to step more aggressively.
-- get_cover=false sidesteps the zstd decompression + Blitbuffer allocation
-- entirely (see bookinfomanager line 376-379). The original implementation
-- passed true and let the bb fall out of scope after the function
-- returned — but the bb was still allocated in C memory for the duration
-- of the loop iteration, and on a Kindle Color the calloc inside
-- zstd_uncompress_ctx could fail (zstd.lua:75 assert).
--
-- Light metadata is also fetched in BATCH via _getLightMetaCache for
-- callers that walk the whole library: a single SELECT replaces ~2000
-- prepared-statement executions, dropping cold-walk cost from ~20s to
-- ~1-2s on a 2000-book Calibre library. _buildBookMetaLight stays the
-- per-book entry point (used when a caller doesn't want to materialize
-- the whole map, and as the fallback path inside the cache builder).
local function _buildLightMetaFromInfo(fp, info)
    info = info or {}
    local cb = _calibreMetadataFor(fp)

    local series_name, series_num
    local cb_series = cb and type(cb.series) == "string" and cb.series ~= "" and cb.series
    if cb_series then
        series_name = cb_series
    elseif info.series then
        series_name = info.series:gsub(" #%d+$", "")
        series_num  = info.series:match(" #(%d+)$")
    end
    if cb and type(cb.series_index) == "number" then
        series_num = tostring(cb.series_index)
    elseif info.series_index then
        series_num = tostring(info.series_index)
    elseif info.series and not series_num then
        series_num = info.series:match(" #(%d+)$")
    end

    local authors
    if cb and type(cb.authors) == "table" and #cb.authors > 0 then
        authors = {}
        for _i, name in ipairs(cb.authors) do authors[#authors + 1] = name end
    else
        authors = splitAuthors(info.authors)
    end

    local genres
    if cb and type(cb.tags) == "table" and #cb.tags > 0 then
        genres = splitGenreTags(cb.tags)
    elseif info.keywords and info.keywords ~= "" then
        genres = splitGenreTags(info.keywords)
    end

    local filename = (fp:match("([^/]+)$") or fp):gsub("%.[^.]+$", "")
    local title
    if cb and type(cb.title) == "string" and cb.title ~= "" then
        title = cb.title
    elseif info.title and info.title ~= "" then
        title = info.title
    else
        title = filename
    end

    -- filename is also returned so callers like searchBooks can include
    -- it in their search haystack without paying for the heavy
    -- buildBookMeta path.
    return {
        filepath    = fp,
        filename    = filename,
        series_name = series_name,
        series_num  = series_num,
        author      = authors and authors[1] or nil,
        authors     = authors,
        -- See buildBookMeta: Calibre-curated sort form, consumed by
        -- cachedSurname in the sort engine. Light meta carries it too
        -- so the predicate-walk path (loadCandidatesByPredicate) gets
        -- correct surname ordering on custom chips, not just the heavy
        -- buildBookMeta path.
        author_sort = cb and type(cb.author_sort) == "string"
                       and cb.author_sort ~= "" and cb.author_sort or nil,
        genres      = genres,
        title       = title,
    }
end

local function _buildBookMetaLight(fp)
    if not fp then return nil end
    local bim  = getBookInfoMgr()
    if not bim then return nil end  -- CoverBrowser disabled (#49)
    local info = bim:getBookInfo(fp, false) or {}
    return _buildLightMetaFromInfo(fp, info)
end

function Repo.buildBook(filepath)
    local book = Repo.buildBookMeta(filepath)
    if not book then return nil end
    local ds = getDocSettings():open(filepath)
    book.page_num = ds:readSetting("last_page")
    book.book_pct = ds:readSetting("percent_finished")
    book.last_xp  = ds:readSetting("last_xpointer")
    -- summary.status feeds the cover-progress indicators in
    -- bookshelf_cover_progress.decide(); read here so the DocSettings
    -- handle is reused. nil is fine -- decide() treats absent status
    -- as "new" and renders nothing.
    local _summary = ds:readSetting("summary")
    book.status = _summary and _summary.status or nil
    -- Same normalisation as Repo.readProgress -- 'complete' -> 'finished',
    -- 'abandoned' -> 'on_hold' -- so every consumer sees one vocabulary.
    if     book.status == "complete"  then book.status = "finished"
    elseif book.status == "abandoned" then book.status = "on_hold"
    end
    -- 1-5 stars (or nil for unrated). Stored under summary.rating by KOReader's
    -- Reader Status dialog. Exposed for the hero card's rating region and for
    -- the rating sort key.
    book.rating = _summary and tonumber(_summary.rating) or nil
    -- BIM skips page count for crengine docs (the unrendered getPageCount()
    -- returns 2-3x the rendered count), so EPUB books have nil page_count
    -- after buildBookMeta. Two sdr-side sources to fall back on, in order:
    --
    --   1. pagemap_doc_pages — set whenever the user has KOReader's stable
    --      page numbers enabled (either publisher page labels ℗, or the
    --      synthetic chars-per-page mode). Stable across font/render
    --      changes — what most users mean by "page count" for an EPUB.
    --
    --   2. stats.pages — the count at the time the doc was last rendered.
    --      Font-dependent, but populated for any opened EPUB.
    --
    -- Preferring pagemap_doc_pages means users with stable page numbers
    -- enabled see the SAME count we'd show in the book-info dialog and
    -- the reader footer, regardless of their current font scaling.
    if not book.page_count then
        local stable_pages = ds:readSetting("pagemap_doc_pages")
        if stable_pages then
            book.page_count = tonumber(stable_pages)
        end
    end
    if not book.page_count then
        local stats = ds:readSetting("stats")
        if type(stats) == "table" and stats.pages then
            book.page_count = tonumber(stats.pages)
        end
    end
    -- page_num precedence mirrors page_count:
    --   1. pagemap_current_page_label — the stable label at the user's
    --      current position. May be non-numeric for front-matter (Roman
    --      numerals "i", "ii"); tonumber-guarded so those fall through.
    --   2. last_page — set for PDF/CBZ (already read above).
    --   3. floor(percent_finished * page_count) — synthesised approximation
    --      so the hero's "page N of M" template works for EPUBs the reader
    --      hasn't given us a stable label for.
    if not book.page_num then
        local label = ds:readSetting("pagemap_current_page_label")
        if label then
            local n = tonumber(label)
            if n then book.page_num = n end
        end
    end
    if not book.page_num and book.book_pct and book.page_count then
        book.page_num = math.floor(book.book_pct * book.page_count + 0.5)
        if book.page_num < 1 then book.page_num = 1 end
    end
    return book
end

-- ─── getCurrent ──────────────────────────────────────────────────────────────
-- Returns the Book record for the last opened file, or nil if none.

function Repo.getCurrent()
    local lastfile = G_reader_settings:readSetting("lastfile")
    if not lastfile then return nil end
    -- Only accept supported book formats. Otherwise hero card stays empty —
    -- avoids stale PNGs / config files / random opened-once non-books from
    -- taking the hero slot.
    local ext = lastfile:match("%.([^.]+)$")
    if not ext or not SUPPORTED_EXT[ext:lower()] then return nil end
    return Repo.buildBook(lastfile)
end

-- ─── getRecent ───────────────────────────────────────────────────────────────
-- Returns up to `limit` Book records from ReadHistory.hist, in order
-- (ReadHistory keeps hist sorted newest-first already). No exclusion —
-- the active book stays visible in the shelf, and the BookshelfWidget
-- highlights the previewed spine instead so the user can tell which one
-- the hero is currently displaying. Earlier iterations excluded lastfile
-- to avoid hero+slot-1 duplication; that exchange wasn't worth the
-- shelves jumping around as the user browsed previews.

function Repo.getRecent(limit, offset)
    local rh   = getReadHistory()
    offset     = offset or 0
    limit      = limit or 8
    local out  = {}
    -- entry.dim is ReadHistory's marker for files deleted via the
    -- KOReader file manager when autoremove_deleted_items_from_history
    -- is off (the default). Stock History dims them; bookshelf treats
    -- them as gone -- if KOReader notices the file is back, the flag
    -- clears and the entry reappears here naturally.
    --
    -- Single pass: count non-dim entries (= total) while fetching
    -- buildBookMeta only for the visible slice [offset+1, offset+limit].
    local total = 0
    for i = 1, #rh.hist do
        local entry = rh.hist[i]
        if not entry.dim then
            total = total + 1
            if total > offset and #out < limit then
                local book = Repo.buildBookMeta(entry.file)
                if book then
                    book.last_read_time = entry.time
                    out[#out + 1] = book
                end
            end
        end
    end
    return out, total
end

-- ─── getLatest ───────────────────────────────────────────────────────────────
-- Returns up to `limit` Book records, sorted newest-by-mtime first, from a
-- recursive filesystem walk rooted at G_reader_settings `home_dir`.
-- Walk depth is capped by `bookshelf_latest_walk_depth` setting (default 3).
-- Results are NOT memoised here — caching is a BookshelfWidget-level concern.

-- KOReader ships LFS as `libs/libkoreader-lfs` and that's the only path that
-- works inside the plugin loader. The unprefixed `require("lfs")` resolves
-- only in the test harness (where we stub package.loaded.lfs) and fails at
-- runtime — which is what crashed the chip switch on first use.
-- ─── Walk cache ──────────────────────────────────────────────────────────────
-- walkBooks is the dominant cost in BookshelfWidget:_rebuild for any
-- non-trivial library: a recursive lfs scan plus per-file mtime stats. Both
-- getLatest and getSeriesGroups call it, and both fire on every chip switch
-- and page flip. We memoise the candidate list keyed by (home, depth) with a
-- short TTL so back-to-back rebuilds reuse the work.
--
-- Invalidation: TTL covers the steady state. main.lua's onCloseDocument hook
-- calls Repo.invalidateWalkCache() so a session that closes a book and
-- returns to Bookshelf picks up any sideloaded / moved files immediately.
-- No TTL on the walk cache: the dir-mtime check in cachedWalk() detects
-- every filesystem-level change cheaply, so a timer would only ever
-- invalidate a cache that already represents reality. The constant stays
-- defined because downstream cache structs still store `expires_at` for
-- legacy reasons (no longer checked for the walk-derived caches).
-- User-driven refresh via the swipe-down gesture invalidates explicitly.
local WALK_CACHE_TTL = 0  -- unused; kept so old struct shapes still init
local _walk_cache = {}      -- { [key] = { list = {...}, expires_at = number } }

-- Series-groups cache. The walk-cache covers the lfs.dir + per-file mtime
-- sweep, but getSeriesGroups also iterates EVERY candidate calling
-- buildBookMeta — that's a BookInfoManager (SQLite) lookup per book, the
-- dominant cost on the Series chip for libraries above ~1k books.
-- Memoise the post-iteration result (full pre-slice list) keyed on the
-- same (home, depth) the walk uses, with a matching TTL. Invalidation
-- piggy-backs on invalidateWalkCache so onCloseDocument naturally
-- refreshes both — a just-read book's read-time bubble-up still lands
-- on the next chip rebuild.
local SERIES_CACHE_TTL = WALK_CACHE_TTL
local _series_cache    = {}  -- { [key] = { groups = {...}, expires_at = number } }
-- Authors and Genres group caches. Same TTL + invalidation pattern as
-- the series cache: filepaths-only "shape" so the cover_bb lifetime
-- hazard from caching Book records doesn't apply.
local _authors_cache   = {}
local _genres_cache    = {}
local _formats_cache   = {}
local _ratings_cache   = {}
-- getAll result cache. FileChooser:genItemTableFromPath is expensive (2–5s
-- on large home dirs); caches the shape (filepaths + folder labels) with the
-- same TTL and invalidation path as the walk cache.
local _all_cache       = {}  -- { [key] = { shapes = {...}, expires_at = number } }
-- getBySource result cache. For custom-kind tabs (genre, folder, collection,
-- etc.) the predicate walk + per-book _safeBuildBookMeta is expensive (full
-- library sweep on every pagination tap). Cache the post-filter, post-sort
-- candidate list keyed on (source, filter, sort_priority) so pagination
-- within a tab is a cheap slice of the cached list. Invalidated by
-- invalidateBookCache (editor Save) and invalidateWalkCache (onCloseDocument).
local _bySource_cache  = {}  -- { [key] = candidates }
-- Light-meta cache: filepath → light record (output of _buildLightMetaFromInfo).
-- Populated once per (home, depth) by a single batch BIM SELECT that replaces
-- the per-book prepared-statement loop. Three walk consumers — getSeriesGroups
-- MISS, _buildGroups (authors/genres), and searchBooks — all walk the SAME
-- candidate list and need the SAME per-book metadata, so paying SQLite once
-- and letting all three readers hit the result is the dominant speedup
-- (Lutesong's Kindle Color: 20s per chip → ~1-2s, 2000-book library).
local _light_meta_cache = {}  -- { [key] = { map = {[fp]=record}, expires_at = number } }
-- Per-file progress cache. DocSettings:open() does a Lua-parse from disk
-- per call, which dominates loops that read percent / summary.status for
-- many books in a row (getAll's prefetch on the Home chip is the obvious
-- one). Caching the parsed result for a short window cuts repeat scans
-- to memory reads.
--
-- Invalidation: onCloseDocument explicitly drops the just-closed file via
-- invalidateProgressCache(fp); invalidateWalkCache wipes the whole map as
-- a belt-and-braces refresh for any sideloaded / metadata-edited cases.
local PROGRESS_CACHE_TTL = 120  -- seconds
local _progress_cache    = {}   -- filepath → { pct, status, expires_at }
local _folder_read_cache = {}   -- folder-key → { summary = table, expires_at = number }

function Repo.invalidateWalkCache()
    _walk_cache       = {}
    _series_cache     = {}
    _authors_cache    = {}
    _genres_cache     = {}
    _formats_cache    = {}
    _ratings_cache    = {}
    _all_cache        = {}
    _bySource_cache   = {}
    _light_meta_cache = {}
    _progress_cache   = {}
    _folder_read_cache = {}
end

function Repo.invalidateSeriesCache()
    _series_cache     = {}
    _authors_cache    = {}
    _genres_cache     = {}
    _formats_cache    = {}
    _ratings_cache    = {}
    _light_meta_cache = {}
end

function Repo.invalidateProgressCache(filepath)
    if filepath then _progress_cache[filepath] = nil
    else _progress_cache = {} end
    _folder_read_cache = {}
end

-- invalidateBookCache -- nil all per-chip result caches so the next chip
-- rebuild fetches + sorts fresh data. Does NOT touch the walk cache (file
-- system scan), the light-meta cache (SQLite batch), the BIM cover cache,
-- or the _folderHasBooks_cache -- those are heavier to rebuild and are
-- not affected by sort / filter / source changes on tabs.
-- Call this before firing on_change after an editor Save.
function Repo.invalidateBookCache(reason)
    local logger = require("logger")
    _series_cache     = {}
    _authors_cache    = {}
    _genres_cache     = {}
    _formats_cache    = {}
    _ratings_cache    = {}
    _all_cache        = {}
    _bySource_cache   = {}
    _folder_read_cache = {}
    if logger and logger.dbg then
        logger.dbg("[bookshelf] cache invalidated: " .. tostring(reason))
    end
end

-- Cached read of a file's percent_finished + summary.status + summary.rating
-- + page count. Returns (pct, status, rating, page_count). Any field may
-- be nil. A pcall guards a corrupt sdr sidecar so the caller's loop
-- survives single-file faults.
--
-- page_count fallback chain (same as buildBook): pagemap_doc_pages first
-- (stable count from KOReader's pagemap), then stats.pages (statistics
-- plugin's view). Lets the cover-progress page-count indicator work for
-- EPUBs, which have no BIM-reported page count.
function Repo.readProgress(filepath)
    if not filepath then return nil, nil, nil, nil end
    local now = os.time()
    local cached = _progress_cache[filepath]
    if cached and cached.expires_at > now then
        return cached.pct, cached.status, cached.rating, cached.page_count
    end
    local pct, status, rating, page_count
    local ok_ds, ds = pcall(function() return getDocSettings():open(filepath) end)
    if ok_ds and ds then
        local ok_pct, p = pcall(ds.readSetting, ds, "percent_finished")
        if ok_pct then pct = tonumber(p) end
        local ok_sum, summary = pcall(ds.readSetting, ds, "summary")
        if ok_sum and type(summary) == "table" then
            status = summary.status
            rating = tonumber(summary.rating)
        end
        local ok_pm, stable_pages = pcall(ds.readSetting, ds, "pagemap_doc_pages")
        if ok_pm and stable_pages then page_count = tonumber(stable_pages) end
        if not page_count then
            local ok_st, stats = pcall(ds.readSetting, ds, "stats")
            if ok_st and type(stats) == "table" and stats.pages then
                page_count = tonumber(stats.pages)
            end
        end
    end
    -- Normalise to bookshelf canonical status values. KOReader's End-of-book
    -- dialog and Book Status widget store 'complete' / 'abandoned' in
    -- summary.status; bookshelf's filter UI / sort engine refer to the
    -- same states as 'finished' / 'on_hold'. Translate once at the
    -- source so every downstream consumer reads the same vocabulary.
    if     status == "complete"  then status = "finished"
    elseif status == "abandoned" then status = "on_hold"
    end
    _progress_cache[filepath] = {
        pct        = pct,
        status     = status,
        rating     = rating,
        page_count = page_count,
        expires_at = now + PROGRESS_CACHE_TTL,
    }
    return pct, status, rating, page_count
end

function Repo.getReadingStatus(filepath)
    local pct, status_name = Repo.readProgress(filepath)
    if status_name == "finished" or status_name == "complete" or (pct and pct >= 1) then
        return { state = "read", pct = pct or 1 }
    elseif status_name == "reading" or status_name == "on_hold"
            or status_name == "abandoned" or (pct and pct > 0) then
        return { state = "reading", pct = pct }
    end
    return nil
end

-- `dirs` (optional out-param): when present, walkBooks records every visited
-- subdirectory's mtime in it (keyed by absolute path). cachedWalk uses this
-- to detect "did anything in the library change since we cached?" with a
-- single stat() per dir on subsequent reads, far cheaper than re-walking
-- the entire tree on each chip tap.
local function walkBooks(root, depth, out, current_depth, dirs)
    current_depth = current_depth or 0
    if current_depth > depth then return end
    -- Refuse to walk an unset/empty root. "/" is permitted (some users set
    -- home_dir to root deliberately) — SYSTEM_DIR_NAMES below filters out
    -- the pseudo-filesystems that would otherwise OOM the walk.
    if current_depth == 0 and (not root or root == "") then
        logger.warn("[bookshelf] walkBooks: home_dir not configured; skipping walk")
        return
    end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs or not lfs or not lfs.dir then return end

    -- Guard against permission errors / missing dirs raised by lfs.dir(root).
    -- lfs.dir returns (iterator, dir_obj); both must be passed to the for
    -- loop or lfs raises "directory metatable expected, got nil" on the first
    -- step. pcall returns (ok, ret1, ret2, …) — capture both real returns.
    local ok, iter, dir_obj = pcall(lfs.dir, root)
    if not ok or type(iter) ~= "function" then return end

    for entry in iter, dir_obj do
        if entry ~= "." and entry ~= ".." and not SYSTEM_DIR_NAMES[entry] then
            local fp = _joinPath(root, entry)
            -- One stat call instead of two on real lfs (which returns a
            -- table from attributes(fp) with no key). Falls back to two
            -- keyed calls for test stubs that don't implement the no-key
            -- form. The fast path halves the syscall count over the
            -- recursive walk on actual hardware.
            local attr = lfs.attributes(fp)
            if type(attr) ~= "table" then
                attr = {
                    mode = lfs.attributes(fp, "mode"),
                    modification = lfs.attributes(fp, "modification"),
                }
            end
            local mode = attr.mode
            if mode == "directory" then
                -- Skip .sdr sidecar dirs. They contain KOReader's per-book
                -- metadata (cover, progress, etc.) and no actual books -- so
                -- descending into them is wasted work. More importantly:
                -- their mtime bumps every time a book is closed (metadata
                -- rewrite), which would falsely invalidate the walk cache
                -- on every read session if we recorded them in `dirs`.
                if entry:sub(-4) ~= ".sdr" then
                    if dirs then dirs[fp] = attr.modification or 0 end
                    walkBooks(fp, depth, out, current_depth + 1, dirs)
                end
            elseif mode == "file" then
                local ext = entry:match("%.([^.]+)$")
                if ext and SUPPORTED_EXT[ext:lower()] then
                    -- size kept alongside mtime so sort-by-File-size on
                    -- custom-source tabs has data without re-statting.
                    -- attr.size is already in hand from the same lfs call.
                    out[#out + 1] = {
                        fp    = fp,
                        mtime = attr.modification or 0,
                        size  = attr.size or 0,
                    }
                end
            end
        end
    end
end

-- _dirsChanged(dirs): true if any recorded directory's current mtime differs
-- from what we saved (or the directory is gone). On Kindle's user partition
-- a stat() takes ~50us and a typical library has ~100-500 dirs, so the
-- whole check is single-digit ms even on a cold filesystem cache. Cheaper
-- than the 1-3s a re-walk would cost.
local function _dirsChanged(dirs)
    if not dirs then return true end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs or not lfs or not lfs.attributes then return true end
    for path, recorded in pairs(dirs) do
        local now_mtime = lfs.attributes(path, "modification")
        if not now_mtime or now_mtime ~= recorded then return true end
    end
    return false
end

-- Returns a shallow copy of the cached candidate list for (home, depth).
-- Walks fresh on miss/expiry/dir-mtime-change. The copy is so callers
-- (e.g. getLatest) can sort in place without mutating the cached order.
local function cachedWalk(home, depth)
    local key = (home or "/") .. ":" .. tostring(depth or 0)
    local now = os.time()
    local entry = _walk_cache[key]
    local stale_reason
    if not entry then
        stale_reason = "miss"
    elseif _dirsChanged(entry.dirs) then
        stale_reason = "dir-mtime"
    end
    if stale_reason then
        local _t0 = _gettime()
        local fresh, dirs = {}, {}
        -- Record the root's own mtime too -- a new top-level book or folder
        -- bumps the home_dir's mtime, and without this entry the dir-mtime
        -- check would miss those adds.
        local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
        if ok_lfs and lfs and lfs.attributes then
            local root_m = lfs.attributes(home, "modification")
            if root_m then dirs[home] = root_m end
        end
        walkBooks(home, depth, fresh, 0, dirs)
        local _dt = (_gettime() - _t0) * 1000
        -- Compare the new book set to the previous one (filepath set
        -- equality). The most common dir-mtime change is a user opening
        -- a new-to-them book for the first time: KOReader creates the
        -- book's .sdr sidecar, which adds an entry to the parent
        -- directory and bumps its mtime -- triggering this rebuild --
        -- but the underlying set of book files is unchanged. In that
        -- case we keep the downstream caches valid and just refresh
        -- the dirs map. Only an actual add/remove cascades.
        local files_changed = true
        if entry and entry.list and stale_reason ~= "miss" then
            files_changed = false
            if #entry.list ~= #fresh then
                files_changed = true
            else
                local old_set = {}
                for i = 1, #entry.list do old_set[entry.list[i].fp] = true end
                for i = 1, #fresh do
                    if not old_set[fresh[i].fp] then files_changed = true; break end
                end
            end
        end
        entry = { list = fresh, dirs = dirs, expires_at = now + WALK_CACHE_TTL }
        _walk_cache[key] = entry
        if files_changed and stale_reason ~= "miss" then
            -- Downstream caches were built against the previous book set
            -- and won't include newly-added (or still-include removed)
            -- books. Drop them so the next query rebuilds against the
            -- fresh walk. Skipped when the book set is unchanged --
            -- saves rebuilding 13+ author/genre group caches just
            -- because a .sdr was created.
            _series_cache    = {}
            _authors_cache   = {}
            _genres_cache    = {}
            _formats_cache   = {}
            _ratings_cache   = {}
            _all_cache       = {}
            _bySource_cache  = {}
            _light_meta_cache = {}
        end
        local dir_count = 0
        for _ in pairs(dirs) do dir_count = dir_count + 1 end
        logger.dbg(string.format("[bookshelf perf] cachedWalk: MISS(%s) walk=%.0fms files=%d dirs=%d depth=%s",
            stale_reason, _dt, #fresh, dir_count, tostring(depth)))
        -- Per-extension breakdown of the freshly-walked library. Helps
        -- confirm whether the new v1.1.2 extensions are pulling in a lot
        -- of files we hadn't seen on v1.1.1 (which would explain heavy
        -- BIM extraction load + Android ANRs).
        do
            local ext_count = {}
            for i = 1, #fresh do
                local fp = fresh[i].fp or ""
                local ext = fp:match("%.([^%.]+)$")
                if ext then
                    ext = ext:lower()
                    ext_count[ext] = (ext_count[ext] or 0) + 1
                end
            end
            local parts = {}
            for ext, n in pairs(ext_count) do
                parts[#parts + 1] = ext .. "=" .. n
            end
        end
    else
        logger.dbg(string.format("[bookshelf perf] cachedWalk: HIT files=%d ttl_left=%ds",
            #entry.list, entry.expires_at - now))
    end
    local copy = {}
    for i = 1, #entry.list do copy[i] = entry.list[i] end
    return copy
end

local function candidatesForScope(home, depth, scope)
    local roots = _scopeRoots(scope)
    if not roots then return cachedWalk(home, depth) end
    local out, seen = {}, {}
    for _, root in ipairs(roots) do
        for _, c in ipairs(cachedWalk(root, depth)) do
            if not seen[c.fp] then
                out[#out + 1] = c
                seen[c.fp] = true
            end
        end
    end
    return out
end

-- ─── Batch BIM loader + light-meta cache ─────────────────────────────────────
-- Pull every text-only bookinfo row from BIM in one SQLite call. Returns a
-- (directory||filename) → info-table map, or nil on failure (caller falls back
-- to per-book bim:getBookInfo via _buildBookMetaLight).
--
-- BIM's public API only exposes a single-row prepared statement
-- (BOOKINFO_SELECT_SQL), so we reach into bim.db_conn directly. The risk is a
-- future BIM schema change; mitigated by pcall + nil return + per-book
-- fallback, so a schema break degrades to "old slow path" rather than a crash.
local function _loadBatchBookInfoFromBim()
    local bim = getBookInfoMgr()
    if not bim or type(bim.openDbConnection) ~= "function" then return nil end
    local ok_open = pcall(function() bim:openDbConnection() end)
    if not ok_open then return nil end
    local conn = bim.db_conn
    if not conn or type(conn.exec) ~= "function" then return nil end

    local sql = "SELECT directory, filename, title, authors, series, series_index, keywords " ..
                "FROM bookinfo WHERE in_progress=0;"
    local rows
    local ok, err = pcall(function() rows = conn:exec(sql) end)
    if not ok then
        logger.warn("[bookshelf] batch BIM read failed:", err)
        return nil
    end
    if not rows then return {} end  -- empty DB

    -- ljsqlite3:exec returns column-major arrays: rows[col_index][row_index].
    local n = (rows[1] and #rows[1]) or 0
    local map = {}
    for i = 1, n do
        local fp = (rows[1][i] or "") .. (rows[2][i] or "")
        map[fp] = {
            title        = rows[3][i],
            authors      = rows[4][i],
            series       = rows[5][i],
            series_index = rows[6][i],
            keywords     = rows[7][i],
        }
    end
    return map
end

-- _getLightMetaCache(home, depth) — returns a fp → light-record map for every
-- candidate in the cached walk. Built once per (home, depth) using a single
-- batch BIM SELECT; subsequent walks for the same (home, depth) are O(1)
-- lookups per book. Falls back to per-book _buildBookMetaLight if the batch
-- query fails (rare; BIM unavailable or schema mismatch).
local function _getLightMetaCache(home, depth)
    local key = (home or "/") .. ":" .. tostring(depth or 0)
    local now = os.time()
    local entry = _light_meta_cache[key]
    if entry and entry.expires_at > now then
        logger.dbg(string.format("[bookshelf perf] light_meta: HIT entries=%d ttl_left=%ds",
            entry.count or 0, entry.expires_at - now))
        return entry.map
    end

    -- Build the map directly from the batch BIM result. Earlier the cache
    -- was filtered through cachedWalk to drop entries for files BIM still
    -- knows about but that have been deleted from disk; callers handle
    -- those with a per-book fallback on lookup miss anyway, so the filter
    -- wasn't load-bearing. Skipping cachedWalk here removes ~2s from
    -- Home's cold path on a 1500-book library — the Home (all-chip) path
    -- has its own single-level lfs.dir scan and never needed the
    -- recursive walk that this cache was forcing.
    local _t0 = _gettime()
    local row_map = _loadBatchBookInfoFromBim()
    local meta_map = {}
    local count = 0
    if row_map then
        for fp, info in pairs(row_map) do
            meta_map[fp] = _buildLightMetaFromInfo(fp, info)
            count = count + 1
        end
    end
    -- Cache even an empty/partial map: callers fall back to per-book on miss,
    -- so an incomplete cache doesn't break correctness — and we avoid hammering
    -- BIM for the same failed query on every chip switch.
    _light_meta_cache[key] = {
        map = meta_map,
        count = count,
        expires_at = now + WALK_CACHE_TTL,
    }
    logger.dbg(string.format("[bookshelf perf] light_meta: MISS build=%.0fms cached=%d batch=%s",
        (_gettime() - _t0) * 1000, count, row_map and "ok" or "fallback"))
    return meta_map
end

-- Walk-time helper: prefer the cache, fall back to per-book on miss. Walk
-- consumers (getSeriesGroups MISS / _buildGroups / searchBooks) call this
-- per candidate instead of _buildBookMetaLight directly.
local function _lightMetaForFp(cache, fp)
    if cache then
        local hit = cache[fp]
        if hit then return hit end
    end
    return _buildBookMetaLight(fp)
end

function Repo.getLatest(limit, offset, scope)
    local _t0 = _gettime()
    local home       = G_reader_settings:readSetting("home_dir") or "/"
    local depth      = BookshelfSettings.read("latest_walk_depth") or 3
    local candidates = candidatesForScope(home, depth, scope)
    -- "latest" chip is mtime-only by design (_SORT_VALID restricts it).
    -- Newest first.
    table.sort(candidates, function(a, b) return a.mtime > b.mtime end)
    offset      = offset or 0
    local total = #candidates
    local out   = {}
    local stop  = math.min(offset + (limit or 8), total)
    for i = offset + 1, stop do
        local book = Repo.buildBookMeta(candidates[i].fp)
        if book then
            book.added_time = candidates[i].mtime
            out[#out + 1] = book
        end
    end
    logger.dbg(string.format("[bookshelf perf] getLatest: %.0fms cands=%d items=%d/%d",
        (_gettime() - _t0) * 1000, #candidates, #out, total))
    return out, total
end

-- ─── getAll / findFirstBookIn ────────────────────────────────────────────────
-- Folder-aware listing for the "All" chip. Delegates to KOReader's
-- FileChooser:genItemTableFromPath so the user's collate, reverse_collate,
-- collate_mixed and book status filter are honoured for free — no need to
-- maintain a parallel sort/filter pipeline. Output is converted into our
-- internal item shape: bare Book records for files, folder records for
-- directories. Folder records carry { kind = "folder", path, label,
-- first_book } where first_book is the first usable book found by walking
-- the directory tree (bounded depth) so the FolderStack widget has a cover
-- to display on the spine.

local function _scanFolderSummary(path, max_depth, collect_files)
    max_depth = max_depth or 3
    if max_depth < 0 then
        return { first_book_fp = nil, book_count = 0, filepaths = collect_files and {} or nil }
    end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs or not lfs then
        return { first_book_fp = nil, book_count = 0, filepaths = collect_files and {} or nil }
    end
    local ok, iter, dir_obj = pcall(lfs.dir, path)
    if not ok or type(iter) ~= "function" then
        return { first_book_fp = nil, book_count = 0, filepaths = collect_files and {} or nil }
    end
    local files, dirs = {}, {}
    for f in iter, dir_obj do
        if f ~= "." and f ~= ".." and not f:match("^%.") and f:sub(-4) ~= ".sdr"
                and not SYSTEM_DIR_NAMES[f] then
            local fp = _joinPath(path, f)
            local attr = lfs.attributes(fp)
            local mode = type(attr) == "table" and attr.mode
                          or lfs.attributes(fp, "mode")
            if mode == "file" then
                local ext = f:match("%.([^.]+)$")
                if ext and SUPPORTED_EXT[ext:lower()] then
                    files[#files + 1] = { name = f, fp = fp }
                end
            elseif mode == "directory" then
                dirs[#dirs + 1] = { name = f, fp = fp }
            end
        end
    end
    table.sort(files, function(a, b) return a.name < b.name end)
    table.sort(dirs, function(a, b) return a.name < b.name end)

    local first = files[1] and files[1].fp or nil
    local count = #files
    local filepaths = collect_files and {} or nil
    if filepaths then
        for _, e in ipairs(files) do filepaths[#filepaths + 1] = e.fp end
    end
    for _, e in ipairs(dirs) do
        local child = _scanFolderSummary(e.fp, max_depth - 1, collect_files)
        if not first and child.first_book_fp then first = child.first_book_fp end
        count = count + (tonumber(child.book_count) or 0)
        if filepaths and child.filepaths then
            for _, fp in ipairs(child.filepaths) do filepaths[#filepaths + 1] = fp end
        end
    end
    return { first_book_fp = first, book_count = count, filepaths = filepaths }
end

function Repo.getFolderSummary(path, max_depth)
    return _scanFolderSummary(path, max_depth, false)
end

function Repo.getFolderReadSummary(path, max_depth)
    if not path then
        return { book_count = 0, read_count = 0, unread_count = 0, all_read = false }
    end
    max_depth = max_depth or 3
    local key = path .. "\0" .. tostring(max_depth)
    local now = os.time()
    local cached = _folder_read_cache[key]
    if cached and cached.expires_at > now then
        return cached.summary
    end

    local folder = _scanFolderSummary(path, max_depth, true)
    local read_count = 0
    for _, fp in ipairs(folder.filepaths or {}) do
        local status = Repo.getReadingStatus(fp)
        if status and status.state == "read" then
            read_count = read_count + 1
        end
    end
    local book_count = tonumber(folder.book_count) or 0
    local summary = {
        book_count    = book_count,
        read_count    = read_count,
        unread_count  = math.max(0, book_count - read_count),
        all_read      = book_count > 0 and read_count >= book_count,
    }
    _folder_read_cache[key] = { summary = summary, expires_at = now + PROGRESS_CACHE_TTL }
    return summary
end

function Repo.markFolderRead(path, max_depth)
    if not path then return 0 end
    local folder = _scanFolderSummary(path, max_depth or 3, true)
    local changed = 0
    for _, fp in ipairs(folder.filepaths or {}) do
        local ok_ds, ds = pcall(function() return getDocSettings():open(fp) end)
        if ok_ds and ds then
            local ok_summary, summary = pcall(ds.readSetting, ds, "summary")
            if not ok_summary or type(summary) ~= "table" then summary = {} end
            summary.status = "complete"
            if type(ds.saveSetting) == "function" then
                pcall(ds.saveSetting, ds, "summary", summary)
                pcall(ds.saveSetting, ds, "percent_finished", 1)
                if type(ds.flush) == "function" then pcall(ds.flush, ds) end
                _progress_cache[fp] = nil
                changed = changed + 1
            end
        end
    end
    _folder_read_cache = {}
    return changed
end

-- Returns the filepath (string) of the first supported book file at or
-- below `path`, depth-limited. Returns nil if no book is found.
--
-- Used by getAll's shape-builder to pick a representative cover for each
-- folder card. Only the filepath is needed at shape-build time — per-page
-- hydration loads the actual Book record with cover. Previously this
-- returned a full Book record built via _safeBuildBookMeta, meaning a
-- zstd cover decompression per subfolder during cold shape construction:
-- the dominant cost on Home for libraries with many subfolders.
-- (We previously also did two stat passes per entry — one looking for
-- files, then a second looking for directories; merged into one pass.)
function Repo.findFirstBookIn(path, max_depth)
    return Repo.getFolderSummary(path, max_depth).first_book_fp
end

-- folderHasBooks(path): true if `path` (recursively) contains at least one
-- supported book file. Short-circuits on first hit; memoized per-session.
-- Used by getAll to suppress empty folder cards before the user sees them.
local _folderHasBooks_cache = {}

function Repo.folderHasBooks(path)
    if not path or path == "" then return false end
    if _folderHasBooks_cache[path] ~= nil then return _folderHasBooks_cache[path] end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs or not lfs then
        _folderHasBooks_cache[path] = true  -- assume non-empty on lfs failure
        return true
    end
    local stack = { path }
    while #stack > 0 do
        local dir = table.remove(stack)
        local ok_dir, iter, dir_obj = pcall(lfs.dir, dir)
        if ok_dir and type(iter) == "function" then
            for entry in iter, dir_obj do
                if entry ~= "." and entry ~= ".." and entry:sub(1, 1) ~= "." then
                    local fp   = _joinPath(dir, entry)
                    local attr = lfs.attributes(fp)
                    if attr then
                        if attr.mode == "file" then
                            local ext = entry:match("%.([^.]+)$")
                            if ext and SUPPORTED_EXT[ext:lower()] then
                                _folderHasBooks_cache[path] = true
                                return true
                            end
                        elseif attr.mode == "directory" and entry ~= ".sdr"
                                and not SYSTEM_DIR_NAMES[entry] then
                            stack[#stack + 1] = fp
                        end
                    end
                end
            end
        end
    end
    _folderHasBooks_cache[path] = false
    return false
end

-- clearFolderHasBooksCache(): call after a tab switch so the next getAll
-- scan picks up any files added during the session.
function Repo.clearFolderHasBooksCache()
    _folderHasBooks_cache = {}
end

-- _makeAllSort(sort_key): factory for the All-tab comparator. After v1.2
-- this is a thin wrapper over SortEngine using Repo.getSortPriority("all")
-- -- the sort_key argument is ignored. Kept for call-site compatibility;
-- can be deleted when callers migrate to passing tab_id.
local function _makeAllSort(_sort_key, sort_priority)
    return SortEngine.chainedComparator(sort_priority or Repo.getSortPriority("all"))
end

-- getAll(path, limit, offset) → (items, total)
-- limit/offset let callers fetch a single page slice without hydrating the
-- full list. total is always the full item count (from cache or fresh scan)
-- so callers can compute total_pages without a second trip.
local function _sortPriorityCacheKey(sort_priority)
    if type(sort_priority) ~= "table" then return "" end
    local parts = {}
    for _, level in ipairs(sort_priority) do
        parts[#parts + 1] = tostring(level.key) .. ":" .. (level.reverse and "r" or "f")
    end
    return table.concat(parts, ",")
end

function Repo.getAll(path, limit, offset, opts)
    local _t0 = _gettime()
    opts = type(opts) == "table" and opts or {}
    offset = offset or 0
    -- Explicit `path` (folder drilldown) wins; fallback resolves the
    -- user's library root and bails when it's unconfigured rather than
    -- walking "/".
    if not path then
        path = _resolveLibraryRoot()
        if not path then
            logger.warn("[bookshelf] getAll: home_dir not configured; refusing to walk")
            return {}, 0
        end
    end
    local sort_key = opts.sort_key or Repo.getSortKey("all")
    local sort_priority = opts.sort_priority or Repo.getSortPriority("all")
    local reverse  = opts.reverse
    if reverse == nil then
        reverse = BookshelfSettings.read("sort_all_reverse") == true
    end
    local mixed = opts.mixed
    if mixed == nil then
        mixed = BookshelfSettings.read("sort_all_mixed") == true
    end
    local cache_key = table.concat({
        path, sort_key, _sortPriorityCacheKey(sort_priority),
        reverse and "R" or "", mixed and "M" or "",
    }, "\0")
    local now   = os.time()
    local entry = _all_cache[cache_key]
    if entry and entry.expires_at > now then
        -- HIT: hydrate only the requested slice — skips BIM lookups for
        -- every item outside the current page.
        local total = #entry.shapes
        local out   = {}
        local stop  = limit and math.min(offset + limit, total) or total
        for i = offset + 1, stop do
            local shape = entry.shapes[i]
            if shape.kind == "folder" then
                local fb = shape.first_book_fp and _safeBuildBookMeta(shape.first_book_fp)
                local read_summary = opts.folder_read_summary
                                     and Repo.getFolderReadSummary(shape.path, 3) or nil
                out[#out + 1] = {
                    kind         = "folder",
                    path         = shape.path,
                    label        = shape.label,
                    first_book   = fb,
                    book_count   = shape.book_count,
                    read_count   = read_summary and read_summary.read_count or nil,
                    unread_count = read_summary and read_summary.unread_count or nil,
                    all_read     = read_summary and read_summary.all_read or nil,
                }
            else
                local b = _safeBuildBookMeta(shape.fp)
                if b then out[#out + 1] = b end
            end
        end
        logger.dbg(string.format("[bookshelf perf] getAll: HIT hydrate=%.0fms items=%d/%d ttl_left=%ds",
            (_gettime() - _t0) * 1000, #out, total, entry.expires_at - now))
        return out, total
    end

    -- MISS: list with lfs directly. FileChooser:genItemTableFromPath called as
    -- a class method (no instance, self.ui==nil) silently fails for any collate
    -- whose item_func needs ui (title, authors, series, keywords), and also
    -- throws on Kindle for the access collate where attr.access is nil.
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs or not lfs or not lfs.dir then
        logger.dbg("[bookshelf perf] getAll: MISS no lfs")
        return {}, 0
    end
    local ok_dir, iter, dir_obj = pcall(lfs.dir, path)
    if not ok_dir or type(iter) ~= "function" then
        logger.dbg("[bookshelf perf] getAll: MISS lfs.dir failed " .. tostring(path))
        return {}, 0
    end

    -- Gather entries with full attributes in one lfs call per entry.
    -- SYSTEM_DIR_NAMES filter keeps a `home_dir = "/"` setup off /proc,
    -- /sys, /dev so the user-visible folder list and per-folder
    -- findFirstBookIn calls stay sane.
    local entries = {}
    for entry in iter, dir_obj do
        if entry ~= "." and entry ~= ".." and entry:sub(1, 1) ~= "."
                and not SYSTEM_DIR_NAMES[entry] then
            local fp   = _joinPath(path, entry)
            local attr = lfs.attributes(fp)
            if attr and entry:sub(-4) ~= ".sdr" then
                entries[#entries + 1] = { name = entry, fp = fp, attr = attr }
            end
        end
    end

    -- Pre-fetch data required by the comparator before sorting so each
    -- comparison stays O(1). Derive needs from the priority list so that
    -- multi-key sorts (e.g. author_surname, series_index) get the right
    -- metadata swept in -- the old legacy sort_key string only triggered
    -- title/percent fetches, leaving author/series nil for those keys.
    local priority = sort_priority
    local needs = {}
    for _, level in ipairs(priority) do
        local k = level.key
        if k == "title" or k == "filename" then needs.title   = true end
        if k == "author_name" or k == "author_surname" then needs.authors = true end
        if k == "series_name" or k == "series_index"   then needs.series  = true end
        if k == "percent_read" then needs.percent  = true end
        if k == "read_status"  then needs.status   = true end
        if k == "last_opened"  then needs.last_opened = true end
    end
    -- Preserve legacy behaviour: the percent_natural sort_key needed titles
    -- in the old code; map it forward so a stale settings file still works.
    if sort_key == "percent_natural" then needs.percent = true end

    if needs.title or needs.authors or needs.series then
        local _pf_t0 = _gettime and _gettime() or 0
        -- Try the shared light-meta cache first: one batch SELECT covers
        -- all of home_dir's recursive walk, so metadata for entries within
        -- the cached range come back as O(1) lookups. Falls back to the
        -- per-book getBookInfo path for entries outside the cache (e.g.
        -- a folder drilldown into a path beyond bookshelf_latest_walk_depth).
        local home_dir = G_reader_settings:readSetting("home_dir") or "/"
        local depth    = BookshelfSettings.read("latest_walk_depth") or 3
        local light_cache = _getLightMetaCache(home_dir, depth)
        local _pf_t_cache = _gettime and _gettime() or 0
        local _pf_hits, _pf_misses = 0, 0
        local bim = getBookInfoMgr()
        for _, e in ipairs(entries) do
            if e.attr and e.attr.mode == "file" then
                local info
                if light_cache then
                    local lc = light_cache[e.fp]
                    if lc then
                        -- Check whether the cached entry has everything we need;
                        -- if authors or series are required but absent in the
                        -- light-meta record, fall through to a fresh BIM call.
                        if (not needs.authors or lc.authors ~= nil)
                                and (not needs.series or lc.series ~= nil) then
                            info = lc
                            _pf_hits = _pf_hits + 1
                        end
                    end
                end
                if not info then
                    _pf_misses = _pf_misses + 1
                    -- pcall: a single corrupt BIM row must not abort the
                    -- whole prefetch sweep -- fall back to filename for the
                    -- failing entry and keep going. get_cover=false skips
                    -- the zstd decompression + Blitbuffer allocation.
                    local ok, fresh = pcall(bim.getBookInfo, bim, e.fp, false)
                    if ok and fresh then
                        info = fresh
                    elseif not ok then
                        logger.warn("[bookshelf] getBookInfo failed for", e.fp, ":", fresh)
                    end
                end
                if info then
                    if needs.title and not e.doc_props then
                        e.doc_props = { display_title = info.title or e.name }
                    end
                    if needs.authors then
                        -- Light-cache records store authors as a table (post
                        -- splitAuthors) while direct BIM rows give the raw
                        -- string. Normalize so the surname parser always
                        -- sees a string. Join tables with "; " because
                        -- AuthorName.surnameOf's pickFirstAuthor splits on
                        -- ";" to pick the leading author.
                        local raw = info.authors
                        if type(raw) == "table" then
                            e.authors = table.concat(raw, "; ")
                        elseif type(raw) == "string" then
                            e.authors = raw
                        end
                    end
                    if needs.series then
                        -- Same shape mismatch between sources: light cache
                        -- uses series_name / series_num; raw BIM uses
                        -- series / series_index. Read either.
                        e.series       = info.series_name or info.series
                        e.series_index = tonumber(info.series_num or info.series_index)
                    end
                else
                    if needs.title and not e.doc_props then
                        e.doc_props = { display_title = e.name }
                    end
                end
            else
                if needs.title and not e.doc_props then
                    e.doc_props = { display_title = e.name }
                end
            end
        end
        local _pf_t1 = _gettime and _gettime() or 0
        logger.info(string.format(
            "[bookshelf perf] getAll prefetch: total=%.0fms (cache_load=%.0fms loop=%.0fms) entries=%d hits=%d misses=%d needs={title=%s,authors=%s,series=%s}",
            (_pf_t1 - _pf_t0) * 1000,
            (_pf_t_cache - _pf_t0) * 1000,
            (_pf_t1 - _pf_t_cache) * 1000,
            #entries, _pf_hits, _pf_misses,
            tostring(needs.title), tostring(needs.authors), tostring(needs.series)))
    end
    if needs.last_opened then
        local ReadHistory = require("readhistory")
        local rh = {}
        for _, item in ipairs(ReadHistory.hist) do
            rh[item.file] = item.time
        end
        for _, e in ipairs(entries) do
            e._last_read = rh[e.fp] or 0
        end
    end
    if needs.percent or needs.status then
        -- Route through Repo.readProgress so steady-state re-runs of this
        -- prefetch (cache TTL expired, but progress cache still warm) skip
        -- the per-file DocSettings:open() cost. readProgress also handles
        -- the pcall guard for corrupt .sdr sidecars -- a nil _pct sorts
        -- as "never opened", matching the previous behaviour.
        --
        -- summary.status is read so percent_natural can put user-marked-
        -- complete books in the finished tier even when percent_finished
        -- < 1 (e.g. user marked complete at 99% read). Without this,
        -- finished books would sort AHEAD of in-progress books because the
        -- comparator only looked at percent (issue #17).
        for _, e in ipairs(entries) do
            if e.attr and e.attr.mode == "file" then
                local pct, status = Repo.readProgress(e.fp)
                e._pct    = pct
                e._status = status
            end
        end
    end

    table.sort(entries, _makeAllSort(sort_key, sort_priority))
    if reverse then
        local n = #entries
        for i = 1, math.floor(n / 2) do
            entries[i], entries[n - i + 1] = entries[n - i + 1], entries[i]
        end
    end

    -- MISS: build the full list, cache all shapes, return just the slice.
    -- When mixed=false, partition so all folders precede all files (each
    -- partition keeps its sort order from the entries pass).
    local ordered_entries = entries
    if not mixed then
        local folders, files = {}, {}
        for _, e in ipairs(entries) do
            if e.attr.mode == "directory" then folders[#folders + 1] = e
            elseif e.attr.mode == "file" then  files[#files + 1] = e
            end
        end
        ordered_entries = {}
        for _, e in ipairs(folders) do ordered_entries[#ordered_entries + 1] = e end
        for _, e in ipairs(files)   do ordered_entries[#ordered_entries + 1] = e end
    end

    -- Build shapes only — no BIM lookups here. Skipping buildBookMeta for
    -- every book in the library is the key perf win: a 200-book library was
    -- doing 200 SQLite round-trips just to build the sort cache. Now only the
    -- current page slice (PAGE_SIZE items) triggers BIM lookups, via the
    -- hydration pass below (same code path as the HIT branch).
    local shapes = {}
    for _, e in ipairs(ordered_entries) do
        if e.attr.mode == "file" then
            local ext = e.name:match("%.([^.]+)$")
            if ext and SUPPORTED_EXT[ext:lower()] then
                shapes[#shapes + 1] = { kind = "book", fp = e.fp }
            end
        elseif e.attr.mode == "directory" then
            -- Omit folders that contain no supported book files at any depth.
            -- folderHasBooks short-circuits on the first hit and memoizes so
            -- repeated renders (cache HIT path above) stay fast.
            local summary = Repo.getFolderSummary(e.fp, 3)
            if (summary.book_count or 0) > 0 then
                shapes[#shapes + 1] = {
                    kind          = "folder",
                    path          = e.fp,
                    label         = e.name,
                    first_book_fp = summary.first_book_fp,
                    book_count    = summary.book_count,
                }
            end
        end
    end
    local total = #shapes
    _all_cache[cache_key] = { shapes = shapes, expires_at = now + WALK_CACHE_TTL }
    -- Hydrate the requested page slice exactly as the HIT path does.
    local out  = {}
    local stop = limit and math.min(offset + limit, total) or total
    for i = offset + 1, stop do
        local shape = shapes[i]
        if shape.kind == "folder" then
            local fb = shape.first_book_fp and _safeBuildBookMeta(shape.first_book_fp)
            local read_summary = opts.folder_read_summary
                                 and Repo.getFolderReadSummary(shape.path, 3) or nil
            out[#out + 1] = {
                kind         = "folder",
                path         = shape.path,
                label        = shape.label,
                first_book   = fb,
                book_count   = shape.book_count,
                read_count   = read_summary and read_summary.read_count or nil,
                unread_count = read_summary and read_summary.unread_count or nil,
                all_read     = read_summary and read_summary.all_read or nil,
            }
        else
            local b = _safeBuildBookMeta(shape.fp)
            if b then out[#out + 1] = b end
        end
    end
    logger.dbg(string.format("[bookshelf perf] getAll: MISS build=%.0fms items=%d/%d sort=%s rev=%s mixed=%s",
        (_gettime() - _t0) * 1000, #out, total, sort_key,
        tostring(reverse), tostring(mixed)))
    return out, total
end

-- ─── getFavorites ────────────────────────────────────────────────────────────
-- Returns up to `limit` Book records from ReadCollection favorites collection,
-- sorted by access time descending (most recently accessed first).

function Repo.getFavorites(limit, offset)
    local rc    = getCollections()
    local items = {}
    for _file, item in pairs(rc.coll and rc.coll.favorites or {}) do
        items[#items + 1] = item
    end
    local key = Repo.getSortKey("favorites")
    if key == "title" then
        -- Title-sort prefetch: get_cover=false skips the zstd decompression +
        -- BlitBuffer allocation per favourite. The loop reads only info.title.
        local bim = getBookInfoMgr()
        local titles = {}
        for _, item in ipairs(items) do
            local fp = item.file
            local info = bim:getBookInfo(fp, false) or {}
            titles[fp] = (info.title or (fp and fp:match("([^/]+)$")) or ""):lower()
        end
        table.sort(items, function(a, b) return titles[a.file] < titles[b.file] end)
    elseif key == "recently_read" then
        -- ReadHistory time per filepath; fall back to attr.access (collection
        -- access time) so unread favourites still sort deterministically.
        local rh        = getReadHistory()
        local read_time = {}
        for _, e in ipairs(rh.hist or {}) do
            if e.file and e.time then read_time[e.file] = e.time end
        end
        table.sort(items, function(a, b)
            local ta = read_time[a.file] or (a.attr and a.attr.access) or 0
            local tb = read_time[b.file] or (b.attr and b.attr.access) or 0
            return ta > tb
        end)
    else
        -- date_added (default): collection access time, newest first.
        table.sort(items, function(a, b)
            return (a.attr and a.attr.access or 0) > (b.attr and b.attr.access or 0)
        end)
    end
    -- Build Book records only for the visible page; total returned so the
    -- caller's _total_hint path can compute total_pages.
    local total = #items
    offset      = offset or 0
    local stop  = math.min(offset + (limit or 8), total)
    local out   = {}
    for i = offset + 1, stop do
        local book = Repo.buildBookMeta(items[i].file)
        if book then
            book.in_favorites = true
            out[#out + 1] = book
        end
    end
    return out, total
end

-- ─── getTags ─────────────────────────────────────────────────────────────────
-- Returns up to `limit` tag groups derived from KOReader's ReadCollection.
-- Skips the built-in "favorites" collection (it has its own chip). Groups
-- are { kind = "tag", series_name = collection_name, books = [...],
-- latest = max(item.attr.access) } so they flow through the same
-- SeriesStack widget + drill-down path as Series / Authors / Genres.
--
-- No shape cache here (unlike getSeriesGroups / getAuthors / getGenres):
-- ReadCollection state changes via user actions (Add to collection /
-- Remove) don't fire our walk-cache invalidation, so a TTL'd cache could
-- show stale collection contents. Per-collection book counts are usually
-- small, so the per-render rebuild cost is dominated by buildBookMeta
-- (a SQLite lookup per book) — acceptable.

-- ─── searchBooks ─────────────────────────────────────────────────────────────
-- Library-wide substring search. Walks the same cached library list used
-- by getLatest / getSeriesGroups / getAuthors etc., builds BIM-meta for
-- each candidate, and matches against a haystack of title + author(s) +
-- series_name + filename + genres. Splits the query on whitespace; every
-- word must appear somewhere in the haystack (AND match) — case-insensitive.
--
-- This is the BIM-cache-backed equivalent of "Calibre Search" in
-- KOReader-stock terms: results return instantly because the metadata is
-- pre-indexed. (KOReader's File Search walks the filesystem freshly per
-- query, which gets unusable past a few hundred books.)
function Repo.searchBooks(query, limit, scope)
    if not query or query == "" then return {} end
    local home  = G_reader_settings:readSetting("home_dir") or "/"
    local depth = BookshelfSettings.read("latest_walk_depth") or 3
    local cands = candidatesForScope(home, depth, scope)
    local words = {}
    for w in query:gmatch("%S+") do
        words[#words + 1] = w:lower()
    end
    if #words == 0 then return {} end
    local light_cache = _getLightMetaCache(home, depth)
    local out = {}
    for _, c in ipairs(cands) do
        -- _buildBookMetaLight rather than buildBookMeta: search compares
        -- text fields only, no covers required. Shared light_cache means
        -- search reuses the same BIM batch read warmed by a previous
        -- Series / Authors / Genres tab visit.
        local b = _lightMetaForFp(light_cache, c.fp)
        if b then
            -- Build a single haystack string from every searchable field
            -- so the match is one find() per word rather than per field.
            local parts = {
                (b.title       or ""):lower(),
                (b.author      or ""):lower(),
                (b.series_name or ""):lower(),
                (b.filename    or ""):lower(),
            }
            if b.authors then
                for _, a in ipairs(b.authors) do parts[#parts + 1] = a:lower() end
            end
            if b.genres then
                for _, g in ipairs(b.genres) do parts[#parts + 1] = g:lower() end
            end
            local hay = table.concat(parts, " ")
            local matches = true
            for _, w in ipairs(words) do
                if not hay:find(w, 1, true) then
                    matches = false; break
                end
            end
            if matches then
                out[#out + 1] = b
                if limit and #out >= limit then break end
            end
        end
    end
    return out
end

-- _groupShapeCmp(priority_or_key): used by series / authors / genres / tags
-- group sorters. Accepts either a v1.1 single key string OR a v1.2 priority
-- list. When a string is passed, lifts it via the legacy map.
local function _groupShapeCmp(priority_or_key)
    local priority
    if type(priority_or_key) == "string" then
        local map = {
            name        = { { key = "filename",    reverse = false } },
            latest_read = { { key = "last_opened", reverse = true  } },
            book_count  = { { key = "book_count",  reverse = true  } },
        }
        priority = map[priority_or_key] or { { key = "filename", reverse = false } }
    else
        priority = priority_or_key
    end
    return SortEngine.chainedComparator(priority)
end

function Repo.getTags(limit, sort_priority_override)
    local rc = getCollections()
    if not rc.coll then return {} end
    local groups = {}
    for coll_name, files in pairs(rc.coll) do
        if coll_name ~= "favorites" then
            local books  = {}
            local latest = 0
            for _file, item in pairs(files) do
                local book = Repo.buildBookMeta(item.file or _file)
                if book then
                    books[#books + 1] = book
                    local t = (item.attr and item.attr.access) or 0
                    if t > latest then latest = t end
                end
            end
            if #books > 0 then
                table.sort(books, function(a, b)
                    return (a.title or "") < (b.title or "")
                end)
                groups[#groups + 1] = {
                    kind        = "tag",
                    series_name = coll_name,
                    books       = books,
                    latest      = latest,
                }
            end
        end
    end
    table.sort(groups, _groupShapeCmp(sort_priority_override or Repo.getSortPriority("tags")))
    if limit and #groups > limit then
        for i = limit + 1, #groups do groups[i] = nil end
    end
    return groups
end

-- ─── getSeriesGroups ─────────────────────────────────────────────────────────
-- Returns up to `limit` series groups derived from a filesystem walk of the
-- user's library (so unread books in a series still show up, not only ones
-- in ReadHistory). Each group is { series_name, books, latest } where books
-- are sorted by series_num ascending. Groups are sorted by most recent
-- activity descending — read-time from ReadHistory when available, else the
-- file's mtime as a fallback so newly-added unread series still surface.
-- Books without a series_name are excluded.

-- Hydrate a cached series shape into a renderable group: rebuild every
-- Book record fresh via buildBookMeta. A previous version of the cache
-- stashed Book objects directly, but their cover_bb fields are owned by
-- ImageWidget and freed after each paint — reusing cached Books segv'd
-- on subsequent renders ("cover image corruption / crash going back out
-- of a series"). Caching the shape (filepath list + sort metadata) and
-- rebuilding Books on read keeps the cover_bb lifetime safe while still
-- skipping the lfs walk + the sort/group pass.
local function hydrateSeriesShape(shape)
    local books = {}
    for i, fp in ipairs(shape.filepaths) do
        if i <= 1 then
            -- Full BIM hydration: cover_bb for the single front cover rendered
            -- by SeriesStack. Only one cover is visible per group on the shelf.
            local b = Repo.buildBookMeta(fp)
            if b then books[#books + 1] = b end
        else
            -- Filepath stub: drilldown via _fetchChipItems calls buildBookMeta
            -- per-book anyway, so the stub is sufficient for that path.
            books[#books + 1] = { filepath = fp }
        end
    end
    return {
        series_name = shape.series_name,
        books       = books,
        latest      = shape.latest,
    }
end

function Repo.getSeriesGroups(limit, offset, sort_priority_override, scope)
    if scope == nil and type(sort_priority_override) == "table" and sort_priority_override.roots then
        scope = sort_priority_override
        sort_priority_override = nil
    end
    local home  = G_reader_settings:readSetting("home_dir") or "/"
    local depth = BookshelfSettings.read("latest_walk_depth") or 3
    local key   = _cacheKeyForScope(home, depth, scope)
    local now   = os.time()

    -- Cache fast path: filepaths + sort metadata are stable across renders;
    -- Books get rehydrated each read so cover_bbs are fresh. Sort runs at
    -- hydrate time so changing bookshelf_sort_series doesn't invalidate the
    -- cache.
    local cached = _series_cache[key]
    if cached and cached.expires_at > now then
        local _t0   = _gettime()
        local sk    = sort_priority_override or Repo.getSortPriority("series")
        local sorted = {}
        for _, s in ipairs(cached.groups) do sorted[#sorted + 1] = s end
        table.sort(sorted, _groupShapeCmp(sk))
        local total = #sorted
        local out   = {}
        offset      = offset or 0
        local stop  = math.min(offset + (limit or 8), total)
        for i = offset + 1, stop do
            out[#out + 1] = hydrateSeriesShape(sorted[i])
        end
        logger.dbg(string.format("[bookshelf perf] getSeriesGroups: HIT hydrate=%.0fms groups=%d/%d",
            (_gettime() - _t0) * 1000, #out, total))
        return out, total
    end

    local _t0 = _gettime()
    -- Build a filepath → read-time map so the series sort still favours
    -- series you've actually been reading lately.
    local rh        = getReadHistory()
    local read_time = {}
    for _, entry in ipairs(rh.hist) do
        local t = entry.time or 0
        if t > (read_time[entry.file] or 0) then
            read_time[entry.file] = t
        end
    end

    local candidates = candidatesForScope(home, depth, scope)
    local light_cache = _getLightMetaCache(home, depth)

    local groups = {}  -- keyed by series_name
    local order  = {}  -- preserves insertion order for deterministic tie-break
    for _, c in ipairs(candidates) do
        -- Lightweight walk: only text fields needed for grouping/sorting.
        -- Using buildBookMeta here kept all cover BlitBuffers live for the
        -- entire 2000-book walk (~120 MB peak on Calibre libraries → OOM).
        -- The shared light_cache turns ~2000 BIM prepared-statement runs into
        -- one batch SELECT for the first chip; subsequent chips (Authors,
        -- Genres) hit the same cache.
        local book = _lightMetaForFp(light_cache, c.fp)
        if book and book.series_name then
            local sname = book.series_name
            if not groups[sname] then
                groups[sname] = { series_name = sname, books = {}, latest = 0, _seen = {} }
                order[#order + 1] = sname
            end
            if not groups[sname]._seen[book.filepath] then
                groups[sname]._seen[book.filepath] = true
                groups[sname].books[#groups[sname].books + 1] = {
                    filepath   = book.filepath,
                    series_num = book.series_num,
                }
            end
            local t = read_time[book.filepath] or c.mtime or 0
            if t > groups[sname].latest then
                groups[sname].latest = t
            end
        end
    end
    -- Flatten to list. Sort runs at hydrate time on the cached shapes (see
    -- HIT branch / MISS hydrate below), so a sort menu change re-renders
    -- without a re-walk.
    local list = {}
    for _, k in ipairs(order) do list[#list + 1] = groups[k] end
    -- Within each group, sort books by series_num ascending. Also remove _seen helper.
    for _, g in ipairs(list) do
        g._seen = nil
        table.sort(g.books, function(a, b)
            return (tonumber(a.series_num) or 0) < (tonumber(b.series_num) or 0)
        end)
    end

    -- Stash the SHAPE (filepaths + sort metadata) — never the Book
    -- records themselves. That avoids the use-after-free on the
    -- ImageWidget-owned cover_bbs that books carry.
    local shapes = {}
    for _, group in ipairs(list) do
        local fps = {}
        for _, b in ipairs(group.books) do fps[#fps + 1] = b.filepath end
        shapes[#shapes + 1] = {
            series_name = group.series_name,
            filepaths   = fps,
            latest      = group.latest,
        }
    end
    _series_cache[key] = { groups = shapes, expires_at = now + SERIES_CACHE_TTL }

    -- MISS path: sort shapes and hydrate the current page, matching the
    -- HIT path. Both paths now go through hydrateSeriesShape so cover_bb
    -- lifetime is identical regardless of cache state.
    local sk = sort_priority_override or Repo.getSortPriority("series")
    local sorted = {}
    for _, s in ipairs(shapes) do sorted[#sorted + 1] = s end
    table.sort(sorted, _groupShapeCmp(sk))

    local total = #sorted
    local out   = {}
    offset      = offset or 0
    local stop  = math.min(offset + (limit or 8), total)
    for i = offset + 1, stop do out[#out + 1] = hydrateSeriesShape(sorted[i]) end
    logger.dbg(string.format("[bookshelf perf] getSeriesGroups: MISS build=%.0fms cands=%d groups=%d/%d",
        (_gettime() - _t0) * 1000, #candidates, #out, total))
    return out, total
end

-- ─── getAuthors / getGenres ──────────────────────────────────────────────────
-- Both return GroupGroup records shaped like the series-group records, so
-- they can flow through the same SeriesStack widget on the shelf and the
-- same drill-down path. Differences encoded via group.kind ("author" /
-- "genre"); the band-text field stays `series_name` so SeriesStack
-- doesn't need a bespoke parameter for each kind.
--
-- Authors: keyed on book.author (single primary author). Books with no
-- author are skipped — the Author tab is implicitly "named authors only".
-- Genres: keyed on each entry of book.genres (multi-tag — a book with
-- "Sci-Fi, Fantasy" appears under both groups).
--
-- Both share the same caching pattern as getSeriesGroups: cache the SHAPE
-- (filepaths + sort metadata), rehydrate Books on read.

local function _hydrateGroupShape(shape)
    local books = {}
    for i, fp in ipairs(shape.filepaths) do
        if i <= 1 then
            -- Full BIM hydration: cover_bb for the single front cover rendered
            -- by SeriesStack. Only one cover is visible per group on the shelf.
            local b = Repo.buildBookMeta(fp)
            if b then books[#books + 1] = b end
        else
            -- Stub: drilldown re-hydrates via _fetchChipItems anyway.
            books[#books + 1] = { filepath = fp }
        end
    end
    return {
        kind         = shape.kind,
        series_name  = shape.series_name,
        books        = books,
        books_meta   = shape.books_meta,  -- carried for drill-time re-sort
        latest       = shape.latest,
        latest_added = shape.latest_added,
    }
end

-- _buildGroups(group_kind, key_fn, multi)
-- Walks the library, groups books by key_fn(book), returns sorted groups.
-- key_fn: (book) -> string | nil  for single-key (multi=false)
-- key_fn: (book) -> table[string] | nil  for multi-key (multi=true)
-- _normalizeGenre(s): case-insensitive + simple-plural-aware key used to
-- group genre strings. "Social Sciences" and "Social Science" collapse
-- into one group; "Mystery" and "mystery" likewise. Strips trailing 's'
-- for words longer than 3 chars (covers most English plurals); rare
-- irregular cases like "series" -> "serie" are acceptable since those
-- aren't typical genre tags.
--
-- Memoized: _buildGroups can call this 12k+ times on a 3k-book library
-- (each book has ~4 genres). With a per-string cache, repeated genre
-- strings (which dominate -- ~50 unique genres in a typical library)
-- cost one lookup after the first parse.
--
-- Only applied for group_kind == "genre" in _buildGroups. Authors keep
-- their case-sensitive identity (case is part of an author's identity
-- on some libraries with stylized spellings).
local _normalize_genre_cache = {}
local function _normalizeGenre(s)
    if not s or s == "" then return "" end
    local cached = _normalize_genre_cache[s]
    if cached ~= nil then return cached end
    local lower = s:lower():gsub("^%s+", ""):gsub("%s+$", "")
    if #lower > 3 and lower:sub(-1) == "s" then
        lower = lower:sub(1, -2)
    end
    _normalize_genre_cache[s] = lower
    return lower
end

local function _buildGroups(group_kind, key_fn, multi, scope)
    local _t0 = _gettime()
    local home  = G_reader_settings:readSetting("home_dir") or "/"
    local depth = BookshelfSettings.read("latest_walk_depth") or 3
    -- Read history → filepath read-time map so groups sort by recently-read.
    local rh        = getReadHistory()
    local read_time = {}
    for _, entry in ipairs(rh.hist) do
        local t = entry.time or 0
        if t > (read_time[entry.file] or 0) then read_time[entry.file] = t end
    end
    local cands = candidatesForScope(home, depth, scope)
    local light_cache = _getLightMetaCache(home, depth)
    local groups = {}
    local order  = {}
    for _, c in ipairs(cands) do
        -- Lightweight walk: text fields only, no cover_bb.
        -- See _buildBookMetaLight for the memory rationale; shared
        -- light_cache means the second + third group chip (Authors after
        -- Series, Genres after Authors) reuse the same BIM batch read.
        local book = _lightMetaForFp(light_cache, c.fp)
        if book then
            local keys = key_fn(book)
            if keys then
                if not multi then keys = { keys } end
                for _, raw_k in ipairs(keys) do
                    if raw_k and raw_k ~= "" then
                        -- For genre groups, key on the normalized form so
                        -- case + plural variants collapse together; for
                        -- other kinds the raw string IS the identity.
                        local lookup_k = (group_kind == "genre")
                            and _normalizeGenre(raw_k) or raw_k
                        local g = groups[lookup_k]
                        if not g then
                            g = {
                                kind        = group_kind,
                                series_name = raw_k,  -- first-seen variant displays
                                books       = {},
                                latest      = 0,
                                _seen       = {},
                            }
                            groups[lookup_k] = g
                            order[#order + 1] = lookup_k
                        end
                        if not g._seen[book.filepath] then
                            g._seen[book.filepath] = true
                            -- Enrich the within-group book record with the
                            -- sort-relevant fields available from light meta
                            -- + walk. Enables sort_priority levels 2+ on
                            -- group tabs to order books within each group
                            -- without an extra BIM read at drill time.
                            local rt = read_time[book.filepath] or 0
                            g.books[#g.books + 1] = {
                                filepath     = book.filepath,
                                title        = book.title,
                                series_name  = book.series_name,
                                series_index = tonumber(book.series_num),
                                author       = book.author,
                                authors      = book.authors,
                                _last_read   = rt,
                                date_added   = c.mtime or 0,
                                size         = c.size or 0,
                            }
                        end
                        -- group.latest: strict max READ TIME across
                        -- members (powers "Most recently read"). Books
                        -- that have never been opened (no ReadHistory
                        -- entry) don't contribute -- a genre with zero
                        -- read books ends up at latest=0 and sorts to
                        -- the end via SORT_TO_END. Adding a book to the
                        -- device doesn't count as reading it.
                        local rt = read_time[book.filepath]
                        if rt and rt > g.latest then g.latest = rt end
                        -- group.latest_added: max file mtime across
                        -- members. Powers "Most recently added" --
                        -- changes when files land in your library,
                        -- regardless of read state.
                        local m = c.mtime or 0
                        if m > (g.latest_added or 0) then g.latest_added = m end
                    end
                end
            end
        end
    end
    local list = {}
    for _, k in ipairs(order) do list[#list + 1] = groups[k] end
    -- Insertion order; getAuthors/getGenres/getTags sort at hydrate time
    -- via _groupShapeCmp on the cached shapes.
    --
    -- Within-group default: series_name -> series_index -> title. Books in
    -- a series cluster together in series order; standalones (no series)
    -- fall to the end via SORT_TO_END and tie-break on title. This is the
    -- baseline that Authors / Genres / Series / Tags / Formats tabs use
    -- until the user overrides via sort_priority levels 2+.
    local default_within = {
        { key = "series_name",  reverse = false },
        { key = "series_index", reverse = false },
        { key = "title",        reverse = false },
    }
    local within_cmp = SortEngine.chainedComparator(default_within)
    for _, g in ipairs(list) do
        g._seen = nil
        table.sort(g.books, within_cmp)
    end
    logger.dbg(string.format("[bookshelf perf] _buildGroups(%s): %.0fms cands=%d groups=%d",
        group_kind, (_gettime() - _t0) * 1000, #cands, #list))
    return list
end

local function _cacheGroupShapes(list, kind)
    local shapes = {}
    for _, group in ipairs(list) do
        local fps        = {}
        local books_meta = {}
        for _, b in ipairs(group.books) do
            fps[#fps + 1] = b.filepath
            -- Copy the sort-relevant fields. Carried in the shape so a
            -- per-tab within-group re-sort (drill-time, sort_priority[2+])
            -- has data without going back to the BIM/light cache.
            books_meta[#books_meta + 1] = {
                filepath     = b.filepath,
                title        = b.title,
                series_name  = b.series_name,
                series_index = b.series_index,
                author       = b.author,
                authors      = b.authors,
                _last_read   = b._last_read,
                date_added   = b.date_added,
                size         = b.size,
            }
        end
        shapes[#shapes + 1] = {
            kind         = kind,
            series_name  = group.series_name,
            filepaths    = fps,
            books_meta   = books_meta,
            latest       = group.latest,
            latest_added = group.latest_added or 0,
        }
    end
    return shapes
end

function Repo.getAuthors(limit, offset, sort_priority_override, scope)
    if scope == nil and type(sort_priority_override) == "table" and sort_priority_override.roots then
        scope = sort_priority_override
        sort_priority_override = nil
    end
    local _t0 = _gettime()
    local home  = G_reader_settings:readSetting("home_dir") or "/"
    local depth = BookshelfSettings.read("latest_walk_depth") or 3
    local key   = _cacheKeyForScope(home, depth, scope)
    local now   = os.time()
    local cached = _authors_cache[key]
    local _hit = cached and cached.expires_at > now
    if not _hit then
        local list = _buildGroups("author", function(b) return b.author end, false, scope)
        _authors_cache[key] = {
            groups     = _cacheGroupShapes(list, "author"),
            expires_at = now + SERIES_CACHE_TTL,
        }
        cached = _authors_cache[key]
    end
    -- Always hydrate (even right after a build): _buildGroups can reuse
    -- the same Book record across groups when a book has multiple keys,
    -- and the resulting shared cover_bb segfaults when one SeriesStack
    -- frees it while another still holds the reference. Hydrating from
    -- shapes calls buildBookMeta per group → independent cover_bbs.
    --
    -- sort_priority_override: when a CUSTOM tab uses kind="authors" as its
    -- source (the user repurposed e.g. the Home tab to show the Authors
    -- view), getBySource passes that tab's sort_priority through here so
    -- the user's sort applies. Without it we'd hardcode the lookup to
    -- tab_id="authors" and miss any tab whose id is different.
    local sk = sort_priority_override or Repo.getSortPriority("authors")
    local sorted = {}
    for _, s in ipairs(cached.groups) do sorted[#sorted + 1] = s end
    table.sort(sorted, _groupShapeCmp(sk))
    local total = #sorted
    local out   = {}
    offset      = offset or 0
    local stop  = math.min(offset + (limit or 8), total)
    for i = offset + 1, stop do
        out[#out + 1] = _hydrateGroupShape(sorted[i])
    end
    logger.dbg(string.format("[bookshelf perf] getAuthors: %s %.0fms groups=%d/%d",
        _hit and "HIT" or "MISS", (_gettime() - _t0) * 1000, #out, total))
    return out, total
end

function Repo.getGenres(limit, offset, sort_priority_override, scope)
    if scope == nil and type(sort_priority_override) == "table" and sort_priority_override.roots then
        scope = sort_priority_override
        sort_priority_override = nil
    end
    local _t0 = _gettime()
    local home  = G_reader_settings:readSetting("home_dir") or "/"
    local depth = BookshelfSettings.read("latest_walk_depth") or 3
    local key   = _cacheKeyForScope(home, depth, scope)
    local now   = os.time()
    local cached = _genres_cache[key]
    local _hit = cached and cached.expires_at > now
    if not _hit then
        local list = _buildGroups("genre", function(b) return b.genres end, true, scope)
        _genres_cache[key] = {
            groups     = _cacheGroupShapes(list, "genre"),
            expires_at = now + SERIES_CACHE_TTL,
        }
        cached = _genres_cache[key]
    end
    -- Always hydrate from shapes — see getAuthors above. For genres
    -- (multi=true), a single book in "Sci-Fi, Fantasy" appears in both
    -- groups; without fresh Book records per group both SeriesStacks
    -- share the same cover_bb and the first to free it segfaults the
    -- second. This was the cause of the genres-tab crash on first tap.
    local sk = sort_priority_override or Repo.getSortPriority("genres")
    local sorted = {}
    for _, s in ipairs(cached.groups) do sorted[#sorted + 1] = s end
    table.sort(sorted, _groupShapeCmp(sk))
    local total = #sorted
    local out   = {}
    offset      = offset or 0
    local stop  = math.min(offset + (limit or 8), total)
    for i = offset + 1, stop do
        out[#out + 1] = _hydrateGroupShape(sorted[i])
    end
    logger.dbg(string.format("[bookshelf perf] getGenres: %s %.0fms groups=%d/%d",
        _hit and "HIT" or "MISS", (_gettime() - _t0) * 1000, #out, total))
    return out, total
end

-- Lightweight choice list for the "Specific Series / Author / Genre / Format"
-- picker. Returns [{value, label, count}, ...] without hydrating book records
-- or loading cover_bbs. Reads directly from the cached shapes so calling
-- this is a single table iteration on cached data once the underlying cache
-- is warm. For a 200-author library this is ~ms vs ~1-2s for the previous
-- path that ran _hydrateGroupShape on every group (one buildBookMeta +
-- cover decompression per group, ALL of it discarded by the picker).
function Repo.getGroupChoices(kind)
    local home  = G_reader_settings:readSetting("home_dir") or "/"
    local depth = BookshelfSettings.read("latest_walk_depth") or 3
    local key   = (home or "/") .. ":" .. tostring(depth or 0)

    local cache_for_kind = {
        series = _series_cache,
        author = _authors_cache,
        genre  = _genres_cache,
        format = _formats_cache,
        rating = _ratings_cache,
    }
    local store = cache_for_kind[kind]
    if not store then return {} end

    -- Ensure the underlying cache is built. limit=0 makes the fetcher's
    -- hydration loop skip while still running the cache-build + sort.
    if not store[key] then
        if     kind == "series" then Repo.getSeriesGroups(0, 0)
        elseif kind == "author" then Repo.getAuthors(0, 0)
        elseif kind == "genre"  then Repo.getGenres(0, 0)
        elseif kind == "format" then Repo.getFormats(0, 0)
        elseif kind == "rating" then Repo.getRatings(0, 0)
        end
    end

    local cache = store[key]
    if not cache or not cache.groups then return {} end

    local out = {}
    for _, s in ipairs(cache.groups) do
        out[#out + 1] = {
            value = s.series_name or "",
            label = s.series_name or "",
            count = s.filepaths and #s.filepaths or 0,
        }
    end
    return out
end

-- Build a normalized format string from a filepath. UPPERCASE because that's
-- how the rest of bookshelf (book detail, etc.) presents formats. Returns nil
-- for files with no extension so _buildGroups skips them.
local function _formatKey(fp)
    if not fp then return nil end
    local ext = fp:match("%.([^.]+)$")
    if not ext or ext == "" then return nil end
    return ext:upper()
end

function Repo.getFormats(limit, offset, sort_priority_override)
    local _t0 = _gettime()
    local home  = G_reader_settings:readSetting("home_dir") or "/"
    local depth = BookshelfSettings.read("latest_walk_depth") or 3
    local key   = (home or "/") .. ":" .. tostring(depth or 0)
    local now   = os.time()
    local cached = _formats_cache[key]
    local _hit = cached and cached.expires_at > now
    if not _hit then
        local list = _buildGroups("format", function(b) return _formatKey(b.filepath) end, false)
        _formats_cache[key] = {
            groups     = _cacheGroupShapes(list, "format"),
            expires_at = now + SERIES_CACHE_TTL,
        }
        cached = _formats_cache[key]
    end
    -- Hydrate from shapes for the same reason as authors/genres -- _buildGroups
    -- reuses Book records across groups, and shared cover_bb would segfault on
    -- the second free.
    local sk = sort_priority_override or Repo.getSortPriority("formats")
    local sorted = {}
    for _, s in ipairs(cached.groups) do sorted[#sorted + 1] = s end
    table.sort(sorted, _groupShapeCmp(sk))
    local total = #sorted
    local out   = {}
    offset      = offset or 0
    local stop  = math.min(offset + (limit or 8), total)
    for i = offset + 1, stop do
        out[#out + 1] = _hydrateGroupShape(sorted[i])
    end
    logger.dbg(string.format("[bookshelf perf] getFormats: %s %.0fms groups=%d/%d",
        _hit and "HIT" or "MISS", (_gettime() - _t0) * 1000, #out, total))
    return out, total
end

-- UTF-8 star characters for the rating group display labels. Used as
-- the group's series_name so chip + breadcrumb render '★★★★★' etc.
local _STAR_REPEAT = {
    [1] = "\xE2\x98\x85",
    [2] = "\xE2\x98\x85\xE2\x98\x85",
    [3] = "\xE2\x98\x85\xE2\x98\x85\xE2\x98\x85",
    [4] = "\xE2\x98\x85\xE2\x98\x85\xE2\x98\x85\xE2\x98\x85",
    [5] = "\xE2\x98\x85\xE2\x98\x85\xE2\x98\x85\xE2\x98\x85\xE2\x98\x85",
}

-- Build the rating groups: walk the library, look up each book's
-- rating via Repo.readProgress (cached + .sdr fast-path), bucket by
-- rating value or 'Unrated'. Books without a .sdr are treated as
-- Unrated without a DocSettings open.
local function _buildRatingGroups()
    local home  = G_reader_settings:readSetting("home_dir") or "/"
    local depth = BookshelfSettings.read("latest_walk_depth") or 3
    local cands = cachedWalk(home, depth)
    local light_cache = _getLightMetaCache(home, depth)
    local rh         = getReadHistory()
    local read_time  = {}
    for _, entry in ipairs(rh.hist) do
        local t = entry.time or 0
        if t > (read_time[entry.file] or 0) then read_time[entry.file] = t end
    end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    local lfs_attr = ok_lfs and lfs and lfs.attributes or nil
    local buckets = { [1]={}, [2]={}, [3]={}, [4]={}, [5]={}, unrated={} }
    for _, c in ipairs(cands) do
        local book = _lightMetaForFp(light_cache, c.fp)
        if book then
            local rating
            local sdr_path = c.fp:gsub("%.[^.]+$", "") .. ".sdr"
            if lfs_attr and lfs_attr(sdr_path, "mode") == "directory" then
                local _p, _s, r = Repo.readProgress(c.fp)
                rating = r
            end
            local bk = rating or "unrated"
            local b_meta = {
                filepath     = c.fp,
                title        = book.title,
                series_name  = book.series_name,
                series_index = tonumber(book.series_num),
                author       = book.author,
                authors      = book.authors,
                _last_read   = read_time[c.fp] or 0,
                date_added   = c.mtime or 0,
                size         = c.size or 0,
                rating       = rating,
            }
            local bucket = buckets[bk]
            bucket[#bucket + 1] = b_meta
        end
    end
    -- Sort books within each bucket via the standard within-group order.
    local SortEngine = require("lib/bookshelf_sort_engine")
    local within_cmp = SortEngine.chainedComparator{
        { key = "series_name",  reverse = false },
        { key = "series_index", reverse = false },
        { key = "title",        reverse = false },
    }
    local groups = {}
    for _, key in ipairs({5, 4, 3, 2, 1, "unrated"}) do
        local books_meta = buckets[key]
        if #books_meta > 0 then
            table.sort(books_meta, within_cmp)
            local g = {
                kind        = "rating",
                series_name = key == "unrated" and "Unrated" or _STAR_REPEAT[key],
                books       = {},
                latest      = 0,
                avg_rating  = key == "unrated" and 0 or key,
            }
            for _, b in ipairs(books_meta) do
                g.books[#g.books + 1] = b
                local t = b._last_read or 0
                if t > g.latest then g.latest = t end
            end
            groups[#groups + 1] = g
        end
    end
    return groups
end

function Repo.getRatings(limit, offset, sort_priority_override)
    local _t0 = _gettime()
    local home  = G_reader_settings:readSetting("home_dir") or "/"
    local depth = BookshelfSettings.read("latest_walk_depth") or 3
    local key   = (home or "/") .. ":" .. tostring(depth or 0)
    local now   = os.time()
    local cached = _ratings_cache[key]
    local _hit = cached and cached.expires_at > now
    if not _hit then
        local list = _buildRatingGroups()
        _ratings_cache[key] = {
            groups     = _cacheGroupShapes(list, "rating"),
            expires_at = now + SERIES_CACHE_TTL,
        }
        cached = _ratings_cache[key]
    end
    local sk = sort_priority_override or Repo.getSortPriority("ratings")
    local sorted = {}
    for _, s in ipairs(cached.groups) do sorted[#sorted + 1] = s end
    table.sort(sorted, _groupShapeCmp(sk))
    local total = #sorted
    local out   = {}
    offset      = offset or 0
    local stop  = math.min(offset + (limit or 8), total)
    for i = offset + 1, stop do
        out[#out + 1] = _hydrateGroupShape(sorted[i])
    end
    logger.dbg(string.format("[bookshelf perf] getRatings: %s %.0fms groups=%d/%d",
        _hit and "HIT" or "MISS", (_gettime() - _t0) * 1000, #out, total))
    return out, total
end

-- ─── searchAll ───────────────────────────────────────────────────────────────
-- Returns { folders, authors, series, genres, books } for a query string.
-- All matching is case-insensitive substring. Returns empty lists immediately
-- for a blank query.
function Repo.searchAll(query, scope)
    local empty = { folders = {}, authors = {}, series = {}, genres = {}, books = {} }
    if not query or query == "" then return empty end
    local q = query:lower()

    -- ── folders ──
    -- Derive from the already-cached walk: unique parent directories whose
    -- basename matches the query. No disk I/O: cachedWalk returns { fp, mtime }.
    local home  = G_reader_settings:readSetting("home_dir") or "/"
    local depth = BookshelfSettings.read("latest_walk_depth") or 3
    local key   = _cacheKeyForScope(home, depth, scope)
    local cands = candidatesForScope(home, depth, scope)
    local seen_dirs = {}
    local folders = {}
    for _, c in ipairs(cands) do
        local dir = c.fp:match("^(.*)/[^/]+$") or "/"
        if not seen_dirs[dir] then
            seen_dirs[dir] = true
            local basename = dir:match("([^/]+)$") or dir
            if basename:lower():find(q, 1, true) then
                local first_book = Repo.buildBookMeta(c.fp)
                folders[#folders + 1] = {
                    kind       = "folder",
                    path       = dir,
                    label      = basename,
                    first_book = first_book,
                }
            end
        end
    end

    -- ── author / series / genre groups ──
    -- Warm each shape cache with limit=0 (populates the cache without
    -- hydrating any groups — in Lua, 0 is truthy so `0 or 8` = 0, giving
    -- an empty loop but still running the _buildGroups fill). Then iterate
    -- shapes directly and hydrate only matching entries, avoiding the cost
    -- of hydrating the full collection just to filter it.
    local function matchGroups(cache_table)
        if not cache_table[key] then return {} end
        local out = {}
        for _, shape in ipairs(cache_table[key].groups) do
            if (shape.series_name or ""):lower():find(q, 1, true) then
                out[#out + 1] = _hydrateGroupShape(shape)
            end
        end
        return out
    end
    Repo.getAuthors(0, 0, nil, scope)
    Repo.getSeriesGroups(0, 0, nil, scope)
    Repo.getGenres(0, 0, nil, scope)

    local authors = matchGroups(_authors_cache)
    local series  = matchGroups(_series_cache)
    local genres  = matchGroups(_genres_cache)

    -- ── books ──
    local books = Repo.searchBooks(query, 200, scope) or {}

    return { folders = folders, authors = authors, series = series, genres = genres, books = books }
end

-- ─── findGroup ───────────────────────────────────────────────────────────────
-- Searches the in-memory shape cache for a group whose series_name matches
-- `name` (case-insensitive exact match) and hydrates just that one group.
-- When the relevant cache is cold (e.g. the user long-presses a book on the
-- Recent tab without ever having visited the Authors tab this session),
-- warms it via the matching getter so the lookup actually finds the full
-- group instead of falling back to a single-book stub. Returns nil when:
-- kind is unrecognised, or no group matches the name even after warming.
function Repo.findGroup(kind, name, scope)
    if not name or name == "" then return nil end
    local home  = G_reader_settings:readSetting("home_dir") or "/"
    local depth = BookshelfSettings.read("latest_walk_depth") or 3
    local key   = _cacheKeyForScope(home, depth, scope)
    local cache
    if     kind == "author" then cache = _authors_cache[key]
    elseif kind == "series" then cache = _series_cache[key]
    elseif kind == "genre"  then cache = _genres_cache[key]
    elseif kind == "format" then cache = _formats_cache[key]
    elseif kind == "rating" then cache = _ratings_cache[key]
    else return nil end
    if not cache then
        if     kind == "author" then Repo.getAuthors(0, 0, nil, scope);      cache = _authors_cache[key]
        elseif kind == "series" then Repo.getSeriesGroups(0, 0, nil, scope); cache = _series_cache[key]
        elseif kind == "genre"  then Repo.getGenres(0, 0, nil, scope);       cache = _genres_cache[key]
        elseif kind == "format" then Repo.getFormats(0, 0);      cache = _formats_cache[key]
        elseif kind == "rating" then Repo.getRatings(0, 0);      cache = _ratings_cache[key]
        end
        if not cache then return nil end
    end
    local lname = name:lower()
    for _, shape in ipairs(cache.groups) do
        if (shape.series_name or ""):lower() == lname then
            return _hydrateGroupShape(shape)
        end
    end
    return nil
end

function Repo.getNextUnreadInSeries(limit, offset, scope)
    local _t0 = _gettime()
    local home  = G_reader_settings:readSetting("home_dir") or "/"
    local depth = BookshelfSettings.read("latest_walk_depth") or 3
    local cands = candidatesForScope(home, depth, scope)
    local light_cache = _getLightMetaCache(home, depth)
    local natsort = require("sort").natsort_cmp()

    local read_time = {}
    for _, entry in ipairs(getReadHistory().hist) do
        local t = entry.time or 0
        if t > (read_time[entry.file] or 0) then read_time[entry.file] = t end
    end

    local groups, order = {}, {}
    for _, c in ipairs(cands) do
        local book = _lightMetaForFp(light_cache, c.fp)
        if book and book.series_name then
            local pct, status = Repo.readProgress(book.filepath)
            local sname = book.series_name
            local group = groups[sname]
            if not group then
                group = { series_name = sname, books = {} }
                groups[sname] = group
                order[#order + 1] = sname
            end
            group.books[#group.books + 1] = {
                filepath   = book.filepath,
                title      = book.title,
                series_num = tonumber(book.series_num),
                pct        = pct,
                status     = status,
                read_time  = read_time[book.filepath] or 0,
            }
        end
    end

    local function book_cmp(a, b)
        if a.series_num and b.series_num and a.series_num ~= b.series_num then
            return a.series_num < b.series_num
        end
        if a.series_num and not b.series_num then return true end
        if b.series_num and not a.series_num then return false end
        return natsort(a.title or a.filepath or "", b.title or b.filepath or "")
    end

    local picks = {}
    for _, sname in ipairs(order) do
        local books = groups[sname].books
        table.sort(books, book_cmp)

        local latest_completed_idx, latest_completed_time = nil, 0
        local in_progress
        local started = false
        for i, b in ipairs(books) do
            local pct = b.pct or 0
            local finished = b.status == "finished" or b.status == "complete" or pct >= 1
            local reading = not finished and (b.status == "reading" or b.status == "on_hold"
                or b.status == "abandoned" or (pct > 0 and pct < 1))
            if reading then
                started = true
                if not in_progress or (b.read_time or 0) > (in_progress.read_time or 0) then
                    in_progress = b
                end
            end
            if finished then
                started = true
                latest_completed_idx = i
                latest_completed_time = math.max(latest_completed_time, b.read_time or 0)
            end
            if b.read_time and b.read_time > 0 then started = true end
        end

        local pick = in_progress
        if not pick and started and latest_completed_idx then
            for i = latest_completed_idx + 1, #books do
                local b = books[i]
                local pct = b.pct or 0
                local finished = b.status == "finished" or b.status == "complete" or pct >= 1
                if not finished then
                    pick = b
                    break
                end
            end
        end
        if pick then
            picks[#picks + 1] = {
                filepath = pick.filepath,
                latest_completed_time = latest_completed_time > 0 and latest_completed_time
                    or (pick.read_time or 0),
                series_name = sname,
            }
        end
    end

    table.sort(picks, function(a, b)
        if a.latest_completed_time ~= b.latest_completed_time then
            return a.latest_completed_time > b.latest_completed_time
        end
        return (a.series_name or ""):lower() < (b.series_name or ""):lower()
    end)

    offset = offset or 0
    local total = #picks
    local out = {}
    local stop = math.min(offset + (limit or 8), total)
    for i = offset + 1, stop do
        local b = Repo.buildBookMeta(picks[i].filepath)
        if b then out[#out + 1] = b end
    end
    logger.dbg(string.format("[bookshelf perf] getNextUnreadInSeries: %.0fms cands=%d picks=%d/%d",
        (_gettime() - _t0) * 1000, #cands, #out, total))
    return out, total
end

-- ─── enrichStats ─────────────────────────────────────────────────────────────
-- Mutates `book` in-place with statistics fields from readerstatistics.
-- Graceful no-op when the statistics plugin is absent or its API method is nil.
--
-- CONTRACT: ReaderStatistics:getBookStat(filepath) is the intended public API
-- boundary for v0.1. As of 2026-05, upstream KOReader does not expose this
-- exact method — getBookStat() does not exist in the KOReader codebase.
-- The pcall + nil-guard means we fall through silently and all stat-based
-- tokens auto-hide via Tokens.isEmpty. When the upstream API stabilises,
-- update this single function — that's why the boundary is isolated here.

-- enrichStats — fill the book record with reading-statistics fields.
-- Queries the statistics plugin's SQLite DB directly: ReaderStatistics
-- doesn't expose a clean filepath-keyed API, only an integer id_book and
-- KeyValuePage-shaped output for its Reader-context UI. We compute the
-- file's partial MD5 (the same key the stats plugin uses) and read the
-- rolled-up fields from the `book` table plus a couple of derived stats
-- from `page_stat_data` for days-reading / pages-per-day / speed.
--
-- Per-filepath cache with TTL: fires on every hero rebuild + every preview
-- tap, and the SQLite open + 3 prepared queries adds up across an
-- interactive session. Cached fields are mutated into the passed-in book
-- on subsequent calls within TTL. Invalidate via Repo.invalidateStatsCache()
-- (called from onCloseDocument so freshly-read pages surface immediately).
local STATS_CACHE_TTL = 30  -- seconds
local _stats_cache = {}     -- filepath → { fields = {...}, expires_at = number }
local STATS_FIELDS = {
    "book_read_time_seconds", "book_pages_read", "days_reading_book",
    "pages_per_day", "speed_pph", "book_time_left_minutes",
}

function Repo.invalidateStatsCache(filepath)
    if filepath then _stats_cache[filepath] = nil
    else _stats_cache = {} end
end

function Repo.enrichStats(book)
    if not book or not book.filepath then return end
    local now = os.time()
    local cached = _stats_cache[book.filepath]
    if cached and cached.expires_at > now then
        for _, k in ipairs(STATS_FIELDS) do book[k] = cached.fields[k] end
        return
    end
    -- ReaderStatistics keys books by `partial_md5_checksum` stored in the
    -- DocSettings sidecar (statistics/main.lua:2740). Read from there
    -- first; fall back to recomputing only if the sidecar is missing.
    local md5
    local ok_ds, ds = pcall(function() return getDocSettings():open(book.filepath) end)
    if ok_ds and ds and ds.readSetting then
        md5 = ds:readSetting("partial_md5_checksum")
    end
    if not md5 then
        local ok_util, util = pcall(require, "util")
        if ok_util and util and util.partialMD5 then
            md5 = util.partialMD5(book.filepath)
        end
    end
    if not md5 then return end

    local ok_ds, DataStorage = pcall(require, "datastorage")
    local ok_sq, SQ3         = pcall(require, "lua-ljsqlite3/init")
    if not (ok_ds and DataStorage and ok_sq and SQ3) then return end
    local db_path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"

    local ok_conn, conn = pcall(SQ3.open, db_path)
    if not ok_conn or not conn then return end

    -- Roll-ups from the book table (kept in sync by ReaderStatistics).
    local id_book, total_read_time, total_read_pages, pages_total
    local ok_q, err = pcall(function()
        local stmt = conn:prepare(
            "SELECT id, total_read_time, total_read_pages, pages "
            .. "FROM book WHERE md5 = ? LIMIT 1")
        local row = stmt:reset():bind(md5):step()
        stmt:close()
        if row then
            id_book          = tonumber(row[1])
            total_read_time  = tonumber(row[2]) or 0
            total_read_pages = tonumber(row[3]) or 0
            pages_total      = tonumber(row[4]) or 0
        end
    end)
    if not ok_q or not id_book then conn:close(); return end

    -- Days-reading + first-open + last-page from page_stat_data, same query
    -- shape as ReaderStatistics:getBookStat.
    local total_days, first_open
    pcall(function()
        local stmt = conn:prepare(
            "SELECT count(*) FROM ("
            .. "  SELECT strftime('%Y-%m-%d', start_time, 'unixepoch', 'localtime') AS d "
            .. "  FROM page_stat_data WHERE id_book = ? GROUP BY d)")
        local row = stmt:reset():bind(id_book):step()
        stmt:close()
        total_days = row and tonumber(row[1]) or 0
    end)
    pcall(function()
        local stmt = conn:prepare(
            "SELECT min(start_time) FROM page_stat_data WHERE id_book = ?")
        local row = stmt:reset():bind(id_book):step()
        stmt:close()
        first_open = row and tonumber(row[1]) or nil
    end)
    -- Capped per-page totals for avg_time: mirrors ReaderStatistics's
    -- self.avg_time (statistics.koplugin/main.lua:41 + 999). Per-page
    -- duration is capped at max_sec so outlier sessions don't inflate
    -- the average. page_stat is a VIEW that rescales pages to handle
    -- font-size changes. (#38.)
    local stats = G_reader_settings:readSetting("statistics")
    local max_sec = (stats and stats.max_sec) or 120
    local capped_pages, capped_time
    pcall(function()
        local stmt = conn:prepare(
            "SELECT count(*), sum(d) FROM (SELECT min(sum(duration), ?) AS d "
            .. "FROM page_stat WHERE id_book = ? GROUP BY page)")
        local row = stmt:reset():bind(max_sec, id_book):step()
        stmt:close()
        if row then
            capped_pages, capped_time = tonumber(row[1]), tonumber(row[2])
        end
    end)
    conn:close()

    -- Roll-up derived fields. Defensive math: pages_total/total_read_pages
    -- can be 0 on a freshly-tracked book; guard divisions.
    book.book_read_time_seconds = total_read_time
    book.book_pages_read        = total_read_pages
    book.days_reading_book      = total_days
    if total_days > 0 then
        book.pages_per_day = math.floor(total_read_pages / total_days + 0.5)
    end
    if total_read_time > 0 then
        -- Speed in pages per hour.
        book.speed_pph = math.floor(total_read_pages * 3600 / total_read_time + 0.5)
    end
    -- Time-left = pages_remaining × capped_avg_per_page. pages_remaining
    -- must be in the SAME UNITS as pages_total. The stats DB's book.pages
    -- is the document's internal page count (self.document:getPageCount(),
    -- typically 317 for an EPUB rendered at the user's font size). The
    -- DocSettings book.page_num we'd otherwise use is often in pagemap
    -- LABEL units (231 publisher labels) — same book, different scale.
    -- Mixing those gives a pages_left that's wildly wrong (#38).
    --
    -- Derive current_page from book_pct (a unit-agnostic 0..1 fraction)
    -- × pages_total. This matches KOReader's stats calculation exactly,
    -- which uses self.ui:getCurrentPage() (internal units) against
    -- self.document:getPageCount() (same internal units).
    if capped_pages and capped_pages > 0 and capped_time
            and pages_total > 0 and book.book_pct then
        local current_page = math.floor(book.book_pct * pages_total + 0.5)
        local pages_left = math.max(0, pages_total - current_page)
        book.book_time_left_minutes = math.floor(
            pages_left * capped_time / capped_pages / 60 + 0.5)
    end

    -- Snapshot computed fields into the cache.
    local snapshot = {}
    for _, k in ipairs(STATS_FIELDS) do snapshot[k] = book[k] end
    _stats_cache[book.filepath] = { fields = snapshot, expires_at = now + STATS_CACHE_TTL }
end

-- _bySourceCacheKey: stable string key for the _bySource_cache table. Encodes
-- source kind + id, the active filter statuses (sorted for stability), and the
-- sort priority levels in order. Cheap: just table.concat over scalar fields.
local function _bySourceCacheKey(source, filter, sort_priority, scope)
    local parts = { (source and source.kind) or "?", (source and source.id) or "" }
    local roots = _scopeRoots(scope)
    if roots then
        parts[#parts + 1] = "scope:" .. table.concat(roots, ",")
    end
    if filter and filter.statuses then
        local keys = {}
        for k in pairs(filter.statuses) do keys[#keys + 1] = k end
        table.sort(keys)
        parts[#parts + 1] = "f:" .. table.concat(keys, ",")
    end
    if sort_priority then
        for _, level in ipairs(sort_priority) do
            parts[#parts + 1] = "s:" .. level.key .. ":" .. (level.reverse and "r" or "f")
        end
    end
    return table.concat(parts, "|")
end

-- ─── getBySource ─────────────────────────────────────────────────────────────
-- getBySource(source, filter, sort_priority, offset, limit)
-- Generic resolver for the v1.4 custom-tab feature. `source` is a table
-- describing what to load:
--   { kind = "all" }
--   { kind = "recent" }                — delegates to Repo.getRecent
--   { kind = "latest" }                — delegates to Repo.getLatest
--   { kind = "series" }                — delegates to Repo.getSeriesGroups
--   { kind = "authors" | "genres" | "tags" } — delegates to existing group fetchers
--   { kind = "favorites" }             — delegates to Repo.getFavorites
--   { kind = "folder",     id = "/absolute/path" }
--   { kind = "collection", id = "collection_name" }
--   { kind = "tag",        id = "tag_name" }
--   { kind = "genre",      id = "genre_name" }
--   { kind = "author",     id = "Author Name" }
--   { kind = "status",     id = "unread"|"reading"|"on_hold"|"finished" }
--
-- For built-in kinds, this is a thin alias over the existing per-chip
-- functions (they already apply sort + filter internally). For the new
-- kinds, the resolver walks the BIM via a predicate filter, then applies
-- sort_priority via SortEngine and a per-tab status filter.
function Repo.getBySource(source, filter, sort_priority, offset, limit, scope)
    if not source or not source.kind then return {}, 0 end
    local kind = source.kind

    -- Built-in kinds: delegate to existing functions; they already use
    -- Repo.getSortPriority(kind) internally, so callers should not pass
    -- a custom sort_priority for these (use the editor's sort UI instead,
    -- which writes back to the tab schema). filter on built-ins is also a
    -- no-op in v1.4 -- the existing functions do not yet honour it.
    -- Pass the calling tab's sort_priority through to the group fetchers.
    -- Without this they'd hardcode Repo.getSortPriority(<fixed tab id>) and
    -- miss any custom tab whose id is different from the source kind --
    -- e.g. a tab with id="all" and source.kind="authors" (user repurposed
    -- the Home chip to show the Authors view): without the pass-through,
    -- getAuthors would look up tab_id="authors" which doesn't exist in
    -- that user's schema and fall back to the legacy default sort.
    -- When a reading-status filter is active on a book-list built-in
    -- (all / recent / latest / favorites), don't take the early-return
    -- path -- the built-in fetchers don't honour the filter. Fall
    -- through to the predicate-based path below which applies it
    -- uniformly. Group kinds (series/authors/genres/tags/formats/
    -- ratings) ARE early-returned because the filter is per-book and
    -- a group view returns groups, not books.
    local has_status_filter = filter and filter.statuses and next(filter.statuses) ~= nil
    if not has_status_filter then
        if kind == "all"       then return Repo.getAll(nil, limit, offset)         end
        if kind == "recent"    then return Repo.getRecent(limit, offset)           end
        if kind == "latest"    then return Repo.getLatest(limit, offset, scope)    end
        if kind == "favorites" then return Repo.getFavorites(limit, offset)        end
    end
    if kind == "series"    then return Repo.getSeriesGroups(limit, offset, sort_priority, scope) end
    if kind == "authors"   then return Repo.getAuthors(limit, offset, sort_priority, scope)      end
    if kind == "genres"    then return Repo.getGenres(limit, offset, sort_priority, scope)       end
    if kind == "tags"      then return Repo.getTags(limit, sort_priority)                 end
    if kind == "formats"   then return Repo.getFormats(limit, offset, sort_priority)      end
    if kind == "ratings"   then return Repo.getRatings(limit, offset, sort_priority)      end

    -- Custom kinds: walk the library and apply a predicate filter.
    -- Results are cached by (source, filter, sort_priority) so pagination
    -- within a tab reuses the full sorted candidate list rather than doing
    -- a fresh library walk + per-book BIM sweep on every page flip.
    --
    -- IMPORTANT: the cache stores FILEPATHS only, not full Book records.
    -- ImageWidget frees cover_bb after each paint, so reusing a Book record
    -- across rebuilds returns the SAME Book whose cover_bb has been freed
    -- (memory feedback_image_disposable_shared_book). We hydrate fresh on
    -- every page request by calling _safeBuildBookMeta for the visible slice.
    local cache_key = _bySourceCacheKey(source, filter, sort_priority, scope)
    local cached_paths = _bySource_cache[cache_key]

    if cached_paths then
        -- Cache hit: slice the path list (already in sorted, post-filter
        -- order) and rehydrate just the visible page.
        local total = #cached_paths
        local from  = (offset or 0) + 1
        local to    = limit and math.min(from + limit - 1, total) or total
        local page  = {}
        for i = from, to do
            local b = _safeBuildBookMeta(cached_paths[i])
            if b then page[#page + 1] = b end
        end
        return page, total
    end

    -- Cache miss: build the full candidate list with fresh records, sort,
    -- then cache the resulting filepath order. The miss-path callers get
    -- the freshly-built records (covers fresh by definition).
    local candidates
    do
        -- cachedWalk returns the full recursive file list. We hydrate each
        -- candidate with the LIGHT metadata builder (no cover_bb) so the
        -- predicate / filter / sort pass doesn't pull ~50KB of cover data
        -- per book into memory just to throw most of it away. The visible
        -- page slice is rebuilt with full _safeBuildBookMeta below, so
        -- covers are still rendered correctly -- just for 8 books instead
        -- of 3000.
        local function loadCandidatesByPredicate(pred)
            local home  = G_reader_settings:readSetting("home_dir") or "/"
            local depth = BookshelfSettings.read("latest_walk_depth") or 3
            local cands = candidatesForScope(home, depth, scope)
            -- Pull the whole library's light metadata in a single batch
            -- SELECT instead of one prepared-statement call per file. On a
            -- 2000-book Calibre library that's ~50ms (one SQLite roundtrip)
            -- vs ~2-5s (2000 roundtrips). _lightMetaForFp falls back to
            -- per-file build if a file isn't in the batch result.
            local light_cache = _getLightMetaCache(home, depth)
            -- Build a fp -> last-read-time map from ReadHistory once.
            -- Without this the sort_engine's last_opened comparator sees
            -- nil for every book and gives a stable-but-meaningless order
            -- (reversing just flips the same arbitrary order). Same
            -- mechanism getAll uses when its prefetch sees needs.last_opened.
            local rh        = getReadHistory()
            local read_time = {}
            for _, entry in ipairs(rh.hist) do
                local t = entry.time or 0
                if t > (read_time[entry.file] or 0) then read_time[entry.file] = t end
            end
            local matched = {}
            for _, c in ipairs(cands) do
                local b = _lightMetaForFp(light_cache, c.fp)
                if b and pred(b) then
                    -- Enrich the light record so the sort engine has
                    -- something to compare on:
                    --   * _last_read  -> for sort by "Opened"
                    --   * date_added  -> for sort by "Added" (file mtime is
                    --     the natural proxy on every supported device; for
                    --     Calibre users it's the sync time, for direct
                    --     copies it's the copy time).
                    b._last_read = read_time[c.fp] or 0
                    if not b.date_added then b.date_added = c.mtime or 0 end
                    -- size comes straight from the walk's lfs.attributes
                    -- result -- no extra syscall. Sort-by-File-size on
                    -- custom-source tabs needs this.
                    if not b.size then b.size = c.size or 0 end
                    matched[#matched + 1] = b
                end
            end
            return matched
        end

        if kind == "library" or kind == "all" or kind == "latest" then
            -- Library walk + tautological predicate. 'all' (Home folders)
            -- and 'latest' (Latest added) reach this branch only when a
            -- filter is active -- otherwise their early-returns above
            -- run their bespoke fetchers. With a filter, treating them
            -- as 'walk everything and filter' is semantically right;
            -- the sort_priority the caller supplies still drives order.
            candidates = loadCandidatesByPredicate(function(_b) return true end)
        elseif kind == "recent" then
            -- Recently read with filter: match against ReadHistory
            -- filepaths. ReadHistory is already ordered newest-first,
            -- but the sort_priority pass below decides final order
            -- (default is last_opened desc, which matches the legacy
            -- getRecent behaviour).
            local rh = getReadHistory()
            local in_history = {}
            for _, entry in ipairs(rh.hist) do
                if entry.file then in_history[entry.file] = true end
            end
            candidates = loadCandidatesByPredicate(function(b)
                return in_history[b.filepath]
            end)
        elseif kind == "favorites" then
            -- Favourites with filter: match against the favorites
            -- collection. Same flow as 'collection' but with a fixed
            -- collection name.
            local rc = require("readcollection")
            local set = {}
            local fav = rc.coll and rc.coll.favorites
            if type(fav) == "table" then
                for _file, item in pairs(fav) do
                    local fp = item.file or _file
                    if type(fp) == "string" then set[fp] = true end
                end
            end
            candidates = loadCandidatesByPredicate(function(b)
                return set[b.filepath]
            end)
        elseif kind == "folder" then
            local prefix = source.id or ""
            candidates = loadCandidatesByPredicate(function(b)
                return type(b.filepath) == "string" and b.filepath:sub(1, #prefix) == prefix
            end)
        elseif kind == "collection" then
            local rc  = require("readcollection")
            local set = {}
            local coll = rc.coll and rc.coll[source.id]
            if type(coll) == "table" then
                for _, item in pairs(coll) do
                    if type(item) == "table" and item.file then set[item.file] = true end
                end
            end
            candidates = loadCandidatesByPredicate(function(b) return set[b.filepath] end)
        elseif kind == "tag" then
            local target = source.id
            candidates = loadCandidatesByPredicate(function(b)
                if type(b.tags) ~= "table" then return false end
                for _, t in ipairs(b.tags) do if t == target then return true end end
                return false
            end)
        elseif kind == "genre" then
            -- Match on normalized form so case + plural variants of the
            -- same conceptual genre are picked up. Same normalization as
            -- _buildGroups -- keep both in sync if the normaliser changes.
            local target_norm = _normalizeGenre(source.id or "")
            candidates = loadCandidatesByPredicate(function(b)
                if type(b.genres) ~= "table" then return false end
                for _, g in ipairs(b.genres) do
                    if _normalizeGenre(g) == target_norm then return true end
                end
                return false
            end)
        elseif kind == "author" then
            local target = source.id
            candidates = loadCandidatesByPredicate(function(b)
                return b.author == target or b.author_name == target or b.author_surname == target
            end)
        elseif kind == "single_series" then
            -- Books whose series_name matches the picked one. Light meta
            -- uses series_name; full Book records use both series_name and
            -- series. Check both for safety.
            local target = source.id
            candidates = loadCandidatesByPredicate(function(b)
                return b.series_name == target or b.series == target
            end)
        elseif kind == "status" then
            local target = source.id
            candidates = loadCandidatesByPredicate(function(b)
                return b.read_status == target
            end)
        elseif kind == "format" then
            -- Match by uppercase extension to align with _formatKey + the
            -- "Specific format..." picker. Light meta carries .filepath
            -- (filename in fallback shapes); the matcher only needs the
            -- extension, no BIM read required.
            local target = (source.id or ""):upper()
            candidates = loadCandidatesByPredicate(function(b)
                return _formatKey(b.filepath) == target
            end)
        elseif kind == "rating" then
            -- source.id is "1".."5" for a star count, or "unrated" / "0".
            -- Predicate fetches the rating lazily via readProgress (with
            -- .sdr fast-path) and matches. Heavier than other predicates
            -- because rating lives in DocSettings, but books without a
            -- .sdr short-circuit -- on a typical library that's most of
            -- them.
            local raw = tostring(source.id or "")
            local target = tonumber(raw)
            if raw == "unrated" or target == 0 then target = nil end
            local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
            local lfs_attr = ok_lfs and lfs and lfs.attributes or nil
            candidates = loadCandidatesByPredicate(function(b)
                if not b._progress_fetched and b.filepath then
                    local sdr_path = b.filepath:gsub("%.[^.]+$", "") .. ".sdr"
                    if lfs_attr and lfs_attr(sdr_path, "mode") == "directory" then
                        local _p, _s, r = Repo.readProgress(b.filepath)
                        b.rating = r
                    end
                    b._progress_fetched = true
                end
                return b.rating == target
            end)
        else
            return {}, 0
        end

        -- Filter by reading statuses (multi-select set; nil/empty = no
        -- filter). Light metadata doesn't carry read_status, so we
        -- lazily fetch via Repo.readProgress for each candidate -- only
        -- when the filter is actually active so most users pay nothing.
        --
        -- _progress_fetched flag tracks "we already paid for this book's
        -- DocSettings:open() in this query" so the subsequent sort-needs
        -- prefetch (below) doesn't re-do work the filter already did.
        if filter and filter.statuses then
            local active = false
            for _ in pairs(filter.statuses) do active = true; break end
            if active then
                local kept = {}
                for _, b in ipairs(candidates) do
                    local s = b.read_status or b._status
                    if not s and not b._progress_fetched and b.filepath then
                        local pct, status, rating = Repo.readProgress(b.filepath)
                        b._pct                = pct
                        b._status             = status
                        b.rating              = b.rating or rating
                        b._progress_fetched   = true
                        s = status
                    end
                    -- Normalise to bookshelf vocabulary (matches the chip
                    -- editor's status IDs: unread / reading / on_hold /
                    -- finished). KOReader writes a different set into
                    -- DocSettings ("complete" / "abandoned"; nil/"new" for
                    -- unopened books) so we must map across before the
                    -- filter lookup, or unread / Finished / On-hold books
                    -- get silently dropped. (Issue #41.)
                    if     s == nil or s == "new" then s = "unread"
                    elseif s == "complete"        then s = "finished"
                    elseif s == "abandoned"       then s = "on_hold"
                    end
                    if filter.statuses[s] then kept[#kept + 1] = b end
                end
                candidates = kept
            end
        end

        -- needs-introspection for the sort: only pay for DocSettings reads
        -- when the user's sort priority actually depends on progress data.
        -- Same pattern getAll uses for its prefetch (search for "local needs").
        local needs_progress = false
        if sort_priority then
            for _, lv in ipairs(sort_priority) do
                local k = lv.key
                if k == "percent_read"
                        or k == "read_status"
                        or k == "read_status_active"
                        or k == "rating" then
                    -- 'rating' lives in summary.rating which Repo.readProgress
                    -- now also returns, so it piggybacks on the same prefetch.
                    needs_progress = true
                    break
                end
            end
        end

        if needs_progress then
            -- Fast path: check .sdr existence with a single lfs.attributes()
            -- call BEFORE the much-heavier DocSettings:open(). Unread books
            -- have no sidecar, and would otherwise pay ~50ms per book to
            -- learn that. On a typical library where ~70% of books are
            -- unread, this gives a 3-10x speedup over an unconditional
            -- readProgress per candidate.
            --
            -- Note: even when sdr exists, Repo.readProgress hits its
            -- _progress_cache (120s TTL) so re-sorts within the same
            -- session are cheap.
            local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
            local lfs_attr = ok_lfs and lfs and lfs.attributes or nil
            local _t0 = _gettime()
            local fast_skipped, full_read = 0, 0
            for _, b in ipairs(candidates) do
                if not b._progress_fetched and b.filepath then
                    -- "Foo.epub" -> "Foo.sdr"
                    local sdr_path = b.filepath:gsub("%.[^.]+$", "") .. ".sdr"
                    local has_sdr  = lfs_attr
                        and lfs_attr(sdr_path, "mode") == "directory"
                    if has_sdr then
                        local pct, status, rating = Repo.readProgress(b.filepath)
                        b._pct      = pct
                        b._status   = status
                        b.rating    = b.rating or rating
                        full_read   = full_read + 1
                    else
                        b._pct      = nil
                        b._status   = nil
                        -- rating stays nil too -- unread books can't be rated
                        fast_skipped = fast_skipped + 1
                    end
                    b._progress_fetched = true
                end
            end
            logger.dbg(string.format(
                "[bookshelf perf] sort-needs progress: %.0fms full=%d skipped=%d/%d",
                (_gettime() - _t0) * 1000, full_read, fast_skipped, #candidates))
        end

        -- Sort.
        if sort_priority and #sort_priority > 0 then
            SortEngine.sort(candidates, sort_priority)
        end
    end

    -- Cache the FILEPATHS in sorted/filtered order. Next page request
    -- slices this list and rehydrates fresh Book records so cover_bb is
    -- always fresh.
    local paths = {}
    for _, b in ipairs(candidates) do paths[#paths + 1] = b.filepath end
    _bySource_cache[cache_key] = paths

    -- candidates is light metadata (no covers). For the visible slice,
    -- rebuild with the full _safeBuildBookMeta path so covers render.
    -- Light records are released for GC after this function returns.
    local total = #paths
    local from  = (offset or 0) + 1
    local to    = limit and math.min(from + limit - 1, total) or total
    local page  = {}
    for i = from, to do
        local b = _safeBuildBookMeta(paths[i])
        if b then page[#page + 1] = b end
    end
    return page, total
end

return Repo
