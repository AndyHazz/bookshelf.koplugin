--- calibre_metadata.lua
---
--- VENDORED FILE. Byte-identical copies live at:
---   bookends.koplugin/calibre_metadata.lua
---   bookshelf.koplugin/lib/calibre_metadata.lua
--- Never edit one without the other. tools/check_token_parity.sh fails on drift.
---
--- Reads Calibre's metadata.calibre and exposes each book's fields by absolute
--- filepath. Extracted from bookshelf's book repository so bookends can share
--- it rather than reimplement it, which matters for one specific reason: both
--- plugins write the calibre.bookshelf.json harvest sidecar, and bookends needs
--- a strict SUBSET of the fields (it has no use for author_sort or the extra
--- series columns). A subset writer would silently clobber bookshelf's richer
--- harvest and break author-sort ordering for anyone running both. Identical
--- code writes an identical file, so either plugin can write it safely.
---
--- Keyed by absolute filepath, so a caller with one open document (bookends)
--- pays no library-scan cost.
---
--- The gate is a PARAMETER, not a settings read: see entryFor below.

-- Lazily and defensively required, like lfs and rapidjson below: it keeps this
-- module loadable under a standalone `lua`, which is what makes it testable
-- outside KOReader at all. Only used for one debug line.
local function _dbg(msg)
    local ok, logger = pcall(require, "logger")
    if ok and logger and logger.dbg then logger.dbg(msg) end
end

-- Local copy: the repository this was extracted from still needs its own for
-- directory walking, so this is a deliberate duplicate of four trivial lines
-- rather than a new cross-module dependency.
local function _joinPath(parent, child)
    if parent == "/" then return "/" .. child end
    return parent .. "/" .. child
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

-- ── calibre.bookshelf.json: our own sidecar KOReader will not touch ─────────
--
-- KOReader's calibre plugin rewrites metadata.calibre after a wireless sync
-- from load_calibre's whitelisted fields, permanently deleting everything
-- else -- measured against the real binding, the fields WE read that do not
-- survive are author_sort, languages, comments and user_metadata. So when a
-- calibre-written file passes through here, the two fields with NO other
-- source anywhere -- author_sort (the old wipe, NiLuJe/lua-rapidjson#1 still
-- dormant) and the custom series columns (issue 299) -- are HARVESTED into a
-- sidecar of our own, beside metadata.calibre, keyed by lpath. When a
-- KOReader-rewritten file comes through instead, the harvest is merged back
-- over it. languages and comments are deliberately not harvested: both fall
-- back to the book's own embedded metadata through BIM, so the sidecar stays
-- a few KB instead of duplicating every description in the library.
--
-- WHICH KIND OF FILE is decided by evidence, not mtime: a calibre-written
-- file carries user_metadata or author_sort keys on its entries (calibre
-- writes them for every book once the columns exist); a file where NO entry
-- has either has been through KOReader's plugin. Trusting a calibre-written
-- file wholly is what lets a user genuinely clearing a column see it clear.
local HARVEST_NAME = "calibre.bookshelf.json"

local function _harvestPath(meta_path)
    return meta_path:gsub("/[^/]+$", "") .. "/" .. HARVEST_NAME
end

local function _loadHarvest(meta_path)
    local ok_json, rapidjson = pcall(require, "rapidjson")
    if not ok_json then return nil end
    local ok, data = pcall(rapidjson.load, _harvestPath(meta_path))
    if ok and type(data) == "table" and type(data.books) == "table" then
        return data.books
    end
    return nil
end

local function _sameHarvestEntry(a, b)
    if (a and a.author_sort) ~= (b and b.author_sort) then return false end
    local ea, eb = (a and a.extra_series) or {}, (b and b.extra_series) or {}
    if #ea ~= #eb then return false end
    for i = 1, #ea do
        if ea[i].name ~= eb[i].name or ea[i].num ~= eb[i].num then
            return false
        end
    end
    local fa, fb = (a and a.calibre) or {}, (b and b.calibre) or {}
    for k, v in pairs(fa) do if fb[k] ~= v then return false end end
    for k in pairs(fb) do if fa[k] == nil then return false end end
    return true
end

local function _saveHarvest(meta_path, books, previous)
    -- Only on change: this runs inside the metadata reload, and a JSON write
    -- per reload would be flash wear for nothing.
    local changed = false
    if not previous then
        changed = next(books) ~= nil
    else
        for k, v in pairs(books) do
            if not _sameHarvestEntry(v, previous[k]) then changed = true break end
        end
        if not changed then
            for k in pairs(previous) do
                if books[k] == nil then changed = true break end
            end
        end
    end
    if not changed then return end
    local ok_json, rapidjson = pcall(require, "rapidjson")
    if not ok_json or type(rapidjson.dump) ~= "function" then return end
    pcall(rapidjson.dump, { version = 1, books = books },
          _harvestPath(meta_path), { pretty = true })
    _dbg("[bookshelf] calibre harvest written: " .. _harvestPath(meta_path))
end

local _calibre_state = {
    last_check = 0,
    file_path  = nil,
    file_mtime = 0,
    map        = nil,
}

local function _calibreMetadataFor(filepath, enabled)
    if not filepath then return nil end
    -- The gate is the CALLER's, not a settings read, because the two plugins
    -- gate differently and both are right. Bookshelf hides this behind a beta
    -- setting because its calibre data overrides title, authors, series,
    -- language and description across the whole library. Bookends consumes it
    -- ONLY through %calibre{...}, and its needs("calibre") check already means
    -- this file is never probed unless a template names the token - so the
    -- token IS the gate there, and a second switch would earn nothing but
    -- another thing to discover, document and translate.
    -- Default OFF still holds for non-Calibre users: no probe, no JSON parse.
    if not enabled then return nil end
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
    -- WHICH PARSER, and why it matters (issue 299): rapidjson.load_calibre is
    -- KOReader's slimming parser -- fast and memory-light because it KEEPS
    -- ONLY the fields its calibre plugin needs, and user_metadata (where a
    -- Calibre custom series column lives) is not one of them. Verified
    -- empirically: load_calibre drops it, plain load keeps it. So secondary
    -- series need the plain parse -- but a plain parse builds the WHOLE file
    -- as Lua tables, and a big library's metadata.calibre (long comments, one
    -- entry per book) can be tens of MB, which is a real transient spike on a
    -- 256MB Kindle. The gate: plain-parse only under the size cap, slim each
    -- entry immediately to the fields this file actually reads, and above the
    -- cap fall back to load_calibre -- exactly today's behaviour, minus
    -- secondary series.
    --
    -- KNOWN FRAGILITY, the author_sort wipe all over again: KOReader's OWN
    -- calibre plugin loads this file through load_calibre and its
    -- saveBookList() dumps those slimmed tables straight back -- so the first
    -- WIRELESS calibre sync rewrites metadata.calibre without user_metadata,
    -- permanently, and secondary series silently degrade to the primary until
    -- a USB sync regenerates the file. Reading here cannot defend against a
    -- writer elsewhere; the durable fix is upstream, adding user_metadata to
    -- load_calibre's whitelist beside author_sort (NiLuJe/lua-rapidjson#1,
    -- dormant). USB-sync libraries -- where calibre writes the file and the
    -- wireless plugin never does -- are unaffected.
    local CALIBRE_FULL_PARSE_MAX = 8 * 1024 * 1024
    local data, full
    if (attr and attr.size or 0) <= CALIBRE_FULL_PARSE_MAX then
        local ok, d = pcall(rapidjson.load, meta_path)
        if ok and type(d) == "table" then data, full = d, true end
    end
    if not data and rapidjson.load_calibre then
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
    -- Slim a full-parse entry down to what the readers of this map use
    -- (grep cb%. for the list), plus extra_series extracted from any Calibre
    -- custom column of datatype "series" -- reduced here to bare name/number
    -- pairs so the retained map never holds the user_metadata blobs.
    local function slim(book)
        local out = {
            lpath        = book.lpath,
            title        = book.title,
            authors      = book.authors,
            author_sort  = book.author_sort,
            series       = book.series,
            series_index = book.series_index,
            tags         = book.tags,
            keywords     = book.keywords,
            languages    = book.languages,
            comments     = book.comments,
        }
        if type(book.user_metadata) == "table" then
            local extras
            for _col, def in pairs(book.user_metadata) do
                if type(def) == "table" and def.datatype == "series"
                        and type(def["#value#"]) == "string"
                        and def["#value#"] ~= "" then
                    extras = extras or {}
                    extras[#extras + 1] = {
                        name = def["#value#"],
                        num  = type(def["#extra#"]) == "number"
                               and tostring(def["#extra#"]) or nil,
                    }
                end
            end
            out.extra_series = extras
        end
        -- Arbitrary calibre fields for the %calibre{name} token: a flat map
        -- of display-ready STRINGS keyed by lowercased lookup name without
        -- the leading '#', built here so the retained map holds a few short
        -- strings per book and never the user_metadata blobs. Dates reduce
        -- to the year (the driving request is publication year); rating
        -- halves from the file's 0-10 to calibre's star scale; columns of
        -- datatype "comments" are skipped outright -- long-form HTML is the
        -- wrong shape for a one-line token and a real memory cost when
        -- multiplied by every book in the library.
        local fields
        local function put(key, value)
            if value == nil or value == "" then return end
            fields = fields or {}
            fields[key] = value
        end
        local function yearOf(v)
            local y = type(v) == "string" and v:match("^(%d%d%d%d)")
            -- calibre writes 0100/0101-01-01 for "no date set".
            if y and y:sub(1, 1) ~= "0" then return y end
        end
        local function displayValue(v, datatype)
            if datatype == "comments" then return nil end
            if datatype == "datetime" then return yearOf(v) end
            local t = type(v)
            if t == "string" then return v ~= "" and v or nil end
            if t == "number" then return string.format("%g", v) end
            -- false maps to nil, not "no": it keeps [if:calibre{col}]
            -- truthiness honest, since any non-empty string reads truthy.
            if t == "boolean" then return v and "yes" or nil end
            if t == "table" then
                local parts = {}
                for _j, item in ipairs(v) do
                    if type(item) == "string" and item ~= "" then
                        parts[#parts + 1] = item
                    end
                end
                if #parts > 0 then return table.concat(parts, ", ") end
            end
        end
        put("pubdate", yearOf(book.pubdate))
        put("publisher", displayValue(book.publisher))
        if type(book.rating) == "number" and book.rating > 0 then
            put("rating", string.format("%g", book.rating / 2))
        end
        if type(book.user_metadata) == "table" then
            for col, def in pairs(book.user_metadata) do
                if type(def) == "table" then
                    local key = tostring(col):gsub("^#", ""):lower()
                    if fields == nil or fields[key] == nil then
                        put(key, displayValue(def["#value#"], def.datatype))
                    end
                end
            end
        end
        out.calibre = fields
        return out
    end
    local lib_root = meta_path:gsub("/[^/]+$", "")
    local map = {}
    local calibre_written = false
    for _i, book in ipairs(data) do
        if type(book) == "table" and book.lpath then
            if book.user_metadata ~= nil or book.author_sort ~= nil then
                calibre_written = true
            end
            map[lib_root .. "/" .. book.lpath] = full and slim(book) or book
        end
    end
    if full and calibre_written then
        -- A calibre-written file: harvest everything with no other source.
        local harvest = {}
        for _i, book in ipairs(data) do
            if type(book) == "table" and book.lpath then
                local entry = map[lib_root .. "/" .. book.lpath]
                if entry and (entry.author_sort or entry.extra_series
                              or entry.calibre) then
                    harvest[book.lpath] = {
                        author_sort  = entry.author_sort,
                        extra_series = entry.extra_series,
                        calibre      = entry.calibre,
                    }
                end
            end
        end
        _saveHarvest(meta_path, harvest, _loadHarvest(meta_path))
    elseif not calibre_written then
        -- KOReader's plugin has rewritten the file: merge what was harvested
        -- back over the survivors, by lpath.
        local harvest = _loadHarvest(meta_path)
        if harvest then
            for lpath, saved in pairs(harvest) do
                local entry = map[lib_root .. "/" .. lpath]
                if entry then
                    if entry.author_sort == nil then
                        entry.author_sort = saved.author_sort
                    end
                    if entry.extra_series == nil then
                        entry.extra_series = saved.extra_series
                    end
                    -- Per-KEY merge, not all-or-nothing. entry.calibre is
                    -- rarely nil after a rewrite: the three standard fields
                    -- (pubdate, publisher, rating) are built from TOP-LEVEL
                    -- keys that SURVIVE the strip, so a whole-table nil check
                    -- saw a non-empty table and skipped the restore, silently
                    -- dropping every harvested CUSTOM column on any book with
                    -- a publisher, pubdate or rating - which is most books.
                    -- Only the sparse ones ever recovered. Found by testing
                    -- against a genuine calibre-written file on device; the
                    -- pure-Lua suite pins it now.
                    -- Keys present in the file still win, so a column the user
                    -- genuinely cleared in Calibre stays cleared.
                    if saved.calibre then
                        entry.calibre = entry.calibre or {}
                        for k, v in pairs(saved.calibre) do
                            if entry.calibre[k] == nil then
                                entry.calibre[k] = v
                            end
                        end
                    end
                end
            end
        end
    end
    _calibre_state.file_path  = meta_path
    _calibre_state.file_mtime = mtime
    _calibre_state.map        = map
    return map[filepath]
end

local CalibreMeta = {}

CalibreMeta.HARVEST_NAME = HARVEST_NAME

--- The slimmed per-book entry, or nil.
--- `enabled` is the caller's gate; falsy returns nil without touching the
--- filesystem. See the module header for why it is a parameter.
function CalibreMeta.entryFor(filepath, enabled)
    return _calibreMetadataFor(filepath, enabled)
end

--- Just the flat map of calibre field name to display string, which is all
--- %calibre{...} needs. Keys are lowercased and carry no leading '#'.
function CalibreMeta.fieldsFor(filepath, enabled)
    local entry = _calibreMetadataFor(filepath, enabled)
    return entry and entry.calibre or nil
end

--- Force the next call to reparse. Called when the library is refreshed.
function CalibreMeta.invalidate()
    _calibre_state.last_check = 0
    _calibre_state.file_mtime = -1
end

return CalibreMeta
