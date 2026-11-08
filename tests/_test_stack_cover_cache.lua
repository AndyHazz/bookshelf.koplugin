-- tests/_test_stack_cover_cache.lua
-- Covers on series and folder stacks are kept at their exact size.
--
-- A stack's cover is drawn at the book's own shape, not the grid's 2:3 slot,
-- so it never matched the one-per-book cache entry and was decoded from BIM
-- (zstd) and scaled in Lua on every paint: 60% of a page turn on a Series
-- shelf on a PW5 (1.2-1.4 s a turn). Each size now has its own entry: in
-- memory only, under the cache's budget, dropped with the book's cover.
package.path = "./?.lua;" .. package.path

package.loaded["logger"] = { dbg = function() end, warn = function() end, info = function() end }
local disk = { stores = 0, loads = 0 }
function disk.store() disk.stores = disk.stores + 1; return true end
function disk.load() disk.loads = disk.loads + 1 end
function disk.drop() end
function disk.clear() end
package.loaded["lib/bookshelf_cover_disk_cache"] = disk
package.loaded["lib/bookshelf_hero_tier"] = { drop = function() end }

local Cache = require("lib/bookshelf_scaled_cover_cache")
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq

local function bb(w, h)
    return { stride = w, getWidth = function() return w end, getHeight = function() return h end }
end

t.test("a stack cover is kept at its size, in memory only", function()
    Cache:clear(); disk.stores, disk.loads = 0, 0
    local b = bb(100, 160)
    eq(Cache:getSized("/b/a.epub", 100, 160), nil)
    eq(Cache:putSized("/b/a.epub", 100, 160, b), b)
    eq(Cache:getSized("/b/a.epub", 100, 160), b)
    eq(Cache:getSized("/b/a.epub", 100, 150), nil, "another size served the same bitmap")
    eq(Cache:get("/b/a.epub"), nil, "the grid's entry for the book answered with a stack's")
    eq(disk.stores, 0, "a stack size was written to disk")
    assert(Cache._sized_bytes > 0, "a stack cover is not counted against a budget")
end)

t.test("dropping a book's cover drops its stack sizes, and only its", function()
    Cache:clear()
    Cache:putSized("/b/a.epub", 100, 160, bb(100, 160))
    Cache:putSized("/b/a.epub", 80, 120, bb(80, 120))
    Cache:putSized("/b/ab.epub", 100, 160, bb(100, 160))
    Cache:drop("/b/a.epub")
    eq(Cache:getSized("/b/a.epub", 100, 160), nil, "a replaced cover's old art stays on its stacks")
    eq(Cache:getSized("/b/a.epub", 80, 120), nil)
    assert(Cache:getSized("/b/ab.epub", 100, 160), "another book's stack cover went with it")
end)

t.test("shelf covers coming and going never push the sized copies out", function()
    -- On a PW5 a cycle through six shelves pushed ~8 MB of shelf covers
    -- through the 24 MB cache; the sized copies shared its LRU and were
    -- made again on every visit.
    Cache:clear()
    Cache:setByteBudget(1000)
    local th = bb(10, 10)
    Cache:putSized("/b/t.epub", 10, 10, th)
    for i = 1, 50 do Cache:put("/b/big" .. i, bb(30, 30)) end
    eq(Cache:getSized("/b/t.epub", 10, 10), th, "a sized copy went out with the shelf covers")
    Cache:setByteBudget(24 * 1024 * 1024)
end)

t.test("the sized copies keep to their own budget", function()
    Cache:clear()
    local budget = Cache:sizedBudget()
    local each = 100 * 100
    local n = math.floor(budget / each) + 10
    for i = 1, n do Cache:putSized("/b/" .. i, 100, 100, bb(100, 100)) end
    assert(Cache._sized_bytes <= budget, "over its budget")
    eq(Cache:getSized("/b/1", 100, 100), nil, "the oldest was never let go")
    assert(Cache:getSized("/b/" .. n, 100, 100), "the newest was let go")
end)

t.test("dropping every cover in memory (a contrast change) drops the sized copies", function()
    Cache:clear()
    Cache:putSized("/b/a.epub", 10, 10, bb(10, 10))
    Cache:dropMemory()
    eq(Cache:getSized("/b/a.epub", 10, 10), nil, "a copy boosted at the old strength stayed")
end)

t.test("a stack's cover and a thumbnail of the same size are kept apart", function()
    Cache:clear()
    local top, thumb = bb(100, 160), bb(100, 160)
    Cache:putSized("/b/a.epub", 100, 160, top, "top")
    Cache:putSized("/b/a.epub", 100, 160, thumb)
    eq(Cache:getSized("/b/a.epub", 100, 160, "top"), top)
    eq(Cache:getSized("/b/a.epub", 100, 160), thumb)
    Cache:drop("/b/a.epub")
    eq(Cache:getSized("/b/a.epub", 100, 160, "top"), nil, "a tagged copy outlived its cover")
end)

t.test("the stack path reads its size before decoding, and keeps what it scales", function()
    local SW = io.open("lib/bookshelf_spine_widget.lua"):read("*a")
    local body = assert(SW:match("\nfunction SpineWidget:_renderCoverAlignTop%(.-\nend\n"))
    local g = body:find([[ScaledCoverCache:getSized(fp, img_w, nat_h, "top")]], 1, true)
    local d = body:find("_getRepo().getCoverBB(fp)", 1, true)
    assert(g and d and g < d, "the stack cover is decoded before its kept copy is looked for")
    assert(body:find([[ScaledCoverCache:putSized(fp, img_w, nat_h, scaled_bb, "top")]], 1, true), "the scaled stack cover is not kept")
end)

t.done()
