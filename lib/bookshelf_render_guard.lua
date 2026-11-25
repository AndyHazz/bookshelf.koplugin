-- lib/bookshelf_render_guard.lua
-- Keeps one book from taking KOReader down during the page-count scan
-- (issue 518).
--
-- The scan renders each book in a forked child so that a book the engine
-- cannot handle costs the child, not KOReader. That holds for a crash, but
-- not for memory: a complete-works omnibus on a 512MB Kobo ran the whole
-- device out ("FATAL ERROR #-2: realloc failed"), froze it for minutes, and
-- KOReader went down with the child, on the same books every run. Three
-- things here, each enough on its own for some of that:
--
--   childLimits()  run first thing in the child. Marks the child as the
--                  process to kill when memory runs out (oom_score_adj), and
--                  caps its address space near what is free, so an
--                  allocation the device cannot afford fails in the child at
--                  once instead of the whole device thrashing.
--   mark(fp)       before each render, which book is in flight, in a small
--                  file. KOReader dying mid-render leaves it behind.
--   takeCrashed()  at the next scan: the book that was in flight, if any,
--                  goes on a list of books the scan skips (and reports as
--                  not counted) for as long as the file stays the same size.
--
-- A fourth for a book that neither crashes nor runs out of memory but never
-- finishes: childDeadline() has the kernel end the child after
-- RENDER_LIMIT_S, and skip() puts the book on the same list.
--
-- And one for speed: withoutForcedCollect(fn), around the child's
-- openDocument.
local M = {}

-- { [filepath] = size in bytes }. A new key in 6.0 (was "page_count_skip"),
-- so the books skipped under the old, larger share below are tried once more
-- under the new one; a book that still takes the device down is skipped again
-- on the next run.
M.SETTING = "page_count_skip_v2"
-- How much of the memory the device has free a child may take. The rest is
-- KOReader's and the system's. Half, not three quarters (issue 518): on a
-- 512 MB Kobo with no swap, three quarters let a heavy book push the whole
-- system into a freeze before the child's allocation was refused. With half,
-- the same books fail cleanly or finish (confirmed by the reporter: 106
-- previously skipped books retried, 40 failed, no freeze).
M.AVAILABLE_SHARE = 0.5

-- How long one book's render may take. A book whose layout never ends held
-- the scan on a Kindle PW3 until Stop: one child at 100% CPU, memory steady,
-- so neither the cap nor the crash marker saw it. The slowest of the other
-- 242 books in that library took 31 s.
M.RENDER_LIMIT_S = 300

local function readFile(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

-- memAvailableBytes(meminfo_text) -> MemAvailable in bytes, or nil.
function M.memAvailableBytes(text)
    local kb = text and text:match("MemAvailable:%s*(%d+)%s*kB")
    return kb and tonumber(kb) * 1024 or nil
end

-- addressLimit(vsize, available) -> the RLIMIT_AS to set: what the child has
-- mapped already (most of it shared with KOReader, untouched) plus its share
-- of what is free. nil when either is unknown, which leaves the limit alone.
function M.addressLimit(vsize, available)
    if not (vsize and available) or vsize <= 0 or available <= 0 then return nil end
    return math.floor(vsize + available * M.AVAILABLE_SHARE)
end

-- Which limit the child gets. RLIMIT_AS (address space) counts every font
-- and library mapped in whole, most of it never touched: on the PW5 a render
-- using ~30 MB failed with 120 MB of address space spare, a different 76-97
-- books each scan, and every one passed with no cap. From Linux 4.7
-- RLIMIT_DATA counts the process's own private memory (heap and anonymous
-- mappings), which is what ran out in issue 518, and leaves mapped files
-- out. Older kernels only count the heap there, so they keep RLIMIT_AS.
-- Resource numbers as on x86, ARM and AArch64.
M.RLIMIT_DATA, M.RLIMIT_AS = 2, 9

-- kernelAtLeast(release, major, minor) -> bool, release as uname -r prints it.
function M.kernelAtLeast(release, major, minor)
    local a, b = tostring(release or ""):match("^(%d+)%.(%d+)")
    a, b = tonumber(a), tonumber(b)
    if not a then return false end
    return a > major or (a == major and b >= minor)
end

-- pickLimit(release, vmsize, vmdata, available) -> resource, limit, room
-- (bytes), or nil when there is not enough to go on. room: what the child may
-- take above what it has, the same share of the free memory either way.
function M.pickLimit(release, vmsize, vmdata, available)
    if not available or available <= 0 then return nil end
    local room = math.floor(available * M.AVAILABLE_SHARE)
    if vmdata and vmdata > 0 and M.kernelAtLeast(release, 4, 7) then
        return M.RLIMIT_DATA, vmdata + room, room
    end
    local as = M.addressLimit(vmsize, available)
    if as then return M.RLIMIT_AS, as, as - vmsize end
    return nil
end

-- childLimits() -> room, available (bytes, either nil when unknown): what it
-- set, for the scan's log when a render fails.
function M.childLimits()
    local set_limit, avail
    pcall(function()
        local f = io.open("/proc/self/oom_score_adj", "w")
        if f then f:write("1000"); f:close() end
    end)
    pcall(function()
        local statm = readFile("/proc/self/statm")
        local pages = statm and tonumber(statm:match("^(%d+)"))
        local ffi = require("ffi")
        pcall(ffi.cdef, [[
            struct bookshelf_rlimit { unsigned long rlim_cur; unsigned long rlim_max; };
            int setrlimit(int resource, const struct bookshelf_rlimit *rlim);
            long sysconf(int name);
        ]])
        local page = 4096
        local ok_p, p = pcall(function() return tonumber(ffi.C.sysconf(30)) end)  -- _SC_PAGESIZE
        if ok_p and p and p > 0 then page = p end
        avail = M.memAvailableBytes(readFile("/proc/meminfo"))
        local status = readFile("/proc/self/status")
        local data_kb = status and tonumber(status:match("VmData:%s*(%d+)%s*kB"))
        local res, limit, room = M.pickLimit(readFile("/proc/sys/kernel/osrelease"),
            pages and pages * page, data_kb and data_kb * 1024, avail)
        -- unsigned long is 32 bits on the Kobos and Kindles: stay under it.
        if not limit or (ffi.sizeof("unsigned long") == 4 and limit >= 2^32) then return end
        local rl = ffi.new("struct bookshelf_rlimit", limit, limit)
        if ffi.C.setrlimit(res, rl) == 0 then set_limit = room end
    end)
    return set_limit, avail
end

-- childDeadline(seconds): run in the child, before the render. alarm() has
-- the kernel end the process (SIGALRM, never handled) once that long has
-- passed, whatever the engine is doing; the scan then sees a child that
-- ended without a count. It dies with the child, so nothing is left armed.
function M.childDeadline(seconds)
    return pcall(function()
        local ffi = require("ffi")
        pcall(ffi.cdef, "unsigned int alarm(unsigned int seconds);")
        ffi.C.alarm(seconds or M.RENDER_LIMIT_S)
    end)
end

-- timedOut(elapsed, seconds) -> true when a render that gave no count ran for
-- the whole limit: the deadline ended it, not the book failing by itself.
function M.timedOut(elapsed, seconds)
    return type(elapsed) == "number" and elapsed >= (seconds or M.RENDER_LIMIT_S)
end

-- failureNote(err, headroom, avail) -> "why" for the log line of a render that
-- gave no count: the error, the room the child had over what it started with,
-- and what the device had free then. MB, rounded.
function M.failureNote(err, headroom, avail)
    local function mb(b) return b and string.format("%d MB", math.floor(b / 1048576 + 0.5)) or "?" end
    local e = tostring(err or "no count"):gsub("%s+", " "):sub(1, 200)
    return string.format("%s; room %s, free %s", e, mb(headroom), mb(avail))
end

local function inflightPath()
    return require("lib/bookshelf_paths").settingsDir() .. "/page_count_inflight"
end

function M.mark(fp)
    pcall(function()
        local f = io.open(inflightPath(), "w")
        if f then f:write(fp); f:close() end
    end)
end

function M.clear()
    pcall(os.remove, inflightPath())
end

local function sizeOf(fp)
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok then return nil end
    return lfs.attributes(fp, "size")
end

-- withoutForcedCollect(fn) -> fn's first two results, with full collections asked for
-- inside it skipped. KOReader's DocumentRegistry:openDocument forces two
-- before every open, so an earlier document's memory can be reused. The
-- scan's child has no earlier document and is thrown away after the count,
-- and walking a heap forked from KOReader's is slow: 1.2-1.3 s a book on a
-- PW5 (65 MB heap), 2.4 s > 1.2 s for a render with crengine's cache warm,
-- the same page counts. Only an explicit full collection is skipped; the
-- collector's own incremental work and collectgarbage("count") and the like
-- go on as usual. collectgarbage is put back afterwards, so this is safe
-- where the work runs in KOReader itself rather than a child.
function M.withoutForcedCollect(fn)
    local globals = package.loaded._G
    local real = globals.collectgarbage
    globals.collectgarbage = function(opt, ...)
        if opt == nil or opt == "collect" then return 0 end
        return real(opt, ...)
    end
    local ok, a, b = pcall(fn)
    globals.collectgarbage = real
    if not ok then error(a, 0) end
    return a, b
end

-- takeCrashed(store) -> the file path left in flight, now on the skip list,
-- or nil. store is { read(key), save(key, v), flush() }.
function M.takeCrashed(store)
    local fp = readFile(inflightPath())
    M.clear()
    if not fp or fp == "" then return nil end
    M.skip(store, fp)
    return fp
end

-- skip(store, fp): onto the list of books the scan does not render again
-- while the file stays the same size.
function M.skip(store, fp)
    local list = store.read(M.SETTING)
    if type(list) ~= "table" then list = {} end
    list[fp] = sizeOf(fp) or -1
    store.save(M.SETTING, list)
    if store.flush then store.flush() end
end

-- skipped(store, fp) -> true while fp is on the list and still the same size.
-- A file that changed (a new download, a fixed copy) gets another try.
function M.skipped(store, fp, list)
    list = list or store.read(M.SETTING)
    local size = type(list) == "table" and list[fp]
    if not size then return false end
    return size == -1 or sizeOf(fp) == size
end

return M
