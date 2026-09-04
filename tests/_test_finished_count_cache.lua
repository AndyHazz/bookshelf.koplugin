-- tests/_test_finished_count_cache.lua
-- Repo.countFinishedBooks stats every sidecar in the library (~650ms for 243
-- books on a PW5). A status line naming %books_read puts that on the hero's
-- critical path, so it was paid again on every launch. The count is now stored
-- and adopted on the first access after a restart: hero 1595ms -> ~854ms.
--
-- Correctness rests entirely on the INVALIDATION, not on a short TTL, so that
-- is what these pin. A stale count is silent -- the shelf shows a wrong number
-- and nothing errors -- which is exactly the failure no other test would catch.
--
-- SOURCE-SHAPE checks: the store is a module local behind pcall'd requires for
-- persist/datastorage, neither of which the repository suite stubs.
package.path = "./?.lua;./?/init.lua;" .. package.path

local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()

local src   = io.open("lib/bookshelf_book_repository.lua"):read("*a")
-- The walked count and the public one are separate: the walk is what gets
-- stored, and Repo.countFinishedBooks adds the Kindle library on top of it.
local count = src:match("\nlocal function _finishedCountWalked%(%)\n(.-)\nend\n")
local pub   = src:match("\nfunction Repo%.countFinishedBooks%(%)\n(.-)\nend\n")
local prog  = src:match("\nfunction Repo%.invalidateProgressCache%(filepath%)\n(.-)\nend\n")
local walk  = src:match("\nfunction Repo%.invalidateWalkCache%(%)\n(.-)\nend\n")

t.test("the four functions are still there", function()
    assert(count, "_finishedCountWalked is gone or was renamed")
    assert(pub,   "Repo.countFinishedBooks is gone or was renamed")
    assert(prog,  "Repo.invalidateProgressCache is gone or was renamed")
    assert(walk,  "Repo.invalidateWalkCache is gone or was renamed")
end)

t.test("the stored count is adopted instead of re-walking", function()
    assert(count:match("_loadFinishedCount%(%)"),
        "the count must consult the store before walking, or every launch "
        .. "stats every sidecar again")
    assert(count:match("_saveFinishedCount"),
        "a fresh count must be stored, or the next launch walks again")
end)

t.test("a status change drops the stored count", function()
    -- invalidateProgressCache is what fires on a status change or metadata
    -- edit. Miss this and finishing a book leaves the old number on screen
    -- until the 24h backstop expires.
    assert(prog:match("_dropFinishedCount%(%)"),
        "invalidateProgressCache must drop the stored count")
    assert(prog:match("_finished_count%.value = nil"),
        "it must drop the in-memory value too, or the store is cleared while "
        .. "a stale number keeps being served from memory")
end)

t.test("a library change drops it as well", function()
    assert(walk:match("_dropFinishedCount%(%)"),
        "invalidateWalkCache must drop the stored count -- books added or "
        .. "removed change what there is to count")
end)

t.test("the Kindle share is never persisted", function()
    -- The store is trustworthy only because every LOCAL mutation drops it.
    -- Nothing drops it when a Kindle status changes, so a Kindle contribution
    -- baked into the stored value would be served stale for up to 24h. The
    -- public function must therefore add it outside the cached/stored path.
    assert(not count:match("_kindleStatusCounts"),
        "the walked count is what gets stored -- it must not fold in Kindle "
        .. "books, or a stale Kindle tally survives a restart")
    assert(pub:match("_kindleStatusCounts%(%)"),
        "Repo.countFinishedBooks must add the Kindle share itself")
    assert(not pub:match("_saveFinishedCount"),
        "the public count must not persist its total -- only the walk is stored")
end)

t.test("a TTL backstops a status changed behind our back", function()
    -- A sync from another device can change a status without going through
    -- either invalidation. The old in-memory cache had a 60s TTL that caught
    -- that; persistence must not lose it entirely.
    assert(src:match("FINISHED_COUNT_TTL"),
        "the stored count needs an expiry, or a status changed off-device is "
        .. "never noticed")
end)

t.done()
