-- tests/_test_scaled_cover_cache_deferred.lua
-- A cover's disk copy is written after the turn, not during it.
--
-- put() wrote each new cover to the disk cache as it was made: 20-26 ms a
-- cover on a PW5, on the turn, so ~180 ms of a page of nine never-seen
-- covers (Spines, Face out). With KOReader's event loop there, the write is
-- queued and made once covers stop arriving (a pause), a few at a time.
-- Without it (tests, standalone) it stays immediate: _test_scaled_cover_cache_disk.
package.path = "./?.lua;" .. package.path
package.loaded["logger"] = { dbg = function() end, warn = function() end, info = function() end }

local now = 100
package.loaded["lib/bookshelf_gettime"] = function() return now end
local queue = {}
package.loaded["ui/uimanager"] = {
    scheduleIn = function(_um, delay, fn) queue[#queue + 1] = { at = now + delay, fn = fn } end,
}
local boost = 0
package.loaded["lib/bookshelf_image_contrast"] = {
    boost = function() return boost end,
    isBoosted = function() return false end,
    boostImage = function() end,
}
local disk = { files = {}, stores = 0 }
function disk.store(fp, bb) disk.stores = disk.stores + 1; disk.files[fp] = bb; return true end
function disk.load(fp) return disk.files[fp] end
function disk.drop(fp) disk.files[fp] = nil end
function disk.clear() disk.files = {} end
package.loaded["lib/bookshelf_cover_disk_cache"] = disk

local Cache = require("lib/bookshelf_scaled_cover_cache")
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq

local function bb(w, h) return { stride = w, getWidth = function() return w end, getHeight = function() return h end } end
local function reset()
    Cache:clear(); queue = {}; disk.files, disk.stores = {}, 0; boost = 0; now = 100
end
-- Run what is due, as the event loop would, until `untilT`.
local function runUntil(untilT)
    while true do
        table.sort(queue, function(a, b) return a.at < b.at end)
        local nxt = queue[1]
        if not nxt or nxt.at > untilT then break end
        table.remove(queue, 1)
        now = nxt.at
        nxt.fn()
    end
    now = untilT
end

t.test("a new cover is not written on the turn, but after a pause", function()
    reset()
    Cache:put("/b/a.epub", bb(10, 10))
    eq(disk.stores, 0)
    runUntil(now + Cache.DISK_WRITE_DELAY_S + 1)
    eq(disk.stores, 1)
    assert(disk.files["/b/a.epub"], "it was never written")
end)

t.test("covers still arriving keep the writes waiting", function()
    reset()
    Cache:put("/b/a.epub", bb(10, 10))
    runUntil(now + Cache.DISK_WRITE_DELAY_S * 0.6)
    Cache:put("/b/b.epub", bb(10, 10))       -- the next turn
    runUntil(now + Cache.DISK_WRITE_DELAY_S * 0.6)
    eq(disk.stores, 0)
    runUntil(now + Cache.DISK_WRITE_DELAY_S + 1)
    eq(disk.stores, 2)
end)

t.test("a cover dropped before its write is not written back", function()
    -- drop() means its source changed: writing the old copy afterwards would
    -- bring the replaced cover back on every launch.
    reset()
    Cache:put("/b/a.epub", bb(10, 10))
    Cache:drop("/b/a.epub")
    runUntil(now + Cache.DISK_WRITE_DELAY_S + 1)
    eq(disk.files["/b/a.epub"], nil)
end)

t.test("Clear cover cache cancels every write still waiting", function()
    reset()
    Cache:put("/b/a.epub", bb(10, 10))
    Cache:put("/b/b.epub", bb(10, 10))
    Cache:clear()
    runUntil(now + Cache.DISK_WRITE_DELAY_S + 1)
    eq(disk.stores, 0)
end)

t.test("a larger copy replaces the waiting one: written once, the larger", function()
    reset()
    Cache:put("/b/a.epub", bb(10, 10))
    local big = bb(20, 20)
    Cache:put("/b/a.epub", big)
    runUntil(now + Cache.DISK_WRITE_DELAY_S + 1)
    eq(disk.stores, 1)
    eq(disk.files["/b/a.epub"], big)
end)

t.test("with Image contrast on, written at once: the raw copy, before the boost", function()
    reset()
    boost = 3
    Cache:put("/b/a.epub", bb(10, 10))
    eq(disk.stores, 1)
end)

t.test("flushWrites writes what is waiting now (suspend, exit)", function()
    reset()
    Cache:put("/b/a.epub", bb(10, 10))
    Cache:put("/b/b.epub", bb(10, 10))
    Cache:flushWrites()
    eq(disk.stores, 2)
    runUntil(now + Cache.DISK_WRITE_DELAY_S + 1)
    eq(disk.stores, 2)                      -- nothing written twice
end)

t.test("the shelf flushes them on suspend and on KOReader's settings flush", function()
    local w = io.open("lib/bookshelf_widget.lua"):read("*a")
    for _i, name in ipairs({ "onSuspend", "onFlushSettings" }) do
        local body = assert(w:match("\nfunction BookshelfWidget:" .. name .. "%(%)\n(.-)\nend\n"))
        assert(body:find("flushCoverWrites()", 1, true), name .. " does not flush the cover writes")
    end
    assert(w:find("if type(SCC) == \"table\" and SCC.flushWrites then pcall(SCC.flushWrites, SCC) end", 1, true),
        "flushCoverWrites does not reach the cache")
end)

t.done()
