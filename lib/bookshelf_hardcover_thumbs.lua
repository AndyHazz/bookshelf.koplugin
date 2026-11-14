-- bookshelf_hardcover_thumbs.lua
-- Cover thumbnails for the Hardcover picker (lib/bookshelf_hardcover_picker).
--
-- The list opens at once, with text only, and each row's cover arrives when
-- it has been fetched: a small disk cache keyed by the image's address, and
-- a loader that downloads what the page on screen is missing. One download
-- at a time, each in a forked child, so the list keeps answering taps; the
-- loader only polls. A page turn replaces what is waiting. Closing the list
-- stops it.
--
-- These are fetched because the reader searched Hardcover and is looking at
-- the results: nothing here runs by itself.

local UIManager = require("ui/uimanager")

local M = {}

-- How often the loader looks at its child, and how long a child may take.
M.POLL_S = 0.25
M.TIMEOUT_S = 25
-- A cover not looked at for this long is removed from the cache.
M.KEEP_DAYS = 30

local function now()
    local ok, gettime = pcall(require, "lib/bookshelf_gettime")
    return ok and gettime() or os.time()
end

local function lfs() return require("libs/libkoreader-lfs") end

function M.cacheDir()
    return require("lib/bookshelf_paths").cacheFile("covers/hardcover_picker")
end

-- urlOf(record) -> the record's cover address, or nil.
function M.urlOf(rec)
    local img = type(rec) == "table" and rec.cached_image or nil
    local url = type(img) == "table" and img.url or nil
    if type(url) ~= "string" or not url:match("^https?://") then return nil end
    return url
end

-- A file name from an address: two 32-bit running hashes, in hex. Not a
-- security boundary, only a name that two addresses do not share.
local function nameFor(url)
    local a, b = 5381, 52711
    for i = 1, #url do
        local c = url:byte(i)
        a = (a * 33 + c) % 4294967296
        b = (b * 31 + c * 7 + i) % 4294967296
    end
    return string.format("%08x%08x", a, b)
end

function M.pathFor(url)
    return M.cacheDir() .. "/" .. nameFor(url) .. ".img"
end

-- cached(url) -> the cover's path when it has been fetched, else nil.
function M.cached(url)
    if type(url) ~= "string" then return nil end
    local path = M.pathFor(url)
    local ok, attr = pcall(lfs().attributes, path)
    if ok and type(attr) == "table" and attr.mode == "file" and (attr.size or 0) > 0 then
        return path
    end
    return nil
end

-- sweep(at): drop covers older than KEEP_DAYS, and half-written files.
function M.sweep(at)
    at = at or os.time()
    local dir = M.cacheDir()
    local names = {}
    local ok = pcall(function()
        for name in lfs().dir(dir) do names[#names + 1] = name end
    end)
    if not ok then return end
    for _i, name in ipairs(names) do
        if name ~= "." and name ~= ".." then
            local path = dir .. "/" .. name
            local attr = lfs().attributes(path)
            if type(attr) == "table" and attr.mode == "file"
                    and (name:match("%.tmp$")
                        or (at - (attr.modification or at)) > M.KEEP_DAYS * 86400) then
                pcall(os.remove, path)
            end
        end
    end
end

-- ── the child process (seams for tests) ─────────────────────────────────────
function M._spawn(url, path)
    local ffiutil = require("ffi/util")
    local pid = ffiutil.runInSubProcess(function()
        pcall(function()
            require("lib/bookshelf_cover_fetch").download(url, path, nil, nil,
                { block_timeout = 10, total_timeout = 20 })
        end)
    end)
    return pid or nil
end

function M._done(pid)
    return require("ffi/util").isSubProcessDone(pid)
end

function M._kill(pid)
    local ffiutil = require("ffi/util")
    ffiutil.terminateSubProcess(pid)
    -- Collect it, so no zombie is left; it may take a moment to die.
    local tries = 0
    local function reap()
        tries = tries + 1
        if not ffiutil.isSubProcessDone(pid) and tries < 20 then
            UIManager:scheduleIn(0.5, reap)
        end
    end
    reap()
end

-- ── the loader ──────────────────────────────────────────────────────────────
local Loader = {}
Loader.__index = Loader

local _swept = false

-- newLoader{ on_loaded = function(record), on_failed = function(record) }
function M.newLoader(opts)
    if not _swept then
        _swept = true
        pcall(M.sweep)
    end
    local self = setmetatable({
        on_loaded = opts and opts.on_loaded,
        on_failed = opts and opts.on_failed,
        waiting   = {},     -- { url, ... } in page order
        listeners = {},     -- url -> { record, ... } on the page now
        failed    = {},     -- url -> true: would not download, this session
        current   = nil,    -- { url, path, handle, started }
        stopped   = false,
    }, Loader)
    self._poll = function() self:_tick() end
    return self
end

-- want(records): the records on screen now. Their missing covers are
-- fetched, in order; whatever was waiting from another page is dropped.
function Loader:want(records)
    if self.stopped then return end
    self.waiting, self.listeners = {}, {}
    local queued = {}
    for _i, rec in ipairs(records or {}) do
        local url = M.urlOf(rec)
        if url and not self.failed[url] and not M.cached(url) then
            self.listeners[url] = self.listeners[url] or {}
            table.insert(self.listeners[url], rec)
            if not queued[url] and not (self.current and self.current.url == url) then
                queued[url] = true
                self.waiting[#self.waiting + 1] = url
            end
        end
    end
    self:_next()
end

function Loader:_next()
    if self.stopped or self.current then return end
    local url = table.remove(self.waiting, 1)
    if not url then return end
    local path = M.pathFor(url)
    pcall(function() require("lib/bookshelf_fs").ensureDir(M.cacheDir()) end)
    local ok, handle = pcall(M._spawn, url, path)
    if not ok or not handle then
        self.failed[url] = true
        return self:_next()
    end
    self.current = { url = url, path = path, handle = handle, started = now() }
    UIManager:scheduleIn(M.POLL_S, self._poll)
end

function Loader:_tick()
    if self.stopped then return end
    local cur = self.current
    if not cur then return end
    local done = M._done(cur.handle)
    if not done and now() - cur.started > M.TIMEOUT_S then
        pcall(M._kill, cur.handle)
        done = true
    end
    if not done then
        UIManager:scheduleIn(M.POLL_S, self._poll)
        return
    end
    self.current = nil
    if M.cached(cur.url) then
        for _i, rec in ipairs(self.listeners[cur.url] or {}) do
            if self.on_loaded then pcall(self.on_loaded, rec) end
        end
    else
        self.failed[cur.url] = true
        for _i, rec in ipairs(self.listeners[cur.url] or {}) do
            if self.on_failed then pcall(self.on_failed, rec) end
        end
    end
    self.listeners[cur.url] = nil
    self:_next()
end

-- hasFailed(url) -> true when that cover would not download this session.
function Loader:hasFailed(url)
    return url ~= nil and self.failed[url] == true
end

-- stop(): the list closed. Ends the child in flight; nothing more is
-- announced.
function Loader:stop()
    if self.stopped then return end
    self.stopped = true
    UIManager:unschedule(self._poll)
    if self.current then
        pcall(M._kill, self.current.handle)
        self.current = nil
    end
    self.waiting, self.listeners = {}, {}
end

return M
