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

Spec fields (only label, available and list are required):

    api          the SOURCE_API version the spec was written against (number)
    label        function() -> string, the name in the shelf source picker
    available    function() -> bool; false hides the source everywhere, so a
                 source whose plugin or device is missing simply is not there
    list         function(source) -> { record, ... }, every book the shelf
                 holds. Bookshelf filters, sorts and pages them. `source` is the
                 shelf's own source table, so one spec can serve several shelves.
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
    open         function(book, ctx) -> true when the source handled the open.
                 ctx.widget is the shelf, ctx.after_open the callback to pass on.
                 Without it, or when it returns false, Bookshelf opens
                 book.filepath itself.
    invalidate   function(filepath or nil), a file changed: drop any cache

Records are ordinary book tables: filepath, title, authors, series, cover_image_path
and so on, the same fields a walked book carries. Bookshelf stamps each listed
record with `source_kind` so it can find its way back.

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
local RESERVED = {
    all = true, library = true, recent = true, latest = true, favorites = true,
    folder = true, folder_flat = true, series = true, authors = true,
    genres = true, tags = true, formats = true, ratings = true, languages = true,
    statuses = true, collection = true, opds = true,
}

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
    for _i, f in ipairs({ "label", "available", "list" }) do
        if type(spec[f]) ~= "function" then return false, f .. " must be a function" end
    end
    for _i, f in ipairs({ "cover", "owns", "open", "invalidate", "new_shelf" }) do
        if spec[f] ~= nil and type(spec[f]) ~= "function" then
            return false, f .. " must be a function"
        end
    end
    if not _specs[id] then _order[#_order + 1] = id end
    _specs[id] = spec
    return true
end

function M.unregister(id)
    if not _specs[id] then return end
    _specs[id] = nil
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
        if _specs[id].library and used[id] and M.isAvailable(id) then out[#out + 1] = id end
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
