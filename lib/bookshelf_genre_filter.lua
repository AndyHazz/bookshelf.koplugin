-- lib/bookshelf_genre_filter.lua
-- Cleans up the genre tags Hardcover supplies: a global blocklist, a tag-alias
-- map (rename / merge / drop) and per-book exclusions. Only Hardcover's list
-- goes through this -- a book's own embedded / Calibre genres are never
-- touched. Matching is case-insensitive, like genres everywhere else.
--
-- Rules live in the settings store:
--   hardcover_genre_blocklist  list of tags never used
--   hardcover_genre_aliases    list of { from =, to = }; to == "" drops the tag
--   hardcover_genre_excluded   { [filepath] = list of tags hidden for that book }
--
-- The pure functions take the rules as arguments (testable without settings);
-- the accessors at the bottom read and write the store.

local GenreFilter = {}

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function keyOf(s) return trim(s):lower() end

-- Set of lowercase keys from a list of strings.
local function keySet(list)
    local set = {}
    for _i, v in ipairs(type(list) == "table" and list or {}) do
        local k = keyOf(v)
        if k ~= "" then set[k] = true end
    end
    return set
end

-- lowercase from -> trimmed target ("" = drop) from a list of { from, to }.
local function aliasMap(aliases)
    local map = {}
    for _i, a in ipairs(type(aliases) == "table" and aliases or {}) do
        if type(a) == "table" then
            local k = keyOf(a.from)
            if k ~= "" then map[k] = trim(a.to) end
        end
    end
    return map
end

-- The filter proper, over precompiled lookups (keySet / aliasMap).
local function filterWith(list, blocked, excluded, alias)
    local out, seen = {}, {}
    for _i, raw in ipairs(type(list) == "table" and list or {}) do
        local rk = keyOf(raw)
        if rk ~= "" and not blocked[rk] then
            local name = trim(raw)
            local to = alias[rk]
            if to ~= nil then name = to end
            local k = keyOf(name)
            if k ~= ""
                and not blocked[k] and not excluded[k] and not excluded[rk]
                and not seen[k] then
                seen[k] = true
                out[#out + 1] = name
            end
        end
    end
    return out
end

-- Pure: apply the rules to a raw tag list. Order of play for each tag:
--   1. blocked as written -> dropped
--   2. alias: renamed (merging into an existing tag), or dropped when its
--      target is empty. One pass; a target is not aliased again.
--   3. blocked or excluded under its final name (or as written) -> dropped
-- Result is de-duplicated (first spelling wins), original order kept. Returns
-- {} when nothing survives.
-- rules = { blocklist = {...}, aliases = {{from=,to=}...}, excluded = {...} }
function GenreFilter.filter(list, rules)
    rules = rules or {}
    return filterWith(list, keySet(rules.blocklist), keySet(rules.excluded),
        aliasMap(rules.aliases))
end

-- Pure: `base` followed by whatever of `extra` it doesn't already have.
function GenreFilter.union(base, extra)
    local out, seen = {}, {}
    for _i, v in ipairs(type(base) == "table" and base or {}) do
        local k = keyOf(v)
        if k ~= "" and not seen[k] then seen[k] = true; out[#out + 1] = v end
    end
    for _i, v in ipairs(type(extra) == "table" and extra or {}) do
        local k = keyOf(v)
        if k ~= "" and not seen[k] then seen[k] = true; out[#out + 1] = v end
    end
    return out
end

-- Pure list helpers shared by the accessors (return a new list, or nil when
-- nothing changed so callers can skip the write).
function GenreFilter.listAdd(list, tag)
    tag = trim(tag)
    if tag == "" then return nil end
    local k = keyOf(tag)
    local out = {}
    for _i, v in ipairs(type(list) == "table" and list or {}) do
        if keyOf(v) == k then return nil end
        out[#out + 1] = v
    end
    out[#out + 1] = tag
    return out
end

function GenreFilter.listRemove(list, tag)
    local k = keyOf(tag)
    local out, hit = {}, false
    for _i, v in ipairs(type(list) == "table" and list or {}) do
        if keyOf(v) == k then hit = true else out[#out + 1] = v end
    end
    return hit and out or nil
end

-- Pure: set / replace an alias (to == "" drops the tag); nil if unchanged.
function GenreFilter.aliasSet(aliases, from, to)
    from, to = trim(from), trim(to)
    if from == "" or keyOf(from) == keyOf(to) then return nil end
    local k = keyOf(from)
    local out, replaced = {}, false
    for _i, a in ipairs(type(aliases) == "table" and aliases or {}) do
        if type(a) == "table" and keyOf(a.from) == k then
            if a.to == to and a.from == from then return nil end
            out[#out + 1] = { from = from, to = to }
            replaced = true
        else
            out[#out + 1] = a
        end
    end
    if not replaced then out[#out + 1] = { from = from, to = to } end
    return out
end

-- Pure: rename a tag as it is SHOWN. Aliases match Hardcover's original names
-- in one pass, so a shown name may be the output of aliases (Sci-Fi ->
-- Science Fiction) and/or an original name. Retarget every alias that
-- produces it, and alias the name itself too for books that carry it as is.
-- to == "" hides it. nil when nothing changes.
function GenreFilter.aliasRename(aliases, shown, to)
    shown, to = trim(shown), trim(to)
    local sk = keyOf(shown)
    if sk == "" or sk == keyOf(to) then return nil end
    local out = {}
    for _i, a in ipairs(type(aliases) == "table" and aliases or {}) do
        if type(a) == "table" and keyOf(a.to) == sk then
            -- An alias that now points at itself is a no-op: drop it.
            if keyOf(a.from) ~= keyOf(to) then out[#out + 1] = { from = a.from, to = to } end
        else
            out[#out + 1] = a
        end
    end
    return GenreFilter.aliasSet(out, shown, to) or out
end

function GenreFilter.aliasRemove(aliases, from)
    local k = keyOf(from)
    local out, hit = {}, false
    for _i, a in ipairs(type(aliases) == "table" and aliases or {}) do
        if type(a) == "table" and keyOf(a.from) == k then hit = true
        else out[#out + 1] = a end
    end
    return hit and out or nil
end

-- ─── settings-backed accessors ───────────────────────────────────────────────

local function S() return require("lib/bookshelf_settings_store") end

-- Shared empty list: the compiled-rules cache below keys on table identity, so
-- "no rules" must hand back the same table every time.
local NO_TAGS = {}

local function readList(key)
    local v = S().read(key)
    return type(v) == "table" and v or NO_TAGS
end

function GenreFilter.blocklist() return readList("hardcover_genre_blocklist") end
function GenreFilter.aliases()   return readList("hardcover_genre_aliases") end

function GenreFilter.excludedFor(filepath)
    local map = S().read("hardcover_genre_excluded")
    return (filepath and type(map) == "table" and type(map[filepath]) == "table")
        and map[filepath] or NO_TAGS
end

function GenreFilter.addBlocked(tag)
    local new = GenreFilter.listAdd(GenreFilter.blocklist(), tag)
    if new then S().save("hardcover_genre_blocklist", new) end
    return new ~= nil
end

function GenreFilter.removeBlocked(tag)
    local new = GenreFilter.listRemove(GenreFilter.blocklist(), tag)
    if new then S().save("hardcover_genre_blocklist", new) end
    return new ~= nil
end

function GenreFilter.setAlias(from, to)
    local new = GenreFilter.aliasSet(GenreFilter.aliases(), from, to)
    if new then S().save("hardcover_genre_aliases", new) end
    return new ~= nil
end

function GenreFilter.renameShown(shown, to)
    local new = GenreFilter.aliasRename(GenreFilter.aliases(), shown, to)
    if new then S().save("hardcover_genre_aliases", new) end
    return new ~= nil
end

function GenreFilter.removeAlias(from)
    local new = GenreFilter.aliasRemove(GenreFilter.aliases(), from)
    if new then S().save("hardcover_genre_aliases", new) end
    return new ~= nil
end

local function saveExcluded(filepath, list)
    local map = S().read("hardcover_genre_excluded")
    if type(map) ~= "table" then map = {} end
    map[filepath] = (#list > 0) and list or nil
    S().save("hardcover_genre_excluded", map)
end

-- One write for many books: updates = { [filepath] = full list (may be empty) }.
function GenreFilter.setExcludedMany(updates)
    local map = S().read("hardcover_genre_excluded")
    if type(map) ~= "table" then map = {} end
    for fp, list in pairs(updates) do
        map[fp] = (#list > 0) and list or nil
    end
    S().save("hardcover_genre_excluded", map)
end

function GenreFilter.excludeForBook(filepath, tag)
    if not filepath then return false end
    local new = GenreFilter.listAdd(GenreFilter.excludedFor(filepath), tag)
    if new then saveExcluded(filepath, new) end
    return new ~= nil
end

function GenreFilter.restoreForBook(filepath, tag)
    if not filepath then return false end
    local new = GenreFilter.listRemove(GenreFilter.excludedFor(filepath), tag)
    if new then saveExcluded(filepath, new) end
    return new ~= nil
end

-- The blocklist and alias lookups, compiled once and reused until the rules
-- change. Saving a rule stores a NEW list table, so table identity is the
-- change signal. forBook runs once per linked book on every library build;
-- rebuilding these sets per book cost ~7us a book even with no rules set.
local _compiled = { bl = false, al = false }
local NO_KEYS = {}

local function compiled()
    local bl, al = GenreFilter.blocklist(), GenreFilter.aliases()
    if _compiled.bl ~= bl or _compiled.al ~= al then
        _compiled = { bl = bl, al = al, blocked = keySet(bl), alias = aliasMap(al) }
    end
    return _compiled
end

-- Filter Hardcover's raw genres for one book using the saved rules.
function GenreFilter.forBook(list, filepath)
    local c = compiled()
    local ex = GenreFilter.excludedFor(filepath)
    return filterWith(list, c.blocked, #ex > 0 and keySet(ex) or NO_KEYS, c.alias)
end

return GenreFilter
