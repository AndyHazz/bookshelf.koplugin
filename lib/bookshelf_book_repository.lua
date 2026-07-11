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
local Filter = require("lib/bookshelf_filter")
local BookshelfSettings = require("lib/bookshelf_settings_store")
local _ok = pcall(require, "lib/bookshelf_i18n")  -- soft: tests stub-load without it
local i18n = package.loaded["lib/bookshelf_i18n"]
local function tr(s) if i18n and i18n.gettext then return i18n.gettext(s) end; return s end

-- Wall-clock timer. Falls back to os.clock() (CPU-only) if LuaSocket absent.
local _gettime
do
    local ok, s = pcall(require, "socket")
    _gettime = (ok and s and type(s.gettime) == "function")
        and function() return s.gettime() end
        or  os.clock
end

-- ─── Module-local helpers ────────────────────────────────────────────────────

-- True for FictionBook files (.fb2 / .fb2.zip), whose author strings need
-- the comma treatment below.
local function _isFb2(fp)
    if type(fp) ~= "string" then return false end
    local lower = fp:lower()
    return lower:match("%.fb2$") ~= nil or lower:match("%.fb2%.zip$") ~= nil
end

-- Split a newline-separated author string into a trimmed array, or
-- return nil. KOReader's BIM joins multiple <dc:creator> entries with
-- "\n"; for most formats that's the only separator we should split on.
-- Splitting on comma corrupts library-format names like
-- "Clarke, Arthur C." into ["Clarke", "Arthur C."] and creates phantom
-- author entries on the Authors tab (issue #74 follow-up).
--
-- fb2 is the exception (#242): crengine composes each fb2 author from the
-- format's structured first/middle/last fields and joins multiple authors
-- with ", " -- so there a comma can only be the join, never part of a
-- "Surname, Forename" name, and without the extra split a co-authored
-- fb2 becomes one bogus merged author. The empty middle-name slot also
-- leaves "Alpha  Tester"-style double spaces, collapsed below so fb2 and
-- EPUB copies of the same author match exactly.
--
-- Calibre's own metadata bypasses this helper entirely -- it arrives
-- pre-split as cb.authors (table).
local function splitAuthors(s, fp)
    if not s or s == "" then return nil end
    local pat = _isFb2(fp) and "[^\n,]+" or "[^\n]+"
    local t = {}
    for part in s:gmatch(pat) do
        local cleaned = part:match("^%s*(.-)%s*$")  -- trim whitespace
            :gsub("%s+", " ")                       -- collapse internal runs
        if cleaned ~= "" then t[#t + 1] = cleaned end
    end
    return #t > 0 and t or nil
end

local function shallowCopyRecord(record)
    local copy = {}
    for k, v in pairs(record or {}) do
        copy[k] = v
    end
    return copy
end

-- Split a genre/tag string (or array of strings) on common EPUB delimiters
-- (comma, semicolon, pipe, newline) and return a trimmed array, or nil.
-- Slash is handled specially: only a SPACED slash ("Fiction / Fantasy",
-- BISAC-style subject hierarchies) separates genres. A bare slash is part
-- of the tag itself ("hurt/comfort" -- issue #240), so it must NOT split.
-- Normalise the spaced form to the newline delimiter up front, then split
-- on the remaining separators with bare "/" no longer among them.
local function splitGenreTags(src)
    local t = {}
    local inputs = type(src) == "table" and src or { src }
    for _i, s in ipairs(inputs) do
        local norm = s:gsub("%s+/%s+", "\n")
        for part in norm:gmatch("[^,;|\n]+") do
            local trimmed = part:match("^%s*(.-)%s*$")
            if trimmed and trimmed ~= "" then t[#t + 1] = trimmed end
        end
    end
    return #t > 0 and t or nil
end

-- Custom-metadata fast gate (issue #262). DocSettings:findCustomMetadataFile
-- stats each sidecar location per book; on a large library on slow storage
-- (Boox/Android SD, ~1200 books) those per-book stats dominated the light-meta
-- build (~15s, even with the DB read snapshotted). A custom_metadata.lua can
-- only live INSIDE a book's ".sdr" sidecar dir, so if no such dir exists in the
-- name-resolvable locations there is nothing to find. List each relevant PARENT
-- directory ONCE (cached) and check for the sibling ".sdr" by name -- turning
-- thousands of per-book stats into a handful of directory reads. The hash
-- location isn't name-derivable (it needs the file's partialMD5), so when it's
-- in play we fall back to the exact per-book probe (rare: only if a hash
-- sidecar tree exists or it's the preferred location).
local _dir_entry_cache = {}
local function _invalidateCustomMetaGate()
    _dir_entry_cache = {}
end
local function _dirHasEntry(dir, name)
    local set = _dir_entry_cache[dir]
    if not set then
        set = {}
        local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
        if ok_lfs and lfs and lfs.attributes(dir, "mode") == "directory" then
            pcall(function()
                for entry in lfs.dir(dir) do set[entry] = true end
            end)
        end
        _dir_entry_cache[dir] = set
    end
    return set[name] == true
end
-- True when a custom_metadata.lua COULD exist for `filepath` in a location we
-- can resolve by name (doc sibling / dir mirror). Conservative: any
-- uncertainty (hash location active, unparseable path) returns true so the
-- caller does the exact probe.
local function _customMetaPossible(filepath)
    -- No lfs (e.g. the standalone test harness) -> can't list dirs; be safe
    -- and let the caller do the exact probe.
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not (ok_lfs and lfs) then return true end
    local ok_ds, DocSettings = pcall(require, "docsettings")
    if not ok_ds or not DocSettings then return true end
    local pref = G_reader_settings
        and G_reader_settings:readSetting("document_metadata_folder", "doc") or "doc"
    if pref == "hash" then return true end
    if DocSettings.isHashLocationEnabled and DocSettings.isHashLocationEnabled() then
        return true
    end
    -- .sdr dir name mirrors getSidecarDir: path minus the last suffix + ".sdr".
    local base = filepath:match("^(.*)%.") or filepath
    local parent, stem = base:match("^(.*/)([^/]+)$")
    if not (parent and stem) then return true end
    local sdr = stem .. ".sdr"
    if _dirHasEntry(parent, sdr) then return true end          -- doc (sibling)
    local ok_dst, DataStorage = pcall(require, "datastorage")
    if ok_dst and DataStorage and DataStorage.getDocSettingsDir then
        local root = DataStorage:getDocSettingsDir()
        if root and _dirHasEntry(root .. parent, sdr) then return true end  -- dir (mirror)
    end
    return false
end

-- The KOReader custom Keywords override (.sdr custom_props.keywords) for a book,
-- or nil when none is set. An explicit empty string is preserved (the user
-- cleared the keywords) so the embedded source reads as "no genres", not a
-- fall-back to the file's own keywords.
local function _customKeywords(filepath)
    if not filepath then return nil end
    local ok, DocSettings = pcall(require, "docsettings")
    if not (ok and DocSettings and DocSettings.findCustomMetadataFile) then return nil end
    -- Cheap gate: skip the per-book multi-location stat when no sidecar dir
    -- that could hold a custom_metadata.lua exists for this book.
    if not _customMetaPossible(filepath) then return nil end
    local cmf = DocSettings:findCustomMetadataFile(filepath)
    if not cmf then return nil end
    local ok2, cp = pcall(function()
        return DocSettings.openSettingsFile(cmf):readSetting("custom_props")
    end)
    if ok2 and type(cp) == "table" and cp.keywords ~= nil then return cp.keywords end
    return nil
end

-- Per-source genre lists (each nil when that source has none for this book).
local function _calibreGenres(cb)
    if cb and type(cb.tags) == "table" and #cb.tags > 0 then return splitGenreTags(cb.tags) end
    return nil
end
local function _embeddedGenres(filepath, info)
    local kw = _customKeywords(filepath)
    if kw == nil then kw = info and info.keywords end
    if kw and kw ~= "" then return splitGenreTags(kw) end
    return nil
end

-- Resolve a book's genres honouring the per-book source preference, AND return
-- the per-source lists (for the source chip bar). Calibre and embedded are
-- resolved here; "hardcover" leaves the base (calibre > embedded), which
-- Hardcover.enrichBook then overrides (and stamps sources.hardcover). No
-- preference = auto priority calibre > embedded (the previous behaviour).
-- Returns: resolved_list, sources_table { calibre=, embedded= }.
local function genreData(filepath, cb, info)
    local calibre  = _calibreGenres(cb)
    local embedded = _embeddedGenres(filepath, info)
    local pref = BookshelfSettings.genreSource and BookshelfSettings.genreSource(filepath)
    local resolved
    if pref == "calibre"  and calibre  then resolved = calibre
    elseif pref == "embedded" and embedded then resolved = embedded
    else resolved = calibre or embedded end
    return resolved, { calibre = calibre, embedded = embedded }
end

-- Write an edit of the embedded genres to KOReader's custom Keywords override
-- (the same field Show info edits), shared both ways. `genres` is the full
-- replacement list; an empty list clears the keywords (shows as no genres).
-- Creates the custom-metadata file with a copy of the original doc_props (as
-- KOReader expects) when none exists, flushes it, and broadcasts so KOReader's
-- own book-info UIs refresh. Invalidates the book cache so genres re-resolve.
function Repo.setEmbeddedGenres(filepath, genres)
    if not filepath then return end
    local DocSettings = require("docsettings")
    local keywords = (type(genres) == "table" and #genres > 0)
        and table.concat(genres, ", ") or ""
    local cmf = DocSettings:findCustomMetadataFile(filepath)
    local cds
    if cmf then
        cds = DocSettings.openSettingsFile(cmf)
    else
        cds = DocSettings.openSettingsFile()
        -- KOReader's own setCustomMetadata stashes a copy of the ORIGINAL
        -- doc_props here (title/authors/keywords/...) so a never-opened book
        -- still resolves its metadata when CoverBrowser is off. A never-opened
        -- book has no regular sidecar, so DocSettings:open() yields nothing;
        -- fall back to BIM's extracted props (originals, no custom file exists
        -- yet to overlay) so the copy isn't empty.
        local props
        local ok, sds = pcall(function() return DocSettings:open(filepath) end)
        if ok and sds then props = sds:readSetting("doc_props") end
        if not props or next(props) == nil then
            local ok_bim, BookInfoManager = pcall(require, "bookinfomanager")
            if ok_bim and BookInfoManager and BookInfoManager.getDocProps then
                local bim_props = BookInfoManager:getDocProps(filepath)
                if bim_props and next(bim_props) ~= nil then props = bim_props end
            end
        end
        cds:saveSetting("doc_props", props or {})  -- originals, for restore/“customized”
    end
    local custom_props = cds:readSetting("custom_props", {})
    custom_props.keywords = keywords
    cds:flushCustomMetadata(filepath)
    -- The file's effective keywords changed: drop the grouping caches AND the
    -- light-meta records (invalidateBookCache keeps the latter warm) so genres
    -- re-resolve from the new override on the next read.
    Repo.invalidateBookCache("embedded-genres")
    Repo.invalidateLightMeta()
    local ok_ev, Event = pcall(require, "ui/event")
    local ok_um, UIManager = pcall(require, "ui/uimanager")
    if ok_ev and ok_um then
        -- InvalidateMetadataCache deletes BIM's cached row so its next
        -- getDocProps re-extracts and overlays the new keywords; without it
        -- KOReader's Show-info keeps showing the pre-edit keywords (it reads
        -- the stale cached row). BookMetadataChanged then refreshes the UIs.
        UIManager:broadcastEvent(Event:new("InvalidateMetadataCache", filepath))
        UIManager:broadcastEvent(Event:new("BookMetadataChanged", { filepath = filepath }))
    end
end

-- Supported e-book extensions (used in getCurrent and walkBooks via
-- _supportedExt). Mirrors the document formats KOReader itself registers
-- (frontend/document/*), minus pure images and code/scripts -- those are
-- openable but aren't shelf books and would surface cover/sidecar files.
-- Compound ".zip" forms (fb2.zip etc.) are handled by _supportedExt; a bare
-- ".zip"/".tar" archive is intentionally NOT a book.
local SUPPORTED_EXT = {
    -- ebooks
    epub=true, epub3=true, fb2=true, fb3=true, mobi=true, azw=true,
    azw3=true, prc=true, pdb=true, tcr=true, ["fb2.zip"]=true,
    -- documents
    pdf=true, djvu=true, djv=true, xps=true, chm=true, doc=true, docx=true,
    docm=true, rtf=true, odt=true,
    -- text / markup (and their zipped forms)
    txt=true, md=true, html=true, htm=true, xhtml=true, htmlz=true,
    ["html.zip"]=true, ["htm.zip"]=true, ["txt.zip"]=true,
    ["md.zip"]=true, ["rtf.zip"]=true,
    -- comics
    cbz=true, cbr=true, cbt=true,
}

-- _supportedExt(name): the supported book extension for a filename (lowercased,
-- e.g. "epub" or the compound "fb2.zip"), or nil if not a book. Handles the
-- ".zip" book forms KOReader registers (fb2.zip, html.zip, ...) without
-- treating a bare/unknown ".zip" archive as a book.
local function _supportedExt(name)
    if not name then return nil end
    local last = name:match("%.([^.]+)$")
    if not last then return nil end
    last = last:lower()
    if last == "zip" then
        local compound = name:match("%.([^.]+%.[Zz][Ii][Pp])$")
        compound = compound and compound:lower()
        return (compound and SUPPORTED_EXT[compound]) and compound or nil
    end
    return SUPPORTED_EXT[last] and last or nil
end

-- _formatLabel(fp): uppercase format label for display/grouping. Collapses a
-- compound ".zip" book to its inner kind ("book.fb2.zip" -> "FB2") so zipped
-- and plain books share one format card. Falls back to the last extension.
local function _formatLabel(fp)
    if not fp then return nil end
    local ext = _supportedExt(fp) or fp:match("%.([^.]+)$")
    if not ext or ext == "" then return nil end
    return (ext:gsub("%.[Zz][Ii][Pp]$", "")):upper()
end

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

-- Last-good Book records keyed by filepath, used by buildBookMeta to
-- mask BIM's transient "in_progress=1" wipe of metadata fields during
-- a re-extraction. Persists across renders and across invalidateBookCache
-- (the per-chip caches clear, but each book's record stays so a refresh
-- cycle doesn't flicker to fallback rendering). Memory: one record per
-- visited filepath; typical session sees a few hundred entries at
-- ~500 bytes each, so well under 1 MB on a 17k-book library.
local _meta_record_cache = {}

local function getBookInfoMgr()
    if _bim_cache ~= nil then
        return _bim_cache or nil
    end
    local ok, mod = pcall(require, "bookinfomanager")
    _bim_cache = (ok and mod) or false
    return _bim_cache or nil
end

local _hardcover_cache
local function getHardcover()
    if _hardcover_cache ~= nil then
        return _hardcover_cache or nil
    end
    local ok, mod = pcall(require, "lib/bookshelf_hardcover")
    _hardcover_cache = (ok and mod) or false
    return _hardcover_cache or nil
end

-- Public: true if BookInfoManager is available (CoverBrowser enabled).
-- main.lua queries this at init to decide whether to take over the home
-- screen or bail with a "Bookshelf requires CoverBrowser" notification.
function Repo.hasBookInfoManager()
    return getBookInfoMgr() ~= nil
end
local function getDocSettings()  return require("docsettings") end

-- The shelf render already prefers book.cover_image_path over the embedded
-- cover, but that field is only ever set by Hardcover today. The Cover picker
-- (bookshelf_cover_apply) writes a native custom cover for ANY book, so point
-- cover_image_path at it here too. Gated on the tiny "cover_choices" map so the
-- findCustomCoverFile disk probe is paid only for books this feature actually
-- customised -- not on every book on every render. Runs just before
-- Hardcover.enrichBook, which may still override for a linked, use_cover book.
local function _applyCustomCoverIfCustomized(book)
    if type(book) ~= "table" or not book.filepath then return end
    local choices = BookshelfSettings.read("cover_choices")
    if type(choices) ~= "table" or choices[book.filepath] == nil then return end
    local ds = getDocSettings()
    local ok, custom = pcall(ds.findCustomCoverFile, ds, book.filepath)
    if ok and type(custom) == "string" and custom ~= "" then
        book.cover_image_path = custom
    end
end

-- _hasSidecar(filepath): does KOReader hold DocSettings (a metadata sidecar)
-- for this book? Used as the cheap "has it ever been opened?" gate before the
-- much heavier Repo.readProgress (DocSettings:open) on status/rating filters
-- and sort prefetches.
--
-- KOReader's "Book metadata location" setting stores the .sdr alongside the
-- book ("doc", the default), in a central folder ("dir"), or by partial-hash
-- ("hash"). The old gate statted only the sibling "<book>.sdr" dir, so for
-- "dir"/"hash" users no sidecar was ever found and every book read as unread /
-- unrated in filters and sorts while covers showed the real status (issue
-- #117). DocSettings:hasSidecarFile checks the correct location(s) and only
-- stats (no Lua parse), so it preserves the "don't open every sidecar"
-- optimisation from #113 -- it just looks in the right place.
-- Memoized per filepath: status/rating filter sweeps call this for every
-- candidate on every evaluation, and the books that benefit from the
-- cheap gate (never opened, no sidecar) are exactly the ones that never
-- enter _progress_cache - so without a memo they re-stat each sweep.
-- Invalidation mirrors the progress cache (Repo.invalidateProgressCache):
-- closing a book is the only in-app way a sidecar appears.
local _sidecar_memo = {}
local function _hasSidecar(filepath)
    if not filepath then return false end
    local memo = _sidecar_memo[filepath]
    if memo ~= nil then return memo end
    local res = false
    local ds = getDocSettings()
    if ds and ds.hasSidecarFile then
        local ok, r = pcall(ds.hasSidecarFile, ds, filepath)
        if ok then res = r and true or false end
    end
    _sidecar_memo[filepath] = res
    return res
end

-- Hard ceiling on how many items a single fetch will HYDRATE (build a Book
-- record + decompress a cover for). Real pagination shows a screenful; a limit
-- anywhere near this means a caller pointed a hydrating fetcher at "everything"
-- instead of enumerating via the light getGroupChoices path. We clamp rather
-- than honour it, so the mistake degrades to an incomplete page + a logged
-- warning instead of an out-of-memory SIGKILL (which Lua cannot catch).
local MAX_HYDRATE = 512
-- light_only: when the caller wants only light metadata (one batched SELECT,
-- no full Book records, no cover decompress) the hydration ceiling doesn't
-- apply -- it exists solely to stop a runaway HYDRATING fetch from OOM-killing
-- the app. Clamping a light fetch silently truncated full-list consumers like
-- the "Go to letter" jump at exactly 512 items (#229).
local function _hydrationStop(offset, limit, total, default_limit, who, light_only)
    offset = offset or 0
    local want = limit or default_limit or 8
    if not light_only and want > MAX_HYDRATE then
        logger.warn(string.format(
            "[bookshelf] %s asked to hydrate %s items; clamping to %d "
            .. "(use getGroupChoices / a light path for full lists)",
            tostring(who), tostring(want), MAX_HYDRATE))
        want = MAX_HYDRATE
    end
    return math.min(offset + want, total)
end

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
local function _safeBuildBookMeta(fp, opts)
    local ok, b = pcall(Repo.buildBookMeta, fp, opts)
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
    for _i, name in ipairs({ "metadata.calibre", ".metadata.calibre" }) do
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
    for _i, book in ipairs(data) do
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
    favorites  = "updated",        -- newly favourited / unfavourited books float
    series     = "latest_read",
    authors    = "latest_read",
    genres     = "latest_read",
    tags       = "latest_read",
    formats    = "name",
    languages  = "book_count",
}

local _SORT_VALID = {
    all        = {
        title = true, natural = true, date_added = true,
        size  = true, format  = true, last_read  = true,
        percent_unopened_first = true, percent_unopened_last = true,
        percent_natural        = true,
    },
    latest     = { mtime = true },
    favorites  = { updated = true, date_added = true, title = true,
                   recently_read = true },
    series     = { name = true, latest_read = true, book_count = true },
    authors    = { name = true, latest_read = true, book_count = true },
    genres     = { name = true, latest_read = true, book_count = true },
    tags       = { name = true, latest_read = true, book_count = true },
    formats    = { name = true, latest_read = true, book_count = true },
    languages  = { name = true, latest_read = true, book_count = true },
}

-- getSortPriority(tab_id): returns the priority list for a tab, falling back
-- to the legacy single-key sort if no tab schema is present. This is the
-- bridge function during the v1.2 transition -- once Phase 2's editor lands,
-- the schema will always carry sort_priority and the legacy fallback can
-- be deleted.
local TabModel   = require("lib/bookshelf_tab_model")
local SortEngine = require("lib/bookshelf_sort_engine")
local BookshelfLang = require("lib/bookshelf_lang")

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

-- buildBookMeta(filepath [, opts])
-- opts.want_cover: when false, ask BIM with get_cover=false so the zstd
-- decompression + Blitbuffer allocation are skipped entirely (see
-- bookinfomanager.lua line 376-379). Callers who already know the
-- scaled cover is cached elsewhere (ScaledCoverCache) pass false to
-- avoid the wasted decode-then-immediately-free dance on warm-cache
-- pagination. Cover-needing callers (hero, series stack, folder card)
-- omit opts and get the default true.
--
-- The returned record's cover_bb is nil when want_cover=false. SpineWidget
-- handles a nil cover_bb by checking ScaledCoverCache first, then falling
-- back to Repo.getCoverBB(filepath) for a synchronous lazy decode.
function Repo.buildBookMeta(filepath, opts)
    if not filepath then return nil end
    local want_cover = not opts or opts.want_cover ~= false
    local bim  = getBookInfoMgr()
    if not bim then return nil end  -- CoverBrowser disabled (#49)
    -- BIM opens / queries its own SQLite database here. The DB can be
    -- transiently inaccessible during a fresh USB import (BIM itself
    -- is mid-write, file-locked, or the database is being recreated
    -- entirely). Without pcall, the SQLite error bubbles all the way
    -- up to UIManager and crashes KOReader — reported by issue #63
    -- where importing books over USB triggered "Uh oh, something went
    -- awry" on the next paginate-and-rehydrate. Catch the error,
    -- continue with empty BIM info so file-based metadata fallbacks
    -- (Calibre JSON, filename-derived title) still populate the
    -- record; a later rebuild after BIM finishes will fill in the
    -- gaps.
    local ok_bim, info_or_err = pcall(bim.getBookInfo, bim, filepath, want_cover)
    if not ok_bim then
        logger.warn("[bookshelf] BIM getBookInfo failed for", filepath, ":",
                    tostring(info_or_err))
    end
    local info = (ok_bim and info_or_err) or {}
    -- Sticky-record cache. BIM's getBookInfo SELECT has a "WHERE
    -- in_progress=0" guard, so a row that's mid-extraction returns
    -- nil. Without this fallback, every cover-only re-extraction
    -- nulls the row briefly while BIM writes its "in_progress"
    -- placeholder, this function returns a minimal record, and the
    -- spine widget downgrades to fallback (filename) rendering --
    -- the user sees title/author/series flicker out and back in
    -- around the moment the cover finishes loading. Return the last
    -- good record we built for this file when BIM doesn't currently
    -- have usable metadata for it.
    if not info.has_meta and _meta_record_cache[filepath] then
        local cached = shallowCopyRecord(_meta_record_cache[filepath])
        _applyCustomCoverIfCustomized(cached)
        local Hardcover = getHardcover()
        if Hardcover and Hardcover.enrichBook then
            pcall(Hardcover.enrichBook, cached)
        end
        return cached
    end
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
        -- Guard empty / whitespace / name-less ("#3") embedded series: the
        -- Calibre branch above already drops cb.series == "", so mirror it
        -- here. Without this an empty series_name bucketed the book into a
        -- junk single-book series stack even though KOReader's book info
        -- shows the series as N/A (issue #127, non-Calibre libraries).
        local sname = info.series:gsub(" #%d+$", "")
        sname = sname:match("^%s*(.-)%s*$")  -- trim
        if sname ~= "" then series_name = sname end
        series_num = info.series:match(" #(%d+)$")
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
        authors = splitAuthors(info.authors, filepath)
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

    -- Genres honour the per-book source preference (calibre / embedded /
    -- hardcover); with none set, auto priority Calibre > embedded. The Hardcover
    -- override (when chosen, or auto + sync) is applied later by enrichBook.
    local genres, genre_sources = genreData(filepath, cb, info)

    local book = {
        filepath    = filepath,
        filename    = filename,
        format      = _formatLabel(filepath) or "",
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
        -- Per-source genre lists for the book-detail Tags tab's source chip bar
        -- (Hardcover added by enrichBook). Cheap by-products of genre resolution.
        genre_sources = genre_sources,
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
        -- Original (pre-thumbnail) cover dimensions BIM records as "WxH",
        -- e.g. "1072x1448". Used by the Hardcover enricher to decide whether
        -- the embedded cover is lower resolution than Hardcover's.
        cover_sizetag = info.cover_sizetag,
        lang        = (cb and type(cb.languages) == "table" and cb.languages[1])
                       or info.language,
        description = (cb and type(cb.comments) == "string" and cb.comments ~= "")
                       and cb.comments
                       or (info.description and info.description ~= ""
                           and info.description)
                       or nil,
        page_count  = info.pages,
    }
    -- Cache fresh records whose text metadata is present, with the
    -- cover_bb stripped. ImageWidget marks the cover_bb's
    -- image_disposable=true after first paint -- it's a one-shot
    -- BlitBuffer. Caching the bb pointer and returning it on the
    -- next call (when BIM's in_progress=1 wipe makes this function
    -- fall back to the cache) reads freed C memory and corrupts the
    -- render -- visible as folder cover garbage on the home screen.
    -- Strip the bb here; the cache serves only text fields, and a
    -- nil cover_bb on the cached path makes the spine fall back to
    -- the paper-tone "no cover" state for that brief in-progress
    -- window. That's a far smaller visual change than the previous
    -- text-disappears flicker, and BIM's next successful commit
    -- restores the full record (with a fresh bb) on the very next
    -- poll.
    if info.has_meta == "Y" then
        local cached = {}
        for k, v in pairs(book) do
            if k ~= "cover_bb" then cached[k] = v end
        end
        _meta_record_cache[filepath] = cached
    end
    _applyCustomCoverIfCustomized(book)
    local Hardcover = getHardcover()
    if Hardcover and Hardcover.enrichBook then
        pcall(Hardcover.enrichBook, book)
    end
    return book
end

-- Repo.getCoverBB(filepath) — lazy cover accessor for callers that
-- skipped the cover decode in buildBookMeta(opts.want_cover=false). Hands
-- back BIM's freshly-decoded BlitBuffer (or nil if BIM has no cover row
-- or its row is mid-extraction). The caller OWNS the returned bb; pass
-- it to ImageWidget with image_disposable=true or free() it explicitly
-- after use. Same pcall guard as buildBookMeta for the import-window
-- crash path.
function Repo.getCoverBB(filepath)
    if not filepath then return nil end
    local bim = getBookInfoMgr()
    if not bim then return nil end
    local ok_bim, info_or_err = pcall(bim.getBookInfo, bim, filepath, true)
    if not ok_bim then
        logger.warn("[bookshelf] BIM getBookInfo (cover only) failed for",
                    filepath, ":", tostring(info_or_err))
        return nil
    end
    local info = info_or_err or {}
    if info.ignore_cover then return nil end
    return info.cover_bb
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
        -- Guard empty / whitespace / name-less ("#3") embedded series: the
        -- Calibre branch above already drops cb.series == "", so mirror it
        -- here. Without this an empty series_name bucketed the book into a
        -- junk single-book series stack even though KOReader's book info
        -- shows the series as N/A (issue #127, non-Calibre libraries).
        local sname = info.series:gsub(" #%d+$", "")
        sname = sname:match("^%s*(.-)%s*$")  -- trim
        if sname ~= "" then series_name = sname end
        series_num = info.series:match(" #(%d+)$")
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
        authors = splitAuthors(info.authors, fp)
    end

    local genres, genre_sources = genreData(fp, cb, info)

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
    local rec = {
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
        genre_sources = genre_sources,
        title       = title,
        lang        = (cb and type(cb.languages) == "table" and cb.languages[1])
                       or info.language,
    }
    -- Apply the global "Use Hardcover metadata" override here too, so the
    -- genre / author / series chips (built from these light records) switch
    -- over with the per-book tag pills. Cheap (memoized link + cache reads,
    -- no file I/O) and a no-op when the toggle is off / book isn't linked.
    local Hardcover = getHardcover()
    if Hardcover and Hardcover.applyMetadata then
        pcall(Hardcover.applyMetadata, rec)
    end
    return rec
end

local function _buildBookMetaLight(fp)
    if not fp then return nil end
    local bim  = getBookInfoMgr()
    if not bim then return nil end  -- CoverBrowser disabled (#49)
    -- pcall-guarded; see buildBookMeta for rationale (#63/#71).
    local ok_bim, info_or_err = pcall(bim.getBookInfo, bim, fp, false)
    if not ok_bim then
        logger.warn("[bookshelf] BIM getBookInfo (light) failed for", fp, ":",
                    tostring(info_or_err))
    end
    local info = (ok_bim and info_or_err) or {}
    return _buildLightMetaFromInfo(fp, info)
end

-- Forward declarations: the per-file progress cache lives with the other
-- caches further down, but buildBook (below) seeds it from the
-- DocSettings handle it opens, and Lua upvalue scoping needs the local
-- to exist before that function body is compiled.
local _progress_cache, PROGRESS_CACHE_TTL

-- #159: a "p(<n>)" token in a filename (e.g. "Caliban's War - p(624).epub")
-- gives a publisher/preferred page count for books KOReader can't page-count
-- until they're rendered — unopened reflowable formats, which have no BIM,
-- pagemap or stats count. Used ONLY as a last resort (a real rendered/stable
-- count always wins) and inert for filenames without the token, so it costs
-- nothing unless the user opts in by adopting the naming convention. Matched
-- case-insensitively on the basename only; the book's display title comes from
-- metadata, not the filename, so this never changes the shown name.
local function pageCountFromFilename(filepath)
    if type(filepath) ~= "string" then return nil end
    local base = filepath:match("([^/]+)$") or filepath
    local n = base:match("[Pp]%((%d+)%)")
    return n and tonumber(n) or nil
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
    --
    -- ds_page_count is derived unconditionally (not just when BIM left
    -- page_count nil) because it doubles as the progress-cache seed
    -- below, which must match what readProgress would compute for this
    -- file - readProgress never sees BIM's count.
    local ds_page_count
    do
        local stable_pages = ds:readSetting("pagemap_doc_pages")
        if stable_pages then ds_page_count = tonumber(stable_pages) end
        if not ds_page_count then
            local stats = ds:readSetting("stats")
            if type(stats) == "table" and stats.pages then
                ds_page_count = tonumber(stats.pages)
            end
        end
    end
    -- #159: fall back to a p(<n>) token in the filename when there's no
    -- sidecar-derived count (unopened reflowable books). ds-or-filename also
    -- seeds the progress cache below, so it must match what readProgress
    -- computes (which never sees BIM's count).
    local fallback_page_count = ds_page_count or pageCountFromFilename(filepath)
    if not book.page_count then
        book.page_count = fallback_page_count
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
    -- Seed the progress cache from the DocSettings handle we already
    -- paid to open, so a readProgress(fp) that follows (status badges,
    -- filters, sort keys) is a table lookup instead of a second sidecar
    -- parse. Field values mirror readProgress exactly: same status
    -- normalisation (applied above), and ds_page_count rather than
    -- book.page_count, which may carry BIM's count that readProgress
    -- never sees.
    _progress_cache[filepath] = {
        pct        = tonumber(book.book_pct),
        status     = book.status,
        rating     = book.rating,
        page_count = fallback_page_count,
        expires_at = os.time() + PROGRESS_CACHE_TTL,
    }
    return book
end

-- ─── getCurrent ──────────────────────────────────────────────────────────────
-- Returns the Book record for the last opened file, or nil if none.

-- Kobo books open via a decrypted /tmp copy, so KOReader's lastfile is that
-- temp path (no extension), not the virtual book -- the hero would never tie it
-- back. _openBook calls noteKoboOpen so getCurrent/currentFilepath can map that
-- temp path to the virtual Kobo record (#203). In-memory only (lost on restart,
-- as is the temp file). [[project_kobo_virtual_library_integration]]
local _last_kobo_open = nil
function Repo.noteKoboOpen(decrypted_path, record)
    if decrypted_path and record then
        _last_kobo_open = { path = decrypted_path, record = record, virtual = record.filepath }
    end
end

function Repo.getCurrent()
    local lastfile = G_reader_settings:readSetting("lastfile")
    if _last_kobo_open and lastfile == _last_kobo_open.path then
        -- Recently-opened Kobo book: return a fresh shallow copy of the virtual
        -- record with a fresh cover, so the hero shows it as current.
        local r = {}
        for k, v in pairs(_last_kobo_open.record) do r[k] = v end
        local ok_k, KoboSource = pcall(require, "lib/bookshelf_kobo_source")
        if ok_k and KoboSource and r.filepath then
            local bb, cw, ch = KoboSource.coverBB(r.filepath)
            if bb then r.cover_bb, r.cover_w, r.cover_h, r.has_cover = bb, cw, ch, true end
        end
        return r
    end
    local fp = Repo.currentFilepath()
    if not fp then return nil end
    return Repo.buildBook(fp)
end

-- Repo.currentFilepath() — the filepath getCurrent() would build, or nil,
-- WITHOUT touching BIM / DocSettings. Lets callers (the hero memo) key on
-- the current book without paying the lockable getBookInfo read just to
-- learn its path. Applies the same supported-format gate as getCurrent so
-- stale PNGs / config files / opened-once non-books don't claim the hero.
function Repo.currentFilepath()
    local lastfile = G_reader_settings:readSetting("lastfile")
    if not lastfile then return nil end
    -- A just-opened Kobo book: report the virtual path (which ends .epub, so it
    -- passes the format gate) instead of the extensionless /tmp decrypted copy.
    if _last_kobo_open and lastfile == _last_kobo_open.path then
        return _last_kobo_open.virtual
    end
    if not _supportedExt(lastfile) then return nil end
    return lastfile
end

-- ─── getRecent ───────────────────────────────────────────────────────────────
-- Returns up to `limit` Book records from ReadHistory.hist, in order
-- (ReadHistory keeps hist sorted newest-first already). No exclusion —
-- the active book stays visible in the shelf, and the BookshelfWidget
-- highlights the previewed spine instead so the user can tell which one
-- the hero is currently displaying. Earlier iterations excluded lastfile
-- to avoid hero+slot-1 duplication; that exchange wasn't worth the
-- shelves jumping around as the user browsed previews.

-- opts.lazy_cover: when true, per-book ScaledCoverCache probe; on
-- cache hit, pass want_cover=false to buildBookMeta to skip the BIM
-- zstd decompress.
function Repo.getRecent(limit, offset, opts)
    local rh   = getReadHistory()
    offset     = offset or 0
    limit      = limit or 8
    if not (opts and opts.light_only) and limit > MAX_HYDRATE then
        logger.warn(string.format("[bookshelf] getRecent asked to hydrate %s; clamping to %d",
            tostring(limit), MAX_HYDRATE))
        limit = MAX_HYDRATE
    end
    local out  = {}
    local ScaledCoverCache
    if opts and opts.lazy_cover then
        ScaledCoverCache = require("lib/bookshelf_scaled_cover_cache")
    end
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
                local meta_opts
                if ScaledCoverCache and ScaledCoverCache:has(entry.file) then
                    meta_opts = { want_cover = false }
                end
                local book = Repo.buildBookMeta(entry.file, meta_opts)
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
-- Lifting the cap on desktop runs (home_dir = $HOME) walks the entire
-- user tree at unbounded depth and locks up the UI — keep the
-- conservative default and let users opt into a deeper walk via the
-- settings spinner if their library lives more than three levels deep.
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
-- Invalidation (now purely event-driven, 2026-05-28): NONE of the metadata
-- caches consult `expires_at` any more. The TTL constants are kept defined
-- for documentation / cache-struct shape stability, but every HIT path
-- treats any cached entry as fresh. Freshness comes from three explicit
-- signals:
--   * cachedWalk's dir-mtime check picks up filesystem-level changes
--     (sideloaded books, deletions, renames) on every walk.
--   * BookMetadataChanged (KOReader event) -> Bookshelf:onBookMetadataChanged
--     calls Repo.invalidateBookCache, which clears _progress_cache,
--     _light_meta_cache, _bySource_cache and the per-group caches.
--   * Swipe-down on the home screen calls Repo.invalidateWalkCache() to
--     wipe everything (the user's manual escape hatch for external app
--     changes that don't fire BookMetadataChanged).
-- Cover bitmaps remain bounded by ScaledCoverCache's LRU; everything else
-- stays warm until something explicitly invalidates it.
--
-- This replaces the previous belt-and-braces TTL fallback (24 h on group
-- / shape caches, 120 s on _progress_cache, 30 s on _stats_cache). In
-- practice the TTLs were never the load-bearing invalidation -- the event
-- hooks already cover the cases that matter -- and within a single
-- session the TTLs only ever cost work without preventing staleness that
-- the events hadn't already cleared.
local WALK_CACHE_TTL = 24 * 3600  -- vestigial; HIT paths no longer consult expires_at
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
local _series_cache    = {}  -- { [key] = { groups = {...}, standalones = {...}, expires_at = number } }
-- Authors and Genres group caches. Same TTL + invalidation pattern as
-- the series cache: filepaths-only "shape" so the cover_bb lifetime
-- hazard from caching Book records doesn't apply.
local _authors_cache   = {}
local _genres_cache    = {}
local _formats_cache   = {}
local _ratings_cache   = {}
local _languages_cache = {}
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
-- Folder→bookpaths cache. Used by selection-mode plumbing to answer
-- "which book filepaths live (recursively) under this folder?" without
-- redoing an lfs scan per query. The cached walk-list already knows the
-- answer; we just prefix-filter it once per (folder, walk-generation)
-- and memoise. Invalidated alongside the walk cache and inside
-- cachedWalk's files-changed branch.
local _folder_book_paths_cache = {}  -- { [path] = { paths = {...} } }
-- Per-file progress cache. DocSettings:open() does a Lua-parse from disk
-- per call, which dominates loops that read percent / summary.status for
-- many books in a row (getAll's prefetch on the Home chip is the obvious
-- one). Caching the parsed result for a short window cuts repeat scans
-- to memory reads.
--
-- Invalidation: onCloseDocument explicitly drops the just-closed file via
-- invalidateProgressCache(fp); invalidateWalkCache wipes the whole map as
-- a belt-and-braces refresh for any sideloaded / metadata-edited cases.
--
-- NOTE: declared (as locals) above Repo.buildBook, which seeds this
-- cache; assigned here so they live with the rest of the cache block.
PROGRESS_CACHE_TTL = 120  -- seconds
_progress_cache    = {}   -- filepath → { pct, status, expires_at }

-- Forward declarations so invalidateWalkCache below resolves these to the
-- module-local tables created later (Repo.folderHasBooks's memo at
-- ~line 1206 and _normalizeGenre's memo at ~line 1994). Without these
-- forward decls, the assignments inside invalidateWalkCache would write
-- to globals (not the locals the readers consult), so the invalidation
-- would silently no-op.
local _folderHasBooks_cache
local _normalize_genre_cache
local _normalize_author_cache
local _normalize_lang_cache
-- Filter helpers used by group fetchers / hydrators / getAll. Their
-- definitions live further down (near _buildGroups for readability)
-- but several call sites — getTags, getAll's folder-filter pass,
-- hydrateSeriesShape, getSeriesGroups — appear earlier in the file.
-- Without forward decls, Lua treats those references as globals and
-- the chip rebuild crashes at runtime with "attempt to call global
-- '_shapeHasFilteredBook' (a nil value)".
local _normalizeGenre
local _normalizeLang
local _normalizeStatus
local _statusForFp
local _filterIsActive
local _shapeHasFilteredBook
local _shapeVisible
local _applyFilter
local _recordMatches

function Repo.invalidateWalkCache()
    _walk_cache       = {}
    _series_cache     = {}
    _authors_cache    = {}
    _genres_cache     = {}
    _formats_cache    = {}
    _ratings_cache    = {}
    _languages_cache  = {}
    _all_cache        = {}
    _bySource_cache   = {}
    _light_meta_cache = {}
    _folder_book_paths_cache = {}
    _progress_cache   = {}
    -- Sidecar dirs may have appeared/vanished (sideload, new books), so the
    -- custom-metadata fast gate must re-list on the next derive.
    _invalidateCustomMetaGate()
    -- _sidecar_memo travels with _progress_cache everywhere: a walk
    -- invalidation can mean sideloaded sidecars (Syncthing, USB), so the
    -- "has it ever been opened?" answers may have changed too.
    _sidecar_memo     = {}
    -- _folderHasBooks_cache: memoizes whether a folder contains a book at
    -- any depth. Previously preserved across invalidations so the negative-
    -- result-for-an-empty-folder didn't have to re-walk. Trouble: when a
    -- book is *added* to a folder that previously had none, the cache
    -- returns the stale "false" and the folder is hidden from Home until
    -- the session restarts. Wiping here costs a re-walk on the next render
    -- but keeps Home in sync with the user's actual library.
    _folderHasBooks_cache = {}
    -- _normalize_genre_cache: production it's harmless to keep (genre
    -- strings don't change), but per-test state pollution breaks isolation
    -- if a test injects different genre keys under the same input shape.
    -- Negligible production cost to rebuild.
    _normalize_genre_cache = {}
    _normalize_author_cache = {}
    _normalize_lang_cache  = {}
    -- Force getBookInfoMgr to re-resolve via require on its next call. In
    -- production this is a no-op cost (require's own cache returns the same
    -- module instantly), but it lets tests that swap the bookinfomanager
    -- stub between cases actually see the new stub -- previously the first
    -- test's BIM was sticky for the whole suite.
    _bim_cache = nil
end

function Repo.invalidateSeriesCache()
    _series_cache     = {}
    _authors_cache    = {}
    _genres_cache     = {}
    _formats_cache    = {}
    _ratings_cache    = {}
    _languages_cache  = {}
    _light_meta_cache = {}
end

-- invalidateAllCache(): drop just the getAll shape cache. Used when a
-- setting that controls All/Folder sort or partition (e.g. KOReader's
-- collate_mixed) changes — those settings are part of the cache key,
-- but pre-existing keyed entries shouldn't linger as warm slots the
-- user no longer wants to fall back into. Walk cache and group shape
-- caches are untouched (their data isn't affected by these settings).
function Repo.invalidateAllCache()
    _all_cache = {}
end

-- invalidateFavoritesCache(): drop only _bySource_cache entries keyed on
-- the favourites chip. Called when bookshelf knows the favourites set
-- has just been mutated (★ toggle in the book menu, bulk add/remove,
-- etc.) so the next visit to the Favourites view reflects the change
-- without forcing the user to swipe-down for a full library refresh.
--
-- Targets only favourites because the broader caches (walk, group
-- shape, all) are unaffected by collection membership and shouldn't
-- be invalidated for this kind of edit -- doing so would force an
-- expensive re-walk when the user next switches to Authors / Series /
-- etc., which is wasteful.
--
-- Two cache-key shapes can hold favourites lists:
--   * "favorites|..."             — the built-in tab (source.kind="favorites")
--   * "collection|favorites|..."  — a user-built chip pointing at the
--                                   default ReadCollection ("favorites")
-- Strip both so a ★ toggle invalidates whichever shape the user has on
-- their favourites chip(s).
function Repo.invalidateFavoritesCache()
    for k in pairs(_bySource_cache) do
        if k:sub(1, 10) == "favorites|"
                or k:sub(1, 21) == "collection|favorites|" then
            _bySource_cache[k] = nil
        end
    end
end

-- invalidateReadStateCache(): drop only the _bySource_cache entries whose
-- SORT depends on read state — last-opened time, reading progress, or
-- read status. Called from onCloseDocument: the just-closed book's read
-- state changed (it jumped to the top of ReadHistory, its progress moved),
-- so any chip ordered by one of those keys has a stale cached filepath
-- order. The classic symptom (issue 85): in the Recent chip — whose tab
-- carries sort_priority {last_opened, reverse} and therefore routes through
-- the predicate/cache path, NOT the getRecent fast-path — a freshly-closed
-- book didn't move to the top until a manual swipe-down refresh.
--
-- Deliberately narrow: the cache key encodes each sort level as
-- "s:<key>:<r|f>" (see _bySourceCacheKey), so we match on the read-state
-- sort tokens only. Chips ordered by stable metadata (title, filename,
-- date_added, series_name, author_surname, book_count) can't have reordered
-- and keep their cache. We also leave the walk cache + light-meta cache
-- warm — read state isn't a filesystem change — so the next fetch just
-- re-sorts the cached candidates rather than re-walking the library. This
-- is the targeted alternative to invalidateWalkCache, which the swipe-down
-- refresh uses (full wipe) and which onCloseDocument intentionally avoids.
--
-- "s:read_status" (no trailing colon) intentionally matches both
-- read_status and read_status_active. rating is included because a star
-- rating set while reading lands in the sdr sidecar and can reorder a
-- rating-sorted chip; date_added (file mtime) and the metadata keys
-- (title / filename / series_name / author_surname / book_count) are NOT
-- touched by reading, so chips sorted on them keep their cache.
local READ_STATE_SORT_TOKENS = {
    "s:last_opened:", "s:percent_read:", "s:read_status", "s:rating:",
}
function Repo.invalidateReadStateCache()
    for k in pairs(_bySource_cache) do
        for _i, tok in ipairs(READ_STATE_SORT_TOKENS) do
            if k:find(tok, 1, true) then
                _bySource_cache[k] = nil
                break
            end
        end
    end
end

-- _resetLightMetaProgress(filepath)  -- nil-internal helper. The
-- predicate path in getBySource mutates _progress_fetched / _status /
-- _pct / rating ON the cached light-meta records (it caches the
-- "did we already read DocSettings for this candidate" flag so a
-- subsequent sort-needs pass doesn't repeat the work). Those
-- mutations persist for the cache's lifetime; the predicate then
-- reuses the stale snapshot on the next run.
--
-- Pre-v2.0.4 the bug was masked because _light_meta_cache had
-- WALK_CACHE_TTL=0 and was effectively always-MISS, so every fetch
-- rebuilt fresh records. Bumping the TTL exposed the mutation as a
-- stale-data regression: a book whose status had been changed via
-- the long-press menu (or from anywhere else) stayed in the
-- previous status-filtered chip until KOReader restart, because the
-- cached record's _progress_fetched=true short-circuited the
-- re-read. Fix: when invalidateProgressCache fires (which happens
-- on every status change and metadata edit), strip the
-- per-DocSettings mutations from any cached light-meta record for
-- the same filepath so the next predicate run reads fresh state.
-- Targets issue #40.
local function _resetLightMetaProgress(rec)
    rec._progress_fetched = nil
    rec._status           = nil
    rec._pct              = nil
    rec.rating            = nil
    rec.read_status       = nil
end

function Repo.invalidateProgressCache(filepath)
    if filepath then
        _progress_cache[filepath] = nil
        _sidecar_memo[filepath] = nil
        for _key, entry in pairs(_light_meta_cache) do
            if entry and entry.map then
                local rec = entry.map[filepath]
                if rec then _resetLightMetaProgress(rec) end
            end
        end
    else
        _progress_cache = {}
        _sidecar_memo = {}
        for _key, entry in pairs(_light_meta_cache) do
            if entry and entry.map then
                for _fp, rec in pairs(entry.map) do
                    _resetLightMetaProgress(rec)
                end
            end
        end
    end
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
    _languages_cache  = {}
    _all_cache        = {}
    _bySource_cache   = {}
    if logger and logger.dbg then
        logger.dbg("[bookshelf] cache invalidated: " .. tostring(reason))
    end
end

-- Drop the light-meta cache (the per-file records the genre/author/series
-- chips are grouped from). invalidateBookCache deliberately keeps this warm
-- (it's a BIM batch query to rebuild), but a change to the *content* of those
-- records -- e.g. toggling "Use Hardcover metadata", which rewrites
-- title/author/series/genres -- must force a rebuild or the chips stay stale.
-- The walk cache (file list) is untouched; only the per-file metadata refetches.
function Repo.invalidateLightMeta()
    _light_meta_cache = {}
    -- Re-read sidecar directories on the next derive so a freshly-written
    -- custom_metadata.lua (e.g. a genre edit) is seen by the fast gate.
    _invalidateCustomMetaGate()
end

-- Cached read of a file's percent_finished + summary.status + summary.rating
-- + page count. Returns (pct, status, rating, page_count). Any field may
-- be nil. A pcall guards a corrupt sdr sidecar so the caller's loop
-- survives single-file faults.
--
-- page_count fallback chain (same as buildBook): pagemap_doc_pages first
-- (stable count from KOReader's pagemap), then stats.pages (statistics
-- plugin's view), then a p(<n>) token in the filename (#159). Lets the
-- cover-progress page-count indicator work for EPUBs, which have no
-- BIM-reported page count — including unopened ones via the filename token.
function Repo.readProgress(filepath)
    if not filepath then return nil, nil, nil, nil end
    local now = os.time()
    local cached = _progress_cache[filepath]
    if cached then
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
    -- #159: last-resort filename fallback (see pageCountFromFilename), matching
    -- buildBook's progress-cache seed so the sort key / badge agree.
    if not page_count then
        page_count = pageCountFromFilename(filepath)
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
        -- Skip "." / ".." and any hidden file or directory (entries
        -- starting with "."). The hidden-file filter catches AppleDouble
        -- metadata companions macOS spits out when copying to FAT32
        -- (`._<filename>`, same extension as the original so the
        -- extension-only filter below lets them through as "books"),
        -- plus the usual .DS_Store / .git / .calibre-cache / etc. that
        -- never contain real books. The other walkers in this file
        -- (around lines 1222, 1269, 1406) already do this; walkBooks
        -- was the odd one out.
        if entry:sub(1, 1) ~= "." and not SYSTEM_DIR_NAMES[entry] then
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
                if _supportedExt(entry) then
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
            _folder_book_paths_cache = {}
        end
        local dir_count = 0
        for _k in pairs(dirs) do dir_count = dir_count + 1 end
        logger.dbg(string.format("[bookshelf perf] cachedWalk: MISS(%s) walk=%.0fms files=%d dirs=%d depth=%s",
            stale_reason, _dt, #fresh, dir_count, tostring(depth)))
    else
        logger.dbg(string.format("[bookshelf perf] cachedWalk: HIT files=%d ttl_left=%ds",
            #entry.list, entry.expires_at - now))
    end
    local copy = {}
    for i = 1, #entry.list do copy[i] = entry.list[i] end
    return copy
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

    local sql = "SELECT directory, filename, title, authors, series, series_index, keywords, language " ..
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
            language     = rows[8][i],
        }
    end
    return map
end

-- ─── light-meta disk snapshot ────────────────────────────────────────────────
-- The batch SELECT above is I/O-bound on the WHOLE bookinfo table: cover
-- blobs live inline in the rows, so SQLite drags every cover's pages off
-- disk even though we only read text columns. On a PW5 that's ~740ms of
-- the cold boot; on slow Android SD storage it plausibly scales to tens of
-- seconds (issue 262). Snapshot the raw row map to a small zstd file,
-- fingerprinted by the BIM db's (size, mtime): any BIM write (extraction,
-- metadata edit, prune) changes the fingerprint and falls back to the live
-- SELECT, which re-saves. Only the RAW rows are persisted — the derived
-- light records fold in Calibre metadata at derive time, which must stay
-- fresh independently of BIM.
local LIGHTMETA_SNAPSHOT_VERSION = 1

local function _bimDbFingerprint()
    local ok, DataStorage = pcall(require, "datastorage")
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not (ok and ok_lfs and DataStorage and lfs) then return nil end
    local db_path = DataStorage:getSettingsDir() .. "/bookinfo_cache.sqlite3"
    local size = lfs.attributes(db_path, "size")
    if not size then return nil end
    local mtime = lfs.attributes(db_path, "modification") or 0
    return string.format("v%d:%d:%d", LIGHTMETA_SNAPSHOT_VERSION, size, mtime)
end

local function _lightMetaPersist()
    local ok, DataStorage = pcall(require, "datastorage")
    local ok_p, Persist = pcall(require, "persist")
    if not (ok and ok_p and DataStorage and Persist) then return nil end
    local ok_new, p = pcall(Persist.new, Persist, {
        path  = DataStorage:getDataDir() .. "/cache/bookshelf.lightmeta",
        codec = "zstd",
    })
    return ok_new and p or nil
end

-- Returns the persisted raw row map when the BIM db hasn't changed since it
-- was saved, else nil.
local function _loadRowSnapshot()
    local fingerprint = _bimDbFingerprint()
    if not fingerprint then return nil end
    local p = _lightMetaPersist()
    if not p then return nil end
    local ok, t = pcall(p.load, p)
    if ok and type(t) == "table"
            and t.fingerprint == fingerprint
            and type(t.rows) == "table" then
        return t.rows
    end
    return nil
end

local function _saveRowSnapshot(rows)
    if type(rows) ~= "table" then return end
    local fingerprint = _bimDbFingerprint()
    if not fingerprint then return end
    local p = _lightMetaPersist()
    if not p then return end
    pcall(p.save, p, { fingerprint = fingerprint, rows = rows })
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
    if entry then
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
    -- Disk snapshot first: skips the blob-page-heavy SELECT entirely when
    -- the BIM db is unchanged since last save (the common cold boot).
    local snapshot = _loadRowSnapshot()
    local row_map = snapshot or _loadBatchBookInfoFromBim()
    if row_map and not snapshot then
        _saveRowSnapshot(row_map)
    end
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
    logger.dbg(string.format("[bookshelf perf] light_meta: MISS build=%.0fms cached=%d source=%s",
        (_gettime() - _t0) * 1000, count,
        snapshot and "snapshot" or (row_map and "batch" or "fallback")))
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

-- Flat list of every book filepath in the library: the same depth-capped
-- recursive walk getLatest / the series + author groups use (honours the
-- bookshelf_latest_walk_depth setting). For bulk operations that need only
-- paths, not per-book metadata. Returns a shallow copy (safe to mutate).
function Repo.getAllFilepaths()
    local home  = G_reader_settings:readSetting("home_dir") or "/"
    local depth = BookshelfSettings.read("latest_walk_depth") or 3
    -- cachedWalk yields candidate RECORDS ({ fp = "...", mtime = ... }), not
    -- bare paths (getLatest reads candidates[i].fp) -- pull the path strings.
    local paths = {}
    for _i, c in ipairs(cachedWalk(home, depth)) do
        if type(c) == "table" and type(c.fp) == "string" then
            paths[#paths + 1] = c.fp
        elseif type(c) == "string" then
            paths[#paths + 1] = c
        end
    end
    return paths
end

function Repo.getLatest(limit, offset, opts)
    local _t0 = _gettime()
    local home       = G_reader_settings:readSetting("home_dir") or "/"
    local depth      = BookshelfSettings.read("latest_walk_depth") or 3
    local candidates = cachedWalk(home, depth)
    -- "latest" chip is mtime-only by design (_SORT_VALID restricts it).
    -- Newest first.
    table.sort(candidates, function(a, b) return a.mtime > b.mtime end)
    offset      = offset or 0
    local total = #candidates
    local out   = {}
    local stop  = _hydrationStop(offset, limit, total, 8, "getLatest", opts and opts.light_only)
    local ScaledCoverCache
    if opts and opts.lazy_cover then
        ScaledCoverCache = require("lib/bookshelf_scaled_cover_cache")
    end
    for i = offset + 1, stop do
        local fp = candidates[i].fp
        local meta_opts
        if ScaledCoverCache and ScaledCoverCache:has(fp) then
            meta_opts = { want_cover = false }
        end
        local book = Repo.buildBookMeta(fp, meta_opts)
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
    max_depth = max_depth or 3
    if max_depth < 0 then return nil end
    local lfs = require("libs/libkoreader-lfs")
    local ok, iter, dir_obj = pcall(lfs.dir, path)
    if not ok then return nil end
    local files, dirs = {}, {}
    for f in iter, dir_obj do
        if f ~= "." and f ~= ".." and not f:match("^%.") then
            local fp = _joinPath(path, f)
            local attr = lfs.attributes(fp)
            local mode = type(attr) == "table" and attr.mode
                          or lfs.attributes(fp, "mode")
            if mode == "file" then
                if _supportedExt(f) then
                    files[#files + 1] = { name = f, fp = fp }
                end
            elseif mode == "directory" then
                dirs[#dirs + 1] = { name = f, fp = fp }
            end
        end
    end
    -- Files at this level take precedence over deeper subdirectories.
    table.sort(files, function(a, b) return a.name < b.name end)
    if files[1] then return files[1].fp end
    table.sort(dirs, function(a, b) return a.name < b.name end)
    for _i, e in ipairs(dirs) do
        local found = Repo.findFirstBookIn(e.fp, max_depth - 1)
        if found then return found end
    end
    return nil
end

-- folderHasBooks(path): true if `path` (recursively) contains at least one
-- supported book file. Short-circuits on first hit; memoized per-session.
-- Used by getAll to suppress empty folder cards before the user sees them.
-- Re-assignment (not `local`) so invalidateWalkCache's forward-declared
-- name at the top of the file resolves to this same upvalue.
_folderHasBooks_cache = {}

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
                            if _supportedExt(entry) then
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

-- getFolderBookPaths(path): list of every book filepath under `path` at
-- any depth (subject to the latest_walk_depth setting that bounds the
-- underlying cachedWalk). Used by selection-mode plumbing — both the
-- long-press dialog's add/remove actions and the per-paint "is this
-- folder card partially selected?" check.
--
-- Rides the existing cachedWalk: first call per folder filters the
-- cached global walk-list by path prefix and memoises. Subsequent calls
-- are an O(1) map lookup until the walk cache invalidates (which clears
-- this cache in lockstep), at which point the next call re-filters
-- against the fresh walk.
--
-- Returns a fresh array each call so callers can sort / mutate safely.
function Repo.getFolderBookPaths(path)
    if not path or path == "" then return {} end
    local cached = _folder_book_paths_cache[path]
    if cached then
        local out = {}
        for i = 1, #cached.paths do out[i] = cached.paths[i] end
        return out
    end
    local home  = G_reader_settings:readSetting("home_dir") or "/"
    local depth = BookshelfSettings.read("latest_walk_depth") or 3
    local cands = cachedWalk(home, depth)
    -- Prefix match: a book at `<path>/...` is "under" path. Append "/"
    -- so we don't match sibling folders that share a name prefix (e.g.
    -- "/Foo" must not match "/FooBar/book.epub"). Path itself may or
    -- may not end with "/" — normalise both sides.
    local prefix = path
    if prefix:sub(-1) ~= "/" then prefix = prefix .. "/" end
    local paths = {}
    for i = 1, #cands do
        local fp = cands[i].fp
        if fp and fp:sub(1, #prefix) == prefix then
            paths[#paths + 1] = fp
        end
    end
    -- Deep-nesting fallback (#202): the home-rooted walk is bounded by
    -- latest_walk_depth, so a folder whose books all sit deeper than that
    -- prefix-matches nothing -- even though drilling into it shows books
    -- (browsing scans one level per drill). When the prefix filter comes
    -- up empty, walk the asked-about folder ITSELF with the same depth
    -- budget: cost scales with that subtree only, each drill level
    -- re-anchors the budget (matching what browsing reveals), and a truly
    -- empty folder confirms cheaply. Memoised below either way; the cache
    -- clears in lockstep with the walk cache.
    if #paths == 0 then
        local found = {}
        walkBooks(path, depth, found)
        for i = 1, #found do paths[#paths + 1] = found[i].fp end
    end
    _folder_book_paths_cache[path] = { paths = paths }
    -- Return a copy so caller mutations don't poison the cache.
    local out = {}
    for i = 1, #paths do out[i] = paths[i] end
    return out
end

-- _makeAllSort(sort_key): factory for the All-tab comparator. After v1.2
-- this is a thin wrapper over SortEngine using Repo.getSortPriority("all")
-- -- the sort_key argument is ignored. Kept for call-site compatibility;
-- can be deleted when callers migrate to passing tab_id.
local function _makeAllSort(_sort_key)
    return SortEngine.chainedComparator(Repo.getSortPriority("all"))
end

-- getAll(path, limit, offset, sort_priority) → (items, total)
-- limit/offset let callers fetch a single page slice without hydrating the
-- full list. total is always the full item count (from cache or fresh scan)
-- so callers can compute total_pages without a second trip.
--
-- sort_priority (optional) is an array of { key, reverse } levels handed in
-- by callers that want their chip's sort to drive the order -- e.g. a
-- Specific-folder chip with sort_priority = {filename, series_index, title}.
-- When nil/empty, falls back to the "all" tab's stored sort_priority for
-- backward compatibility (Home folders unchanged). The legacy reverse +
-- mixed settings apply only on the fallback path; when sort_priority is
-- provided, each level carries its own direction and reverse is redundant.
-- _filterAllShapes(shapes, filter, light_cache): produce a filter-aware
-- shape list for getAll. Books are kept iff they pass the full compiled
-- filter; folders are kept iff any book under them matches, with
-- first_book_fp swapped to the first matching book under that path.
-- Returns {shapes, total}. Returns the input shapes unchanged when
-- filter is inactive — every call site can hand its full shape list to
-- this helper unconditionally.
-- light_cache (optional): fp -> light-record map shared with the
-- caller's prefetch pass; used to avoid re-reading BIM for each fp.
-- Falls back to _buildBookMetaLight(fp) when absent.
local function _filterAllShapes(shapes, filter, light_cache)
    if not _filterIsActive(filter) then return shapes, #shapes end
    local compiled = Filter.compile(filter, Repo.filterOpts())
    -- Build a light record for a filepath: shared cache when available,
    -- per-book fallback otherwise. Always returns a table (bare filepath
    -- record on total miss) so _recordMatches has something to test.
    local function _recordForFp(fp)
        local rec = light_cache and _lightMetaForFp(light_cache, fp) or _buildBookMetaLight(fp)
        return rec or { filepath = fp }
    end
    local out = {}
    for _i, shape in ipairs(shapes) do
        if shape.kind == "book" then
            if _recordMatches(_recordForFp(shape.fp), compiled) then
                out[#out + 1] = shape
            end
        elseif shape.kind == "folder" then
            local fpaths = Repo.getFolderBookPaths(shape.path) or {}
            local first_fp
            for i = 1, #fpaths do
                if _recordMatches(_recordForFp(fpaths[i]), compiled) then
                    first_fp = fpaths[i]
                    break
                end
            end
            if first_fp then
                -- Annotated copy: replace first_book_fp with the
                -- filter-aware leader so the folder card cover shows a
                -- book that actually matches the filter. Other fields
                -- pass through unchanged. The original shape stays
                -- intact in the cache.
                out[#out + 1] = {
                    kind          = "folder",
                    path          = shape.path,
                    label         = shape.label,
                    first_book_fp = first_fp,
                }
            end
        end
    end
    return out, #out
end

-- Repo.getAll(path, limit, offset, sort_priority, filter, opts)
--
-- opts.lazy_cover — when true, the HIT hydration path probes
-- ScaledCoverCache by filepath for each book in the slice and passes
-- want_cover=false to buildBookMeta for books whose cover is already
-- cached. Avoids the wasted BIM zstd decompress on warm-cache
-- pagination. Ignored on the MISS path (full library walk) because
-- the cache hasn't seen those shapes yet.
function Repo.getAll(path, limit, offset, sort_priority, filter, opts)
    local _t0 = _gettime()
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
    -- Effective priority: caller's wins; otherwise the "all" tab settings.
    local has_caller_priority = sort_priority and #sort_priority > 0
    local priority = has_caller_priority and sort_priority
                                          or Repo.getSortPriority("all")
    -- Legacy single-key view of the priority -- kept for the existing
    -- "needs" prefetch logic and the cache-key path; the actual sort goes
    -- through SortEngine.chainedComparator(priority) below.
    local sort_key = (priority and priority[1] and priority[1].key)
                  or Repo.getSortKey("all")
    -- reverse only applies on the fallback path; chip sort_priority
    -- encodes per-level reverse internally. `mixed` (folders interleaved
    -- with files, instead of partitioned folders-first) follows
    -- KOReader's global "Folders and files mixed" setting and applies
    -- regardless of chip priority — the user's library-wide preference
    -- should win over a per-chip partition choice.
    local reverse  = (not has_caller_priority) and BookshelfSettings.read("sort_all_reverse") == true
    local mixed    = G_reader_settings and G_reader_settings:isTrue("collate_mixed") or false
    -- Cache key includes a stable serialization of the priority so chips
    -- with different sort_priority don't collide on cached shapes.
    local prio_parts = {}
    if priority then
        for _i, lv in ipairs(priority) do
            prio_parts[#prio_parts + 1] = (lv.key or "") .. (lv.reverse and "R" or "")
        end
    end
    local cache_key = table.concat({
        path, table.concat(prio_parts, ","),
        reverse and "R" or "", mixed and "M" or "",
    }, "\0")
    local now   = os.time()
    local entry = _all_cache[cache_key]
    if entry then
        -- HIT: hydrate only the requested slice — skips BIM lookups for
        -- every item outside the current page. When filter is active,
        -- collapse the shape list to filter-passing entries first so
        -- the slice maths against the visible total.
        local home_lc  = G_reader_settings:readSetting("home_dir") or "/"
        local depth_lc = BookshelfSettings.read("latest_walk_depth") or 3
        local hit_light_cache = Filter.isActive(filter) and _getLightMetaCache(home_lc, depth_lc) or nil
        local shapes_for_slice, total = _filterAllShapes(entry.shapes, filter, hit_light_cache)
        local out   = {}
        local stop  = _hydrationStop(offset, limit, total, total, "getAll", opts and opts.light_only)
        -- Letter-jump path: serve light metadata for the slice instead of
        -- full _safeBuildBookMeta records. Book shapes only carry .fp, so a
        -- batched light-meta lookup supplies the sort-key fields (title /
        -- author / series); folder shapes already carry their label. The
        -- caller only reads those to find a page boundary and never renders
        -- these records, so skipping the heavy build is safe.
        if opts and opts.light_only then
            local light_cache = hit_light_cache or _getLightMetaCache(home_lc, depth_lc)
            for i = offset + 1, stop do
                local shape = shapes_for_slice[i]
                if shape.kind == "folder" then
                    out[#out + 1] = { kind = "folder", path = shape.path,
                                      label = shape.label, name = shape.label }
                else
                    local b = _lightMetaForFp(light_cache, shape.fp)
                    out[#out + 1] = b or { fp = shape.fp, filepath = shape.fp }
                end
            end
            return out, total
        end
        -- Lazy-cover probe: per-book ScaledCoverCache check, skip the
        -- BIM zstd decode when a cover is already cached for the
        -- filepath. SpineWidget reads from the cache directly.
        local ScaledCoverCache
        if opts and opts.lazy_cover then
            ScaledCoverCache = require("lib/bookshelf_scaled_cover_cache")
        end
        for i = offset + 1, stop do
            local shape = shapes_for_slice[i]
            if shape.kind == "folder" then
                local fb_opts
                if ScaledCoverCache and shape.first_book_fp
                        and ScaledCoverCache:has(shape.first_book_fp) then
                    fb_opts = { want_cover = false }
                end
                local fb = shape.first_book_fp and _safeBuildBookMeta(shape.first_book_fp, fb_opts)
                out[#out + 1] = {
                    kind       = "folder",
                    path       = shape.path,
                    label      = shape.label,
                    first_book = fb,
                }
            else
                local meta_opts
                if ScaledCoverCache and ScaledCoverCache:has(shape.fp) then
                    meta_opts = { want_cover = false }
                end
                local b = _safeBuildBookMeta(shape.fp, meta_opts)
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
    -- comparison stays O(1). Derive needs from the effective priority
    -- (caller's or the "all" fallback, set up at the top of getAll) so
    -- multi-key sorts (e.g. author_surname, series_index) get the right
    -- metadata swept in.
    local needs = {}
    for _i, level in ipairs(priority) do
        local k = level.key
        if k == "title" or k == "filename" then needs.title   = true end
        if k == "author_name" or k == "author_surname" then needs.authors = true end
        if k == "series_name" or k == "series_index"
                or k == "series_combined"              then needs.series  = true end
        if k == "percent_read" then needs.percent  = true end
        if k == "read_status" or k == "read_status_active" then needs.status = true end
        if k == "last_opened"  then needs.last_opened = true end
        -- rating / page_count are NOT on the light shelf record (rating is
        -- never set by buildBookMeta; page_count is nil for EPUBs), so a sort
        -- by either is a no-op unless we hydrate them from the sidecar here.
        if k == "rating"       then needs.rating     = true end
        if k == "page_count"   then needs.page_count = true end
        -- Folder cards carry no book_count until we count their contents
        -- (issue 90: "sort folders by number of files").
        if k == "book_count"   then needs.book_count = true end
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
        for _i, e in ipairs(entries) do
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
        logger.dbg(string.format(
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
        for _i, item in ipairs(ReadHistory.hist) do
            rh[item.file] = item.time
        end
        for _i, e in ipairs(entries) do
            e._last_read = rh[e.fp] or 0
        end
        -- Folder rows inherit the max read-time from any book somewhere
        -- below them, so 'most recently opened' sorts a folder near its
        -- contents instead of pinning every folder to the never-opened
        -- tier. We could compute this by statting every .sdr underneath,
        -- but ReadHistory already knows which books were opened recently
        -- and where they live — a much smaller list to walk.
        --
        -- For each ReadHistory entry, walk its parent chain upward and
        -- bump the first folder in our current listing that's an
        -- ancestor of that file. Bounded by ReadHistory.hist size (~50)
        -- times average path depth.
        local folder_by_fp = {}
        for _i, e in ipairs(entries) do
            if e.attr and e.attr.mode == "directory" then
                folder_by_fp[e.fp] = e
            end
        end
        for _i, item in ipairs(ReadHistory.hist) do
            local fp, t = item.file, item.time
            if fp and t then
                local parent = fp:match("^(.*)/[^/]+$")
                while parent and parent ~= "" do
                    local folder = folder_by_fp[parent]
                    if folder then
                        if (folder._last_read or 0) < t then
                            folder._last_read = t
                        end
                        break
                    end
                    parent = parent:match("^(.*)/[^/]+$")
                end
            end
        end
    end
    if needs.percent or needs.status or needs.rating or needs.page_count then
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
        --
        -- rating / page_count: set on the record (the comparator reads
        -- a.rating / a.page_count, no underscore) so a sort by either
        -- actually reorders. Only written when that key is in the priority.
        for _i, e in ipairs(entries) do
            if e.attr and e.attr.mode == "file" then
                local pct, status, rating, page_count = Repo.readProgress(e.fp)
                e._pct    = pct
                e._status = status
                if needs.rating     then e.rating     = rating     end
                if needs.page_count then e.page_count = page_count end
            end
        end
    end

    if needs.book_count then
        -- Folder cards on the home/folder view have no book_count of their
        -- own; count their contents so "sort by Book count" orders folders
        -- by how many books they hold (issue 90).
        --
        -- The obvious implementation -- getFolderBookPaths(e.fp) per folder
        -- -- is O(folders x files): each call linear-scans the whole cached
        -- walk-list with a fresh substring alloc per candidate. On a large
        -- library (#113: ~hundreds of folders x ~1.6k files on a 1GHz Kobo)
        -- that cost ~5.5s and froze the launch. Instead, walk every book's
        -- parent chain upward ONCE and bump the first listed folder that's
        -- an ancestor -- O(files x depth), the same attribution shape as the
        -- last_opened block above. The count is identical to
        -- getFolderBookPaths' prefix match (entries are siblings, so a book
        -- under e.fp hits e.fp as its first listed ancestor), so the sort
        -- value still matches the badge the card shows. Plain book entries
        -- have no folder-count concept: they're left nil and the comparator
        -- (a.book_count or #a.filepaths) sorts them to the end of their
        -- partition.
        local folder_by_fp = {}
        for _i, e in ipairs(entries) do
            if e.attr and e.attr.mode == "directory" then
                e.book_count = 0
                folder_by_fp[e.fp] = e
            end
        end
        local home  = G_reader_settings:readSetting("home_dir") or "/"
        local depth = BookshelfSettings.read("latest_walk_depth") or 3
        local cands = cachedWalk(home, depth)
        for i = 1, #cands do
            local fp = cands[i].fp
            local parent = fp and fp:match("^(.*)/[^/]+$")
            while parent and parent ~= "" do
                local folder = folder_by_fp[parent]
                if folder then
                    folder.book_count = folder.book_count + 1
                    break
                end
                parent = parent:match("^(.*)/[^/]+$")
            end
        end
    end

    -- Sort with the effective priority. SortEngine handles per-level
    -- reverse internally, so the legacy whole-list reverse only fires on
    -- the fallback path (no caller-supplied priority).
    table.sort(entries, SortEngine.chainedComparator(priority))
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
        for _i, e in ipairs(entries) do
            if e.attr.mode == "directory" then folders[#folders + 1] = e
            elseif e.attr.mode == "file" then  files[#files + 1] = e
            end
        end
        ordered_entries = {}
        for _i, e in ipairs(folders) do ordered_entries[#ordered_entries + 1] = e end
        for _i, e in ipairs(files)   do ordered_entries[#ordered_entries + 1] = e end
    end

    -- Build shapes only — no BIM lookups here. Skipping buildBookMeta for
    -- every book in the library is the key perf win: a 200-book library was
    -- doing 200 SQLite round-trips just to build the sort cache. Now only the
    -- current page slice (PAGE_SIZE items) triggers BIM lookups, via the
    -- hydration pass below (same code path as the HIT branch).
    local shapes = {}
    for _i, e in ipairs(ordered_entries) do
        if e.attr.mode == "file" then
            if _supportedExt(e.name) then
                shapes[#shapes + 1] = { kind = "book", fp = e.fp }
            end
        elseif e.attr.mode == "directory" then
            -- Omit folders that contain no supported book files at any depth.
            -- One walk answers both questions in the common case: finding the
            -- folder's representative cover also proves it's non-empty, so
            -- seed folderHasBooks' memo from it (later callers -- selection
            -- mode, repeat builds -- then hit the memo). Only when no book
            -- sits within findFirstBookIn's depth bound do we pay the
            -- second, unbounded folderHasBooks walk to decide whether the
            -- folder is truly empty; books deeper than the bound keep their
            -- folder card, just without a cover (same as before).
            local first_fp = Repo.findFirstBookIn(e.fp, 3)
            if first_fp then
                _folderHasBooks_cache[e.fp] = true
            end
            if first_fp or Repo.folderHasBooks(e.fp) then
                -- findFirstBookIn returns just the filepath; per-page
                -- hydration below builds the actual Book record with cover.
                shapes[#shapes + 1] = {
                    kind          = "folder",
                    path          = e.fp,
                    label         = e.name,
                    first_book_fp = first_fp,
                }
            end
        end
    end
    _all_cache[cache_key] = { shapes = shapes, expires_at = now + WALK_CACHE_TTL }
    -- Hydrate the requested page slice exactly as the HIT path does.
    -- Filter-aware: collapse to visible shapes first when active.
    local miss_lc_home  = G_reader_settings:readSetting("home_dir") or "/"
    local miss_lc_depth = BookshelfSettings.read("latest_walk_depth") or 3
    local miss_light_cache = Filter.isActive(filter) and _getLightMetaCache(miss_lc_home, miss_lc_depth) or nil
    local shapes_for_slice, total = _filterAllShapes(shapes, filter, miss_light_cache)
    local out  = {}
    local stop = _hydrationStop(offset, limit, total, total, "getAll", opts and opts.light_only)
    for i = offset + 1, stop do
        local shape = shapes_for_slice[i]
        if shape.kind == "folder" then
            local fb = shape.first_book_fp and _safeBuildBookMeta(shape.first_book_fp)
            out[#out + 1] = {
                kind       = "folder",
                path       = shape.path,
                label      = shape.label,
                first_book = fb,
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

function Repo.getFavorites(limit, offset, opts)
    local rc    = getCollections()
    local items = {}
    for _file, item in pairs(rc.coll and rc.coll.favorites or {}) do
        items[#items + 1] = item
    end
    local key = Repo.getSortKey("favorites")
    if key == "title" then
        -- Title-sort prefetch, cheapest source first: the light-meta
        -- batch cache (one library-wide SQLite SELECT, usually already
        -- warm from the group chips) covers favourites under home_dir;
        -- favourites outside the walk fall back per-file inside
        -- _lightMetaForFp, which still skips covers. Replaces the old
        -- per-favourite BIM row read on every fetch. When CoverBrowser
        -- is disabled (issue #49) records come back nil and every title
        -- falls back to the filename basename, so the sort still runs
        -- deterministically rather than nil-derefing.
        local home  = G_reader_settings:readSetting("home_dir") or "/"
        local depth = BookshelfSettings.read("latest_walk_depth") or 3
        local light_cache = _getLightMetaCache(home, depth)
        local titles = {}
        for _i, item in ipairs(items) do
            local fp  = item.file
            local rec = _lightMetaForFp(light_cache, fp)
            local title = rec and rec.title
            titles[fp] = (title or (fp and fp:match("([^/]+)$")) or ""):lower()
        end
        table.sort(items, function(a, b) return titles[a.file] < titles[b.file] end)
    elseif key == "recently_read" then
        -- ReadHistory time per filepath; fall back to attr.access (collection
        -- access time) so unread favourites still sort deterministically.
        local rh        = getReadHistory()
        local read_time = {}
        for _i, e in ipairs(rh.hist or {}) do
            if e.file and e.time then read_time[e.file] = e.time end
        end
        table.sort(items, function(a, b)
            local ta = read_time[a.file] or (a.attr and a.attr.access) or 0
            local tb = read_time[b.file] or (b.attr and b.attr.access) or 0
            return ta > tb
        end)
    elseif key == "updated" then
        -- ReadCollection assigns a monotonically increasing `order` value
        -- as items are added (via getCollectionNextOrder = max + 1). Sort
        -- DESC so newly favourited books float to the top — the use case
        -- "I just starred this, where did it go?" lands at slot 1.
        table.sort(items, function(a, b)
            return (a.order or 0) > (b.order or 0)
        end)
    elseif key == "date_added" then
        -- Legacy default before "updated": collection access time, newest
        -- first. Kept as an opt-in for users who preferred this ordering.
        table.sort(items, function(a, b)
            return (a.attr and a.attr.access or 0) > (b.attr and b.attr.access or 0)
        end)
    else
        -- Unknown key: fall through to "updated" — matches _SORT_DEFAULT.
        table.sort(items, function(a, b)
            return (a.order or 0) > (b.order or 0)
        end)
    end
    -- Build Book records only for the visible page; total returned so the
    -- caller's _total_hint path can compute total_pages.
    local total = #items
    offset      = offset or 0
    local stop  = _hydrationStop(offset, limit, total, 8, "getFavorites", opts and opts.light_only)
    local out   = {}
    local ScaledCoverCache
    if opts and opts.lazy_cover then
        ScaledCoverCache = require("lib/bookshelf_scaled_cover_cache")
    end
    for i = offset + 1, stop do
        local fp = items[i].file
        local meta_opts
        if ScaledCoverCache and ScaledCoverCache:has(fp) then
            meta_opts = { want_cover = false }
        end
        local book = Repo.buildBookMeta(fp, meta_opts)
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
function Repo.searchBooks(query, limit)
    if not query or query == "" then return {} end
    local home  = G_reader_settings:readSetting("home_dir") or "/"
    local depth = BookshelfSettings.read("latest_walk_depth") or 3
    local cands = cachedWalk(home, depth)
    local words = {}
    for w in query:gmatch("%S+") do
        words[#words + 1] = w:lower()
    end
    if #words == 0 then return {} end
    local light_cache = _getLightMetaCache(home, depth)
    local out = {}
    for _i, c in ipairs(cands) do
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
                for _i, a in ipairs(b.authors) do parts[#parts + 1] = a:lower() end
            end
            if b.genres then
                for _i, g in ipairs(b.genres) do parts[#parts + 1] = g:lower() end
            end
            local hay = table.concat(parts, " ")
            local matches = true
            for _i, w in ipairs(words) do
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

-- _isTitleCase(s): true when every word starts with an uppercase letter and
-- the string isn't entirely uppercase -- "Southern Reach" yes; "southern
-- reach", "Southern reach", "SOUTHERN REACH" no. Used when case-insensitive
-- grouping merges spelling variants ("southern reach" / "Southern Reach"):
-- prefer a Title Case variant for the displayed stack label, else first-seen.
local function _isTitleCase(s)
    if not s or s == "" then return false end
    if s == s:upper() then return false end          -- all-caps
    for word in s:gmatch("%S+") do
        local c = word:match("^(%a)")                 -- first alpha char of the word
        if c and c ~= c:upper() then return false end
    end
    return true
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

function Repo.getTags(limit, offset, sort_priority_override, filter, opts)
    local rc = getCollections()
    if not rc.coll then return {}, 0 end
    local active = _filterIsActive(filter)
    -- ALL members hydrate with light metadata (one batched SELECT, no cover
    -- decode): the stack visual only renders books[1]'s cover, the within-
    -- group title sort and status filter read light fields, and drilldown /
    -- preload consumers re-hydrate by filepath themselves. The visible page
    -- slice upgrades each group's front book to a full record below --
    -- previously EVERY member of EVERY collection paid a full buildBookMeta
    -- (cover zstd decode included) on each Collections render.
    -- light_only (letter-jump index): same hydration, skips the front-book
    -- upgrade since the caller never renders these records.
    local light_only = opts and opts.light_only
    local light_cache
    local home  = G_reader_settings:readSetting("home_dir") or "/"
    local depth = BookshelfSettings.read("latest_walk_depth") or 3
    -- Compile once before the loop (not per book) when filter is active,
    -- so every per-book test is an O(1) lookup on the compiled result.
    local compiled = active and Filter.compile(filter, Repo.filterOpts()) or nil
    local groups = {}
    for coll_name, files in pairs(rc.coll) do
        if coll_name ~= "favorites" then
            local books  = {}
            local latest = 0
            for _file, item in pairs(files) do
                local fp = item.file or _file
                light_cache = light_cache or _getLightMetaCache(home, depth)
                local book = _lightMetaForFp(light_cache, fp)
                if book then
                    -- When filter is active, only include books that pass
                    -- the full filter (status + genre + langs + formats +
                    -- collections). Filter-inactive path pays nothing extra.
                    local include = true
                    if compiled then
                        include = _recordMatches(book, compiled)
                    end
                    if include then
                        books[#books + 1] = book
                        local t = (item.attr and item.attr.access) or 0
                        if t > latest then latest = t end
                    end
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
    -- Window the sorted list with offset + limit (cursor-driven pagination,
    -- mirroring getRatings / getAuthors / etc.) and return the unwindowed
    -- total so the caller can compute the page count. Without `total`, the
    -- chip strip's pagination falls back to #out, capping the Collections
    -- view at one page of `limit` items even when more collections exist.
    local total = #groups
    offset      = offset or 0
    local stop  = _hydrationStop(offset, limit, total, total, "getTags", opts and opts.light_only)
    local out   = {}
    -- Upgrade each visible group's FRONT book (the one whose cover the
    -- SeriesStack renders) to a full record. Covers already in
    -- ScaledCoverCache skip the BIM zstd decode; SpineWidget repaints
    -- them from the cache by filepath key.
    local ScaledCoverCache
    if not light_only and opts and opts.lazy_cover then
        ScaledCoverCache = require("lib/bookshelf_scaled_cover_cache")
    end
    for i = offset + 1, stop do
        local g = groups[i]
        if not light_only and g.books[1] and g.books[1].filepath then
            local fp = g.books[1].filepath
            local meta_opts
            if ScaledCoverCache and ScaledCoverCache:has(fp) then
                meta_opts = { want_cover = false }
            end
            local full = Repo.buildBookMeta(fp, meta_opts)
            if full then g.books[1] = full end
        end
        out[#out + 1] = g
    end
    return out, total
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
local function hydrateSeriesShape(shape, filter, light_only)
    -- Filter the series's book list when a status filter is active.
    -- An empty result → caller drops this series from the visible list.
    local order = shape.filepaths
    local meta  = shape.books_meta
    if _filterIsActive(filter) and meta then
        local filtered = _applyFilter(meta, filter)
        if #filtered == 0 then return nil end
        order = {}
        for i = 1, #filtered do order[i] = filtered[i].filepath end
    end
    -- light_only (letter-jump index): caller reads only series_name and
    -- never renders the stack, so skip the front-cover buildBookMeta decode.
    local books = {}
    if light_only then
        for i = 1, #order do books[i] = { filepath = order[i] } end
    else
        for i, fp in ipairs(order) do
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
    end
    return {
        series_name = shape.series_name,
        books       = books,
        latest      = shape.latest,
    }
end

-- Distinct value list for a filter dimension, shaped for the picker UI:
-- { {value=string, label=string, count=number}, ... }. Reuses the existing
-- group enumerators (each group card carries series_name = the value and a
-- filepaths array for the count). Collections come from ReadCollection.
function Repo.distinctFilterValues(dim)
    local out = {}
    if dim == "collections" then
        local rc = getCollections()
        if rc and rc.coll then
            for name, coll in pairs(rc.coll) do
                if name ~= "favorites" then
                    local n = 0
                    for _fp in pairs(coll) do n = n + 1 end
                    out[#out + 1] = { value = name, label = name, count = n }
                end
            end
        end
        table.sort(out, function(a, b) return a.label < b.label end)
        return out
    end
    -- Ratings: the value set is fixed ("1".."5"/"unrated") and does NOT match
    -- what getGroupChoices("rating") returns (its values are star-glyph strings
    -- and "Unrated", not the numeric keys the filter uses). Return the fixed list
    -- from Filter.ratingValues() with count=0; real counts are deferred to the
    -- faceted-count task. The fixed list is always complete (all 6 buckets) so
    -- the picker shows every option even when the user's library has no 5-star
    -- books yet.
    if dim == "ratings" then
        local rv = Filter.ratingValues()
        for _i, v in ipairs(rv) do
            out[#out + 1] = { value = v.value, label = v.label, count = 0 }
        end
        return out
    end
    -- Delegate to the lightweight choice list (getGroupChoices builds the group
    -- cache with limit=0, so it skips per-group hydration: no buildBookMeta and
    -- no cover decompression, which the old getGenres(100000, ...) path paid for
    -- every group only to discard it -- ~1-2s on a large library, the cause of
    -- the slow genre-filter open). Same `value` (series_name) the pickers store,
    -- so the language/genre canonicalisation round-trip is unchanged.
    local kind_for = { genres = "genre", langs = "language", formats = "format" }
    local kind = kind_for[dim]
    if not kind then return out end
    out = Repo.getGroupChoices(kind)
    table.sort(out, function(a, b) return a.label < b.label end)
    return out
end

-- Filepath membership set for one collection (default collection resolver
-- handed to Filter.compile).
function Repo.collectionFilepaths(name)
    local rc = getCollections()
    if not rc or not rc.coll then return {} end
    local coll = rc.coll[name]
    if type(coll) ~= "table" then return {} end
    local set = {}
    for filepath in pairs(coll) do set[filepath] = true end
    return set
end

-- Standard options handed to Filter.compile so the language/genre dimensions
-- canonicalise the same way the chip-source paths and the value enumerators do
-- (else a picked "English"/Title-Case genre would never match raw book.lang /
-- book.genres). collection_resolver supplies per-collection filepath sets.
function Repo.filterOpts()
    return {
        collection_resolver = Repo.collectionFilepaths,
        lang_canonical = function(v)
            if v == nil then return nil end
            return BookshelfLang.canonical(v) or _normalizeLang(v)
        end,
        genre_normalize = _normalizeGenre,
    }
end

-- Read-time assembly for the Series source: choose which cached shapes
-- participate, filter, sort and hydrate one combined, paginated list.
-- Shared by getSeriesGroups' cache HIT and MISS paths so they can't drift.
--
-- The chip's RAW series_membership filter value drives participation (#160):
--   nil / "in_series" -> stacks only (the historical behaviour)
--   "both"            -> stacks + standalone books as plain singles
--   "standalone"      -> standalone books only
-- ("both" never compiles into the per-book filter, so the other dimensions
-- keep working; "standalone"/"in_series" compile as before and stay
-- consistent with what this participation choice emits.)
--
-- hide_single (#127) interaction: in the mixed "both" view a one-book series
-- isn't noise, it's just a book -- so instead of being dropped it DEGRADES to
-- a plain single. Elsewhere the drop behaviour is unchanged.
local function _seriesReadout(group_shapes, standalone_shapes, filter,
                              hide_single, sk, limit, offset, light_only)
    local mode = filter and filter.series_membership
    local want_groups  = mode ~= "standalone"
    local want_singles = mode == "both" or mode == "standalone"
    local degrade      = hide_single and mode == "both"
    local sorted = {}
    if want_groups then
        for _i, s in ipairs(group_shapes or {}) do
            -- Degraded 1-book stacks are re-added as singles below.
            if not (degrade and s.filepaths and #s.filepaths == 1)
                    and _shapeVisible(s, filter, hide_single) then
                sorted[#sorted + 1] = s
            end
        end
    end
    if want_singles then
        local compiled = _filterIsActive(filter)
            and Filter.compile(filter, Repo.filterOpts()) or nil
        local function addSingle(std)
            if not compiled or _recordMatches(std, compiled) then
                sorted[#sorted + 1] = std
            end
        end
        for _i, std in ipairs(standalone_shapes or {}) do addSingle(std) end
        if degrade then
            for _i, s in ipairs(group_shapes or {}) do
                if s.filepaths and #s.filepaths == 1 then
                    local m = (s.books_meta and s.books_meta[1]) or {}
                    addSingle({
                        standalone  = true,
                        filepath    = s.filepaths[1],
                        -- Sort/display fallbacks: a 1-book series is named
                        -- after its series for ordering purposes.
                        series_name = s.series_name,
                        series_num  = m.series_num,
                        genres      = m.genres,
                        lang        = m.lang,
                        latest      = s.latest,
                        book_count  = 1,
                    })
                end
            end
        end
    end
    table.sort(sorted, _groupShapeCmp(sk))
    local total = #sorted
    local out   = {}
    offset      = offset or 0
    local stop  = _hydrationStop(offset, limit, total, 8, "getSeriesGroups", light_only)
    for i = offset + 1, stop do
        local s = sorted[i]
        if s.standalone then
            if light_only then
                -- Letter-jump index: sort-key fields only, never rendered.
                out[#out + 1] = { filepath = s.filepath, title = s.title,
                                  filename = s.filename, series_name = s.series_name }
            else
                -- Plain Book record: shelf_row renders it as a single cover
                -- and taps open the book, same as any book-list chip.
                local b = Repo.buildBookMeta(s.filepath)
                if b then out[#out + 1] = b end
            end
        else
            out[#out + 1] = hydrateSeriesShape(s, filter, light_only)
        end
    end
    return out, total
end

function Repo.getSeriesGroups(limit, offset, sort_priority_override, filter, opts)
    local home  = G_reader_settings:readSetting("home_dir") or "/"
    local depth = BookshelfSettings.read("latest_walk_depth") or 3
    local key   = (home or "/") .. ":" .. tostring(depth or 0)
    local now   = os.time()
    -- Read at the top so both the cache HIT and MISS paths apply the same
    -- single-book-stack rule (issue #127). Filtered at read time, not bake
    -- time, so toggling the setting takes effect on the next render with no
    -- cache invalidation.
    local hide_single = BookshelfSettings.isTrue("hide_single_book_stacks")

    -- Cache fast path: filepaths + sort metadata are stable across renders;
    -- Books get rehydrated each read so cover_bbs are fresh. Sort runs at
    -- hydrate time so changing bookshelf_sort_series doesn't invalidate the
    -- cache.
    local cached = _series_cache[key]
    if cached then
        local _t0 = _gettime()
        local sk  = sort_priority_override or Repo.getSortPriority("series")
        local out, total = _seriesReadout(cached.groups, cached.standalones,
            filter, hide_single, sk, limit, offset, opts and opts.light_only)
        logger.dbg(string.format("[bookshelf perf] getSeriesGroups: HIT hydrate=%.0fms groups=%d/%d",
            (_gettime() - _t0) * 1000, #out, total))
        return out, total
    end

    local _t0 = _gettime()
    -- Build a filepath → read-time map so the series sort still favours
    -- series you've actually been reading lately.
    local rh        = getReadHistory()
    local read_time = {}
    for _i, entry in ipairs(rh.hist) do
        local t = entry.time or 0
        if t > (read_time[entry.file] or 0) then
            read_time[entry.file] = t
        end
    end

    local candidates = cachedWalk(home, depth)
    local light_cache = _getLightMetaCache(home, depth)

    local groups      = {}  -- keyed by series_name
    local order       = {}  -- preserves insertion order for deterministic tie-break
    local standalones = {}  -- books with no series (#160), in walk order
    for _i, c in ipairs(candidates) do
        -- Lightweight walk: only text fields needed for grouping/sorting.
        -- Using buildBookMeta here kept all cover BlitBuffers live for the
        -- entire 2000-book walk (~120 MB peak on Calibre libraries → OOM).
        -- The shared light_cache turns ~2000 BIM prepared-statement runs into
        -- one batch SELECT for the first chip; subsequent chips (Authors,
        -- Genres) hit the same cache.
        local book = _lightMetaForFp(light_cache, c.fp)
        if book and book.series_name then
            local sname = book.series_name
            -- Bucket case-insensitively so "Southern Reach" and "southern
            -- reach" merge into one stack. Display the first-seen spelling,
            -- but upgrade to a Title Case variant if one shows up.
            local skey = sname:lower()
            local g = groups[skey]
            if not g then
                g = { series_name = sname, books = {}, latest = 0, _seen = {} }
                groups[skey] = g
                order[#order + 1] = skey
            elseif _isTitleCase(sname) and not _isTitleCase(g.series_name) then
                g.series_name = sname
            end
            if not g._seen[book.filepath] then
                g._seen[book.filepath] = true
                g.books[#g.books + 1] = {
                    filepath   = book.filepath,
                    series_num = book.series_num,
                    genres     = book.genres,
                    lang       = book.lang,
                }
            end
            local t = read_time[book.filepath] or c.mtime or 0
            if t > g.latest then g.latest = t end
        elseif book then
            -- No series: a standalone shape (#160), cached alongside the
            -- group shapes. Carries the same sort-key fields the comparator
            -- reads on group shapes (filename fallbacks, latest, book_count)
            -- so _groupShapeCmp interleaves the mixed list for free, plus
            -- genres/lang/filepath so the per-book filter dimensions work.
            standalones[#standalones + 1] = {
                standalone   = true,
                filepath     = book.filepath,
                filename     = book.filename,
                title        = book.title,
                genres       = book.genres,
                lang         = book.lang,
                latest       = read_time[book.filepath] or c.mtime or 0,
                latest_added = c.mtime or 0,
                -- Sort-only field (hydration replaces this shape with a real
                -- Book record). 0, not 1: under a book-count sort a standalone
                -- isn't a series at all, so it ranks below a 1-book series
                -- rather than tying with it in arbitrary order. Degraded
                -- 1-book stacks (hide_single + "both") keep count 1 -- they
                -- ARE a series, just rendered as a single.
                book_count   = 0,
            }
        end
    end
    -- Flatten to list. Sort runs at hydrate time on the cached shapes (see
    -- HIT branch / MISS hydrate below), so a sort menu change re-renders
    -- without a re-walk.
    local list = {}
    for _i, k in ipairs(order) do list[#list + 1] = groups[k] end
    -- Within each group, sort books by series_num ascending. Also remove _seen helper.
    for _i, g in ipairs(list) do
        g._seen = nil
        table.sort(g.books, function(a, b)
            return (tonumber(a.series_num) or 0) < (tonumber(b.series_num) or 0)
        end)
    end

    -- Stash the SHAPE (filepaths + sort metadata) — never the Book
    -- records themselves. That avoids the use-after-free on the
    -- ImageWidget-owned cover_bbs that books carry.
    local shapes = {}
    for _i, group in ipairs(list) do
        local fps = {}
        local books_meta = {}
        for _i, b in ipairs(group.books) do
            fps[#fps + 1] = b.filepath
            -- Carry filepath + series_num so hydrate-time filter checks
            -- (live readProgress, cached) can run against the same
            -- structure as the other group kinds. genres/lang are carried
            -- so genre and language filters work on group chips.
            -- series_name too: without it the compiled series_membership
            -- check saw every member as standalone, so an explicit "Only
            -- books in series" filter emptied the Series chip (#160).
            books_meta[#books_meta + 1] = {
                filepath    = b.filepath,
                series_num  = b.series_num,
                series_name = group.series_name,
                genres      = b.genres,
                lang        = b.lang,
            }
        end
        shapes[#shapes + 1] = {
            series_name = group.series_name,
            filepaths   = fps,
            books_meta  = books_meta,
            latest      = group.latest,
        }
    end
    _series_cache[key] = { groups = shapes, standalones = standalones,
                           expires_at = now + SERIES_CACHE_TTL }

    -- MISS path: same readout as the HIT path (sort + hydrate one combined,
    -- paginated list), so cover_bb lifetime and the series_membership
    -- participation rules are identical regardless of cache state.
    local sk = sort_priority_override or Repo.getSortPriority("series")
    local out, total = _seriesReadout(shapes, standalones, filter,
        hide_single, sk, limit, offset, opts and opts.light_only)
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

-- _filterIsActive(filter): true when filter.statuses has at least one
-- key set. nil filter / nil statuses / empty statuses → "no filter".
_filterIsActive = function(filter)
    return Filter.isActive(filter)
end

-- _shapeHasFilteredBook(shape, filter): cheap "is this group visible
-- under the active filter?" predicate. Short-circuits on first match.
-- Returns true when filter is inactive (no-op). Used to drop empty
-- groups before pagination so page counts stay sane.
_shapeHasFilteredBook = function(shape, filter)
    if not Filter.isActive(filter) then return true end
    local meta = shape.books_meta
    if not meta then return true end  -- transition-compat: nothing to test against
    local compiled = Filter.compile(filter, Repo.filterOpts())
    for i = 1, #meta do
        if _recordMatches(meta[i], compiled) then return true end
    end
    return false
end

-- _shapeVisible(shape, filter, hide_single): _shapeHasFilteredBook plus the
-- optional "hide single-book stacks" rule (issue #127). A series or genre
-- stack with a single book is usually noise -- a one-off poorly-tagged book,
-- a title duplicated into the series field (the empty-series case is dropped
-- upstream now), or an incomplete series. When the user opts in, drop it.
-- Only the series + genre fetchers use this; authors / formats / languages
-- keep the plain predicate, since a one-book group there is normal.
_shapeVisible = function(shape, filter, hide_single)
    if hide_single and shape.filepaths and #shape.filepaths <= 1 then
        return false
    end
    return _shapeHasFilteredBook(shape, filter)
end

-- _recordMatches(b, compiled): test a book/light record against a compiled
-- filter, resolving per-book data lazily -- only the dimensions the compiled
-- filter actually constrains. Status and rating are the expensive ones (a
-- DocSettings open): resolved only when compiled.statuses / compiled.ratings
-- are set, using the _hasSidecar fast-path so unopened books cost a stat, not
-- an open (issue #113/#117). `format` is path-derivable; filled in for light
-- records (which omit it) so the format dimension works everywhere.
_recordMatches = function(b, compiled)
    if b.format == nil and b.filepath then b.format = _formatLabel(b.filepath) end
    local need_status = compiled.statuses ~= nil
    local need_rating = compiled.ratings  ~= nil
    if (need_status and b._status == nil) or (need_rating and b.rating == nil) then
        if b.filepath and _hasSidecar(b.filepath) then
            local _pct, status, rating = Repo.readProgress(b.filepath)
            if b._status == nil then b._status = _normalizeStatus(status) end
            if b.rating  == nil then b.rating  = rating end
        else
            if b._status == nil then b._status = "unread" end
            -- no sidecar => never opened => unrated; leave b.rating nil
        end
        b._progress_fetched = true
    end
    return Filter.matches(b, compiled)
end

-- _applyFilter(meta_list, filter): returns a new list containing only meta
-- entries that pass the full compiled filter. Compiles once per call;
-- resolves status lazily via _recordMatches (sidecar-gated, issue #113).
-- Callers should check _filterIsActive(filter) before invoking.
_applyFilter = function(meta_list, filter)
    if not meta_list then return {} end
    if not Filter.isActive(filter) then return meta_list end
    local compiled = Filter.compile(filter, Repo.filterOpts())
    local out = {}
    for i = 1, #meta_list do
        local m = meta_list[i]
        if _recordMatches(m, compiled) then out[#out + 1] = m end
    end
    return out
end

-- _withinPriority(sk): returns the level-2+ slice of a sort_priority,
-- or nil when the chip only has a single level (no within-group rule).
-- Used by every group hydrator to pick the cover that reflects the
-- chip's secondary sort.
local function _withinPriority(sk)
    if not sk or #sk < 2 then return nil end
    local out = {}
    for i = 2, #sk do out[#out + 1] = sk[i] end
    return out
end

-- within_priority (optional): the chip's sort_priority levels 2+. When
-- supplied, books_meta is re-sorted by it so the leader's filepath
-- becomes books[1] (the visible cover on the stack widget). The build-
-- time order (series_name → series_index → title) is the fallback the
-- shape was cached in; without this, a "Genres / book count then added"
-- chip would still show the alphabetically-first cover, not the most-
-- recently-added one.
--
-- Sorting is done on a copy so the cached shape's books_meta isn't
-- mutated (the cache must stay stable across chips that share the same
-- shape but differ in within-priority).
local function _hydrateGroupShape(shape, within_priority, filter, light_only)
    local meta = shape.books_meta
    -- Filter (status-only today). Empty result → caller drops this group.
    if _filterIsActive(filter) and meta then
        meta = _applyFilter(meta, filter)
        if #meta == 0 then return nil end
    end
    -- When filter is inactive, fall back to the cached shape filepaths
    -- (no need to materialise meta for the unfiltered cover).
    local order
    if meta ~= shape.books_meta then
        order = {}
        for i = 1, #meta do order[i] = meta[i].filepath end
    else
        order = shape.filepaths
    end
    -- light_only (letter-jump index): the caller reads only the group's
    -- series_name to locate a page boundary and never renders the card, so
    -- skip the within-group re-sort (it only decides WHICH book's cover
    -- shows) and the per-group buildBookMeta cover decode. The cover decode
    -- is what made a full-list group fetch (e.g. 292 authors) take ~7s.
    if not light_only
            and within_priority and #within_priority > 0 and meta and #meta > 1 then
        local SortEngine = require("lib/bookshelf_sort_engine")
        local meta_copy = {}
        for i = 1, #meta do meta_copy[i] = meta[i] end
        SortEngine.sort(meta_copy, within_priority)
        meta = meta_copy
        local sorted_fps = {}
        for i = 1, #meta_copy do sorted_fps[i] = meta_copy[i].filepath end
        order = sorted_fps
    end
    local books = {}
    if light_only then
        for i = 1, #order do books[i] = { filepath = order[i] } end
    else
        for i, fp in ipairs(order) do
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
    end
    return {
        kind         = shape.kind,
        series_name  = shape.series_name,
        books        = books,
        books_meta   = meta,  -- carried for drill-time re-sort
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
-- on some libraries with stylized spellings). Re-assignment (not
-- `local`) so the forward decl above resolves here.
_normalize_genre_cache = {}
_normalizeGenre = function(s)
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

-- _normalizeAuthor(s): canonical key so "Richard Osman" and
-- "Osman, Richard" group together. AuthorName.surnameOf + .givenOf
-- parse both Calibre conventions; we then concatenate lowercased
-- "given surname". Two variants of the same name produce the same
-- output, so _buildGroups collapses them into one author card. The
-- first-seen variant still drives the displayed series_name, so a
-- user with mostly "Forename Surname" books sees that form on the
-- card even when one of the books is "Surname, Forename".
_normalize_author_cache = {}
local _AuthorName_mod
local function _normalizeAuthor(s)
    if not s or s == "" then return "" end
    local cached = _normalize_author_cache[s]
    if cached ~= nil then return cached end
    if not _AuthorName_mod then
        local ok, mod = pcall(require, "lib/bookshelf_author_name")
        if ok then _AuthorName_mod = mod end
    end
    local key
    if _AuthorName_mod then
        local surname = _AuthorName_mod.surnameOf(s) or ""
        local given   = _AuthorName_mod.givenOf(s)   or ""
        key = (given .. " " .. surname):lower()
                  :gsub("%s+", " ")
                  :gsub("^%s+", ""):gsub("%s+$", "")
        if key == "" then key = s:lower() end
    else
        key = s:lower()
    end
    _normalize_author_cache[s] = key
    return key
end

local _LANG_UNKNOWN_KEY = "__bookshelf_unknown_lang__"

-- _normalizeLang(s): canonical key for grouping by language. Trims and
-- lowercases the input, then drops any region/script suffix ("en-US",
-- "zh_Hans") so library entries that vary only in region collapse into
-- one card. Full-name forms ("English", "français") stay distinct from
-- their codes.
_normalize_lang_cache = {}
_normalizeLang = function(s)
    if not s or s == "" then return "" end
    local cached = _normalize_lang_cache[s]
    if cached ~= nil then return cached end
    local lower = s:lower():gsub("^%s+", ""):gsub("%s+$", "")
    -- "en-US" / "en_US" -> "en". Keep names like "english" untouched.
    local primary = lower:match("^([^-_]+)")
    if primary and #primary >= 2 and #primary <= 3
            and primary:match("^[a-z]+$") then
        lower = primary
    end
    _normalize_lang_cache[s] = lower
    return lower
end

-- _normalizeStatus(s): map any raw KOReader status to the bookshelf
-- vocabulary used by the chip-editor filter UI and the SortEngine.
-- Repo.readProgress already maps "complete" → "finished" and
-- "abandoned" → "on_hold"; here we additionally collapse the
-- nil/"new" cases into "unread" so the filter set can key on a single
-- canonical token per state.
_normalizeStatus = function(s)
    if s == nil or s == "new" then return "unread" end
    return s
end

-- _statusForFp(fp): canonical bookshelf status for a single filepath.
-- Cheap-path checks whether a DocSettings sidecar exists at all — a book
-- without one has never been opened, so its status is "unread" without paying
-- a DocSettings parse. _hasSidecar consults the configured metadata location
-- (#117), so this is correct regardless of where the sidecar lives.
_statusForFp = function(fp)
    if not fp then return "unread" end
    if not _hasSidecar(fp) then return "unread" end
    local _pct, status = Repo.readProgress(fp)
    return _normalizeStatus(status)
end

-- Public tally for the whole walked library, used by the "Shelf size" module.
-- Returns: total book count, and a per-status table keyed by the canonical
-- bookshelf states. Built on _statusForFp, so unopened books (no sidecar)
-- cost nothing beyond the walk, and opened ones hit the progress cache.
function Repo.countByStatus()
    local counts = { unread = 0, reading = 0, on_hold = 0, finished = 0 }
    local paths = Repo.getAllFilepaths()
    for _i, fp in ipairs(paths) do
        local s = _statusForFp(fp)
        counts[s] = (counts[s] or 0) + 1
    end
    return #paths, counts
end

local function _buildGroups(group_kind, key_fn, multi)
    local _t0 = _gettime()
    local home  = G_reader_settings:readSetting("home_dir") or "/"
    local depth = BookshelfSettings.read("latest_walk_depth") or 3
    -- Read history → filepath read-time map so groups sort by recently-read.
    local rh        = getReadHistory()
    local read_time = {}
    for _i, entry in ipairs(rh.hist) do
        local t = entry.time or 0
        if t > (read_time[entry.file] or 0) then read_time[entry.file] = t end
    end
    local cands = cachedWalk(home, depth)
    local light_cache = _getLightMetaCache(home, depth)
    local groups = {}
    local order  = {}
    for _i, c in ipairs(cands) do
        -- Lightweight walk: text fields only, no cover_bb.
        -- See _buildBookMetaLight for the memory rationale; shared
        -- light_cache means the second + third group chip (Authors after
        -- Series, Genres after Authors) reuse the same BIM batch read.
        local book = _lightMetaForFp(light_cache, c.fp)
        if book then
            local keys = key_fn(book)
            if keys then
                if not multi then keys = { keys } end
                for _i, raw_k in ipairs(keys) do
                    if raw_k and raw_k ~= "" then
                        -- For language, resolve the canonical key + friendly
                        -- label once (carried into the display block below).
                        local lang_label

                        -- Key on the normalised form per group kind:
                        --   genre  → lowercase + simple plural collapse
                        --            ("Mystery" / "mystery" / "Mysteries")
                        --   author → canonical "given surname" so the
                        --            same person stored as "Forename
                        --            Surname" and "Surname, Forename"
                        --            collapses into one card.
                        --   other  → raw string is the identity.
                        local lookup_k
                        if group_kind == "genre" then
                            lookup_k = _normalizeGenre(raw_k)
                        elseif group_kind == "author" then
                            lookup_k = _normalizeAuthor(raw_k)
                        elseif group_kind == "language" then
                            if raw_k == _LANG_UNKNOWN_KEY then
                                lookup_k = _LANG_UNKNOWN_KEY
                            else
                                local ck, cl = BookshelfLang.canonical(raw_k)
                                lookup_k   = ck or _normalizeLang(raw_k)
                                lang_label = cl
                            end
                        else
                            lookup_k = raw_k
                        end
                        local g = groups[lookup_k]
                        if not g then
                            -- Author group display respects the user's
                            -- "Author name formatting" setting (auto /
                            -- first_last / last_first). "auto" leaves the
                            -- first-seen variant alone; the others force
                            -- a consistent form regardless of how each
                            -- book stored its author.
                            local display_name = raw_k
                            if group_kind == "author" and _AuthorName_mod then
                                local fmt = BookshelfSettings.read("author_format") or "auto"
                                if fmt ~= "auto" then
                                    display_name = _AuthorName_mod.formatted(raw_k, fmt)
                                end
                            elseif group_kind == "language" then
                                if raw_k == _LANG_UNKNOWN_KEY then
                                    display_name = tr("Unknown")
                                else
                                    -- Friendly, localised name from
                                    -- bookshelf_lang (e.g. "English" for any of
                                    -- en / eng / en-GB / English). Falls back to
                                    -- the canonical key if no name resolved.
                                    display_name = lang_label or lookup_k
                                end
                            end
                            g = {
                                kind        = group_kind,
                                series_name = display_name,
                                books       = {},
                                latest      = 0,
                                _seen       = {},
                            }
                            groups[lookup_k] = g
                            order[#order + 1] = lookup_k
                        elseif group_kind ~= "author"
                                and _isTitleCase(raw_k)
                                and not _isTitleCase(g.series_name) then
                            -- Case-insensitive kinds (e.g. genre) merge
                            -- spelling variants; upgrade the displayed label
                            -- to a Title Case spelling when one appears.
                            -- Authors keep their format-driven display.
                            g.series_name = raw_k
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
                                genres       = book.genres,
                                lang         = book.lang,
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
    for _i, k in ipairs(order) do list[#list + 1] = groups[k] end
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
    for _i, g in ipairs(list) do
        g._seen = nil
        table.sort(g.books, within_cmp)
    end
    logger.dbg(string.format("[bookshelf perf] _buildGroups(%s): %.0fms cands=%d groups=%d",
        group_kind, (_gettime() - _t0) * 1000, #cands, #list))
    return list
end

local function _cacheGroupShapes(list, kind)
    local shapes = {}
    for _i, group in ipairs(list) do
        local fps        = {}
        local books_meta = {}
        for _i, b in ipairs(group.books) do
            fps[#fps + 1] = b.filepath
            -- Copy the sort-relevant fields. Carried in the shape so a
            -- per-tab within-group re-sort (drill-time, sort_priority[2+])
            -- has data without going back to the BIM/light cache.
            -- genres/lang are carried so genre and language filters work
            -- on group chips (authors/genres/tags/formats/languages).
            books_meta[#books_meta + 1] = {
                filepath     = b.filepath,
                title        = b.title,
                series_name  = b.series_name,
                series_index = b.series_index,
                author       = b.author,
                authors      = b.authors,
                genres       = b.genres,
                lang         = b.lang,
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

function Repo.getAuthors(limit, offset, sort_priority_override, filter, opts)
    local _t0 = _gettime()
    local home  = G_reader_settings:readSetting("home_dir") or "/"
    local depth = BookshelfSettings.read("latest_walk_depth") or 3
    local key   = (home or "/") .. ":" .. tostring(depth or 0)
    local now   = os.time()
    local cached = _authors_cache[key]
    local _hit = cached
    if not _hit then
        -- Multi-author indexing: a book co-authored by A & B & C appears
        -- under each of A, B, and C in the Authors view. Pre-#74 the key
        -- was b.author (= authors[1]) with multi=false, so co-authors were
        -- silently dropped from the Authors tab. Matches the existing
        -- Genres pattern (multi=true) and Calibre's Authors browser.
        local list = _buildGroups("author", function(b) return b.authors end, true)
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
    local within = _withinPriority(sk)
    local sorted = {}
    for _i, s in ipairs(cached.groups) do
        if _shapeHasFilteredBook(s, filter) then sorted[#sorted + 1] = s end
    end
    table.sort(sorted, _groupShapeCmp(sk))
    local total = #sorted
    local out   = {}
    offset      = offset or 0
    local stop  = _hydrationStop(offset, limit, total, 8, "getAuthors", opts and opts.light_only)
    for i = offset + 1, stop do
        out[#out + 1] = _hydrateGroupShape(sorted[i], within, filter, opts and opts.light_only)
    end
    logger.dbg(string.format("[bookshelf perf] getAuthors: %s %.0fms groups=%d/%d",
        _hit and "HIT" or "MISS", (_gettime() - _t0) * 1000, #out, total))
    return out, total
end

function Repo.getGenres(limit, offset, sort_priority_override, filter, opts)
    local _t0 = _gettime()
    local home  = G_reader_settings:readSetting("home_dir") or "/"
    local depth = BookshelfSettings.read("latest_walk_depth") or 3
    local key   = (home or "/") .. ":" .. tostring(depth or 0)
    local now   = os.time()
    local cached = _genres_cache[key]
    local _hit = cached
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
    local sk = sort_priority_override or Repo.getSortPriority("genres")
    local within = _withinPriority(sk)
    -- Same single-book-stack rule as series (issue #127), applied here so a
    -- genre with one poorly-tagged book can be hidden too.
    local hide_single = BookshelfSettings.isTrue("hide_single_book_stacks")
    local sorted = {}
    for _i, s in ipairs(cached.groups) do
        if _shapeVisible(s, filter, hide_single) then sorted[#sorted + 1] = s end
    end
    table.sort(sorted, _groupShapeCmp(sk))
    local total = #sorted
    local out   = {}
    offset      = offset or 0
    local stop  = _hydrationStop(offset, limit, total, 8, "getGenres", opts and opts.light_only)
    for i = offset + 1, stop do
        out[#out + 1] = _hydrateGroupShape(sorted[i], within, filter, opts and opts.light_only)
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
        series   = _series_cache,
        author   = _authors_cache,
        genre    = _genres_cache,
        format   = _formats_cache,
        rating   = _ratings_cache,
        language = _languages_cache,
    }
    local store = cache_for_kind[kind]
    if not store then return {} end

    -- Ensure the underlying cache is built. limit=0 makes the fetcher's
    -- hydration loop skip while still running the cache-build + sort.
    if not store[key] then
        if     kind == "series"   then Repo.getSeriesGroups(0, 0)
        elseif kind == "author"   then Repo.getAuthors(0, 0)
        elseif kind == "genre"    then Repo.getGenres(0, 0)
        elseif kind == "format"   then Repo.getFormats(0, 0)
        elseif kind == "rating"   then Repo.getRatings(0, 0)
        elseif kind == "language" then Repo.getLanguages(0, 0)
        end
    end

    local cache = store[key]
    if not cache or not cache.groups then return {} end

    local out = {}
    for _i, s in ipairs(cache.groups) do
        out[#out + 1] = {
            value = s.series_name or "",
            label = s.series_name or "",
            count = s.filepaths and #s.filepaths or 0,
        }
    end
    return out
end

-- getGroupFilepaths(kind): mirrors getGroupChoices but returns { [value] =
-- { filepath, ... }, ... } from the cached shapes. value = the series_name the
-- group cache uses (same key distinctFilterValues emits) so callers can cross-
-- reference with filter selections. No hydration, no cover decompression.
function Repo.getGroupFilepaths(kind)
    local home  = G_reader_settings:readSetting("home_dir") or "/"
    local depth = BookshelfSettings.read("latest_walk_depth") or 3
    local key   = (home or "/") .. ":" .. tostring(depth or 0)

    local cache_for_kind = {
        series   = _series_cache,
        author   = _authors_cache,
        genre    = _genres_cache,
        format   = _formats_cache,
        rating   = _ratings_cache,
        language = _languages_cache,
    }
    local store = cache_for_kind[kind]
    if not store then return {} end

    -- Ensure the underlying cache is built (same pattern as getGroupChoices).
    if not store[key] then
        if     kind == "series"   then Repo.getSeriesGroups(0, 0)
        elseif kind == "author"   then Repo.getAuthors(0, 0)
        elseif kind == "genre"    then Repo.getGenres(0, 0)
        elseif kind == "format"   then Repo.getFormats(0, 0)
        elseif kind == "rating"   then Repo.getRatings(0, 0)
        elseif kind == "language" then Repo.getLanguages(0, 0)
        end
    end

    local cache = store[key]
    if not cache or not cache.groups then return {} end

    local out = {}
    for _i, s in ipairs(cache.groups) do
        out[s.series_name or ""] = s.filepaths or {}
    end
    return out
end

-- filterValueCounts(dim, filter): faceted counts for dimension `dim` under
-- `filter`. For each value in dim, returns how many books pass (filter minus
-- dim) AND have that value. Returns nil when no OTHER dimension is active
-- (caller uses static totals). nil for statuses/folders (out of scope).
--
-- Light records are built once per call via the batch BIM cache; no covers
-- are decompressed. Status/rating resolution is sidecar-gated (_hasSidecar)
-- via _recordMatches. Rating is special-cased: the cache keys by star glyphs
-- but distinctFilterValues("ratings") keys by "1".."5"/"unrated", so we
-- re-bucket explicitly.
function Repo.filterValueCounts(dim, filter)
    if dim == "statuses" or dim == "folders" then return nil end
    -- reduced = filter minus `dim`
    local reduced = {}
    for k, v in pairs(filter or {}) do if k ~= dim then reduced[k] = v end end
    if not Filter.isActive(reduced) then return nil end  -- fast path: no other dim
    local compiled = Filter.compile(reduced, Repo.filterOpts())

    local home  = G_reader_settings:readSetting("home_dir") or "/"
    local depth = BookshelfSettings.read("latest_walk_depth") or 3

    if dim == "collections" then
        local rc = getCollections()
        if not rc or not rc.coll then return {} end
        local light_cache = _getLightMetaCache(home, depth)
        local counts = {}
        for name, coll in pairs(rc.coll) do
            if name ~= "favorites" then
                local n = 0
                for filepath in pairs(coll) do
                    local rec = _lightMetaForFp(light_cache, filepath)
                    if rec and _recordMatches(rec, compiled) then n = n + 1 end
                end
                counts[name] = n
            end
        end
        return counts
    end

    -- Ratings: the group cache uses star-glyph series_names; distinctFilterValues
    -- uses "1".."5"/"unrated". Re-walk the library and bucket by numeric key.
    if dim == "ratings" then
        local light_cache = _getLightMetaCache(home, depth)
        local cands = cachedWalk(home, depth)
        local counts = { unrated = 0 }
        for i = 1, 5 do counts[tostring(i)] = 0 end
        for _i, c in ipairs(cands) do
            local rec = _lightMetaForFp(light_cache, c.fp)
            if rec and _recordMatches(rec, compiled) then
                -- Explicitly resolve rating (always needed here to bucket).
                local rating_val
                if _hasSidecar(c.fp) then
                    local _p, _s, r = Repo.readProgress(c.fp)
                    rating_val = r
                end
                local bucket = (rating_val and rating_val > 0)
                    and tostring(math.floor(rating_val)) or "unrated"
                counts[bucket] = (counts[bucket] or 0) + 1
            end
        end
        return counts
    end

    local kind = ({ genres = "genre", langs = "language",
                    formats = "format" })[dim]
    if not kind then return nil end
    local groups = Repo.getGroupFilepaths(kind)
    local light_cache = _getLightMetaCache(home, depth)
    local counts = {}
    for value, fps in pairs(groups) do
        local n = 0
        for _i, fp in ipairs(fps) do
            local rec = _lightMetaForFp(light_cache, fp)
            if rec and _recordMatches(rec, compiled) then n = n + 1 end
        end
        counts[value] = n
    end
    return counts
end

-- getFolderChoices: every directory under home_dir that contains a book at any
-- depth, surfaced as picker choices for the "Specific folder…" chip source.
-- Walks the cached library file list (no fresh lfs scan) and collects every
-- ancestor of every book between home_dir (exclusive) and the book's filename.
-- Stored without a trailing slash so the path matches what Repo.getAll(path)
-- expects (its _joinPath would otherwise double-slash) and what the Home-
-- folders drilldown writes (shape.path = raw lfs entry, no trailing slash).
-- Sorted by lowercased full path so siblings naturally group under parents.
function Repo.getFolderChoices()
    local home  = G_reader_settings:readSetting("home_dir") or "/"
    local depth = BookshelfSettings.read("latest_walk_depth") or 3
    local cands = cachedWalk(home, depth)
    -- home == "/" is kept as literal so the loop's parent ~= home_norm check
    -- terminates at root; for any other home we strip trailing slashes so the
    -- equality compares cleanly.
    local home_norm = home == "/" and "/" or home:gsub("/+$", "")

    local seen = {}
    for _i, c in ipairs(cands) do
        local fp = c.fp or ""
        local parent = fp:match("^(.*)/[^/]+$")
        while parent and parent ~= "" and parent ~= home_norm do
            seen[parent] = true
            parent = parent:match("^(.*)/[^/]+$")
        end
    end

    local out = {}
    for path in pairs(seen) do
        local basename = path:match("([^/]+)$") or path
        out[#out + 1] = { value = path, label = basename, subtitle = path }
    end
    table.sort(out, function(a, b) return a.value:lower() < b.value:lower() end)
    return out
end

-- Build a normalized format string from a filepath. UPPERCASE because that's
-- how the rest of bookshelf (book detail, etc.) presents formats. Returns nil
-- for files with no extension so _buildGroups skips them.
local function _formatKey(fp)
    return _formatLabel(fp)
end

function Repo.getFormats(limit, offset, sort_priority_override, filter, opts)
    local _t0 = _gettime()
    local home  = G_reader_settings:readSetting("home_dir") or "/"
    local depth = BookshelfSettings.read("latest_walk_depth") or 3
    local key   = (home or "/") .. ":" .. tostring(depth or 0)
    local now   = os.time()
    local cached = _formats_cache[key]
    local _hit = cached
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
    local within = _withinPriority(sk)
    local sorted = {}
    for _i, s in ipairs(cached.groups) do
        if _shapeHasFilteredBook(s, filter) then sorted[#sorted + 1] = s end
    end
    table.sort(sorted, _groupShapeCmp(sk))
    local total = #sorted
    local out   = {}
    offset      = offset or 0
    local stop  = _hydrationStop(offset, limit, total, 8, "getFormats", opts and opts.light_only)
    for i = offset + 1, stop do
        out[#out + 1] = _hydrateGroupShape(sorted[i], within, filter, opts and opts.light_only)
    end
    logger.dbg(string.format("[bookshelf perf] getFormats: %s %.0fms groups=%d/%d",
        _hit and "HIT" or "MISS", (_gettime() - _t0) * 1000, #out, total))
    return out, total
end

-- getLanguages: group books by their ebook language metadata. Single-key
-- per book (a book is filed under exactly one language card).
-- Books without a language are filed as 'Unknown'
function Repo.getLanguages(limit, offset, sort_priority_override, filter, opts)
    local _t0 = _gettime()
    local home  = G_reader_settings:readSetting("home_dir") or "/"
    local depth = BookshelfSettings.read("latest_walk_depth") or 3
    local key   = (home or "/") .. ":" .. tostring(depth or 0)
    local now   = os.time()
    local cached = _languages_cache[key]
    local _hit = cached
    if not _hit then
        local list = _buildGroups("language",
            function(b)
                local v = b.lang
                if v == nil or v == "" then return _LANG_UNKNOWN_KEY end
                return v
            end, false)
        _languages_cache[key] = {
            groups     = _cacheGroupShapes(list, "language"),
            expires_at = now + SERIES_CACHE_TTL,
        }
        cached = _languages_cache[key]
    end
    local sk = sort_priority_override or Repo.getSortPriority("languages")
    local within = _withinPriority(sk)
    local sorted = {}
    for _i, s in ipairs(cached.groups) do
        if _shapeHasFilteredBook(s, filter) then sorted[#sorted + 1] = s end
    end
    table.sort(sorted, _groupShapeCmp(sk))
    local total = #sorted
    local out   = {}
    offset      = offset or 0
    local stop  = _hydrationStop(offset, limit, total, 8, "getLanguages", opts and opts.light_only)
    for i = offset + 1, stop do
        out[#out + 1] = _hydrateGroupShape(sorted[i], within, filter, opts and opts.light_only)
    end
    logger.dbg(string.format("[bookshelf perf] getLanguages: %s %.0fms groups=%d/%d",
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
    for _i, entry in ipairs(rh.hist) do
        local t = entry.time or 0
        if t > (read_time[entry.file] or 0) then read_time[entry.file] = t end
    end
    local buckets = { [1]={}, [2]={}, [3]={}, [4]={}, [5]={}, unrated={} }
    for _i, c in ipairs(cands) do
        local book = _lightMetaForFp(light_cache, c.fp)
        if book then
            local rating
            if _hasSidecar(c.fp) then
                local _p, _s, r = Repo.readProgress(c.fp)
                rating = r
            end
            -- Bucket key: only an integer 1..5 is a star bucket; everything
            -- else (nil, 0 = KOReader's "no rating", a float, out of range)
            -- is Unrated. NB 0 is TRUTHY in Lua, so `rating or "unrated"`
            -- would key buckets[0] (nil) and crash on #bucket below.
            local bk = "unrated"
            if type(rating) == "number" then
                local r = math.floor(rating)
                if r >= 1 and r <= 5 then bk = r end
            end
            local b_meta = {
                filepath     = c.fp,
                title        = book.title,
                series_name  = book.series_name,
                series_index = tonumber(book.series_num),
                author       = book.author,
                authors      = book.authors,
                genres       = book.genres,
                lang         = book.lang,
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
    for _i, key in ipairs({5, 4, 3, 2, 1, "unrated"}) do
        local books_meta = buckets[key]
        if #books_meta > 0 then
            table.sort(books_meta, within_cmp)
            local g = {
                kind        = "rating",
                series_name = key == "unrated" and tr("Unrated") or _STAR_REPEAT[key],
                books       = {},
                latest      = 0,
                avg_rating  = key == "unrated" and 0 or key,
            }
            for _i, b in ipairs(books_meta) do
                g.books[#g.books + 1] = b
                local t = b._last_read or 0
                if t > g.latest then g.latest = t end
            end
            groups[#groups + 1] = g
        end
    end
    return groups
end

function Repo.getRatings(limit, offset, sort_priority_override, filter, opts)
    local _t0 = _gettime()
    local home  = G_reader_settings:readSetting("home_dir") or "/"
    local depth = BookshelfSettings.read("latest_walk_depth") or 3
    local key   = (home or "/") .. ":" .. tostring(depth or 0)
    local now   = os.time()
    local cached = _ratings_cache[key]
    local _hit = cached
    if not _hit then
        local list = _buildRatingGroups()
        _ratings_cache[key] = {
            groups     = _cacheGroupShapes(list, "rating"),
            expires_at = now + SERIES_CACHE_TTL,
        }
        cached = _ratings_cache[key]
    end
    local sk = sort_priority_override or Repo.getSortPriority("ratings")
    local within = _withinPriority(sk)
    local sorted = {}
    for _i, s in ipairs(cached.groups) do
        if _shapeHasFilteredBook(s, filter) then sorted[#sorted + 1] = s end
    end
    table.sort(sorted, _groupShapeCmp(sk))
    local total = #sorted
    local out   = {}
    offset      = offset or 0
    local stop  = _hydrationStop(offset, limit, total, 8, "getRatings", opts and opts.light_only)
    for i = offset + 1, stop do
        out[#out + 1] = _hydrateGroupShape(sorted[i], within, filter, opts and opts.light_only)
    end
    logger.dbg(string.format("[bookshelf perf] getRatings: %s %.0fms groups=%d/%d",
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

    local home  = G_reader_settings:readSetting("home_dir") or "/"
    local depth = BookshelfSettings.read("latest_walk_depth") or 3
    local key   = (home or "/") .. ":" .. tostring(depth or 0)

    -- ── folders ──
    -- Folder names are excluded from search by default (issue #190): most
    -- libraries file books into author / series / genre folders, so a folder
    -- whose name matches the query just duplicates the metadata group of the
    -- same name (often with a slightly different count when a book is filed
    -- there without matching metadata). Opt in via the "Include folder names
    -- in search results" advanced setting for folder-led navigation.
    -- Derive from the already-cached walk: unique parent directories whose
    -- basename matches the query. No disk I/O: cachedWalk returns { fp, mtime }.
    local folders = {}
    if BookshelfSettings.read("search_include_folders") == true then
        local cands = cachedWalk(home, depth)
        local seen_dirs = {}
        for _i, c in ipairs(cands) do
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
        for _i, shape in ipairs(cache_table[key].groups) do
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
    local depth = BookshelfSettings.read("latest_walk_depth") or 3
    local key   = (home or "/") .. ":" .. tostring(depth or 0)
    local cache
    if     kind == "author"   then cache = _authors_cache[key]
    elseif kind == "series"   then cache = _series_cache[key]
    elseif kind == "genre"    then cache = _genres_cache[key]
    elseif kind == "format"   then cache = _formats_cache[key]
    elseif kind == "rating"   then cache = _ratings_cache[key]
    elseif kind == "language" then cache = _languages_cache[key]
    else return nil end
    if not cache then
        if     kind == "author"   then Repo.getAuthors(0, 0);      cache = _authors_cache[key]
        elseif kind == "series"   then Repo.getSeriesGroups(0, 0); cache = _series_cache[key]
        elseif kind == "genre"    then Repo.getGenres(0, 0);       cache = _genres_cache[key]
        elseif kind == "format"   then Repo.getFormats(0, 0);      cache = _formats_cache[key]
        elseif kind == "rating"   then Repo.getRatings(0, 0);      cache = _ratings_cache[key]
        elseif kind == "language" then Repo.getLanguages(0, 0);    cache = _languages_cache[key]
        end
        if not cache then return nil end
    end
    local lname = name:lower()
    for _i, shape in ipairs(cache.groups) do
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
    if cached then
        for _i, k in ipairs(STATS_FIELDS) do book[k] = cached.fields[k] end
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
    for _i, k in ipairs(STATS_FIELDS) do snapshot[k] = book[k] end
    _stats_cache[book.filepath] = { fields = snapshot, expires_at = now + STATS_CACHE_TTL }
end

-- _bySourceCacheKey: stable string key for the _bySource_cache table. Encodes
-- source kind + id, the active filter statuses (sorted for stability), and the
-- sort priority levels in order. Cheap: just table.concat over scalar fields.
local function _bySourceCacheKey(source, filter, sort_priority)
    local parts = { (source and source.kind) or "?", (source and source.id) or "" }
    local fsig = Filter.signature(filter)
    if fsig ~= "" then
        parts[#parts + 1] = "f:" .. fsig
    end
    if sort_priority then
        for _i, level in ipairs(sort_priority) do
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
-- Repo.getBySource(source, filter, sort_priority, offset, limit, opts)
-- opts is forwarded to Repo.getAll for the "all" / "folder" dispatches
-- (lazy_cover_w / lazy_cover_h). Other kinds ignore opts today.
function Repo.getBySource(source, filter, sort_priority, offset, limit, opts)
    if not source or not source.kind then return {}, 0 end
    local kind = source.kind
    -- Kobo virtual library (OGKevin/kobo.koplugin): records come from the plugin
    -- bridge, not the filesystem/BIM. Sort the full set with the SortEngine (the
    -- Kobo chip's sort_priority) and paginate. Empty + cheap when the plugin is
    -- unavailable, so this is inert on non-Kobo devices.
    if kind == "kobo" then
        local ok_kobo, KoboSource = pcall(require, "lib/bookshelf_kobo_source")
        if not (ok_kobo and KoboSource and KoboSource.isAvailable()) then return {}, 0 end
        local books = KoboSource.listBooks()
        if sort_priority and #sort_priority > 0 then
            local ok_sort = pcall(table.sort, books, SortEngine.chainedComparator(sort_priority))
            if not ok_sort then table.sort(books, function(a, b)
                return (a.title or "") < (b.title or "") end) end
        end
        local total = #books
        local off, lim = offset or 0, limit or #books
        local page = {}
        for i = off + 1, math.min(off + lim, total) do
            local rec = books[i]
            -- Attach the cover eagerly for the VISIBLE slice only: BIM can't read
            -- the DRM'd kepub, so there's no lazy ScaledCoverCache path -- the
            -- plugin hands back a fresh (copied) blitbuffer the spine can free
            -- after paint. nil (no extracted sidecar cover yet) -> placeholder.
            -- Re-fetched each rebuild, so the freed bb is never reused.
            local bb, cw, ch = KoboSource.coverBB(rec.filepath)
            if bb then
                rec.cover_bb, rec.cover_w, rec.cover_h = bb, cw, ch
                rec.has_cover = true
            end
            page[#page + 1] = rec
        end
        return page, total
    end
    -- Diag: wrap getBySource so chip-switch / pagination logs can be
    -- correlated with fetch cost. The repo's existing per-fetcher logs
    -- show the *internal* breakdown; this outer log shows the
    -- end-to-end cost the caller pays, including the dispatch overhead
    -- and any predicate-path detour.
    local _diag_t0 = _gettime()
    local _diag_id = (source.id and (": id=" .. tostring(source.id):sub(1, 32)))
                     or ""

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
    -- uniformly.
    --
    -- Group kinds (series/authors/genres/tags/formats/ratings) now
    -- accept a `filter` argument and apply it natively (Phase 1 of the
    -- filter-applies-to-groups feature). Empty groups are elided pre-
    -- pagination; covers and per-stack stats reflect the filtered set
    -- where appropriate. Folder cards through Repo.getAll do the same.
    --
    -- sort_priority gate for the legacy book-list fetchers: they use a
    -- single-key sort_<chip> setting with a small whitelist (date_added /
    -- title / recently_read on favorites, etc), and the v2 chip editor
    -- writes only to tab.sort_priority -- never to the legacy key. So a
    -- chip with sort_priority = [series_name, series_index, title]
    -- silently fell back to the fetcher's default ordering. Route through
    -- the predicate path whenever sort_priority is non-empty so the full
    -- SortEngine drives the order. Reported by user feedback on v2.0.1.
    --
    -- kind == "all" and kind == "folder" dispatch to Repo.getAll because
    -- that path produces FOLDER cards in addition to books (the tree view
    -- the user expects for a folder-organised library). The predicate path
    -- below returns books only and runs only when a status filter is active
    -- (books-only degradation). The caller's sort_priority is threaded into
    -- getAll so chip-configured sort applies to both partitions.
    local has_status_filter = Filter.isActive(filter)
    local has_custom_sort   = sort_priority and #sort_priority > 0
    if not has_status_filter then
        if kind == "all"       then return Repo.getAll(nil, limit, offset, sort_priority, nil, opts)       end
        if kind == "folder"    then return Repo.getAll(source.id, limit, offset, sort_priority, nil, opts) end
        if not has_custom_sort then
            if kind == "recent"    then return Repo.getRecent(limit, offset, opts)       end
            if kind == "latest"    then return Repo.getLatest(limit, offset, opts)       end
            if kind == "favorites" then return Repo.getFavorites(limit, offset, opts)    end
        end
    else
        -- Folder views with an active status filter still produce folder
        -- cards, but only those with at least one matching book. getAll
        -- handles the filter natively below (see Phase 1 work).
        if kind == "all"    then return Repo.getAll(nil, limit, offset, sort_priority, filter, opts)       end
        if kind == "folder" then return Repo.getAll(source.id, limit, offset, sort_priority, filter, opts) end
    end
    if kind == "series"    then return Repo.getSeriesGroups(limit, offset, sort_priority, filter, opts) end
    if kind == "authors"   then return Repo.getAuthors(limit, offset, sort_priority, filter, opts) end
    if kind == "genres"    then return Repo.getGenres(limit, offset, sort_priority, filter, opts)  end
    if kind == "tags"      then return Repo.getTags(limit, offset, sort_priority, filter, opts)    end
    if kind == "formats"   then return Repo.getFormats(limit, offset, sort_priority, filter, opts) end
    if kind == "ratings"   then return Repo.getRatings(limit, offset, sort_priority, filter, opts) end
    if kind == "languages" then return Repo.getLanguages(limit, offset, sort_priority, filter, opts) end

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
    local cache_key = _bySourceCacheKey(source, filter, sort_priority)
    local cached_paths = _bySource_cache[cache_key]

    if cached_paths then
        -- Cache hit: slice the path list (already in sorted, post-filter
        -- order) and rehydrate just the visible page.
        local total = #cached_paths
        local from  = (offset or 0) + 1
        local to    = _hydrationStop(offset or 0, limit, total, total, "getBySource", opts and opts.light_only)
        local page  = {}
        if opts and opts.light_only then
            -- Letter-jump path: the caller only reads sort-key fields
            -- (title / author / series) to locate a page boundary and never
            -- renders these records, so skip the heavy _safeBuildBookMeta
            -- and serve light metadata. On a big chip this is the difference
            -- between thousands of DocSettings reads and one batched SELECT.
            local home  = G_reader_settings:readSetting("home_dir") or "/"
            local depth = BookshelfSettings.read("latest_walk_depth") or 3
            local light_cache = _getLightMetaCache(home, depth)
            for i = from, to do
                local b = _lightMetaForFp(light_cache, cached_paths[i])
                if b then page[#page + 1] = b end
            end
            return page, total
        end
        -- opts.lazy_cover: covers already in ScaledCoverCache skip the
        -- BIM zstd decode (want_cover=false); SpineWidget repaints them
        -- from the cache by filepath key. Same probe as getRecent/getAll.
        local ScaledCoverCache
        if opts and opts.lazy_cover then
            ScaledCoverCache = require("lib/bookshelf_scaled_cover_cache")
        end
        for i = from, to do
            local meta_opts
            if ScaledCoverCache and ScaledCoverCache:has(cached_paths[i]) then
                meta_opts = { want_cover = false }
            end
            local b = _safeBuildBookMeta(cached_paths[i], meta_opts)
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
        local function loadCandidatesByPredicate(pred, walk_root)
            local home  = G_reader_settings:readSetting("home_dir") or "/"
            local depth = BookshelfSettings.read("latest_walk_depth") or 3
            -- walk_root lets a folder-scoped source (folder_flat, #76) walk
            -- its own subtree directly instead of the whole home tree --
            -- correct for folders OUTSIDE home_dir (Browse device), where a
            -- home-rooted walk + prefix filter would find nothing. The light
            -- metadata batch stays keyed to home; entries outside it fall
            -- back to a per-file build in _lightMetaForFp.
            local cands = cachedWalk(walk_root or home, depth)
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
            for _i, entry in ipairs(rh.hist) do
                local t = entry.time or 0
                if t > (read_time[entry.file] or 0) then read_time[entry.file] = t end
            end
            local matched = {}
            for _i, c in ipairs(cands) do
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
            for _i, entry in ipairs(rh.hist) do
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
            -- Reached only when a status filter is active (otherwise the
            -- early-return above sends folder chips to getAll for tree view).
            -- Books-only descent: prefix is source.id with exactly one
            -- trailing slash so "/lib/comics" doesn't false-match
            -- "/lib/comics-x/...". Accepts source.id stored either with or
            -- without a trailing slash.
            local prefix = (source.id or ""):gsub("/+$", "") .. "/"
            candidates = loadCandidatesByPredicate(function(b)
                return type(b.filepath) == "string" and b.filepath:sub(1, #prefix) == prefix
            end)
        elseif kind == "folder_flat" then
            -- Flattened folder (#76): every book under source.id at any
            -- depth, no folder cards -- the folder equivalent of "library"
            -- (Home flattened). Walk the folder root directly so it works
            -- for folders both inside and outside home_dir; the walk is
            -- already scoped to the subtree, so the predicate is tautological.
            candidates = loadCandidatesByPredicate(function(_b) return true end,
                (source.id or ""):gsub("/+$", ""))
        elseif kind == "collection" then
            local rc  = require("readcollection")
            local set = {}
            local coll = rc.coll and rc.coll[source.id]
            if type(coll) == "table" then
                for _i, item in pairs(coll) do
                    if type(item) == "table" and item.file then set[item.file] = true end
                end
            end
            candidates = loadCandidatesByPredicate(function(b) return set[b.filepath] end)
        elseif kind == "tag" then
            -- Book records carry BIM/Calibre tag data under b.genres (the
            -- field name is unified across the cb.tags + cb.keywords +
            -- BIM-keywords sources in buildBookMeta). The predicate read
            -- b.tags, which no record ever sets, so this dispatch was
            -- silently empty. No production UI creates source.kind="tag"
            -- today (the chip editor's "Specific tag…" writes
            -- kind="collection"), but the drilldown payload in
            -- bookshelf_widget.lua does use kind="tag" and a future
            -- migration / settings edit could route through this branch.
            local target = source.id
            candidates = loadCandidatesByPredicate(function(b)
                if type(b.genres) ~= "table" then return false end
                for _i, t in ipairs(b.genres) do if t == target then return true end end
                return false
            end)
        elseif kind == "genre" then
            -- Match on normalized form so case + plural variants of the
            -- same conceptual genre are picked up. Same normalization as
            -- _buildGroups -- keep both in sync if the normaliser changes.
            local target_norm = _normalizeGenre(source.id or "")
            candidates = loadCandidatesByPredicate(function(b)
                if type(b.genres) ~= "table" then return false end
                for _i, g in ipairs(b.genres) do
                    if _normalizeGenre(g) == target_norm then return true end
                end
                return false
            end)
        elseif kind == "author" then
            -- Pinned-author chips ("Create chip from this" on an author
            -- stack) match against the full authors list, not just the
            -- primary author -- otherwise a chip pinned to a co-author
            -- would miss the books they share with the primary author.
            -- Keeps this path consistent with the Authors tab drilldown,
            -- which uses _buildGroups("author", b.authors, multi=true).
            local target = source.id
            candidates = loadCandidatesByPredicate(function(b)
                if b.author == target or b.author_name == target or b.author_surname == target then
                    return true
                end
                if type(b.authors) == "table" then
                    for _i, a in ipairs(b.authors) do
                        if a == target then return true end
                    end
                end
                return false
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
        elseif kind == "language" then
            -- The chip's id is the language card's display label (e.g.
            -- "English") or, for older paths, a code. Canonicalise it the same
            -- way book languages are canonicalised so every spelling matches
            -- (en / eng / en-GB / English -> one key). Mirrors _buildGroups.
            local raw_id     = source.id or ""
            local target_key = BookshelfLang.canonical(raw_id)
            local is_unknown = raw_id == "" or raw_id == _LANG_UNKNOWN_KEY
                or _normalizeLang(raw_id) == _normalizeLang(tr("Unknown"))
            if is_unknown or not target_key then
                candidates = loadCandidatesByPredicate(function(b)
                    return b.lang == nil or b.lang == ""
                end)
            else
                candidates = loadCandidatesByPredicate(function(b)
                    if b.lang == nil or b.lang == "" then return false end
                    return BookshelfLang.canonical(b.lang) == target_key
                end)
            end
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
            candidates = loadCandidatesByPredicate(function(b)
                if not b._progress_fetched and b.filepath then
                    if _hasSidecar(b.filepath) then
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

        -- Filter candidates by any active filter dimension (status, genre,
        -- lang, format, collections, folders). Light metadata doesn't carry
        -- read_status, so status is resolved lazily via _recordMatches --
        -- only when the compiled filter constrains it -- so most users pay
        -- nothing extra. _recordMatches encapsulates the sidecar fast-path
        -- (_hasSidecar gates the heavier DocSettings:open, issue #113/#117)
        -- and sets _progress_fetched so the subsequent sort prefetch below
        -- doesn't re-open sidecars already read here.
        if Filter.isActive(filter) then
            local compiled_e = Filter.compile(filter, Repo.filterOpts())
            local kept = {}
            for _i, b in ipairs(candidates) do
                if _recordMatches(b, compiled_e) then kept[#kept + 1] = b end
            end
            candidates = kept
        end

        -- needs-introspection for the sort: only pay for DocSettings reads
        -- when the user's sort priority actually depends on progress data.
        -- Same pattern getAll uses for its prefetch (search for "local needs").
        local needs_progress = false
        if sort_priority then
            for _i, lv in ipairs(sort_priority) do
                local k = lv.key
                if k == "percent_read"
                        or k == "read_status"
                        or k == "read_status_active"
                        or k == "rating"
                        or k == "page_count" then
                    -- 'rating' and 'page_count' both come back from
                    -- Repo.readProgress (summary.rating + the sidecar page
                    -- map), so they piggyback on the same prefetch.
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
            local _t0 = _gettime()
            local fast_skipped, full_read = 0, 0
            for _i, b in ipairs(candidates) do
                if not b._progress_fetched and b.filepath then
                    local has_sdr = _hasSidecar(b.filepath)
                    if has_sdr then
                        local pct, status, rating, page_count = Repo.readProgress(b.filepath)
                        b._pct       = pct
                        b._status    = status
                        b.rating     = b.rating or rating
                        b.page_count = b.page_count or page_count
                        full_read    = full_read + 1
                    else
                        b._pct      = nil
                        b._status   = nil
                        -- rating / page_count stay nil too -- unread books
                        -- can't be rated and have no sidecar page map
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
    for _i, b in ipairs(candidates) do paths[#paths + 1] = b.filepath end
    _bySource_cache[cache_key] = paths

    -- candidates is light metadata (no covers). For the visible slice,
    -- rebuild with the full _safeBuildBookMeta path so covers render.
    -- Light records are released for GC after this function returns.
    local total = #paths
    local from  = (offset or 0) + 1
    local to    = _hydrationStop(offset or 0, limit, total, total, "getBySource", opts and opts.light_only)
    local page  = {}
    if opts and opts.light_only then
        -- Letter-jump path: the sorted light candidates already carry the
        -- sort-key fields the caller needs, so hand back that slice directly
        -- rather than re-hydrating full records (covers etc.) it won't use.
        for i = from, to do
            local b = candidates[i]
            if b then page[#page + 1] = b end
        end
        return page, total
    end
    -- opts.lazy_cover: same ScaledCoverCache probe as the HIT path above.
    local ScaledCoverCache
    if opts and opts.lazy_cover then
        ScaledCoverCache = require("lib/bookshelf_scaled_cover_cache")
    end
    for i = from, to do
        local meta_opts
        if ScaledCoverCache and ScaledCoverCache:has(paths[i]) then
            meta_opts = { want_cover = false }
        end
        local b = _safeBuildBookMeta(paths[i], meta_opts)
        if b then page[#page + 1] = b end
    end
    logger.dbg(string.format(
        "[bookshelf perf] getBySource: kind=%s%s path=predicate cached=%s total=%d elapsed=%.0fms",
        kind, _diag_id, cached_paths and "HIT" or "MISS", total,
        (_gettime() - _diag_t0) * 1000))
    return page, total
end

return Repo
