--[[
bookshelf_sources.lua -- shelf sources that come from somewhere other than the
walked library: the Kindle's own catalogue, the Kobo store's library, and any
source another plugin registers (issue 452).

Bookshelf used to know each of these by name: `kind == "kindle"` in the
repository, the widget and the shelf editor, one copy per question asked of it.
A plugin that wanted a shelf of its own had to replace Bookshelf's functions at
runtime. This is the one place those questions are asked instead, so a source
is a table of answers registered once, and the rest of Bookshelf asks the
registry.

A source is registered under the id its shelves store as `source.kind`:

    local Sources = require("lib/bookshelf_sources")   -- inside Bookshelf
    ui.bookshelf:registerSource("komga", spec)          -- from another plugin

A source works in one of two ways, and says which by giving `list` or `fetch`:

  list mode   the source hands over every book at once; Bookshelf filters,
              sorts and pages them with the shelf's own settings. The Kindle
              and Kobo libraries work like this.
  fetch mode  the source pages and orders itself, a server's catalogue say,
              and may have folders to drill into. Bookshelf shows what it is
              given, in that order, and leaves out its own sort and filter rows
              in the shelf editor.

Spec fields (label, available, and one of list / fetch are required):

    api          the SOURCE_API version the spec was written against (number)
    label        function() -> string, the name in the shelf source picker
    available    function() -> bool; false hides the source everywhere, so a
                 source whose plugin or device is missing simply is not there
    list         function(source) -> { record, ... }, every book the shelf
                 holds. `source` is the shelf's own source table, so one spec
                 can serve several shelves.
    fetch        function(source, drill, offset, limit) -> { record, ... }, total
                 One page. `drill` is nil at the shelf's top level, or the entry
                 open_folder returned for the folder the reader is in. `total`
                 is the number of items at this level, or nil when the source
                 does not know yet. Called on every shelf render, so it must
                 answer from what the source already holds: fetch in the
                 background and call ui.bookshelf:sourceChanged(id) when more
                 has arrived.
    open_folder  function(record) -> drill entry, for a record with is_folder.
                 Any table; its `label` names the breadcrumb. Default: the
                 record's own `drill` field.
    refresh      function(source, drill, done), the reader swiped down to
                 refresh. Call done() when there is something new to show.
    remote_prefix a filepath prefix ("komga://") marking records that are not
                 files on the device: Bookshelf then never looks for a sidecar,
                 a KOReader cover or statistics for them.
    info         function(record, ctx), long-press on a remote record. Default:
                 a short message with the title and author.
    pick         function(draft, done), the source's row in the shelf source
                 picker was tapped. Fill draft.source (kind is already set; add
                 whatever identifies what to show) and call done(), or
                 done(false) to cancel. Without it the row sets
                 draft.source = { kind = id }.
    picker       show a row in the shelf source picker (default true)
    library      count these books as part of the library for search and the
                 whole-library tallies, once a shelf uses the source (default
                 false: a source has to opt in)
    sort_default { {key=, reverse=}, ... } for a new shelf of this source
    new_shelf    function(draft), a last word on a new shelf's defaults
    cover        function(record) -> bb, w, h for the visible page only, when a
                 record has no cover file Bookshelf can read itself
    owns         function(book) -> bool, whether a book (possibly rehydrated,
                 so without any field the list added) belongs to this source
    open         function(book, ctx) -> true when the source handled the open,
                 or a local file path for Bookshelf to open. ctx.open(path)
                 opens a file later (after a download, say); ctx.widget is the
                 shelf. Without it, or when it returns false, Bookshelf opens
                 book.filepath itself.
    invalidate   function(filepath or nil), a file changed: drop any cache

Records are ordinary book tables: filepath, title, authors, series, cover_image_path
and so on, the same fields a walked book carries. Bookshelf stamps each listed
record with `source_kind` so it can find its way back. In fetch mode a record
with `is_folder = true` is a folder: it draws as a navigation tile, and tapping
it drills in (see open_folder); it may carry `count` and `cover_image_path`.

A spec is checked when it is registered and every call into it is pcall'd, so a
broken source degrades to an empty shelf rather than taking Bookshelf down.
]]

local M = {}

-- The contract version. A spec written for a newer contract than this is
-- refused, so a plugin can feature-detect with `Sources.API >= n` and fall back.
M.API = 1

local _order = {}   -- registration order, so the picker is stable
local _specs = {}   -- id -> spec

-- The kinds Bookshelf defines itself. A plugin cannot take one of these over.
local RESERVED = {}
for k in ("all library recent latest favorites folder folder_flat series authors "
          .. "genres tags formats ratings languages statuses collection tag genre "
          .. "author single_series status format rating language opds search"):gmatch("%S+") do
    RESERVED[k] = true
end

local function logWarn(...)
    local ok, logger = pcall(require, "logger")
    if ok and logger and logger.warn then logger.warn("[bookshelf] source:", ...) end
end

-- register(id, spec) -> true, or false and the reason.
function M.register(id, spec)
    if type(id) ~= "string" or not id:match("^[%w_%-]+$") then
        return false, "id must be a short word"
    end
    if RESERVED[id] then return false, "id is taken by a built-in source" end
    if type(spec) ~= "table" then return false, "spec must be a table" end
    if spec.api ~= nil and (type(spec.api) ~= "number" or spec.api > M.API) then
        return false, "spec needs source API " .. tostring(spec.api)
                      .. ", this Bookshelf has " .. M.API
    end
    for _i, f in ipairs({ "label", "available" }) do
        if type(spec[f]) ~= "function" then return false, f .. " must be a function" end
    end
    local has_list, has_fetch = type(spec.list) == "function", type(spec.fetch) == "function"
    if has_list == has_fetch then return false, "give exactly one of list or fetch" end
    for _i, f in ipairs({ "cover", "owns", "open", "invalidate", "new_shelf",
                          "open_folder", "refresh", "info", "pick" }) do
        if spec[f] ~= nil and type(spec[f]) ~= "function" then
            return false, f .. " must be a function"
        end
    end
    if spec.remote_prefix ~= nil and (type(spec.remote_prefix) ~= "string"
            or not spec.remote_prefix:match("^%a[%w+.-]*://")) then
        return false, "remote_prefix must look like \"name://\""
    end
    if not _specs[id] then _order[#_order + 1] = id end
    _specs[id] = spec
    M._prefixes = nil
    return true
end

function M.unregister(id)
    if not _specs[id] then return end
    _specs[id] = nil
    M._prefixes = nil
    for i, k in ipairs(_order) do
        if k == id then table.remove(_order, i) break end
    end
end

-- get(id) -> spec or nil. Registered, whether or not available right now.
function M.get(id)
    return type(id) == "string" and _specs[id] or nil
end

-- ids() -> registered ids in registration order.
function M.ids()
    local out = {}
    for i, k in ipairs(_order) do out[i] = k end
    return out
end

-- call(spec, name, ...) -> ok, results... A spec's function, pcall'd; a throw
-- is logged once per call site and reads as a failure.
-- (LuaJIT is Lua 5.1: no table.pack, and unpack is a global.)
local unpack = table.unpack or unpack
local function call(spec, name, ...)
    local f = spec and spec[name]
    if type(f) ~= "function" then return false end
    local res = { n = 0 }
    local function collect(...) res.n = select("#", ...); for i = 1, res.n do res[i] = (select(i, ...)) end end
    collect(pcall(f, ...))
    if not res[1] then logWarn(name, "failed:", tostring(res[2])) return false end
    return true, unpack(res, 2, res.n)
end
M.call = call

-- isAvailable(id) -> bool
function M.isAvailable(id)
    local spec = M.get(id)
    if not spec then return false end
    local ok, avail = call(spec, "available")
    return ok and avail and true or false
end

-- label(id) -> string or nil
function M.label(id)
    local spec = M.get(id)
    local ok, s = call(spec, "label")
    return (ok and type(s) == "string" and s ~= "") and s or nil
end

-- list(id, source) -> records (a fresh table each time) or nil when the source
-- is missing, unavailable or failed. Each record is stamped with source_kind.
function M.list(id, source)
    local spec = M.get(id)
    if not spec or not M.isAvailable(id) then return nil end
    if not spec.list then return nil end
    local ok, books = call(spec, "list", source or { kind = id })
    if not ok or type(books) ~= "table" then return nil end
    local out = {}
    for i = 1, #books do
        local b = books[i]
        if type(b) == "table" then
            if b.source_kind == nil then b.source_kind = id end
            out[#out + 1] = b
        end
    end
    return out
end

-- isPaged(id) -> true for a fetch-mode source (it orders and pages itself).
function M.isPaged(id)
    local spec = M.get(id)
    return spec ~= nil and type(spec.fetch) == "function"
end

-- fetch(id, source, drill, offset, limit) -> records, total; or nil when the
-- source is missing, unavailable, list-mode or failed. Records are stamped with
-- source_kind, and a folder record is given what a navigation tile needs.
function M.fetch(id, source, drill, offset, limit)
    local spec = M.get(id)
    if not (spec and spec.fetch) or not M.isAvailable(id) then return nil end
    local ok, items, total = call(spec, "fetch", source or { kind = id }, drill, offset or 0, limit)
    if not ok or type(items) ~= "table" then return nil end
    local out = {}
    for i = 1, #items do
        local r = items[i]
        if type(r) == "table" then
            if r.source_kind == nil then r.source_kind = id end
            if r.is_folder then
                -- Drawn by the same tile every view already knows for a
                -- catalogue's subfolder, and routed back here on a tap.
                r.kind, r.is_opds_nav, r.source_nav = "opds_nav", true, true
                r.label = r.label or r.title
                r.title = r.title or r.label
                r.display_title = r.display_title or r.title
                if type(r.filepath) ~= "string" or r.filepath == "" then
                    r.filepath = id .. "://nav/" .. tostring(r.id or (offset or 0) + i)
                end
            end
            out[#out + 1] = r
        end
    end
    return out, (type(total) == "number") and total or nil
end

-- drillFor(record) -> the drill entry for a folder record, or nil.
function M.drillFor(record)
    local id = type(record) == "table" and record.source_kind
    local spec = M.get(id)
    if not spec then return nil end
    if spec.open_folder then
        local ok, entry = call(spec, "open_folder", record)
        if ok and type(entry) == "table" then return entry end
        return nil
    end
    return type(record.drill) == "table" and record.drill or nil
end

-- isRemotePath(fp) -> true for a path that is not a file on the device: an
-- OPDS entry, or a record under a registered source's remote_prefix. Cheap on
-- purpose (the repository asks it per book): with no remote source registered
-- it is one prefix test.
function M.isRemotePath(fp)
    if type(fp) ~= "string" then return false end
    if fp:find("^OPDS://") then return true end
    local list = M._prefixes
    if not list then
        list = {}
        for _i, id in ipairs(_order) do
            local p = _specs[id].remote_prefix
            if p then list[#list + 1] = p end
        end
        M._prefixes = list
    end
    for i = 1, #list do
        if fp:sub(1, #list[i]) == list[i] then return true end
    end
    return false
end

-- Change listeners, by name: the shelf rebuilds when a source says it has news.
-- One slot per name, so a shelf widget made afresh replaces its predecessor's
-- listener instead of piling up beside it.
local _listeners = {}
function M.onChanged(name, fn) _listeners[name] = fn end
function M.changed(id)
    for _name, fn in pairs(_listeners) do pcall(fn, id) end
end

-- pickerIds() -> ids to offer in the shelf source picker: available, and not
-- opted out.
function M.pickerIds()
    local out = {}
    for _i, id in ipairs(_order) do
        if _specs[id].picker ~= false and M.isAvailable(id) then out[#out + 1] = id end
    end
    return out
end

-- libraryIds(tabs) -> ids whose books count as part of the library: the spec
-- opted in, the source is available, and some shelf in `tabs` uses it. Having
-- made a shelf of it is the opt-in (see the repository's search notes).
function M.libraryIds(tabs)
    local used = {}
    for _i, t in ipairs(tabs or {}) do
        if type(t) == "table" and type(t.source) == "table" and t.source.kind then
            used[t.source.kind] = true
        end
    end
    local out = {}
    for _i, id in ipairs(_order) do
        local spec = _specs[id]
        if spec.library and spec.list and used[id] and M.isAvailable(id) then out[#out + 1] = id end
    end
    return out
end

-- ownerOf(book) -> id or nil. The stamp first, then each source's own test, so
-- a book rebuilt from its path (no stamp) is still found.
function M.ownerOf(book)
    if type(book) ~= "table" then return nil end
    local kind = book.source_kind
    if kind and _specs[kind] then return kind end
    for _i, id in ipairs(_order) do
        local ok, mine = call(_specs[id], "owns", book)
        if ok and mine then return id end
    end
    return nil
end

-- invalidate(filepath or nil): tell every source a file changed.
function M.invalidate(filepath)
    for _i, id in ipairs(_order) do call(_specs[id], "invalidate", filepath) end
end

-- Bookshelf's own sources, registered like anyone else's.
local function registerBuiltins()
    local ok, builtins = pcall(require, "lib/bookshelf_builtin_sources")
    if ok and type(builtins) == "function" then
        local ok_reg, err = pcall(builtins, M)
        if not ok_reg then logWarn("built-in sources failed:", tostring(err)) end
    end
end
registerBuiltins()

-- Tests only: back to the built-ins alone.
function M._reset() _order, _specs = {}, {}; registerBuiltins() end

return M
