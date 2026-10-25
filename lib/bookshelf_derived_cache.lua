--[[--
Things derived from files that rarely change, kept between sessions.

A picture the shelf builds from a pack's files (a plank strip, a measured
plank reach) was built again on the first shelf of every session: a decode,
a scale, a pass over the pixels, each time with the same answer. This keeps
the answer, keyed on what it was made from:

- stamp(paths...) -> a string naming those files as they are now (path,
  mtime, size each), or nil when one cannot be read. Put it in the key: an
  edited file gives a new key, so nothing here owns any invalidation.
- bb(key) / putBB(key, bb): a picture, in the cover disk cache (raw pixels,
  bounded and swept with the covers).
- get(key) / put(key, value): a small Lua value (numbers, strings, plain
  tables), in one cache file, written a few seconds after the last change.

M._dc, M._store: injectable; false switches either off (tests).
]]

local M = {}

local function lfs()
    if M._lfs ~= nil then return M._lfs or nil end
    local ok, l = pcall(require, "libs/libkoreader-lfs")
    M._lfs = ok and l or false
    return M._lfs or nil
end

function M.stamp(...)
    local fs = lfs()
    if not fs then return nil end
    local parts = {}
    for i = 1, select("#", ...) do
        local p = select(i, ...)
        if p then
            local mt = fs.attributes(p, "modification")
            if not mt then return nil end
            parts[#parts + 1] = p .. "@" .. tostring(mt) .. "/" .. tostring(fs.attributes(p, "size"))
        else
            parts[#parts + 1] = "-"
        end
    end
    return table.concat(parts, ";")
end

local function dc()
    if M._dc == nil then
        local ok, DC = pcall(require, "lib/bookshelf_cover_disk_cache")
        M._dc = ok and DC or false
    end
    return M._dc or nil
end

function M.bb(key)
    local c = key and dc()
    if not c then return nil end
    local ok, bb = pcall(c.load, "derived:" .. key)
    return ok and bb or nil
end

function M.putBB(key, bb)
    local c = key and bb and dc()
    if c then pcall(c.store, "derived:" .. key, bb) end
end

local function store()
    if M._store == nil then
        local ok, st = pcall(function()
            return require("lib/bookshelf_file_store").new(
                require("lib/bookshelf_paths").cacheFile("derived.lua"))
        end)
        M._store = ok and st or false
    end
    return M._store or nil
end

local _values           -- the file's table, read once
local _flush_armed = false

local function values()
    if _values == nil then
        local st = store()
        local ok, v = false, nil
        if st then ok, v = pcall(st.read, "values", nil) end
        _values = (ok and type(v) == "table") and v or {}
    end
    return _values
end

function M.get(key)
    if not (key and store()) then return nil end
    return values()[key]
end

function M.put(key, value)
    local st = key and store()
    if not st then return end
    values()[key] = value
    if _flush_armed then return end
    _flush_armed = true
    local function flush()
        _flush_armed = false
        pcall(st.save, "values", _values)
    end
    local ok, UIManager = pcall(require, "ui/uimanager")
    if ok and UIManager and UIManager.scheduleIn then
        UIManager:scheduleIn(5, flush)
    else
        flush()
    end
end

function M._reset() _values, _flush_armed = nil, false end

return M
