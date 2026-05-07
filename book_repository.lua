-- book_repository.lua
-- Unified Book record source over KOReader's ReadHistory, ReadCollection,
-- BookInfoManager, DocSettings, and (optionally) statistics.koplugin.
--
-- Design contract: this module produces Book records only — no widget code,
-- no UI imports. All external KOReader modules are reached through getter
-- functions so that pure-Lua tests can stub them via package.loaded before
-- require() is called.

local Repo = {}

local logger = require("logger")
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

-- Supported e-book extensions (used in both getCurrent and walkBooks).
local SUPPORTED_EXT = {
    epub=true, pdf=true, mobi=true, azw3=true, fb2=true,
    cbz=true, cbr=true, txt=true, md=true, html=true, htm=true, djvu=true,
}

-- ─── Lazy module accessors ───────────────────────────────────────────────────
-- Never require() at module top-level; tests stub via package.loaded.

local function getReadHistory()  return require("readhistory") end
local function getCollections()  return require("readcollection") end
local function getBookInfoMgr()  return require("bookinfomanager") end
local function getDocSettings()  return require("docsettings") end

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
    if not G_reader_settings:readSetting("bookshelf_calibre_metadata") then
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
        local p = home .. "/" .. name
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
-- writes via the sort menu (BookshelfWidget:_openSortMenu); each chip getter
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
}

local _SORT_VALID = {
    all        = { title = true, date_added = true, path = true },
    latest     = { mtime = true, title = true },
    favorites  = { date_added = true, title = true, recently_read = true },
    series     = { name = true, latest_read = true, book_count = true },
    authors    = { name = true, latest_read = true, book_count = true },
    genres     = { name = true, latest_read = true, book_count = true },
    tags       = { name = true, latest_read = true, book_count = true },
}

function Repo.getSortKey(chip)
    local k = G_reader_settings:readSetting("bookshelf_sort_" .. chip)
    local valid = _SORT_VALID[chip]
    if k and valid and valid[k] then return k end
    return _SORT_DEFAULT[chip]
end

function Repo.buildBookMeta(filepath)
    if not filepath then return nil end
    local bim  = getBookInfoMgr()
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
    if cb and cb.series then
        series_name = cb.series
    elseif info.series then
        series_name = info.series:gsub(" #%d+$", "")
        series_num  = info.series:match(" #(%d+)$")
    end
    if cb and cb.series_index then
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
    if cb and cb.title and cb.title ~= "" then
        title = cb.title
    elseif info.title and info.title ~= "" then
        title = info.title
    else
        title = filename
    end

    -- Genres: Calibre `tags` (array) → BIM `keywords` (string) → none.
    local genres
    if cb and type(cb.tags) == "table" and #cb.tags > 0 then
        genres = {}
        for _i, t in ipairs(cb.tags) do genres[#genres + 1] = t end
    elseif info.keywords and info.keywords ~= "" then
        genres = {}
        for part in info.keywords:gmatch("[^,;]+") do
            local trimmed = part:match("^%s*(.-)%s*$")
            if trimmed and trimmed ~= "" then
                genres[#genres + 1] = trimmed
            end
        end
        if #genres == 0 then genres = nil end
    end

    return {
        filepath    = filepath,
        filename    = filename,
        format      = (filepath:match("%.([^.]+)$") or ""):upper(),
        title       = title,
        author      = authors and authors[1] or nil,
        authors     = authors,
        genres      = genres,
        -- `series` is the raw "Foundation #1" string used by some
        -- consumers; reconstruct it from Calibre fields when needed.
        series      = info.series
                       or (cb and cb.series and series_num
                           and (cb.series .. " #" .. series_num))
                       or (cb and cb.series),
        series_name = series_name,
        series_num  = series_num,
        -- BIM-only: covers and page count are not in metadata.calibre.
        cover_bb    = info.cover_bb,
        has_cover   = info.has_cover and not info.ignore_cover,
        lang        = (cb and cb.languages and cb.languages[1])
                       or info.language,
        description = (cb and cb.comments and cb.comments ~= "")
                       and cb.comments
                       or (info.description and info.description ~= ""
                           and info.description)
                       or nil,
        page_count  = info.pages,
    }
end

function Repo.buildBook(filepath)
    local book = Repo.buildBookMeta(filepath)
    if not book then return nil end
    local ds = getDocSettings():open(filepath)
    book.page_num = ds:readSetting("last_page")
    book.book_pct = ds:readSetting("percent_finished")
    book.last_xp  = ds:readSetting("last_xpointer")
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

function Repo.getRecent(limit)
    local rh  = getReadHistory()
    local out = {}
    for i = 1, #rh.hist do
        local entry = rh.hist[i]
        -- Shelf path: BIM-only meta is enough (no DocSettings needed).
        local book = Repo.buildBookMeta(entry.file)
        if book then
            book.last_read_time = entry.time
            out[#out + 1] = book
            if #out >= (limit or 8) then break end
        end
    end
    return out
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
local WALK_CACHE_TTL = 120  -- seconds; invalidateWalkCache() on onCloseDocument is the primary invalidation path
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
-- getAll result cache. FileChooser:genItemTableFromPath is expensive (2–5s
-- on large home dirs); caches the shape (filepaths + folder labels) with the
-- same TTL and invalidation path as the walk cache.
local _all_cache       = {}  -- { [key] = { shapes = {...}, expires_at = number } }

function Repo.invalidateWalkCache()
    _walk_cache    = {}
    _series_cache  = {}
    _authors_cache = {}
    _genres_cache  = {}
    _all_cache     = {}
end

function Repo.invalidateSeriesCache()
    _series_cache  = {}
    _authors_cache = {}
    _genres_cache  = {}
end

local function walkBooks(root, depth, out, current_depth)
    current_depth = current_depth or 0
    if current_depth > depth then return end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs or not lfs or not lfs.dir then return end

    -- Guard against permission errors / missing dirs raised by lfs.dir(root).
    -- lfs.dir returns (iterator, dir_obj); both must be passed to the for
    -- loop or lfs raises "directory metatable expected, got nil" on the first
    -- step. pcall returns (ok, ret1, ret2, …) — capture both real returns.
    local ok, iter, dir_obj = pcall(lfs.dir, root)
    if not ok or type(iter) ~= "function" then return end

    for entry in iter, dir_obj do
        if entry ~= "." and entry ~= ".." then
            local fp   = root .. "/" .. entry
            local mode = lfs.attributes(fp, "mode")
            if mode == "directory" then
                walkBooks(fp, depth, out, current_depth + 1)
            elseif mode == "file" then
                local ext = entry:match("%.([^.]+)$")
                if ext and SUPPORTED_EXT[ext:lower()] then
                    out[#out + 1] = { fp = fp, mtime = lfs.attributes(fp, "modification") or 0 }
                end
            end
        end
    end
end

-- Returns a shallow copy of the cached candidate list for (home, depth).
-- Walks fresh on miss/expiry. The copy is so callers (e.g. getLatest)
-- can sort in place without mutating the cached canonical order.
local function cachedWalk(home, depth)
    local key = (home or "/") .. ":" .. tostring(depth or 0)
    local now = os.time()
    local entry = _walk_cache[key]
    if not entry or entry.expires_at <= now then
        local _t0 = _gettime()
        local fresh = {}
        walkBooks(home, depth, fresh)
        local _dt = (_gettime() - _t0) * 1000
        entry = { list = fresh, expires_at = now + WALK_CACHE_TTL }
        _walk_cache[key] = entry
        logger.dbg(string.format("[bookshelf perf] cachedWalk: MISS walk=%.0fms files=%d depth=%s",
            _dt, #fresh, tostring(depth)))
    else
        logger.dbg(string.format("[bookshelf perf] cachedWalk: HIT files=%d ttl_left=%ds",
            #entry.list, entry.expires_at - now))
    end
    local copy = {}
    for i = 1, #entry.list do copy[i] = entry.list[i] end
    return copy
end

function Repo.getLatest(limit, offset)
    local _t0 = _gettime()
    local home       = G_reader_settings:readSetting("home_dir") or "/"
    local depth      = G_reader_settings:readSetting("bookshelf_latest_walk_depth") or 3
    local candidates = cachedWalk(home, depth)
    local key = Repo.getSortKey("latest")
    if key == "title" then
        -- Pre-fetch BIM titles so the comparator stays O(1) per pair.
        local bim = getBookInfoMgr()
        local titles = {}
        for _, c in ipairs(candidates) do
            local info = bim:getBookInfo(c.fp, true) or {}
            titles[c.fp] = (info.title or c.fp:match("([^/]+)$") or ""):lower()
        end
        table.sort(candidates, function(a, b) return titles[a.fp] < titles[b.fp] end)
    else
        -- mtime (default): newest first.
        table.sort(candidates, function(a, b) return a.mtime > b.mtime end)
    end
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
    logger.dbg(string.format("[bookshelf perf] getLatest: %.0fms cands=%d items=%d/%d sort=%s",
        (_gettime() - _t0) * 1000, #candidates, #out, total, key))
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

-- Walk into `path` to find the first book metadata-buildable via the
-- BIM, with a bounded recursion depth to keep chip-render time predictable.
-- Files in the current dir are checked before recursing into subdirs;
-- entries are sorted alphabetically so the result is deterministic.
function Repo.findFirstBookIn(path, max_depth)
    max_depth = max_depth or 3
    if max_depth < 0 then return nil end
    local lfs = require("libs/libkoreader-lfs")
    local entries = {}
    local ok, iter, dir_obj = pcall(lfs.dir, path)
    if not ok then return nil end
    for f in iter, dir_obj do
        if f ~= "." and f ~= ".." and not f:match("^%.") then
            entries[#entries + 1] = f
        end
    end
    table.sort(entries)
    -- Pass 1: files at this level. Use SUPPORTED_EXT directly rather
    -- than FileChooser:show_file so we don't need a FileChooser self.
    for _, f in ipairs(entries) do
        local fp = path .. "/" .. f
        local attr = lfs.attributes(fp)
        if attr and attr.mode == "file" then
            local ext = f:match("%.([^.]+)$")
            if ext and SUPPORTED_EXT[ext:lower()] then
                local b = Repo.buildBookMeta(fp)
                if b then return b end
            end
        end
    end
    -- Pass 2: descend into subdirs (depth-limited)
    for _, f in ipairs(entries) do
        local fp = path .. "/" .. f
        local attr = lfs.attributes(fp)
        if attr and attr.mode == "directory" then
            local found = Repo.findFirstBookIn(fp, max_depth - 1)
            if found then return found end
        end
    end
    return nil
end

local function _makeCollateSort(collate, rh_map)
    local SORT_LAST = "\xEF\xBF\xBF"
    if collate == "natural" then
        local ok, sort_mod = pcall(require, "sort")
        if ok and sort_mod and sort_mod.natsort_cmp then
            local natsort = sort_mod.natsort_cmp()
            return function(a, b) return natsort(a.name, b.name) end
        end
    elseif collate == "access" then
        local rh = rh_map or {}
        return function(a, b)
            local ta = rh[a.fp] or a.attr.access or a.attr.modification or 0
            local tb = rh[b.fp] or b.attr.access or b.attr.modification or 0
            return ta > tb
        end
    elseif collate == "date" then
        return function(a, b)
            return (a.attr.modification or 0) > (b.attr.modification or 0)
        end
    elseif collate == "size" then
        return function(a, b)
            return (a.attr.size or 0) < (b.attr.size or 0)
        end
    elseif collate == "type" then
        return function(a, b)
            local ea = (a.name:match("%.([^.]+)$") or ""):lower()
            local eb = (b.name:match("%.([^.]+)$") or ""):lower()
            if ea ~= eb then return ea < eb end
            return a.name:lower() < b.name:lower()
        end
    elseif collate == "title" then
        return function(a, b)
            local ta = (a.doc_props and a.doc_props.display_title or a.name):lower()
            local tb = (b.doc_props and b.doc_props.display_title or b.name):lower()
            return ta < tb
        end
    elseif collate == "authors" then
        return function(a, b)
            local aa = (a.doc_props and a.doc_props.authors or SORT_LAST):lower()
            local ab = (b.doc_props and b.doc_props.authors or SORT_LAST):lower()
            if aa ~= ab then return aa < ab end
            local ta = (a.doc_props and a.doc_props.display_title or a.name):lower()
            local tb = (b.doc_props and b.doc_props.display_title or b.name):lower()
            return ta < tb
        end
    elseif collate == "series" then
        return function(a, b)
            local sa = (a.doc_props and a.doc_props.series or SORT_LAST):lower()
            local sb = (b.doc_props and b.doc_props.series or SORT_LAST):lower()
            if sa ~= sb then return sa < sb end
            local ia = a.doc_props and a.doc_props.series_index
            local ib = b.doc_props and b.doc_props.series_index
            if ia and ib then return ia < ib end
            local ta = (a.doc_props and a.doc_props.display_title or a.name):lower()
            local tb = (b.doc_props and b.doc_props.display_title or b.name):lower()
            return ta < tb
        end
    elseif collate == "keywords" then
        return function(a, b)
            local ka = (a.doc_props and a.doc_props.keywords or SORT_LAST):lower()
            local kb = (b.doc_props and b.doc_props.keywords or SORT_LAST):lower()
            if ka ~= kb then return ka < kb end
            local ta = (a.doc_props and a.doc_props.display_title or a.name):lower()
            local tb = (b.doc_props and b.doc_props.display_title or b.name):lower()
            return ta < tb
        end
    end
    -- strcoll, percent_* → alphabetical by filename
    return function(a, b) return a.name:lower() < b.name:lower() end
end

-- getAll(path, limit, offset) → (items, total)
-- limit/offset let callers fetch a single page slice without hydrating the
-- full list. total is always the full item count (from cache or fresh scan)
-- so callers can compute total_pages without a second trip.
function Repo.getAll(path, limit, offset)
    local _t0 = _gettime()
    offset = offset or 0
    path = path or G_reader_settings:readSetting("home_dir") or "/"
    local collate   = G_reader_settings:readSetting("collate") or "strcoll"
    local cache_key = path .. "\0" .. collate
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
                local fb = shape.first_book_fp and Repo.buildBookMeta(shape.first_book_fp)
                out[#out + 1] = {
                    kind       = "folder",
                    path       = shape.path,
                    label      = shape.label,
                    first_book = fb,
                }
            else
                local b = Repo.buildBookMeta(shape.fp)
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
    local entries = {}
    for entry in iter, dir_obj do
        if entry ~= "." and entry ~= ".." and entry:sub(1, 1) ~= "." then
            local fp   = path .. "/" .. entry
            local attr = lfs.attributes(fp)
            if attr and entry:sub(-4) ~= ".sdr" then
                entries[#entries + 1] = { name = entry, fp = fp, attr = attr }
            end
        end
    end

    -- For metadata sorts, enrich each file entry with BIM fields before
    -- sorting — BIM is already cached so this is fast for scanned libraries.
    local SORT_LAST = "\xEF\xBF\xBF"  -- U+FFFF, sorts after all normal text
    if collate == "title" or collate == "authors"
            or collate == "series" or collate == "keywords" then
        local bim = getBookInfoMgr()
        for _, e in ipairs(entries) do
            if e.attr.mode == "file" then
                local info   = bim:getBookInfo(e.fp, true) or {}
                local s_name = info.series and info.series:gsub(" #%d+$", "")
                e.doc_props  = {
                    display_title = info.title or e.name,
                    authors       = info.authors or SORT_LAST,
                    series        = s_name or SORT_LAST,
                    series_index  = info.series_index,
                    keywords      = info.keywords or SORT_LAST,
                }
            else
                e.doc_props = {
                    display_title = e.name,
                    authors       = SORT_LAST,
                    series        = SORT_LAST,
                    keywords      = SORT_LAST,
                }
            end
        end
    end

    -- For access (last read date), build a ReadHistory map so books sort by
    -- when KOReader opened them, not filesystem atime (unreliable on Kindle).
    local rh_map
    if collate == "access" then
        local ok_rh, rh = pcall(getReadHistory)
        if ok_rh and rh and rh.hist then
            rh_map = {}
            for _, e in ipairs(rh.hist) do
                if e.file and e.time then rh_map[e.file] = e.time end
            end
        end
    end

    table.sort(entries, _makeCollateSort(collate, rh_map))

    -- MISS: build the full list, cache all shapes, return just the slice.
    local all_out = {}
    local shapes  = {}
    for _, e in ipairs(entries) do
        if e.attr.mode == "file" then
            local ext = e.name:match("%.([^.]+)$")
            if ext and SUPPORTED_EXT[ext:lower()] then
                local b = Repo.buildBookMeta(e.fp)
                if b then
                    all_out[#all_out + 1] = b
                    shapes[#shapes + 1] = { kind = "book", fp = e.fp }
                end
            end
        elseif e.attr.mode == "directory" then
            local fb = Repo.findFirstBookIn(e.fp, 3)
            all_out[#all_out + 1] = {
                kind       = "folder",
                path       = e.fp,
                label      = e.name,
                first_book = fb,
            }
            shapes[#shapes + 1] = {
                kind          = "folder",
                path          = e.fp,
                label         = e.name,
                first_book_fp = fb and fb.filepath,
            }
        end
    end
    local total = #all_out
    _all_cache[cache_key] = { shapes = shapes, expires_at = now + WALK_CACHE_TTL }
    local out  = {}
    local stop = limit and math.min(offset + limit, total) or total
    for i = offset + 1, stop do out[#out + 1] = all_out[i] end
    logger.dbg(string.format("[bookshelf perf] getAll: MISS build=%.0fms items=%d/%d",
        (_gettime() - _t0) * 1000, #out, total))
    return out, total
end

-- ─── getFavorites ────────────────────────────────────────────────────────────
-- Returns up to `limit` Book records from ReadCollection favorites collection,
-- sorted by access time descending (most recently accessed first).

function Repo.getFavorites(limit)
    local rc    = getCollections()
    local items = {}
    for _file, item in pairs(rc.coll and rc.coll.favorites or {}) do
        items[#items + 1] = item
    end
    local key = Repo.getSortKey("favorites")
    if key == "title" then
        local bim = getBookInfoMgr()
        local titles = {}
        for _, item in ipairs(items) do
            local fp = item.file
            local info = bim:getBookInfo(fp, true) or {}
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
    local out = {}
    for i = 1, math.min(limit or 8, #items) do
        local book = Repo.buildBookMeta(items[i].file)
        if book then
            book.in_favorites = true
            out[#out + 1] = book
        end
    end
    return out
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
function Repo.searchBooks(query, limit)
    if not query or query == "" then return {} end
    local home  = G_reader_settings:readSetting("home_dir") or "/"
    local depth = G_reader_settings:readSetting("bookshelf_latest_walk_depth") or 3
    local cands = cachedWalk(home, depth)
    local words = {}
    for w in query:gmatch("%S+") do
        words[#words + 1] = w:lower()
    end
    if #words == 0 then return {} end
    local out = {}
    for _, c in ipairs(cands) do
        local b = Repo.buildBookMeta(c.fp)
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

function Repo.getTags(limit)
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
    table.sort(groups, function(a, b) return a.latest > b.latest end)
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

function Repo.getSeriesGroups(limit, offset)
    local home  = G_reader_settings:readSetting("home_dir") or "/"
    local depth = G_reader_settings:readSetting("bookshelf_latest_walk_depth") or 3
    local key   = (home or "/") .. ":" .. tostring(depth or 0)
    local now   = os.time()

    -- Cache fast path: filepaths + sort metadata are stable across
    -- renders; Books get rehydrated each read so cover_bbs are fresh.
    local cached = _series_cache[key]
    if cached and cached.expires_at > now then
        local _t0   = _gettime()
        local total = #cached.groups
        local out   = {}
        offset      = offset or 0
        local stop  = math.min(offset + (limit or 8), total)
        for i = offset + 1, stop do
            out[#out + 1] = hydrateSeriesShape(cached.groups[i])
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

    local candidates = cachedWalk(home, depth)

    local groups = {}  -- keyed by series_name
    local order  = {}  -- preserves insertion order for deterministic tie-break
    for _, c in ipairs(candidates) do
        -- Use the BIM-only meta build: this loop runs over EVERY candidate
        -- in the library walk (potentially hundreds of files), and we don't
        -- need DocSettings here. The full buildBook (sidecar parse) was the
        -- dominant per-rebuild cost on the Series chip; meta-only is just
        -- an in-memory BookInfoManager lookup.
        local book = Repo.buildBookMeta(c.fp)
        if book and book.series_name then
            local sname = book.series_name
            if not groups[sname] then
                groups[sname] = { series_name = sname, books = {}, latest = 0, _seen = {} }
                order[#order + 1] = sname
            end
            if not groups[sname]._seen[book.filepath] then
                groups[sname]._seen[book.filepath] = true
                groups[sname].books[#groups[sname].books + 1] = book
            end
            local t = read_time[book.filepath] or c.mtime or 0
            if t > groups[sname].latest then
                groups[sname].latest = t
            end
        end
    end
    -- Flatten to list and sort by most recent activity.
    local list = {}
    for _, k in ipairs(order) do list[#list + 1] = groups[k] end
    table.sort(list, function(a, b) return a.latest > b.latest end)
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

    local total = #list
    local out   = {}
    offset      = offset or 0
    local stop  = math.min(offset + (limit or 8), total)
    for i = offset + 1, stop do out[#out + 1] = list[i] end
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
        kind        = shape.kind,
        series_name = shape.series_name,
        books       = books,
        latest      = shape.latest,
    }
end

-- _buildGroups(group_kind, key_fn, multi)
-- Walks the library, groups books by key_fn(book), returns sorted groups.
-- key_fn: (book) -> string | nil  for single-key (multi=false)
-- key_fn: (book) -> table[string] | nil  for multi-key (multi=true)
local function _buildGroups(group_kind, key_fn, multi)
    local _t0 = _gettime()
    local home  = G_reader_settings:readSetting("home_dir") or "/"
    local depth = G_reader_settings:readSetting("bookshelf_latest_walk_depth") or 3
    -- Read history → filepath read-time map so groups sort by recently-read.
    local rh        = getReadHistory()
    local read_time = {}
    for _, entry in ipairs(rh.hist) do
        local t = entry.time or 0
        if t > (read_time[entry.file] or 0) then read_time[entry.file] = t end
    end
    local cands = cachedWalk(home, depth)
    local groups = {}
    local order  = {}
    for _, c in ipairs(cands) do
        local book = Repo.buildBookMeta(c.fp)
        if book then
            local keys = key_fn(book)
            if keys then
                if not multi then keys = { keys } end
                for _, k in ipairs(keys) do
                    if k and k ~= "" then
                        local g = groups[k]
                        if not g then
                            g = {
                                kind        = group_kind,
                                series_name = k,
                                books       = {},
                                latest      = 0,
                                _seen       = {},
                            }
                            groups[k] = g
                            order[#order + 1] = k
                        end
                        if not g._seen[book.filepath] then
                            g._seen[book.filepath] = true
                            g.books[#g.books + 1] = book
                        end
                        local t = read_time[book.filepath] or c.mtime or 0
                        if t > g.latest then g.latest = t end
                    end
                end
            end
        end
    end
    local list = {}
    for _, k in ipairs(order) do list[#list + 1] = groups[k] end
    table.sort(list, function(a, b) return a.latest > b.latest end)
    for _, g in ipairs(list) do
        g._seen = nil
        table.sort(g.books, function(a, b)
            return (a.title or "") < (b.title or "")
        end)
    end
    logger.dbg(string.format("[bookshelf perf] _buildGroups(%s): %.0fms cands=%d groups=%d",
        group_kind, (_gettime() - _t0) * 1000, #cands, #list))
    return list
end

local function _cacheGroupShapes(list, kind)
    local shapes = {}
    for _, group in ipairs(list) do
        local fps = {}
        for _, b in ipairs(group.books) do fps[#fps + 1] = b.filepath end
        shapes[#shapes + 1] = {
            kind        = kind,
            series_name = group.series_name,
            filepaths   = fps,
            latest      = group.latest,
        }
    end
    return shapes
end

function Repo.getAuthors(limit, offset)
    local _t0 = _gettime()
    local home  = G_reader_settings:readSetting("home_dir") or "/"
    local depth = G_reader_settings:readSetting("bookshelf_latest_walk_depth") or 3
    local key   = (home or "/") .. ":" .. tostring(depth or 0)
    local now   = os.time()
    local cached = _authors_cache[key]
    local _hit = cached and cached.expires_at > now
    if not _hit then
        local list = _buildGroups("author", function(b) return b.author end, false)
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
    local total = #cached.groups
    local out   = {}
    offset      = offset or 0
    local stop  = math.min(offset + (limit or 8), total)
    for i = offset + 1, stop do
        out[#out + 1] = _hydrateGroupShape(cached.groups[i])
    end
    logger.dbg(string.format("[bookshelf perf] getAuthors: %s %.0fms groups=%d/%d",
        _hit and "HIT" or "MISS", (_gettime() - _t0) * 1000, #out, total))
    return out, total
end

function Repo.getGenres(limit, offset)
    local _t0 = _gettime()
    local home  = G_reader_settings:readSetting("home_dir") or "/"
    local depth = G_reader_settings:readSetting("bookshelf_latest_walk_depth") or 3
    local key   = (home or "/") .. ":" .. tostring(depth or 0)
    local now   = os.time()
    local cached = _genres_cache[key]
    local _hit = cached and cached.expires_at > now
    if not _hit then
        local list = _buildGroups("genre", function(b) return b.genres end, true)
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
    local total = #cached.groups
    local out   = {}
    offset      = offset or 0
    local stop  = math.min(offset + (limit or 8), total)
    for i = offset + 1, stop do
        out[#out + 1] = _hydrateGroupShape(cached.groups[i])
    end
    logger.dbg(string.format("[bookshelf perf] getGenres: %s %.0fms groups=%d/%d",
        _hit and "HIT" or "MISS", (_gettime() - _t0) * 1000, #out, total))
    return out, total
end

-- ─── searchAll ───────────────────────────────────────────────────────────────
-- Returns { folders, authors, series, genres, books } for a query string.
-- All matching is case-insensitive substring. Returns empty lists immediately
-- for a blank query.
function Repo.searchAll(query)
    local empty = { folders = {}, authors = {}, series = {}, genres = {}, books = {} }
    if not query or query == "" then return empty end
    local q = query:lower()

    -- ── folders ──
    -- Derive from the already-cached walk: unique parent directories whose
    -- basename matches the query. No disk I/O: cachedWalk returns { fp, mtime }.
    local home  = G_reader_settings:readSetting("home_dir") or "/"
    local depth = G_reader_settings:readSetting("bookshelf_latest_walk_depth") or 3
    local key   = (home or "/") .. ":" .. tostring(depth or 0)
    local cands = cachedWalk(home, depth)
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
    Repo.getAuthors(0, 0)
    Repo.getSeriesGroups(0, 0)
    Repo.getGenres(0, 0)

    local authors = matchGroups(_authors_cache)
    local series  = matchGroups(_series_cache)
    local genres  = matchGroups(_genres_cache)

    -- ── books ──
    local books = Repo.searchBooks(query, 200) or {}

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
function Repo.findGroup(kind, name)
    if not name or name == "" then return nil end
    local home  = G_reader_settings:readSetting("home_dir") or "/"
    local depth = G_reader_settings:readSetting("bookshelf_latest_walk_depth") or 3
    local key   = (home or "/") .. ":" .. tostring(depth or 0)
    local cache
    if     kind == "author" then cache = _authors_cache[key]
    elseif kind == "series" then cache = _series_cache[key]
    elseif kind == "genre"  then cache = _genres_cache[key]
    else return nil end
    if not cache then
        if     kind == "author" then Repo.getAuthors(0, 0);      cache = _authors_cache[key]
        elseif kind == "series" then Repo.getSeriesGroups(0, 0); cache = _series_cache[key]
        elseif kind == "genre"  then Repo.getGenres(0, 0);       cache = _genres_cache[key]
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
    -- Time-left estimate: pages remaining × current avg time per page.
    if total_read_pages > 0 and pages_total > 0 then
        local pages_left = math.max(0, pages_total - total_read_pages)
        local avg_per_page = total_read_time / total_read_pages
        book.book_time_left_minutes = math.floor(pages_left * avg_per_page / 60 + 0.5)
    end

    -- Snapshot computed fields into the cache.
    local snapshot = {}
    for _, k in ipairs(STATS_FIELDS) do snapshot[k] = book[k] end
    _stats_cache[book.filepath] = { fields = snapshot, expires_at = now + STATS_CACHE_TTL }
end

return Repo
