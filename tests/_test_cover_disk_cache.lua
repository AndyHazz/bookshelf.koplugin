-- tests/_test_cover_disk_cache.lua
-- lib/bookshelf_cover_disk_cache: the disk layer under ScaledCoverCache.
-- Behavioural, not source-shape: this one is pure file I/O, so it round-trips
-- through a real temp directory with a fake Blitbuffer.
--
-- What matters is not that a hit is fast -- it is that a hit is CORRECT. A
-- wrong cover on screen is silent, so every rejection path gets a test: a
-- filepath that hashed to the same file, a truncated write, a bad magic.
package.path = "./?.lua;./?/init.lua;" .. package.path

local TMP = os.getenv("TMPDIR") or "/tmp"
local DIR = TMP .. "/bscovtest_" .. tostring(os.time())

-- ── stubs ───────────────────────────────────────────────────────────────────
-- Minimal lfs over shell + io, so the suite needs no lfs binding. Only the
-- three calls the module makes are implemented.
local lfs_real = {
    attributes = function(path, what)
        -- Directories FIRST: on Linux fopen() on a directory succeeds, so an
        -- io.open probe reports every directory as a file.
        local ok = os.execute('test -d "' .. path .. '"')
        if ok == true or ok == 0 then
            if what then return ({ mode = "directory", modification = 0, size = 0 })[what] end
            return { mode = "directory", modification = 0, size = 0 }
        end
        local f = io.open(path, "rb")
        if not f then return nil end
        local size = f:seek("end") or 0
        f:close()
        -- Per-file mtimes, so the sweep's age ordering can be exercised.
        local mt = (_G.__mtimes and _G.__mtimes[path]) or 0
        if what then return ({ mode = "file", modification = mt, size = size })[what] end
        return { mode = "file", modification = mt, size = size }
    end,
    mkdir = function(path) os.execute('mkdir -p "' .. path .. '"'); return true end,
    -- A read marks a cover used (the sweep goes by last use, not by write).
    touch = function(path, _atime, mtime)
        _G.__mtimes = _G.__mtimes or {}
        _G.__mtimes[path] = mtime or os.time()
        return true
    end,
    dir = function(path)
        local names, pipe = { ".", ".." }, io.popen('ls -A "' .. path .. '" 2>/dev/null')
        if pipe then
            for line in pipe:lines() do names[#names + 1] = line end
            pipe:close()
        end
        local i = 0
        return function() i = i + 1; return names[i] end
    end,
}
package.loaded["libs/libkoreader-lfs"] = lfs_real
package.loaded["logger"] = { dbg = function() end, warn = function() end, info = function() end }
package.loaded["datastorage"] = { getDataDir = function() return DIR end, getSettingsDir = function() return DIR .. "/settings" end }

-- A blitbuffer that is just bytes: enough for store/load to exercise the
-- header and the copy without pulling in the real ffi one.
local ffi_ok, ffi = pcall(require, "ffi")
package.loaded["ffi/blitbuffer"] = {
    TYPE_TO_BPP = { [1] = 8 },
    new = function(w, h, btype, _dataptr, stride)
        stride = stride or w
        local buf = ffi_ok and ffi.new("uint8_t[?]", stride * h) or nil
        return {
            data = buf, stride = stride,
            -- Mirrors the real struct: BB.new derives pixel_stride as
            -- stride * 8 / bpp when it is not given. 8bpp here, so stride.
            pixel_stride = stride,
            getWidth = function() return w end,
            getHeight = function() return h end,
            getType = function() return btype end,
            getRotation = function() return 0 end,
            getInverse = function() return 0 end,
        }
    end,
}

local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()

if not ffi_ok then
    -- The module memcpys raw pixels, so it needs LuaJIT's ffi. Run it with
    --   luajit tests/_test_cover_disk_cache.lua
    io.stderr:write("SKIP  cover disk cache: needs LuaJIT ffi\n")
    print("PASS 0  FAIL 0")
    os.exit(0)
end

lfs_real.mkdir(DIR)
lfs_real.mkdir(DIR .. "/cache")

local Cache = require("lib/bookshelf_cover_disk_cache")
-- Sweeps only where a test asks for one (sweep, _check), not on its writes.
Cache._auto = false
local BB = package.loaded["ffi/blitbuffer"]

local STORE = DIR .. "/cache/bookshelf/scaled_covers"

local function makeBB(w, h, fill, stride)
    stride = stride or w
    local bb = BB.new(w, h, 1, nil, stride)
    for i = 0, stride * h - 1 do bb.data[i] = fill end
    return bb
end

-- The on-disk name is a hash, so find a book's file by its content.
local function fileFor(filepath)
    for entry in lfs_real.dir(STORE) do
        if entry ~= "." and entry ~= ".." then
            local p = STORE .. "/" .. entry
            local f = io.open(p, "rb"); local all = f:read("*a"); f:close()
            if all:find("\n" .. filepath .. "\n", 1, true) then return p, all end
        end
    end
end

t.test("a stored cover comes back with its geometry intact", function()
    local bb = makeBB(8, 4, 200)
    assert(Cache.store("/books/a.epub", bb), "store failed")
    local got = Cache.load("/books/a.epub")
    assert(got, "nothing came back")
    assert(got.getWidth() == 8 and got.getHeight() == 4, "geometry changed")
    assert(got.data[0] == 200 and got.data[8 * 4 - 1] == 200, "pixels changed")
end)

t.test("a padded buffer keeps its row stride", function()
    -- Blitbuffer rows can be padded, so stride is not always the width.
    -- Rebuilt at stride == w, every row after the first shifts left and the
    -- cover renders as a diagonal smear.
    local bb = makeBB(4, 3, 0, 8)
    for row = 0, 2 do
        for col = 0, 3 do bb.data[row * 8 + col] = 10 + row end
    end
    assert(Cache.store("/books/padded.epub", bb), "store failed")
    local got = assert(Cache.load("/books/padded.epub"), "nothing came back")
    assert(tonumber(got.stride) == 8, "stride was not preserved")
    for row = 0, 2 do
        assert(got.data[row * 8] == 10 + row,
            "row " .. row .. " did not survive the round trip")
    end
end)

t.test("a buffer we cannot rebuild exactly is refused, not mangled", function()
    -- The file format carries w/h/stride/type and nothing else, so anything
    -- that would come back different has to be turned away at the door.
    local rotated = makeBB(4, 2, 5)
    rotated.getRotation = function() return 90 end
    assert(not Cache.store("/books/rot.epub", rotated), "stored a rotated buffer")
    assert(Cache.load("/books/rot.epub") == nil, "a refused store left a file")

    local inverted = makeBB(4, 2, 5)
    inverted.getInverse = function() return 1 end
    assert(not Cache.store("/books/inv.epub", inverted), "stored an inverted buffer")

    -- pixel_stride that Blitbuffer.new would not derive from stride and bpp.
    local reshaped = makeBB(4, 2, 5)
    reshaped.pixel_stride = 99
    assert(not Cache.store("/books/ps.epub", reshaped), "stored a reshaped buffer")
end)

t.test("an unknown book is a miss, not an error", function()
    assert(Cache.load("/books/never-stored.epub") == nil)
end)

t.test("a hash collision is a miss, not another book's cover", function()
    -- Two paths hashing to one filename is rare but possible, and silently
    -- serving the wrong cover would be the worst failure this module has. Two
    -- different paths almost never collide by chance, so stage one: write A's
    -- bytes (whose header says A) at the exact filename B resolves to.
    Cache.store("/books/coll-a.epub", makeBB(8, 4, 200))
    Cache.store("/books/coll-b.epub", makeBB(8, 4, 55))
    local _, a_bytes = fileFor("/books/coll-a.epub")
    local b_path     = fileFor("/books/coll-b.epub")
    assert(a_bytes and b_path, "could not stage the collision")
    local f = io.open(b_path, "wb"); f:write(a_bytes); f:close()

    local got = Cache.load("/books/coll-b.epub")
    assert(got == nil, "a collision served the other book's cover")
end)

t.test("a truncated file is rejected", function()
    Cache.store("/books/trunc.epub", makeBB(8, 4, 77))
    -- Chop the pixel data in half, leaving the header intact.
    local key
    for entry in lfs_real.dir(DIR .. "/cache/bookshelf/scaled_covers") do
        if entry ~= "." and entry ~= ".." then
            local p = DIR .. "/cache/bookshelf/scaled_covers/" .. entry
            local f = io.open(p, "rb"); local all = f:read("*a"); f:close()
            if all:find("/books/trunc.epub", 1, true) then key = p end
        end
    end
    assert(key, "could not find the stored file")
    local f = io.open(key, "rb"); local all = f:read("*a"); f:close()
    f = io.open(key, "wb"); f:write(all:sub(1, #all - 10)); f:close()
    assert(Cache.load("/books/trunc.epub") == nil,
        "a short read must be a miss -- half a cover is a corrupt image")
end)

t.test("a file that is not ours is rejected", function()
    Cache.store("/books/bad.epub", makeBB(4, 2, 9))
    local p = assert(fileFor("/books/bad.epub"), "could not find the stored file")
    -- Valid in every respect EXCEPT the magic: right path, right geometry, a
    -- full 4*2 bytes of pixels. Only the magic can reject this one, so the
    -- test cannot pass on the truncation or collision check by accident.
    local f = io.open(p, "wb")
    f:write("NOPE 4 2 4 1 15\n/books/bad.epub\n" .. string.rep("\9", 8))
    f:close()
    assert(Cache.load("/books/bad.epub") == nil, "a bad magic must be a miss")
end)

t.test("drop removes just that book", function()
    Cache.store("/books/keep.epub", makeBB(4, 2, 1))
    Cache.store("/books/gone.epub", makeBB(4, 2, 2))
    Cache.drop("/books/gone.epub")
    assert(Cache.load("/books/gone.epub") == nil, "dropped cover is still there")
    assert(Cache.load("/books/keep.epub") ~= nil, "drop took the wrong book")
end)

t.test("clear empties the store", function()
    Cache.store("/books/x.epub", makeBB(4, 2, 3))
    assert(fileFor("/books/x.epub"), "nothing was stored to clear")
    Cache.clear()
    assert(not fileFor("/books/x.epub"), "clear left the file on disk")
    assert(Cache.load("/books/x.epub") == nil, "clear left something behind")
end)

-- ── sweep ───────────────────────────────────────────────────────────────────
-- The sweep is what bounds the store on disk, and the only thing that ever
-- removes a cover for a book the user deleted. Both halves get tested.

local BOOKS = DIR .. "/books"
lfs_real.mkdir(BOOKS)
_G.__mtimes = {}

local function makeBook(name)
    local p = BOOKS .. "/" .. name
    local f = assert(io.open(p, "wb")); f:write("x"); f:close()
    return p
end

local function ageOf(book, when)
    local p = fileFor(book)
    assert(p, "no cache file for " .. book)
    _G.__mtimes[p] = when
end

local function storeCount()
    local n = 0
    for e in lfs_real.dir(STORE) do
        if e:sub(1, 1) ~= "." then n = n + 1 end   -- not the tally
    end
    return n
end

t.test("under budget the sweep leaves everything alone", function()
    Cache.clear(); _G.__mtimes = {}
    Cache.MAX_BYTES = 32 * 1024 * 1024
    Cache.store(makeBook("k1.epub"), makeBB(8, 8, 1))
    Cache.store(makeBook("k2.epub"), makeBB(8, 8, 2))
    local before = storeCount()
    Cache.sweep()
    assert(storeCount() == before, "the sweep pruned while under budget")
end)

t.test("over budget, a deleted book's cover goes before a live one's", function()
    Cache.clear(); _G.__mtimes = {}
    Cache.MAX_BYTES = 32 * 1024 * 1024
    local gone, live = makeBook("gone.epub"), makeBook("live.epub")
    Cache.store(live, makeBB(16, 16, 1))
    Cache.store(gone, makeBB(16, 16, 2))
    -- The deleted book's cover is the NEWER of the two, so age alone would
    -- keep it and evict the live book's. Only the orphan check gets this right.
    ageOf(live, 100)
    ageOf(gone, 900)
    os.remove(gone)                 -- the book is gone; its cover is not
    Cache.MAX_BYTES = 400           -- room for roughly one
    Cache.sweep()
    assert(Cache.load(live), "the live book's cover was evicted first")
    assert(not Cache.load(gone), "the deleted book's cover survived")
end)

-- PW5, 2026-10-30: the store was over its cap (118 MB), so every session's
-- first write swept it, and an ornament's render (kept under
-- "ornament:<path>|<mtime>|<size>|<w>x<h>", bookshelf_ornaments) named no
-- file and went as an orphan. Each session decoded every piece again.
t.test("over budget, a live ornament's render is not an orphan", function()
    Cache.clear(); _G.__mtimes = {}
    Cache.MAX_BYTES = 32 * 1024 * 1024
    Cache.ORNAMENT_MAX_BYTES = 32 * 1024 * 1024
    local piece, dead = makeBook("cat.png"), makeBook("dog.png")
    local key = "ornament:" .. piece .. "|123|456|50x60"
    local dkey = "ornament:" .. dead .. "|1|2|5x5"
    Cache.store(key, makeBB(16, 16, 1))
    Cache.store(dkey, makeBB(16, 16, 2))
    ageOf(key, 100)                 -- the live piece's is the OLDER
    ageOf(dkey, 900)
    os.remove(dead)
    Cache.ORNAMENT_MAX_BYTES = 400  -- room for one
    Cache.sweep()
    assert(Cache.load(key), "a live ornament's render went as an orphan")
    assert(not Cache.load(dkey), "a deleted piece's render survived")
end)

t.test("with no orphans, the oldest goes first", function()
    Cache.clear(); _G.__mtimes = {}
    Cache.MAX_BYTES = 32 * 1024 * 1024
    local old_b, new_b = makeBook("old.epub"), makeBook("new.epub")
    Cache.store(old_b, makeBB(16, 16, 1))
    Cache.store(new_b, makeBB(16, 16, 2))
    ageOf(old_b, 100)
    ageOf(new_b, 900)
    Cache.MAX_BYTES = 400
    Cache.sweep()
    assert(Cache.load(new_b), "the newer cover was evicted")
    assert(not Cache.load(old_b), "the older cover survived")
end)

t.test("a file with no usable header is treated as an orphan", function()
    Cache.clear(); _G.__mtimes = {}
    Cache.MAX_BYTES = 32 * 1024 * 1024
    local live = makeBook("live2.epub")
    Cache.store(live, makeBB(16, 16, 1))
    -- The junk file is the NEWER of the two, so age alone would keep it and
    -- evict the usable cover. Only treating an unreadable file as an orphan
    -- gets this the right way round.
    ageOf(live, 100)
    local junk = STORE .. "/deadbeef_9"
    local fh = assert(io.open(junk, "wb")); fh:write(string.rep("?", 500)); fh:close()
    _G.__mtimes[junk] = 900
    Cache.MAX_BYTES = 400
    Cache.sweep()
    local still = io.open(junk, "rb")
    if still then still:close() end
    assert(not still, "an unreadable file survived a prune")
    assert(Cache.load(live), "a usable cover was dropped in favour of junk")
end)

-- PW5, 2026-10-31: the store held 59 MB of covers and 32 MB of ornament
-- renders (the ornament library's previews among them) against 96 MB, and
-- went by write time: a cover on Home, read every day but written weeks ago,
-- went first and was decoded again on the next visit (a first switch to a
-- shelf 2-8 s after a restart).
t.test("ornament renders have a budget of their own and never push covers out", function()
    Cache.clear(); _G.__mtimes = {}
    Cache.MAX_BYTES = 32 * 1024 * 1024
    Cache.ORNAMENT_MAX_BYTES = 32 * 1024 * 1024
    local c1, c2 = makeBook("c1.epub"), makeBook("c2.epub")
    Cache.store(c1, makeBB(16, 16, 1)); Cache.store(c2, makeBB(16, 16, 2))
    ageOf(c1, 100); ageOf(c2, 200)
    local pieces = {}
    for i = 1, 3 do
        local key = "ornament:" .. makeBook("p" .. i .. ".png") .. "|1|2|16x16"
        Cache.store(key, makeBB(16, 16, i)); ageOf(key, 900 + i)
        pieces[i] = key
    end
    Cache.MAX_BYTES = 1000          -- the two covers fit
    Cache.ORNAMENT_MAX_BYTES = 400  -- one render fits
    Cache.sweep()
    assert(Cache.load(c1) and Cache.load(c2), "ornament renders pushed a cover out")
    assert(not Cache.load(pieces[1]) and not Cache.load(pieces[2]), "renders past their budget stayed")
    assert(Cache.load(pieces[3]), "the newest render went")
end)

t.test("a cover read lately is kept over one written later and not read", function()
    Cache.clear(); _G.__mtimes = {}
    Cache.MAX_BYTES = 32 * 1024 * 1024
    local used, unused = makeBook("used.epub"), makeBook("unused.epub")
    Cache.store(used, makeBB(16, 16, 1)); Cache.store(unused, makeBB(16, 16, 2))
    ageOf(used, 100); ageOf(unused, 900)
    assert(Cache.load(used))
    Cache.MAX_BYTES = 400
    Cache.sweep()
    assert(Cache.load(used), "a cover in use went because it was written first")
    assert(not Cache.load(unused), "the unread cover stayed")
end)

-- 6.0.4 kept ornament renders under a cover's file name; under the names
-- they have now nothing reads those again, so they go first.
t.test("an ornament render under a cover's file name is an orphan", function()
    Cache.clear(); _G.__mtimes = {}
    Cache.MAX_BYTES = 32 * 1024 * 1024
    local live = makeBook("keep.epub")
    local piece = makeBook("old_piece.png")
    Cache.store(live, makeBB(16, 16, 1)); ageOf(live, 100)
    -- What 6.0.4 wrote: the render, under a plain hash name.
    local key = "ornament:" .. piece .. "|1|2|16x16"
    Cache.store(key, makeBB(16, 16, 2))
    local p = fileFor(key)
    local legacy = p:gsub("/o([0-9a-f]+_%d+)$", "/%1")
    assert(legacy ~= p, "the render's file has no ornament name")
    os.rename(p, legacy); _G.__mtimes[legacy] = 900
    Cache.MAX_BYTES = 400
    Cache.sweep()
    assert(Cache.load(live), "a cover went before a render nothing reads")
    local f = io.open(legacy, "rb"); if f then f:close() end
    assert(not f, "the old render stayed")
end)

-- A full disk crashed a PW5 (2026-10-28); 96 MB of covers is a fair part
-- of what a nearly full device has left. The budgets shrink to a share of
-- the free space plus what the store already holds.
t.test("on a nearly full disk the store keeps to a share of the room", function()
    local function three()
        Cache.clear(); _G.__mtimes = {}
        Cache.MAX_BYTES, Cache.ORNAMENT_MAX_BYTES = 32 * 1024 * 1024, 32 * 1024 * 1024
        local books = {}
        for i = 1, 3 do
            books[i] = makeBook("room" .. i .. ".epub")
            Cache.store(books[i], makeBB(16, 16, i)); ageOf(books[i], 100 * i)
        end
        Cache.MAX_BYTES, Cache.ORNAMENT_MAX_BYTES = 1200, 1200
        return books
    end
    local real_free = Cache._freeBytes
    local books = three()
    Cache._freeBytes = function() return 1024 * 1024 * 1024 end
    Cache.sweep()
    assert(Cache.load(books[1]) and Cache.load(books[2]) and Cache.load(books[3]),
        "plenty of room, yet covers went")
    books = three()
    Cache._freeBytes = function() return 0 end
    Cache.sweep()
    assert(not Cache.load(books[1]), "a full disk kept the whole store")
    books = three()
    Cache._freeBytes = function() return nil end   -- unknown: the caps as they are
    Cache.sweep()
    assert(Cache.load(books[1]) and Cache.load(books[3]), "an unknown free space shrank the store")
    Cache._freeBytes = real_free
end)

-- PW5, 2026-10-31: a full store went over its cap by a few covers every
-- session, and each time the sweep read every file's header (1,100 files,
-- 2.7 s cold) in the middle of a shelf's first build. Over the cap it now
-- goes down to a margin under it, so the next sessions stay under.
t.test("a prune leaves room, so the next sessions do not prune again", function()
    Cache.clear(); _G.__mtimes = {}
    Cache.MAX_BYTES, Cache.ORNAMENT_MAX_BYTES = 32 * 1024 * 1024, 32 * 1024 * 1024
    local real_free = Cache._freeBytes
    Cache._freeBytes = function() return nil end
    local size
    for i = 1, 10 do
        local b = makeBook("h" .. i .. ".epub")
        Cache.store(b, makeBB(16, 16, i)); ageOf(b, i)
        size = size or #select(2, fileFor(b))
    end
    Cache.MAX_BYTES = size * 9          -- one over
    Cache.sweep()
    assert(storeCount() <= math.floor(9 * Cache.PRUNE_TO), "pruned to the cap, not under it: " .. storeCount())
    Cache._freeBytes = real_free
end)

t.test("the automatic check waits, out of the shelf's build", function()
    local src = io.open("lib/bookshelf_cover_disk_cache.lua"):read("*a")
    local body = src:match("\nlocal function maybeSweep%(%)\n(.-)\nend\n")
    assert(body and body:find("scheduleIn(M.SWEEP_DELAY, M._check)", 1, true),
        "the sweep runs inside the write that set it off")
end)

-- PW5, 2026-10-31: under its cap, the session's sweep still listed and
-- stat'd every file (1,100 files, 1.25 s cold) to learn it was under. A
-- running tally of what is held answers that from one small file.
t.test("under the cap, the check reads a tally, not the whole store", function()
    Cache.clear(); _G.__mtimes = {}
    Cache.MAX_BYTES, Cache.ORNAMENT_MAX_BYTES = 32 * 1024 * 1024, 32 * 1024 * 1024
    local real_dir, real_free = lfs_real.dir, Cache._freeBytes
    Cache._freeBytes = function() return nil end
    Cache.store(makeBook("tally1.epub"), makeBB(16, 16, 1))
    Cache.sweep()                     -- an exact tally
    local listings = 0
    lfs_real.dir = function(path) listings = listings + 1; return real_dir(path) end
    Cache.store(makeBook("tally2.epub"), makeBB(16, 16, 2))
    Cache._check()
    assert(listings == 0, "an under-cap check listed the store")
    -- Over the cap by the tally: the full sweep runs.
    local size = #select(2, fileFor(BOOKS .. "/tally1.epub"))
    Cache.MAX_BYTES = size
    Cache._check()
    assert(listings > 0, "over the cap, nothing was swept")
    assert(storeCount() <= 2, "the sweep left the store over its cap")
    lfs_real.dir, Cache._freeBytes = real_dir, real_free
end)

os.execute("rm -rf '" .. DIR .. "'")
t.done()
