-- tests/_test_scaled_cover_cache_disk.lua
-- Pure-Lua tests for the disk backing wired into ScaledCoverCache.
--
-- The disk module itself is covered by _test_cover_disk_cache.lua against real
-- files. What is left to pin is the WIRING, which is where the subtle bugs
-- live: which cache operations mirror to disk, which deliberately do not, and
-- whether a mirror happens on the path where nothing is resident in memory.
-- A fake disk module makes each of those observable.

package.path = "./?.lua;" .. package.path

package.loaded["logger"] = { dbg = function() end, warn = function() end, info = function() end }

-- Fake disk store. Records calls so the tests can assert on them.
local disk = { files = {}, stores = 0, loads = 0, drops = 0, clears = 0, fail_store = false }
function disk.store(fp, bb)
    disk.stores = disk.stores + 1
    if disk.fail_store then return false end
    disk.files[fp] = bb
    return true
end
function disk.load(fp)  disk.loads  = disk.loads  + 1; return disk.files[fp] end
function disk.drop(fp)  disk.drops  = disk.drops  + 1; disk.files[fp] = nil end
function disk.clear()   disk.clears = disk.clears + 1; disk.files = {} end
package.loaded["lib/bookshelf_cover_disk_cache"] = disk

local Cache = require("lib/bookshelf_scaled_cover_cache")
local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()

local function bb(w, h)
    return {
        stride = w,
        getWidth  = function() return w end,
        getHeight = function() return h end,
    }
end

local function reset()
    Cache:clear()
    disk.files, disk.stores, disk.loads = {}, 0, 0
    disk.drops, disk.clears, disk.fail_store = 0, 0, false
end

t.test("a scaled cover is written through to disk", function()
    reset()
    Cache:put("/b/a.epub", bb(10, 10))
    assert(disk.files["/b/a.epub"], "put did not reach the disk")
end)

t.test("get serves a cover from disk when memory is empty", function()
    reset()
    disk.files["/b/cold.epub"] = bb(10, 10)
    local got = Cache:get("/b/cold.epub")
    assert(got, "a cold get missed a cover that was on disk")
    assert(got:getWidth() == 10, "wrong cover came back")
end)

t.test("has finds a disk cover, which is what skips the decode", function()
    reset()
    disk.files["/b/cold.epub"] = bb(10, 10)
    -- has()==true is what makes the caller pass want_cover=false and skip
    -- BIM's zstd decompress. If it only ever consulted memory, a fresh launch
    -- would decode every cover and the disk cache would buy nothing.
    assert(Cache:has("/b/cold.epub"), "has ignored the disk cache")
end)

t.test("hydrating from disk does not write the same bytes back", function()
    reset()
    disk.files["/b/cold.epub"] = bb(10, 10)
    Cache:get("/b/cold.epub")
    assert(disk.stores == 0, "a cover read from disk was written straight back")
end)

t.test("a repeat probe for an absent cover does not re-read the disk", function()
    reset()
    Cache:has("/b/missing.epub")
    Cache:has("/b/missing.epub")
    Cache:has("/b/missing.epub")
    assert(disk.loads == 1, "each probe hit the disk; expected one, got " .. disk.loads)
end)

t.test("drop removes the disk copy even when nothing is resident", function()
    reset()
    disk.files["/b/stale.epub"] = bb(10, 10)
    -- The case that matters: on a fresh launch nothing is in memory, and this
    -- is exactly when BIM reports a re-extracted cover. An early "not resident,
    -- nothing to do" return here would leave the superseded cover on disk and
    -- repaint it on every launch from then on.
    Cache:drop("/b/stale.epub")
    assert(disk.files["/b/stale.epub"] == nil, "stale cover survived on disk")
end)

t.test("a dropped cover is not silently re-hydrated afterwards", function()
    reset()
    disk.files["/b/stale.epub"] = bb(10, 10)
    Cache:drop("/b/stale.epub")
    assert(Cache:get("/b/stale.epub") == nil, "the dropped cover came back")
end)

t.test("clear wipes the disk copies too", function()
    reset()
    Cache:put("/b/a.epub", bb(10, 10))
    Cache:clear()
    assert(disk.clears == 1, "clear did not reach the disk")
    assert(next(disk.files) == nil, "clear left covers on disk")
end)

t.test("evicting for memory pressure keeps the cover on disk", function()
    reset()
    -- Eviction means "RAM is tight", never "this cover is wrong". Mirroring it
    -- to disk would evict the persisted copy on the very launch that filled
    -- the cache, and the feature would never survive a session.
    Cache:setByteBudget(150)
    Cache:put("/b/one.epub", bb(10, 10))   -- 100 bytes
    Cache:put("/b/two.epub", bb(10, 10))   -- pushes past the budget
    assert(Cache._cache["/b/one.epub"] == nil, "test is not evicting; budget too high")
    assert(disk.files["/b/one.epub"], "eviction deleted the persisted cover")
    Cache:setByteBudget(24 * 1024 * 1024)
end)

t.test("a cover rejected by prefer-larger is not written to disk", function()
    reset()
    Cache:put("/b/a.epub", bb(20, 20))
    local before = disk.stores
    Cache:put("/b/a.epub", bb(5, 5))       -- smaller: rejected, existing kept
    assert(disk.stores == before, "a rejected smaller cover overwrote the disk copy")
    assert(disk.files["/b/a.epub"]:getWidth() == 20, "the disk copy was downgraded")
end)

t.test("a failed disk write leaves the memory cache working", function()
    reset()
    disk.fail_store = true
    local got = Cache:put("/b/a.epub", bb(10, 10))
    assert(got, "put returned nothing when the disk write failed")
    assert(Cache:get("/b/a.epub"), "a full disk broke the in-memory cache")
end)

t.done()
