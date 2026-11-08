-- lib/bookshelf_bytecode.lua
-- Our modules load from compiled bytecode kept on the device.
--
-- Every start parsed ~3 MB of our Lua source. On a PW3 the seven largest
-- files took 268 ms to parse against 17 ms to load as bytecode (which is
-- also ~40% of the size to read from flash). install() puts a searcher
-- ahead of the file searchers: for lib/bookshelf_* it loads a bytecode copy
-- keyed on the source file's mtime and size, and on a miss compiles the
-- source as usual and stores the copy for next time.
--
-- The copy is string.dump of the same VM's own compile, so it is only ever
-- read by the VM that wrote it (the folder is named for it), and it keeps
-- the debug info: file names and line numbers in errors are the source's.
-- A copy that will not load (cut short by a power loss) is passed over and
-- written again. Nothing is written on a nearly full disk.
local M = {}

M.PREFIX   = "lib/bookshelf_"
-- Below this much free space, no copies are written (the source still loads).
M.MIN_FREE = 24 * 1024 * 1024

local _root, _dir, _free_ok

local function lfs()
    local ok, l = pcall(require, "libs/libkoreader-lfs")
    return ok and l or nil
end

-- vmTag() -> a folder name for this VM: a copy is only for the VM that made it.
function M.vmTag()
    local ok, J = pcall(require, "jit")
    local tag = (ok and type(J) == "table" and J.version) and (J.version .. "-" .. tostring(J.arch)) or "lua"
    return (tag:gsub("[^%w%.%-]", "_"))
end

-- Seam: compile a source file (loadfile).
M._compile = function(path) return loadfile(path) end

local function freeOk(dir)
    if _free_ok ~= nil then return _free_ok end
    _free_ok = true
    pcall(function()
        local ffi = require("ffi")
        pcall(ffi.cdef, [[
            struct bookshelf_bc_statvfs { unsigned long f_bsize, f_frsize, f_blocks, f_bfree, f_bavail,
                f_files, f_ffree, f_favail, f_fsid, f_flag, f_namemax; int __f_spare[6]; };
            int statvfs(const char *path, struct bookshelf_bc_statvfs *buf);
        ]])
        local st = ffi.new("struct bookshelf_bc_statvfs")
        if ffi.C.statvfs(dir, st) == 0 then
            _free_ok = tonumber(st.f_bavail) * tonumber(st.f_frsize) >= M.MIN_FREE
        end
    end)
    return _free_ok
end

local function mkdirs(L, path)
    local acc = path:sub(1, 1) == "/" and "/" or ""
    for part in path:gmatch("[^/]+") do
        acc = acc .. part .. "/"
        if not L.attributes(acc) then L.mkdir(acc) end
    end
    return L.attributes(path) ~= nil
end

local function store(L, dir, base, file, fn)
    if not mkdirs(L, dir) or not freeOk(dir) then return end
    local ok, code = pcall(string.dump, fn)
    if not ok or not code then return end
    local tmp = dir .. "/." .. file .. ".tmp"
    local f = io.open(tmp, "wb")
    if not f then return end
    local wrote = f:write(code)
    f:close()
    if not wrote or not os.rename(tmp, dir .. "/" .. file) then os.remove(tmp); return end
    -- The copies of earlier versions of this module.
    pcall(function()
        local prefix = base .. "-"
        for name in L.dir(dir) do
            if name ~= file and name:sub(1, #prefix) == prefix and name:sub(-5) == ".luac" then
                os.remove(dir .. "/" .. name)
            end
        end
    end)
end

-- _search(name) -> a loader for one of our modules, or nil to let the usual
-- searchers have it.
function M._search(name)
    if type(name) ~= "string" or name:sub(1, #M.PREFIX) ~= M.PREFIX or not _root then return nil end
    local L = lfs()
    if not L then return nil end
    local src = _root .. name .. ".lua"
    local a = L.attributes(src)
    if not (a and a.mode == "file" and a.modification and a.size) then return nil end
    local base = (name:gsub("[^%w_]", "_"))
    local file = string.format("%s-%d-%d.luac", base, a.modification, a.size)
    local dir = _dir .. "/" .. M.vmTag()
    local cached = dir .. "/" .. file
    if L.attributes(cached) then
        local fn = loadfile(cached)
        if fn then return fn end
    end
    local fn, err = M._compile(src)
    if not fn then
        error(string.format("error loading module '%s' from file '%s':\n\t%s", name, src, tostring(err)), 0)
    end
    pcall(store, L, dir, base, file, fn)
    return fn
end

-- data(src, tag, build) -> build(src), a flat table of strings, numbers and
-- booleans, kept as bytecode keyed on src's mtime and size and read back
-- from that on later starts. A .po parsed on every start was ~140 ms of a
-- PW3's. Anything else (a nested table, nil) is handed back and not kept.
local function serialize(t)
    local parts = { "return {" }
    for k, v in pairs(t) do
        local tk, tv = type(k), type(v)
        if not ((tk == "string" or tk == "number") and (tv == "string" or tv == "number" or tv == "boolean")) then
            return nil
        end
        parts[#parts + 1] = string.format("[%s]=%s,", (tk == "string") and string.format("%q", k) or tostring(k),
            (tv == "string") and string.format("%q", v) or tostring(v))
    end
    parts[#parts + 1] = "}"
    return table.concat(parts, "\n")
end

function M.data(src, tag, build)
    local L = lfs()
    local a = L and _dir and L.attributes(src)
    if not (a and a.mode == "file" and a.modification and a.size) then return build(src) end
    local base = "data_" .. (tostring(tag):gsub("[^%w_]", "_"))
    local file = string.format("%s-%d-%d.luac", base, a.modification, a.size)
    local dir = _dir .. "/" .. M.vmTag()
    local cached = dir .. "/" .. file
    if L.attributes(cached) then
        local fn = loadfile(cached)
        local ok, t = false, nil
        if fn then ok, t = pcall(fn) end
        if ok and type(t) == "table" then return t end
    end
    local t = build(src)
    if type(t) == "table" then
        pcall(function()
            local code = serialize(t)
            if not code then return end
            local fn = (loadstring or load)(code, "=" .. base)
            if fn then store(L, dir, base, file, fn) end
        end)
    end
    return t
end

-- install([root, cache_dir]): root is the plugin folder (ending in "/"),
-- cache_dir where the copies go; both found when not given.
function M.install(root, cache_dir)
    if M._installed then return end
    _root = root or (debug.getinfo(1, "S").source:match("^@(.+/)lib/[^/]+$"))
    if not _root then return end
    if not cache_dir then
        local ok, DataStorage = pcall(require, "datastorage")
        if not ok then return end
        cache_dir = DataStorage:getDataDir() .. "/cache/bookshelf/bytecode"
    end
    _dir = cache_dir
    local searchers = package.loaders or package.searchers
    table.insert(searchers, 2, M._search)
    M._installed = true
end

return M
