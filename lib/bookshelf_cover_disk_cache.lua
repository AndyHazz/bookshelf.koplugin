--[[--
Disk backing for ScaledCoverCache.

ScaledCoverCache is memory-only, so every launch re-derives every visible
cover: BookInfoManager hands back a compressed cover, we decompress it and
scale it to the slot. Measured on a PW5, a first render of the Series chip
spent ~900ms doing that for the ~24 covers of one page, about a quarter of a
3.5s cold start, and paid it again on the next launch.

The covers are already persisted -- in BIM's database -- so this does not
store anything new. It stores the RESULT: the scaled blitbuffer, raw, so a
later launch reads it back instead of decompressing and rescaling. Reading a
262x393 8bpp buffer off the PW5 measured 2.9ms against ~37ms to rebuild it.

Deliberately dumb about correctness. Every way a cover can change already
funnels through ScaledCoverCache:drop (the stale sweep, and the widget when
BIM finishes a fresh extraction) or :clear (a cover-size settings change), so
this mirrors those and owns no invalidation logic of its own. On top of that
each file carries the filepath and geometry it was written for and is rejected
if either disagrees, which turns a hash collision or a half-written file into
a miss rather than a wrong cover on screen.
]]--

local lfs = require("libs/libkoreader-lfs")
local Blitbuffer = require("ffi/blitbuffer")
local logger = require("logger")

local M = {}

local MAGIC = "BSC1"
-- Bounded in BYTES, for the reason ScaledCoverCache gives for bounding RAM
-- the same way: entry size varies ~5x between a shelf cover and a hero one and
-- ~4x between 8bpp grayscale and RGB32, so a file COUNT maps to wildly
-- different amounts of disk. The sweep already stats each file for its mtime;
-- taking the size from the same call makes the byte bound free.
-- 96MB (was 32). One page of shelf covers is ~2.4MB, so this holds ~40 pages
-- -- enough that a deep paging session survives a restart instead of paying
-- the decode+scale again for everything beyond the first dozen pages (the
-- post-restart "first visit to every page is slow" report). Still a cache,
-- not a mirror of the library, and still modest next to BIM's cover
-- database -- the largest thing bookshelf touches on a Kindle.
M.MAX_BYTES = 96 * 1024 * 1024
-- Ornament renders (keys "ornament:...", bookshelf_ornaments) have a budget
-- of their own and their own file names: the ornament library's previews
-- are kept too, and in the covers' budget a browse through a few hundred
-- pieces pushed the shelf's covers out (PW5, 2026-10-31: 32 MB of renders,
-- 59 MB of covers, against 96 MB).
M.ORNAMENT_MAX_BYTES = 24 * 1024 * 1024
local ORNAMENT_PREFIX = "ornament:"
-- Both budgets together never take more than this share of the room the
-- store has: the free space plus what it already holds. A full disk crashed
-- a PW5 (2026-10-28); a nearly full device keeps a smaller store and decodes
-- more often instead.
M.DISK_SHARE = 0.25
-- A read marks a file used for the sweep, at most once a day a file.
local TOUCH_AFTER = 24 * 60 * 60

local _dir            -- resolved cache directory, or false when unavailable
local _swept = false  -- the count sweep runs at most once per session

local function dir()
    if _dir ~= nil then return _dir or nil end
    local ok, DataStorage = pcall(require, "datastorage")
    if not (ok and DataStorage and DataStorage.getDataDir) then
        _dir = false
        return nil
    end
    local d = require("lib/bookshelf_paths").cacheFile("scaled_covers")
    if lfs.attributes(d, "mode") ~= "directory" then
        local ok_mk = pcall(lfs.mkdir, d)
        if not ok_mk or lfs.attributes(d, "mode") ~= "directory" then
            _dir = false
            return nil
        end
    end
    _dir = d
    return d
end

-- djb2 over the path. Multiplication and addition only: KOReader runs LuaJIT,
-- which is Lua 5.1, where the binary `~` xor operator does not exist (it
-- parses on newer LuaJIT builds and on the 5.4 interpreter the tests use,
-- which is exactly why the mistake would have survived to the device). The
-- intermediate stays under 2^53, so it is exact in a double.
--
-- Only has to spread filenames across a directory. Book paths share long
-- prefixes, so trailing bytes -- where they actually differ -- dominate. A
-- collision is caught by the filepath stored in the file header.
local function keyFor(filepath)
    local h = 5381
    for i = 1, #filepath do
        h = (h * 33 + filepath:byte(i)) % 4294967296
    end
    -- "o" is no hex digit: an ornament's file is told by its name alone.
    local kind = filepath:sub(1, #ORNAMENT_PREFIX) == ORNAMENT_PREFIX and "o" or ""
    return string.format("%s%08x_%d", kind, h, #filepath)
end

local function pathFor(filepath)
    local d = dir()
    if not d then return nil end
    return d .. "/" .. keyFor(filepath)
end

-- The book a cache file was written for, without reading its pixels. Used only
-- by the over-budget branch of the sweep, so the common case never pays it.
local function bookOf(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local header = f:read("*l")
    local fp
    if header then
        local magic, _w, _h, _s, _t, fplen =
            header:match("^(%S+) (%d+) (%d+) (%d+) (%d+) (%d+)$")
        if magic == MAGIC then fp = f:read(tonumber(fplen) or 0) end
    end
    f:close()
    return fp
end

--- Bring the store back under M.MAX_BYTES. Public because it is a real
--- operation rather than an internal detail, and because the once-per-session
--- guard belongs to the automatic call below, not to the work itself.
--- Prunes only when actually over the cap, so the usual cost is one dir
--- listing plus a stat per file.
function M.sweep()
    local d = dir()
    if not d then return end
    local ok, entries = pcall(function()
        local list = {}
        for entry in lfs.dir(d) do
            if entry ~= "." and entry ~= ".." then
                local p = d .. "/" .. entry
                local a = lfs.attributes(p) or {}
                list[#list + 1] = { p = p, m = a.modification or 0, b = a.size or 0,
                                    orn = entry:sub(1, 1) == "o" }
            end
        end
        return list
    end)
    if not ok or not entries then return end
    local covers, renders = {}, {}
    for i = 1, #entries do
        local e = entries[i]
        if e.orn then renders[#renders + 1] = e else covers[#covers + 1] = e end
    end
    local cover_cap, render_cap = M.MAX_BYTES, M.ORNAMENT_MAX_BYTES
    local free = M._freeBytes(d)
    if free then
        local held = 0
        for i = 1, #entries do held = held + entries[i].b end
        local share = (free + held) * M.DISK_SHARE
        local f = share / (cover_cap + render_cap)
        if f < 1 then
            cover_cap, render_cap = math.floor(cover_cap * f), math.floor(render_cap * f)
        end
    end
    M._prune(covers, cover_cap, false)
    M._prune(renders, render_cap, true)
end

-- _freeBytes(path) -> the space free to us on path's filesystem, or nil.
-- statvfs, not util.diskUsage: that forks KOReader to run df (27 ms on a
-- PW5 against 0.4). Unknown leaves the budgets as they are.
function M._freeBytes(path)
    local ok, bytes = pcall(function()
        local ffi = require("ffi")
        require("ffi/posix_h")
        local st = ffi.new("struct statvfs")
        if ffi.C.statvfs(path, st) ~= 0 then return nil end
        return tonumber(st.f_bavail) * tonumber(st.f_frsize)
    end)
    if ok and type(bytes) == "number" and bytes >= 0 then return bytes end
    return nil
end

-- _prune(entries, cap, renders): one budget's files brought under its cap.
function M._prune(entries, cap, renders)
    local total = 0
    for i = 1, #entries do total = total + entries[i].b end
    if total <= cap then return end
    -- Over budget. Before falling back to age, drop covers whose book is no
    -- longer there: those can never be used again, while an old cover for a
    -- book still on the shelf may well be wanted on the next launch.
    --
    -- This is the ONLY place that check happens, deliberately. Dropping a
    -- deleted book's cover eagerly (say, from the stale sweep, which already
    -- knows which files have gone) would churn every session for anyone whose
    -- library lives on removable media: unmounted reads as deleted, and the
    -- covers would be discarded and rebuilt on every mount. Doing it only when
    -- space is actually short means an unmounted card costs nothing until the
    -- cache is full, and even then it costs a rebuild rather than a wrong
    -- cover.
    local orphans = 0
    for i = 1, #entries do
        local fp = bookOf(entries[i].p)
        -- An ornament's render is kept under "ornament:<path>|...", not a
        -- path (bookshelf_ornaments renderDiskKey): it is an orphan when its
        -- piece is gone. Read as a path, every one went at each session's
        -- first sweep, and every piece was decoded again (PW5, 2026-10-30).
        -- Among the covers, a render is one 6.0.4 wrote under a cover's
        -- name: nothing reads it under that name now.
        local legacy = false
        if fp and fp:sub(1, #ORNAMENT_PREFIX) == ORNAMENT_PREFIX then
            legacy = not renders
            fp = fp:match("^ornament:(.-)|") or fp
        end
        -- No readable header is its own kind of orphan: nothing can use it.
        entries[i].orphan = legacy or (fp == nil) or (lfs.attributes(fp, "mode") == nil)
        if entries[i].orphan then orphans = orphans + 1 end
    end
    table.sort(entries, function(a, b)
        if a.orphan ~= b.orphan then return a.orphan end   -- orphans first
        return a.m < b.m                                    -- then oldest
    end)
    local pruned = 0
    for i = 1, #entries do
        if total <= cap then break end
        if pcall(os.remove, entries[i].p) then
            total = total - entries[i].b
            pruned = pruned + 1
        end
    end
    logger.dbg(string.format(
        "[bookshelf] cover disk cache: pruned %d of %d files (%d orphaned), now %d KB",
        pruned, #entries, orphans, math.floor(total / 1024)))
end

-- The automatic sweep: at most once per session, after a write.
local function maybeSweep()
    if _swept then return end
    _swept = true
    M.sweep()
end

--- Write a scaled cover. Returns true when it landed on disk.
function M.store(filepath, bb)
    if type(filepath) ~= "string" or filepath == "" or not bb then return false end
    local p = pathFor(filepath)
    if not p then return false end
    local ok = pcall(function()
        local ffi = require("ffi")
        local w, h = bb:getWidth(), bb:getHeight()
        local stride = tonumber(bb.stride)
        local btype  = tonumber(bb:getType())
        if not (w and h and stride and btype) or w <= 0 or h <= 0 then
            error("unusable blitbuffer")
        end
        -- Refuse anything Blitbuffer.new(w, h, type, nil, stride) would not
        -- reproduce exactly. The header carries w, h, stride and type, and the
        -- reader rebuilds from those alone, so a buffer holding state outside
        -- that set must be a miss rather than a subtly wrong cover.
        --
        -- Two things live outside it. pixel_stride is derived from stride and
        -- bpp on the way back in, so a buffer whose own pixel_stride disagrees
        -- would come back reshaped. Rotation and inversion live in the config
        -- byte, which the header has nowhere to put, and an inverted cover
        -- reloaded as a normal one is a photo negative on the shelf.
        --
        -- Note this does NOT reject viewport buffers, and does not need to: a
        -- viewport keeps its parent's stride, so its extra columns sit beyond
        -- w and are never painted, and its rows round-trip as they are.
        local bpp = Blitbuffer.TYPE_TO_BPP and Blitbuffer.TYPE_TO_BPP[btype]
        if not bpp then error("unknown buffer type") end
        if tonumber(bb.pixel_stride) ~= math.floor(stride * 8 / bpp) then
            error("non-derivable pixel stride (viewport or padded buffer)")
        end
        if (bb.getRotation and bb:getRotation() or 0) ~= 0 then error("rotated") end
        if (bb.getInverse  and bb:getInverse()  or 0) ~= 0 then error("inverted") end
        -- Write to a sibling and rename, so a crash mid-write cannot leave a
        -- truncated file that later reads as a valid header with short data.
        local tmp = p .. ".tmp"
        local f = assert(io.open(tmp, "wb"))
        f:write(string.format("%s %d %d %d %d %d\n%s\n",
            MAGIC, w, h, stride, btype, #filepath, filepath))
        f:write(ffi.string(bb.data, stride * h))
        f:close()
        os.remove(p)
        assert(os.rename(tmp, p))
    end)
    if ok then maybeSweep() end
    return ok
end

--- Read a scaled cover back, or nil. Never returns a buffer for a different
--- book or a different geometry than it was written with.
function M.load(filepath)
    if type(filepath) ~= "string" or filepath == "" then return nil end
    local p = pathFor(filepath)
    if not p then return nil end
    local ok, bb = pcall(function()
        local f = io.open(p, "rb")
        if not f then return nil end
        local header = f:read("*l")
        if not header then f:close(); return nil end
        local magic, w, h, stride, btype, fplen =
            header:match("^(%S+) (%d+) (%d+) (%d+) (%d+) (%d+)$")
        if magic ~= MAGIC then f:close(); return nil end
        w, h, stride, btype, fplen =
            tonumber(w), tonumber(h), tonumber(stride), tonumber(btype), tonumber(fplen)
        local stored_fp = f:read(fplen)
        f:read(1)  -- the newline after the path
        if stored_fp ~= filepath then f:close(); return nil end   -- hash collision
        local want = stride * h
        local data = f:read(want)
        f:close()
        if not data or #data ~= want then return nil end           -- truncated
        local out = Blitbuffer.new(w, h, btype, nil, stride)
        if not out then return nil end
        local ffi = require("ffi")
        ffi.copy(out.data, data, want)
        -- Used: the sweep goes by last use, so a cover read every day is
        -- not the first to go because it was written long ago.
        local mt = lfs.attributes(p, "modification")
        local now = os.time()
        if mt and now - mt > TOUCH_AFTER and lfs.touch then pcall(lfs.touch, p, now, now) end
        return out
    end)
    return ok and bb or nil
end

function M.drop(filepath)
    local p = pathFor(filepath)
    if p then pcall(os.remove, p) end
end

function M.clear()
    local d = dir()
    if not d then return end
    pcall(function()
        for entry in lfs.dir(d) do
            if entry ~= "." and entry ~= ".." then pcall(os.remove, d .. "/" .. entry) end
        end
    end)
end

return M
