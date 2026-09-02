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
package.loaded["datastorage"] = { getDataDir = function() return DIR end }

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
local BB = package.loaded["ffi/blitbuffer"]

local STORE = DIR .. "/cache/bookshelf_covers"

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
    for entry in lfs_real.dir(DIR .. "/cache/bookshelf_covers") do
        if entry ~= "." and entry ~= ".." then
            local p = DIR .. "/cache/bookshelf_covers/" .. entry
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
        if e ~= "." and e ~= ".." then n = n + 1 end
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

os.execute("rm -rf '" .. DIR .. "'")
t.done()
