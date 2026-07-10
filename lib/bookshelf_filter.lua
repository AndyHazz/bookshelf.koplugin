-- bookshelf_filter.lua
-- Pure per-chip filter logic: dimension descriptors, active-test, cache
-- signature, predicate compile/matches, and value enumeration. No hard
-- dependency on the repository or KOReader UI at load time so it stays
-- headless-testable; external data enters via injected resolvers.

local _ok = pcall(require, "lib/bookshelf_i18n")
local i18n = package.loaded["lib/bookshelf_i18n"]
local function tr(s) if type(i18n) == "table" and i18n.gettext then return i18n.gettext(s) end; return s end

-- Default collection resolver: read a collection's filepaths from KOReader's
-- ReadCollection. Lazy-required so the module loads headless. Returns a
-- { [filepath]=true } set (empty on any failure).
local function defaultCollectionResolver(name)
    local ok, rc = pcall(require, "readcollection")
    if not ok or not rc or not rc.coll then return {} end
    local coll = rc.coll[name]
    if type(coll) ~= "table" then return {} end
    local set = {}
    for filepath in pairs(coll) do set[filepath] = true end
    return set
end

local Filter = {}

-- Canonical dimension order. `kind` drives the editor: "multi" = multi-select
-- value list; "folder" = include/exclude folder browser. Labels resolve at
-- call time so they follow the active locale (see TabModel.DEFAULTS).
function Filter.dimensions()
    return {
        { key = "statuses",    label = tr("Status"),     kind = "multi"  },
        { key = "genres",      label = tr("Genre"),      kind = "multi"  },
        { key = "langs",       label = tr("Language"),   kind = "multi"  },
        { key = "formats",     label = tr("Format"),     kind = "multi"  },
        { key = "ratings",     label = tr("Rating"),     kind = "multi"  },
        { key = "collections", label = tr("Collection"), kind = "multi"  },
        { key = "series_membership", label = tr("Series"), kind = "choice" },
        { key = "folders",     label = tr("Folders"),    kind = "folder" },
    }
end

-- The single-choice "Series" dimension: standalone books vs books in a series.
-- Stored as a plain string (like folders is an odd-shaped dimension); "both"
-- or absent means no effect. Offered as a radio in the filter editor.
function Filter.seriesValues()
    return {
        { value = "both",       label = tr("Standalone and books in series") },
        { value = "standalone", label = tr("Only standalone books") },
        { value = "in_series",  label = tr("Only books in series") },
    }
end

-- true when the series dimension is narrowing the shelf (not "both"/absent).
local function seriesActive(filter)
    local v = filter and filter.series_membership
    return v == "standalone" or v == "in_series"
end

local function anyKey(t) if type(t) ~= "table" then return false end; for _k in pairs(t) do return true end; return false end

-- The "multi" dimension storage keys, in signature order.
local MULTI_KEYS = { "statuses", "genres", "langs", "formats", "ratings", "collections" }

function Filter.isActive(filter)
    if type(filter) ~= "table" then return false end
    for _i, k in ipairs(MULTI_KEYS) do
        if anyKey(filter[k]) then return true end
    end
    local f = filter.folders
    if f and (anyKey(f.include) or anyKey(f.exclude)) then return true end
    if seriesActive(filter) then return true end
    return false
end

-- Stable, order-independent signature. Each active dimension contributes a
-- sorted, comma-joined fragment; absent dimensions contribute nothing, so the
-- empty filter yields "".
local function sortedKeys(t)
    local out = {}
    if type(t) == "table" then for k in pairs(t) do out[#out + 1] = tostring(k) end end
    table.sort(out)
    return out
end

function Filter.signature(filter)
    if type(filter) ~= "table" then return "" end
    local parts = {}
    for _i, k in ipairs(MULTI_KEYS) do
        local keys = sortedKeys(filter[k])
        if #keys > 0 then parts[#parts + 1] = k .. ":" .. table.concat(keys, ",") end
    end
    local f = filter.folders
    if f then
        local inc = sortedKeys(f.include)
        local exc = sortedKeys(f.exclude)
        if #inc > 0 then parts[#parts + 1] = "fi:" .. table.concat(inc, ",") end
        if #exc > 0 then parts[#parts + 1] = "fe:" .. table.concat(exc, ",") end
    end
    if seriesActive(filter) then parts[#parts + 1] = "sm:" .. filter.series_membership end
    return table.concat(parts, "|")
end

-- Build a lookup set from a filter sub-table (already a key->true map); returns
-- nil when the dimension is unconstrained so matches() can skip it cheaply.
local function setOrNil(t)
    if anyKey(t) then return t end
    return nil
end

-- Normalise a folder path to no trailing slash (root "/" stays "/").
local function normFolder(p)
    if p == "/" then return "/" end
    return (tostring(p):gsub("/+$", ""))
end

-- true if filepath is the folder itself or sits beneath it.
local function underFolder(filepath, folder)
    if folder == "/" then return true end
    if filepath == folder then return true end
    return filepath:sub(1, #folder + 1) == (folder .. "/")
end

-- compile(filter, opts): precompute per-dimension lookups once per query.
-- opts.collection_resolver(name) -> { [filepath]=true } is used in Task 4.
-- opts.lang_canonical(code_or_label) -> key  normalises picker labels to the
--   same key space as raw book.lang values (default: identity).
-- opts.genre_normalize(tag) -> key  normalises picker labels to the same key
--   space as raw book.genres entries (default: identity).
function Filter.compile(filter, opts)
    filter = (type(filter) == "table") and filter or {}
    local c = {
        statuses = setOrNil(filter.statuses),
        formats  = setOrNil(filter.formats),
        ratings  = setOrNil(filter.ratings),
    }
    if anyKey(filter.langs) then
        local fn = (opts and opts.lang_canonical) or function(v) return v end
        local set = {}
        for k in pairs(filter.langs) do local kk = fn(k); if kk ~= nil then set[kk] = true end end
        c.langs = set
        c._lang_canonical = fn
    end
    if anyKey(filter.genres) then
        local fn = (opts and opts.genre_normalize) or function(v) return v end
        local set = {}
        for k in pairs(filter.genres) do local kk = fn(k); if kk ~= nil then set[kk] = true end end
        c.genres = set
        c._genre_normalize = fn
    end
    if anyKey(filter.collections) then
        local resolve = (opts and opts.collection_resolver) or defaultCollectionResolver
        local union = {}
        for name in pairs(filter.collections) do
            local set = resolve(name) or {}
            for fp in pairs(set) do union[fp] = true end
        end
        c.collection_files = union
    end
    local function prefixList(t)
        local out = {}
        if type(t) == "table" then for p in pairs(t) do out[#out + 1] = normFolder(p) end end
        return (#out > 0) and out or nil
    end
    local folders = filter.folders
    if folders then
        c.folder_includes = prefixList(folders.include)
        c.folder_excludes = prefixList(folders.exclude)
    end
    if seriesActive(filter) then c.series_membership = filter.series_membership end
    return c
end

function Filter.matches(book, c)
    if not c then return true end
    if c.statuses then
        local s = book._status or "unread"
        if not c.statuses[s] then return false end
    end
    if c.ratings then
        local r = book.rating
        local rk = (r and r > 0) and tostring(math.floor(r)) or "unrated"
        if not c.ratings[rk] then return false end
    end
    if c.genres then
        local fn = c._genre_normalize or function(v) return v end
        local g = book.genres
        local hit = false
        if type(g) == "table" then
            for i = 1, #g do if c.genres[fn(g[i])] then hit = true; break end end
        end
        if not hit then return false end
    end
    if c.langs then
        local fn = c._lang_canonical or function(v) return v end
        local L = book.lang and fn(book.lang) or nil
        if not (L and c.langs[L]) then return false end
    end
    if c.formats then
        if not (book.format and c.formats[book.format]) then return false end
    end
    if c.collection_files then
        if not (book.filepath and c.collection_files[book.filepath]) then return false end
    end
    if c.folder_excludes then
        local fp = book.filepath or ""
        for i = 1, #c.folder_excludes do
            if underFolder(fp, c.folder_excludes[i]) then return false end
        end
    end
    if c.folder_includes then
        local fp = book.filepath or ""
        local hit = false
        for i = 1, #c.folder_includes do
            if underFolder(fp, c.folder_includes[i]) then hit = true; break end
        end
        if not hit then return false end
    end
    if c.series_membership then
        -- Standalones have no series_name (buildBookMeta normalises "" -> nil).
        local has_series = book.series_name ~= nil and book.series_name ~= ""
        if c.series_membership == "standalone" and has_series then return false end
        if c.series_membership == "in_series" and not has_series then return false end
    end
    return true
end

-- Single-status labels for compact summaries.
local function statusLabel(v)
    local labels = {
        unread   = tr("Unread"),  reading  = tr("Reading"),
        on_hold  = tr("On hold"), finished = tr("Finished"),
    }
    return labels[v] or v
end

-- Single-rating label for compact summaries. Mirrors ratingValues() so a
-- single-selection ratings filter shows the friendly label, not the raw key.
local function ratingLabel(v)
    for _i, rv in ipairs(Filter.ratingValues()) do
        if rv.value == v then return rv.label end
    end
    return tostring(v)
end

function Filter.statusValues()
    return {
        { value = "unread",   label = tr("Unread")   },
        { value = "reading",  label = tr("Reading")  },
        { value = "on_hold",  label = tr("On hold")  },
        { value = "finished", label = tr("Finished") },
    }
end

function Filter.ratingValues()
    return {
        { value = "5",       label = tr("5 stars") },
        { value = "4",       label = tr("4 stars") },
        { value = "3",       label = tr("3 stars") },
        { value = "2",       label = tr("2 stars") },
        { value = "1",       label = tr("1 star")  },
        { value = "unrated", label = tr("Unrated") },
    }
end

local function countKeys(t)
    local n = 0
    if type(t) == "table" then for _k in pairs(t) do n = n + 1 end end
    return n
end

-- dimSummary(filter, dim_key, max_chars): the value text shown on a filter row.
-- "any" when empty; otherwise the selected values, sorted and comma-joined. When
-- max_chars is given and the list is longer, pack whole values up to that budget
-- and append an ellipsis ("Comedy, Fantasy…"). The caller (editor) sizes the
-- budget per row from the row width minus the label, so each row fills close to
-- the edge before truncating. No budget = the full list (used in tests).
function Filter.dimSummary(filter, dim_key, max_chars)
    filter = (type(filter) == "table") and filter or {}
    if dim_key == "folders" then
        local f = filter.folders or {}
        local inc, exc = countKeys(f.include), countKeys(f.exclude)
        if inc == 0 and exc == 0 then return tr("any") end
        return string.format(tr("%d in, %d out"), inc, exc)
    end
    if dim_key == "series_membership" then
        -- An explicitly-chosen "both" shows its own label rather than "any":
        -- on the Series source it's load-bearing (mixes standalone books in
        -- with the stacks, #160), and on book chips the label still reads as
        -- an accurate description of "no narrowing".
        if filter.series_membership == nil then return tr("any") end
        for _i, sv in ipairs(Filter.seriesValues()) do
            if sv.value == filter.series_membership then return sv.label end
        end
        return tostring(filter.series_membership)
    end
    local set = filter[dim_key]
    local n = countKeys(set)
    if n == 0 then return tr("any") end
    -- Build sorted display labels for the selected values. For status/rating
    -- the stored key is an internal token, so map it to a friendly label;
    -- every other dimension stores the display value as the key already.
    local labels = {}
    for k in pairs(set) do
        local lbl
        if dim_key == "statuses" then lbl = statusLabel(k)
        elseif dim_key == "ratings" then lbl = ratingLabel(k)
        else lbl = tostring(k) end
        labels[#labels + 1] = lbl
    end
    table.sort(labels)
    local joined = table.concat(labels, ", ")
    if not max_chars or #joined <= max_chars then return joined end
    -- Overflow: pack whole values until the next would exceed the budget, then
    -- ellipsis. Always show at least the first value. Cutting on value
    -- boundaries (not mid-string) keeps it clean and avoids splitting a UTF-8
    -- character mid-byte.
    local parts, used = {}, 0
    for i = 1, #labels do
        local seg = (i == 1) and labels[i] or (", " .. labels[i])
        if #parts >= 1 and used + #seg > max_chars then break end
        parts[#parts + 1] = labels[i]
        used = used + #seg
    end
    local out = table.concat(parts, ", ")
    if #parts < #labels then out = out .. "\xE2\x80\xA6" end  -- omitted some
    return out
end

function Filter.summary(filter)
    if not Filter.isActive(filter) then return tr("none") end
    local n = 0
    for _i, k in ipairs(MULTI_KEYS) do if anyKey(filter[k]) then n = n + 1 end end
    local f = filter.folders
    if f and (anyKey(f.include) or anyKey(f.exclude)) then n = n + 1 end
    if seriesActive(filter) then n = n + 1 end
    return string.format(tr("%d active"), n)
end

return Filter
