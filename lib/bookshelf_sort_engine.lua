-- bookshelf_sort_engine.lua
-- Pure-function multi-key sort over a list of book records.
-- A "priority" is an ordered list of { key = <string>, reverse = <bool> } entries.
-- The first key compares; if equal, the next key compares; and so on.

local _ok = pcall(require, "lib/bookshelf_i18n")  -- soft: tests stub-load without it
local i18n = package.loaded["lib/bookshelf_i18n"]
local function tr(s) if i18n and i18n.gettext then return i18n.gettext(s) end; return s end

local ok, AuthorName = pcall(require, "lib/bookshelf_author_name")
if not ok then AuthorName = nil end

-- Optional pinyin collation (issue #43). When the "cjk_pinyin_sort"
-- setting is on, every cached sort key passes through Pinyin.key(), which
-- rewrites Han characters to their toneless Mandarin syllables so CJK
-- titles and authors interleave with Latin ones ("liu" files under L).
-- Off (the default), CJK strings keep raw codepoint order, which is
-- approximately radical/stroke order. Both requires are soft: the
-- standalone test harness preloads stubs, and a missing module just
-- means the feature stays off.
local ok_store, Store = pcall(require, "lib/bookshelf_settings_store")
if not ok_store then Store = nil end
local ok_pinyin, Pinyin = pcall(require, "lib/bookshelf_pinyin")
if not ok_pinyin then Pinyin = nil end

local SortEngine = {}

-- Sort keys are memoized on the records themselves (see cachedSurname
-- etc.), so flipping the pinyin toggle must invalidate every record's
-- cached keys -- including records the settings UI can't reach. Epoch
-- counter: refreshPinyinFlag() bumps _key_epoch when the effective flag
-- changes, and ensureEpoch(b) lazily wipes a record's caches the first
-- time it's touched under a new epoch. The settings read itself is
-- memoized against Store.generation() so the per-sort cost is one
-- integer compare, not a settings lookup per comparison.
local _pinyin_on  = false
local _pinyin_gen = -1
local _key_epoch  = 0

local function refreshPinyinFlag()
    if not (Store and Pinyin) then return end
    local gen = Store.generation()
    if gen == _pinyin_gen then return end
    _pinyin_gen = gen
    local on = Store.read("cjk_pinyin_sort") == true
    if on ~= _pinyin_on then
        _pinyin_on = on
        _key_epoch = _key_epoch + 1
    end
end

local function ensureEpoch(b)
    if b._key_epoch ~= _key_epoch then
        b._key_epoch          = _key_epoch
        b._surname_cache      = nil
        b._given_cache        = nil
        b._title_key_cache    = nil
        b._filename_key_cache = nil
        b._series_key_cache   = nil
    end
end

-- Applied at cache-store time, so the conversion runs once per record,
-- not once per comparison. The \1 check makes a double application a
-- no-op (keys already carry the \1 tie-break separator).
local function pinyinise(s)
    if not _pinyin_on then return s end
    if type(s) ~= "string" or s == "" then return s end
    if s:find("\1", 1, true) then return s end
    if not Pinyin.hasHan(s) then return s end
    return Pinyin.key(s)
end

-- Order ranks used by the two read_status comparators.
--   _PROGRESS: natural progression -- TBR first, finished last.
--   _ACTIVE:   what-am-I-reading-now first; unread next; finished last.
-- on_hold sits third in both -- shelved books are below active reading but
-- above already-read.
--
-- Both vocabularies are present: bookshelf's normalised names (unread,
-- on_hold, finished) AND KOReader's raw values that may leak through from
-- DocSettings without normalisation ("new", "abandoned", "complete"), so a
-- comparator called against either shape resolves to the right rank.
-- Issue #41: with only the bookshelf names, raw "complete"/"abandoned"
-- values mapped to nil and dropped to the catch-all 99 ("no metadata"),
-- placing finished/on-hold books at the END of the read_status sort.
local STATUS_RANK_PROGRESS = {
    unread = 1, ["new"] = 1,
    reading = 2,
    on_hold = 3, abandoned = 3,
    finished = 4, complete = 4,
}
local STATUS_RANK_ACTIVE   = {
    reading = 1,
    unread = 2, ["new"] = 2,
    on_hold = 3, abandoned = 3,
    finished = 4, complete = 4,
}

-- nil-safe comparator helper. Returns -1, 0, +1 so it composes cleanly.
-- nil always sorts to the end (higher sort order).
-- Sentinel return values for nil-handling. The chainedComparator detects
-- these and short-circuits BEFORE applying level.reverse, so missing
-- values always sort to the end regardless of ascending / descending
-- direction. Without this, reverse-sort puts nils at the start, which
-- gives users a confusing first page of "no metadata" entries.
local SORT_TO_END   = "__sort_to_end__"   -- a (or both sides) missing -> a after b
local SORT_TO_START = "__sort_to_start__" -- only b missing            -> a before b

local function isMissing(v)
    return v == nil or v == ""
end

local function cmp(a, b)
    local am, bm = isMissing(a), isMissing(b)
    if am and bm then return 0              end
    if am          then return SORT_TO_END   end
    if bm          then return SORT_TO_START end
    if a == b      then return 0             end
    if a < b       then return -1            end
    return 1
end

-- Natural ("Vol 2" before "Vol 10") less-than. Reuses KOReader's own
-- sort.natsort_cmp so name/title ordering matches the native file browser
-- (issue #104). The comparator is built ONCE, module-level, with a
-- persistent conversion cache: natsort_cmp massages each distinct string
-- once and memoizes it, where the old per-comparison fallback re-converted
-- both sides on every one of the ~n*log(n) table.sort calls. (KOReader
-- removed the bare `sort.natsort` in PR #10023, so the previous
-- `_KSort.natsort` guard never fired and EVERY sort silently ran the
-- expensive uncached fallback. The fallback now exists only for the
-- standalone test harness, where the runtime module isn't on package.path.)
-- natsort is case-sensitive, so callers lowercase first to keep sorting
-- case-insensitive (same as the plain cmp path did).
local _ok_natsort, _KSort = pcall(require, "sort")
local _natsort
if _ok_natsort and type(_KSort) == "table" then
    if type(_KSort.natsort_cmp) == "function" then
        _natsort = _KSort.natsort_cmp()       -- comparator + persistent cache
    elseif type(_KSort.natsort) == "function" then
        _natsort = _KSort.natsort             -- pre-2023.02 KOReader
    end
end
local function natLess(a, b)
    if _natsort then return _natsort(a, b) end
    local function pad(d)
        local dec, n = d:match("(%.?)0*(.+)")
        return #dec > 0 and ("%.12f"):format(d) or ("%s%03d%s"):format(dec, #n, n)
    end
    return (a:gsub("%.?%d+", pad)) .. ("%3d"):format(#b)
         < (b:gsub("%.?%d+", pad)) .. ("%3d"):format(#a)
end

-- Natural-order variant of cmp: identical nil/missing handling (so it
-- composes in chainedComparator), but digit runs compare numerically.
local function natCmp(a, b)
    local am, bm = isMissing(a), isMissing(b)
    if am and bm then return 0              end
    if am          then return SORT_TO_END   end
    if bm          then return SORT_TO_START end
    if a == b      then return 0             end
    return natLess(a, b) and -1 or 1
end

-- effective_percent(book): treat "finished" as 1.0 regardless of stored value.
-- Fixes the issue where books marked finished but at 99% still show as < 100%.
-- Also handles lfs-entry shape: _pct / _status instead of percent_finished / read_status.
--
-- Unread books (no sidecar -> nil status, nil pct OR "new" status) get 0.0
-- explicitly. Without this they returned nil and the chained cmp's
-- SORT_TO_END sentinel pushed them to the end regardless of direction,
-- so the "Unread first" sort put them last. (Issue #41.)
local function effective_percent(b)
    local status = b.read_status or b._status
    if status == "finished" or status == "complete" then return 1.0 end
    if status == nil or status == "new" or status == "unread" then return 0 end
    return b.percent_finished or b._pct
end

-- Memoized surname / given lookup. Caches on the record so a sort over
-- 3000 books does 3000 parses, not ~35000 (one per comparison pair).
--
-- Source order:
--   1. b.author_sort           -- Calibre-curated sort form. "Surname,
--                                 Forename" (single) or "Surname1, F1 &
--                                 Surname2, F2" (multi). Honours user
--                                 edits to particles ("St. Crowe", "van
--                                 der"), suffixes, inverted-naming
--                                 cultures, etc. Strictly the right
--                                 answer when present.
--   2. b.author / b.authors    -- BIM or Calibre author metadata --
--                                 surnameOf parses the last token as the
--                                 surname; falls down on the cases
--                                 author_sort covers, but it's all we
--                                 have for non-Calibre libraries.
--   3. b.author_surname        -- pre-parsed surname (rarely set)
--   4. b.series_name           -- group shape (Authors / Genres tab)
--   5. b.name                  -- lfs entry (Home folder cards, where the
--                                 folder name IS the author identifier)
--
-- Parent-folder name is NOT a fallback for book files: the flat library
-- view should respect BIM/Calibre author metadata only, not synthesise
-- author from folder structure. Books without metadata tie at "" which
-- is the honest signal.
local function cachedSurname(b)
    ensureEpoch(b)
    if b._surname_cache ~= nil then return b._surname_cache end
    -- Prefer Calibre's curated author_sort over derived surname.
    if type(b.author_sort) == "string" and b.author_sort ~= "" then
        -- "Surname1, F1 & Surname2, F2" -> first author -> surname.
        local first = b.author_sort:match("^([^&]+)") or b.author_sort
        local surname = first:match("^([^,]+)") or first
        surname = surname:gsub("^%s+", ""):gsub("%s+$", "")
        if surname ~= "" then
            b._surname_cache = pinyinise(surname:lower())
            return b._surname_cache
        end
    end
    local raw = b.author or b.authors or b.author_surname
             or b.series_name or b.name or ""
    if type(raw) ~= "string" then raw = "" end
    -- surnameSortKey strips leading particles ("de Maupassant" sorts
    -- under M, not D) so the alphabetical position matches the user's
    -- mental model of where the surname lives. surnameOf KEEPS the
    -- particle for display.
    local s
    if AuthorName and AuthorName.surnameSortKey then
        s = AuthorName.surnameSortKey(raw)
    elseif AuthorName then
        s = AuthorName.surnameOf(raw):lower()
    else
        s = raw:lower()
    end
    b._surname_cache = pinyinise(s)
    return b._surname_cache
end

-- See cachedSurname for the rationale on each fallback rung. Same chain
-- here so the two comparators stay consistent.
local function cachedGiven(b)
    ensureEpoch(b)
    if b._given_cache ~= nil then return b._given_cache end
    local raw = b.author or b.authors or b.author_name
             or b.series_name or b.name or ""
    if type(raw) ~= "string" then raw = "" end
    local s = AuthorName and AuthorName.givenOf(raw) or raw
    b._given_cache = pinyinise(s:lower())
    return b._given_cache
end

-- Memoized lowercased sort keys, cached on the record like _surname_cache.
-- table.sort runs a comparator ~n*log(n) times; without these the title /
-- filename / series comparators allocated two fresh lowered strings on
-- every call (~2500 at 300 books, ~35000 at 3000). `false` marks "derived,
-- and missing" so absent values are also only derived once; callers turn it
-- back into nil with `or nil` for cmp/natCmp's missing-value sentinels.
-- Safe to cache on the record: hydration (including Hardcover
-- applyMetadata's title/series overrides) finishes before any sort runs,
-- and records are rebuilt whenever metadata changes.
local function cachedTitleKey(b)
    ensureEpoch(b)
    local v = b._title_key_cache
    if v == nil then
        v = b.title or (b.doc_props and b.doc_props.display_title) or b.name
        v = (v ~= nil and v ~= "") and pinyinise(tostring(v):lower()) or false
        b._title_key_cache = v
    end
    return v or nil
end

local function cachedFilenameKey(b)
    ensureEpoch(b)
    local v = b._filename_key_cache
    if v == nil then
        v = b.filename or b.file or b.name or b.series_name
        v = (v ~= nil and v ~= "") and pinyinise(tostring(v):lower()) or false
        b._filename_key_cache = v
    end
    return v or nil
end

local function cachedSeriesKey(b)
    ensureEpoch(b)
    local v = b._series_key_cache
    if v == nil then
        v = b.series_name or b.series
        v = (v ~= nil and v ~= "") and pinyinise(tostring(v):lower()) or false
        b._series_key_cache = v
    end
    return v or nil
end

-- sortKeyValue(item, key): the canonical lowercased string the given sort
-- key orders by -- the SAME derivation the KEYS comparators use. Callers
-- like the home screen's "go to letter" jump match against this so the
-- letter landed on is exactly where the visible sort placed it, rather than
-- a re-derived approximation that can diverge (e.g. matching the forename
-- initial when the chip is sorted by surname). author_surname / author_name
-- reuse the memoised cachedSurname / cachedGiven, which honour Calibre
-- author_sort and particle stripping. Keys with no string identity (dates,
-- progress, counts) fall back to a title-ish value so a letter jump still
-- lands somewhere recognisable.
function SortEngine.sortKeyValue(item, key)
    if not item then return nil end
    refreshPinyinFlag()
    local v
    if key == "author_surname" then
        v = cachedSurname(item)
    elseif key == "author_name" then
        v = cachedGiven(item)
    elseif key == "title" then
        v = item.title or (item.doc_props and item.doc_props.display_title) or item.name
    elseif key == "filename" then
        v = item.filename or item.file or item.name or item.series_name
    elseif key == "series_name" or key == "series_combined" then
        v = item.series_name or item.series
    end
    if type(v) ~= "string" or v == "" then
        v = item.title or (item.doc_props and item.doc_props.display_title)
            or item.name or item.filename or item.file or item.series_name
        if type(v) ~= "string" or v == "" then return nil end
    end
    -- cachedSurname/cachedGiven already pinyinised; raw derivations here
    -- (title/filename/series + the title-ish fallback) get the same
    -- treatment so a letter jump lands where the visible sort placed it.
    return pinyinise(v:lower())
end

SortEngine.KEYS = {
    -- Book record: a.title
    -- lfs entry:   a.doc_props.display_title (when needs_titles prefetch ran) or a.name
    title           = { label = tr("Title"), short = tr("Title"),
                        comparator = function(a, b)
                            return natCmp(cachedTitleKey(a), cachedTitleKey(b))
                        end },
    -- Book record: a.filename / a.file
    -- lfs entry:   a.name
    -- group shape: a.series_name (series/author/genre/tag groups have no filename)
    filename        = { label = tr("Filename"), short = tr("Filename"),
                        comparator = function(a, b)
                            return natCmp(cachedFilenameKey(a), cachedFilenameKey(b))
                        end },
    author_name     = { label = tr("Author (given name)"), short = tr("Author"),
                        comparator = function(a, b) return cmp(cachedGiven(a), cachedGiven(b)) end },
    author_surname  = { label = tr("Author surname"), short = tr("Surname"),
                        comparator = function(a, b) return cmp(cachedSurname(a), cachedSurname(b)) end },
    series_name     = { label = tr("Series name"), short = tr("Series"),
                        comparator = function(a, b)
                            return cmp(cachedSeriesKey(a), cachedSeriesKey(b))
                        end },
    series_index    = { label = tr("Series index"), short = tr("Series #"),
                        comparator = function(a, b) return cmp(tonumber(a.series_index or a.series_num),
                                                                tonumber(b.series_index or b.series_num)) end },
    -- One sort slot that orders by series NAME first, then by INDEX within each
    -- series. Lets users keep "Series, then within-series numbering" without
    -- spending two priority levels on it -- so author + series-combined + title
    -- fits naturally for a typical "by author, by series order, then title"
    -- whole-library sort (issue #72).
    series_combined = { label = tr("Series + index"), short = tr("Series + #"),
                        comparator = function(a, b)
                            local s = cmp(cachedSeriesKey(a), cachedSeriesKey(b))
                            if s ~= 0 then return s end
                            return cmp(tonumber(a.series_index or a.series_num),
                                       tonumber(b.series_index or b.series_num))
                        end },
    -- Book record: a.last_opened
    -- lfs entry:   a._last_read (when last_read prefetch ran)
    -- group shape: a.latest (most-recent last_opened among member books)
    last_opened     = { label = tr("Last opened"), short = tr("Opened"),
                        comparator = function(a, b)
                            return cmp(a.last_opened or a._last_read or a.latest,
                                       b.last_opened or b._last_read or b.latest)
                        end },
    -- effective_percent handles both shapes: percent_finished/_pct + read_status/_status
    percent_read    = { label = tr("Percent read"), short = tr("Progress"),
                        comparator = function(a, b) return cmp(effective_percent(a), effective_percent(b)) end },
    -- Two status sorts: same set, different ordering.
    -- "read_status" keeps the legacy key for back-compat with any tabs whose
    -- sort_priority was set before the split.
    read_status         = { label = tr("Unread/Reading/Finished"),
                            short = tr("Unread 1st"),
                            comparator = function(a, b)
                                -- nil status == unread (no sidecar); look up
                                -- "unread" rather than falling through to 99
                                -- so unread books sort first as the label
                                -- promises. (Issue #41.)
                                return cmp(STATUS_RANK_PROGRESS[a.read_status or a._status or "unread"] or 99,
                                           STATUS_RANK_PROGRESS[b.read_status or b._status or "unread"] or 99)
                            end },
    read_status_active  = { label = tr("Reading/Unread/Finished"),
                            short = tr("Reading 1st"),
                            comparator = function(a, b)
                                return cmp(STATUS_RANK_ACTIVE[a.read_status or a._status or "unread"] or 99,
                                           STATUS_RANK_ACTIVE[b.read_status or b._status or "unread"] or 99)
                            end },
    -- Book record: a.date_added
    -- lfs entry:   a.attr.modification
    -- group shape: a.latest_added (max member mtime; set in _buildGroups so
    --              a "Sort by date added" on Authors / Genres / Series /
    --              Tags / Formats tabs surfaces groups containing recently-
    --              added books first)
    date_added      = { label = tr("Date added"), short = tr("Added"),
                        comparator = function(a, b)
                            local av = a.date_added or a.latest_added
                                    or (a.attr and a.attr.modification)
                            local bv = b.date_added or b.latest_added
                                    or (b.attr and b.attr.modification)
                            return cmp(av, bv)
                        end },
    -- Book record: a.size
    -- lfs entry:   a.attr.size
    -- short is "File size" (not "Size"): on its own next to "Pages" a bare
    -- "Size" reads as page count, which is how book length is usually judged.
    size            = { label = tr("File size"), short = tr("File size"),
                        comparator = function(a, b)
                            return cmp(a.size or (a.attr and a.attr.size),
                                       b.size or (b.attr and b.attr.size))
                        end },
    -- Book record: a.book_count (explicit integer field)
    -- group shape: #a.filepaths (group carries a filepaths array, no book_count field)
    book_count      = { label = tr("Book count"), short = tr("Books"),
                        comparator = function(a, b)
                            local av = a.book_count or (a.filepaths and #a.filepaths)
                            local bv = b.book_count or (b.filepaths and #b.filepaths)
                            return cmp(av, bv)
                        end },
    -- Book record: a.rating (1-5 stars, from DocSettings summary.rating; nil = unrated)
    -- Group shape: a.avg_rating (mean rating across rated members; nil if none)
    rating          = { label = tr("Rating"), short = tr("Rating"),
                        comparator = function(a, b)
                            return cmp(a.rating or a.avg_rating,
                                       b.rating or b.avg_rating)
                        end },
    -- Book record: a.page_count (from BIM / DocSettings stats.pages)
    -- group shape: a.total_pages (sum of member page counts)
    page_count      = { label = tr("Page count"), short = tr("Pages"),
                        comparator = function(a, b)
                            return cmp(a.page_count or a.total_pages,
                                       b.page_count or b.total_pages)
                        end },
}

-- ORDER used to surface keys in the picker UI later. Sorted by perceived
-- usefulness on a typical library view, not alphabetically.
SortEngine.ORDER = {
    "title", "filename", "author_surname", "author_name",
    "series_name", "series_index", "series_combined",
    "last_opened", "date_added",
    "percent_read", "rating",
    "read_status", "read_status_active",
    "size", "page_count", "book_count",
}

-- chainedComparator(priority): builds a single Lua-table-sort comparator from
-- a priority list. Each entry is { key, reverse }. The first entry whose
-- comparator returns non-zero decides ordering; ties cascade to the next key.
-- Levels are resolved against KEYS once here, not on every one of the
-- ~n*log(n) comparator calls; unknown keys drop out up front.
function SortEngine.chainedComparator(priority)
    refreshPinyinFlag()
    local levels = {}
    local used   = {}
    for _i, level in ipairs(priority) do
        local k = SortEngine.KEYS[level.key]
        if k then
            levels[#levels + 1] = { comparator = k.comparator, reverse = level.reverse }
            used[level.key] = true
        end
    end
    -- Deterministic tie-break: when every requested level ties, fall back to
    -- title then filename so equal books never fall into arbitrary order.
    -- table.sort isn't stable, and some sources arrive in non-deterministic
    -- pairs() order (e.g. collections), so without this the leftover order can
    -- even shuffle between renders (#205/#208). filename is the book's path, so
    -- it's unique -> a total order. Skipped if the user already sorts by it.
    if not used.title then
        levels[#levels + 1] = { comparator = SortEngine.KEYS.title.comparator, reverse = false }
    end
    if not used.filename then
        levels[#levels + 1] = { comparator = SortEngine.KEYS.filename.comparator, reverse = false }
    end
    return function(a, b)
        for _i, lv in ipairs(levels) do
            local r = lv.comparator(a, b)
            -- Missing values sort to the end regardless of reverse
            -- direction, so the user never sees "no metadata" books
            -- on the first page when sorting either way.
            if r == SORT_TO_END   then return false end
            if r == SORT_TO_START then return true  end
            if lv.reverse then r = -r end
            if r ~= 0 then return r < 0 end
        end
        return false
    end
end

-- sort(books, priority): in-place sort. `priority` is a list of { key, reverse }.
-- An empty priority is a no-op (stable order preserved).
function SortEngine.sort(books, priority)
    if not priority or #priority == 0 then return books end
    table.sort(books, SortEngine.chainedComparator(priority))
    return books
end

return SortEngine
