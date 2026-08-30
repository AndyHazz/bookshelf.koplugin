-- bookshelf_token_record.lua
-- Makes a SHELF record answer like the HERO's record, one field at a time,
-- without the shelf paying the hero's price.
--
-- ── Why this exists ────────────────────────────────────────────────────────
--
-- lib/bookshelf_tokens.lua has ~60 expanders and every one of them reads a
-- field off the book table it is handed. Literally:
--
--     Tokens.expanders.book_pct = function(b)
--         return b and b.book_pct and pct(b.book_pct) or ""
--     end
--
-- `book_pct` does not exist on a shelf record. The shelf renders
-- Repo.buildBookMeta records, which are BookInfoManager-only and deliberately
-- skip the DocSettings sidecar read -- the dominant per-rebuild cost on
-- libraries over 100 books (bookshelf_book_repository.lua:587-593). So do
-- `status`, `rating`, `size`, `last_opened` and `date_added`, and so does
-- `page_count` for every reflowed EPUB (BIM does not compute one).
--
-- Point a token line editor at list rows unmitigated and every empty-column
-- bug of the last five rounds comes back in a new costume. This module is the
-- mitigation, and it is a WRAPPER rather than a change to the expanders on
-- purpose: an expander is the wrong place to know about sidecars, and there
-- are sixty of them.
--
-- ── The contract ───────────────────────────────────────────────────────────
--
--   Tokens.expand(fmt, TokenRecord.wrap(shelf_record), state)
--
-- must produce what Tokens.expand(fmt, hero_record, state) would, with NO
-- change to bookshelf_tokens.lua. That property is the whole point; if a
-- future field needs an expander edited to work here, the adapter has failed
-- and the field belongs in RESOLVERS instead.
--
-- ── The mechanism ──────────────────────────────────────────────────────────
--
-- A metatable __index over an EMPTY proxy table. Reading a field:
--
--   1. the underlying record's own value wins, always, and is memoised onto
--      the proxy. A path that already supplies `date_added` (the custom-source
--      fetchers stamp it) never reaches the disk for it.
--   2. otherwise a resolver runs, once, and its answer is memoised -- INCLUDING
--      a nil answer, which is why `_resolved` exists as well as the proxy's own
--      fields. Lua's __index fires on every read of an absent key, so a field
--      that legitimately has no value would re-run its resolver, and its stat,
--      on every access without the second table. A book with no sidecar is the
--      common case, not the edge one.
--   3. a field with no resolver reads through to the record and is NOT
--      memoised. It costs one rawget and keeps the wrapper honest if the
--      record gains the field later.
--
-- `false` needs no special case and gets none: __index only fires on nil, so a
-- resolved `false` is returned from the proxy's own storage from then on. The
-- alternative -- a truthiness test anywhere in this file -- would turn a real
-- boolean into a permanent re-resolve, so there are none.
--
-- Writes are not forwarded. The absence of a __newindex means an assignment
-- lands on the proxy and shadows the record; the record itself is never
-- mutated by anything that happens here. See the leak note below.
--
-- ── What it is NOT ─────────────────────────────────────────────────────────
--
-- Not a record. `pairs()` over a wrapper sees only what has already been
-- resolved, because Lua 5.1 / LuaJIT does not honour __pairs -- so anything
-- that COPIES, SERIALISES or CACHES a record will silently take a subset and
-- lose the rest. A wrapper is a read-through view for the life of one render
-- and must not outlive it:
--
--   * never hand one to Repo's caches, to shallowCopyRecord, to a settings
--     write, or to anything that stores a book for later;
--   * unwrap at any boundary that does -- TokenRecord.unwrap is idempotent
--     and safe to call on a plain record.
--
-- Nor is it a substitute for Repo.buildBook. It does not resolve `page_num`,
-- `last_xp` or the statistics fields, and that is deliberate rather than
-- unfinished: buildBook takes page_num from `last_page` or
-- `pagemap_current_page_label` with a percentage-derived approximation only as
-- a last resort, and none of the memoised accessors expose the first two. An
-- adapter that synthesised the approximation alone would put a DIFFERENT page
-- number on a list row than the hero shows for the same PDF. Absent beats
-- contradictory; if %page_num is wanted on a row, it needs a real accessor
-- first.
local TokenRecord = {}

-- Marker on the metatable, so a wrapper is identifiable at a boundary without
-- exporting the metatable itself or reserving a field name on the proxy (which
-- would shadow a record field of the same name).
local MARKER = "__bookshelf_token_record"

-- ── The repository, resolved lazily and once ───────────────────────────────
-- Resolved through pcall so the pure test harness can stub the module, and so
-- a missing repository degrades to "no value" rather than raising inside a
-- render.
local _Repo
local function repo()
    if _Repo == nil then
        local ok, r = pcall(require, "lib/bookshelf_book_repository")
        _Repo = (ok and type(r) == "table") and r or false
    end
    return _Repo or nil
end

-- ── The OPDS guard ─────────────────────────────────────────────────────────
-- "OPDS://server/id" is a pseudo-path for a catalogue entry with no file
-- behind it. Every disk-touching resolver goes through here, so a page of
-- catalogue rows costs no stats at all -- and shows nothing rather than a
-- number derived from a file that does not exist. The codebase already refuses
-- to treat one as a file in the two places it matters
-- (bookshelf_book_repository.lua:715 in buildBookMeta and :914 in getCoverBB).
local function localPath(rec)
    local fp = rec.filepath
    if type(fp) ~= "string" or fp == "" then return nil end
    if fp:find("^OPDS://") then return nil end
    return fp
end

-- ── The ReadHistory lookup ─────────────────────────────────────────────────
--
-- `last_opened` has no memoised accessor in the repository: the three sort
-- paths that need it each build a filepath -> time map inline from
-- ReadHistory.hist (bookshelf_book_repository.lua:2661-2669, :3427-3433,
-- :5496-5500) and throw it away. Building one per ROW would be the "multiply
-- the disk touches" failure in its purest form -- ~50 entries walked 27 times
-- a page -- so it is built once here and reused.
--
-- Invalidated by fingerprint rather than by a hook, because there is no hook
-- to hang it on. ReadHistory mutates `hist` IN PLACE (a freshly closed book is
-- moved to slot 1 with a new time), so the table's identity never changes and
-- cannot be the key. Length plus slot 1's file and time is O(1) and catches
-- exactly the mutation that matters. It costs nothing to be wrong for one
-- render if some other reordering slips through; it would cost a rebuild per
-- row to be certain.
local _rh_map, _rh_print
local function readHistoryMap()
    local ok, RH = pcall(require, "readhistory")
    if not ok or type(RH) ~= "table" then return nil end
    -- Read the field ONCE. ReadHistory exposes `hist` as a plain field today,
    -- but three reads per row for a fingerprint is three too many if it ever
    -- stops being one.
    local hist = RH.hist
    if type(hist) ~= "table" then return nil end
    local first = hist[1]
    local fingerprint = string.format("%d|%s|%s", #hist,
        tostring(first and first.file), tostring(first and first.time))
    if _rh_map and _rh_print == fingerprint then return _rh_map end
    local map = {}
    for _i, entry in ipairs(hist) do
        local t = tonumber(entry.time) or 0
        if entry.file and t > (map[entry.file] or 0) then
            map[entry.file] = t
        end
    end
    _rh_map, _rh_print = map, fingerprint
    return map
end

-- Exposed for the tests, and for anything that swaps ReadHistory underneath us.
function TokenRecord.forgetReadHistory()
    _rh_map, _rh_print = nil, nil
end

-- ── Resolvers ──────────────────────────────────────────────────────────────
--
-- Each entry resolves ONE key. `fill` returns a table of every key the same
-- piece of work answers, so a resolver that costs a sidecar read pays for all
-- of its fields at once no matter which of them the template happened to name
-- first. That is the difference between a template with four progress tokens
-- costing one DocSettings open and costing four.
--
-- A fill result reports "there is no value" with NONE, not with nil and not
-- with false. nil because a nil value in a table is not a key and the caller
-- could not tell "resolved to nothing" from "this resolver does not answer
-- that field"; false because false is a legitimate value for a boolean field,
-- and using it as the absence marker would make the first boolean anyone adds
-- here re-resolve -- with its stat -- on every single read.
local NONE = setmetatable({}, { __tostring = function() return "NONE" end })
local RESOLVERS = {}

-- Repo.progressFor: sidecar-GATED (a memoised stat answers "has KOReader ever
-- opened this file?" before any DocSettings work happens) and TTL-memoised
-- behind that. One call answers four fields, so all four are filled together.
--
-- `status` is left nil for a never-opened book rather than normalised to
-- "unread" here. Tokens.expanders.status already maps nil to "unread", and
-- doing it twice would mean two places to disagree. Note this DIVERGES from
-- the Status column, which keeps catalogue rows nil so they can render a dash;
-- a token line has no dash, and %status's own contract is four canonical
-- strings with "unread" as the floor.
local function fillProgress(rec)
    local out = { book_pct = NONE, status = NONE,
                  rating = NONE, page_count = NONE }
    local fp = localPath(rec)
    if not fp then return out end
    local R = repo()
    if not R or type(R.progressFor) ~= "function" then return out end
    local ok, pct, status, rating, pages = pcall(R.progressFor, fp)
    if not ok then return out end
    if pct    ~= nil then out.book_pct   = pct    end
    if status ~= nil then out.status     = status end
    if rating ~= nil then out.rating     = rating end
    if pages  ~= nil then out.page_count = pages  end
    return out
end

RESOLVERS.book_pct   = fillProgress
RESOLVERS.status     = fillProgress
RESOLVERS.rating     = fillProgress
RESOLVERS.page_count = fillProgress

-- Repo.fileSizeFor: one lfs stat, memoised for the session and dropped by
-- invalidateWalkCache (a sideload is the only thing that changes a file's
-- size). BIM stores no file size at all, which is why the record never has one.
RESOLVERS.size = function(rec)
    local fp = localPath(rec)
    if not fp then return { size = NONE } end
    local R = repo()
    if not R or type(R.fileSizeFor) ~= "function" then return { size = NONE } end
    local ok, bytes = pcall(R.fileSizeFor, fp)
    if not ok or bytes == nil then return { size = NONE } end
    return { size = bytes }
end

-- File mtime is the "date added" proxy the whole codebase uses -- the walk
-- records it as `mtime` and the custom-source fetchers copy it straight to
-- `date_added` (bookshelf_book_repository.lua:1836, :3969, :5514).
--
-- Stat'ed here rather than through the repository because there is no
-- memoised mtime accessor to call, and inventing a module-level memo with no
-- invalidation hook would be worse than the stat: `size` is dropped by
-- invalidateWalkCache and an mtime cache that was not would go stale on
-- exactly the event -- a replaced file -- that changes it. So it is memoised
-- per wrapper only: one stat per row, and only for a template that names the
-- field. If %added and %size ever both become common, the right move is a
-- Repo.fileStatFor next to fileSizeFor so one stat serves both, sharing the
-- walk-cache invalidation; that is a repository change, not one here.
RESOLVERS.date_added = function(rec)
    local fp = localPath(rec)
    if not fp then return { date_added = NONE } end
    -- The lfs shapes already carry the stat this would repeat.
    local attr = rec.attr
    if type(attr) == "table" and tonumber(attr.modification) then
        return { date_added = tonumber(attr.modification) }
    end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs or not lfs or not lfs.attributes then
        return { date_added = NONE }
    end
    local ok, mtime = pcall(lfs.attributes, fp, "modification")
    if not ok or not tonumber(mtime) then return { date_added = NONE } end
    return { date_added = tonumber(mtime) }
end

-- Repo.enrichStats: the statistics plugin's per-book numbers (time read,
-- pages read, speed and friends). The hero record gets these filled at build
-- time, which is why %book_read_time worked there and answered empty in a
-- list line (the Reddit report that prompted this resolver: the tokens showed
-- in the hero and the line PREVIEW - which demonstrates the template against
-- the selected, enriched book - but never in the actual rows).
--
-- Cost shape matches the others: enrichStats memoises per filepath in the
-- repository, reads its md5 from the sidecar when one exists, and one sqlite
-- lookup fills all six fields together - paid only by templates that name a
-- stats token, once per book per session.
local STATS_FIELDS = {
    "book_read_time_seconds", "book_pages_read", "days_reading_book",
    "pages_per_day", "speed_pph", "book_time_left_minutes",
    -- %avg_page_time (#348): one more field off the same single lookup.
    "avg_page_time_seconds", "book_pct_read",
}

local function fillStats(rec)
    local out = {}
    for _i, k in ipairs(STATS_FIELDS) do out[k] = NONE end
    local fp = localPath(rec)
    if not fp then return out end
    local R = repo()
    if not R or type(R.enrichStats) ~= "function" then return out end
    -- enrichStats mutates the table it is given; hand it a scratch one so a
    -- failed lookup cannot leave half-written fields on the record.
    local scratch = { filepath = fp }
    local ok = pcall(R.enrichStats, scratch)
    if not ok then return out end
    for _i, k in ipairs(STATS_FIELDS) do
        if scratch[k] ~= nil then out[k] = scratch[k] end
    end
    return out
end

for _i, k in ipairs(STATS_FIELDS) do
    RESOLVERS[k] = fillStats
end

-- ── Annotation counts (#348) ───────────────────────────────────────────────
--
-- %highlights, %notes, %bookmarks and %annotations were CONSUMERS with no
-- producer: the expanders existed, copied across from bookends, and every one
-- answered empty forever. Documenting them would have been worse than leaving
-- them out, so they are wired here instead.
--
-- A resolver rather than buildBookMeta, for the reason this whole file exists:
-- the counts come from the DocSettings sidecar, which buildBookMeta
-- deliberately does not read. Putting them there would put a sidecar read back
-- on every shelf rebuild.
--
-- The counting rule is the vendored one, which is KOReader's own, so the shelf
-- and the reader cannot disagree about what counts as a note. Required lazily
-- like every other dependency in this file, which has no top-level requires so
-- it stays loadable bare.
--- TTL-memoised, not memoised for the session. Annotations are the one field
--- here that the USER changes between two looks at the same shelf: highlight
--- something, close the book, come back, and a session-long memo would still
--- be showing the old count. It also caches the negative, so a book whose
--- sidecar appears mid-session would have stayed at nothing.
---
--- The whole table expires at once rather than per entry: it keeps the check
--- to one comparison on the hot path and bounds the table's growth, which is
--- the same shape the shelf's device-state cache uses. This file's own note on
--- date_added is the rule being followed here -- a module-level memo with no
--- invalidation hook is worse than the read it saves.
local ANNOTATION_TTL = 30
local _annotation_memo = {}
local _annotation_memo_expires_at = 0

local function annotationCountsFor(rec)
    local fp = localPath(rec)
    if not fp then return nil end
    local now = os.time()
    if now >= _annotation_memo_expires_at then
        _annotation_memo = {}
        _annotation_memo_expires_at = now + ANNOTATION_TTL
    end
    local memo = _annotation_memo[fp]
    if memo ~= nil then return memo or nil end

    local ok_sem, Semantics = pcall(require, "lib/token_semantics")
    local ok_ds, DocSettings = pcall(require, "docsettings")
    if not (ok_sem and Semantics and ok_ds and DocSettings) then
        _annotation_memo[fp] = false
        return nil
    end
    -- hasSidecarFile FIRST: opening settings for a book that has never been
    -- read would create one, and a shelf render must not write to disk.
    local ok_has, has = pcall(function() return DocSettings:hasSidecarFile(fp) end)
    if not ok_has or not has then
        _annotation_memo[fp] = false
        return nil
    end
    local ok, counts = pcall(function()
        local ds = DocSettings:open(fp)
        return Semantics.annotationCounts(ds and ds:readSetting("annotations"))
    end)
    if not ok or type(counts) ~= "table" then
        _annotation_memo[fp] = false
        return nil
    end
    _annotation_memo[fp] = counts
    return counts
end

-- %annotations is deliberately absent from this list: its expander sums the
-- other three itself, so resolving a total here would be a second source for
-- the same number.
local ANNOTATION_FIELDS = { "highlights", "notes", "bookmarks" }

local function fillAnnotations(rec)
    local out = {}
    local counts = annotationCountsFor(rec)
    for _idx, k in ipairs(ANNOTATION_FIELDS) do
        out[k] = counts and counts[k] or NONE
    end
    return out
end

for _idx, k in ipairs(ANNOTATION_FIELDS) do
    RESOLVERS[k] = fillAnnotations
end

RESOLVERS.last_opened = function(rec)
    local fp = localPath(rec)
    if not fp then return { last_opened = NONE } end
    local map = readHistoryMap()
    local t = map and map[fp]
    -- 0 is ReadHistory's "not in the list" answer in the sort paths, where a
    -- total order is needed. Here it would be a date in 1970, so a book with
    -- no history resolves to nothing instead.
    if not t or t <= 0 then return { last_opened = NONE } end
    return { last_opened = t }
end

-- ── wrap ───────────────────────────────────────────────────────────────────

-- TokenRecord.wrap(record) -> a lazy view of `record`, or `record` unchanged
-- when there is nothing to wrap (nil, a non-table, or a wrapper already).
--
-- Wrapping is idempotent so a caller can wrap defensively at a boundary
-- without stacking proxies -- two layers of __index would double every miss.
function TokenRecord.wrap(record)
    if type(record) ~= "table" then return record end
    if TokenRecord.isWrapper(record) then return record end

    -- Keys whose resolver has already run. Separate from the proxy's own
    -- fields because a resolved NIL cannot be stored there: rawset(t, k, nil)
    -- writes nothing and __index would fire again on the next read.
    local resolved = {}

    local mt = {
        [MARKER] = record,
        __index = function(t, k)
            -- Already resolved, and resolved to nothing. Without this the
            -- resolver -- and its stat -- would run again on every read.
            if resolved[k] then return nil end
            -- Rule 1: the record's own value always wins.
            local own = record[k]
            if own ~= nil then
                rawset(t, k, own)
                return own
            end
            local fill = RESOLVERS[k]
            if not fill then return nil end
            -- One piece of work, every field it answers. A sibling is only
            -- taken where the record has nothing of its own and nothing has
            -- been written to the proxy: the sidecar's page count must not
            -- displace BIM's, which rule 1 would have returned had the
            -- template asked for page_count first.
            for key, v in pairs(fill(record)) do
                if record[key] == nil and not resolved[key]
                        and rawget(t, key) == nil then
                    resolved[key] = true
                    if v ~= NONE then rawset(t, key, v) end
                end
            end
            return rawget(t, k)
        end,
    }
    return setmetatable({}, mt)
end

-- TokenRecord.isWrapper(x) -> true when x came out of wrap().
function TokenRecord.isWrapper(x)
    if type(x) ~= "table" then return false end
    local mt = getmetatable(x)
    return type(mt) == "table" and mt[MARKER] ~= nil
end

-- TokenRecord.unwrap(x) -> the record x wraps, or x itself. Idempotent, so it
-- is safe to call at any boundary that persists a record without first asking
-- whether the thing in hand is a wrapper.
function TokenRecord.unwrap(x)
    if type(x) ~= "table" then return x end
    local mt = getmetatable(x)
    if type(mt) == "table" and mt[MARKER] ~= nil then return mt[MARKER] end
    return x
end

-- The set of fields this adapter can produce that a shelf record does not
-- carry. Exported so a test (and, later, the line editor's token picker) can
-- enumerate them rather than restating the list.
TokenRecord.RESOLVED_FIELDS = {}
for k in pairs(RESOLVERS) do
    TokenRecord.RESOLVED_FIELDS[#TokenRecord.RESOLVED_FIELDS + 1] = k
end
table.sort(TokenRecord.RESOLVED_FIELDS)

return TokenRecord
