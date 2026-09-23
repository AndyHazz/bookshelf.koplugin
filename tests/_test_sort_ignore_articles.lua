-- tests/_test_sort_ignore_articles.lua
-- "Ignore The, A, An when sorting" (issue 428), and the sorted caches that
-- have to notice it.
--
-- Usage (from plugin root): lua tests/_test_sort_ignore_articles.lua
--
-- On (the default): titles sort by calibre's title_sort, else with a leading
-- article dropped; series names drop it too (issue 412). Off: both sort
-- exactly as written. The flag rides the key epoch the pinyin setting uses,
-- since the keys are memoised on every record.
--
-- The repository caches SORTED results keyed by the chip's sort levels. A
-- setting that changes how a key is derived is not a level, so both caches
-- kept serving the old order after the toggle (seen on the desktop rig, and
-- the pinyin row had the same gap). SortEngine.keySignature names those
-- settings and both cache keys carry it.

package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local store, gen = {}, 0
package.loaded["lib/bookshelf_settings_store"] = {
    read = function(k) return store[k] end,
    generation = function() return gen end,
}
package.loaded["lib/bookshelf_sort_engine"] = nil
local SortEngine = dofile("lib/bookshelf_sort_engine.lua")

local function set(k, v) store[k] = v; gen = gen + 1 end

local function order(books)
    table.sort(books, SortEngine.chainedComparator({ { key = "title", reverse = false } }))
    local out = {}
    for i, b in ipairs(books) do out[i] = b.title end
    return table.concat(out, ", ")
end

local function shelf()
    return {
        { title = "The Zebra" },
        { title = "Apple" },
        { title = "A Mango", title_sort = "Mango, A" },
    }
end

t.test("on by default: the article is ignored, title_sort honoured", function()
    set("sort_ignore_articles", nil)
    eq(order(shelf()), "Apple, A Mango, The Zebra")
end)

t.test("off: as written, title_sort included", function()
    set("sort_ignore_articles", false)
    eq(order(shelf()), "A Mango, Apple, The Zebra")
end)

t.test("records sorted before the toggle are re-keyed after it", function()
    set("sort_ignore_articles", nil)
    local books = shelf()
    eq(order(books), "Apple, A Mango, The Zebra")
    set("sort_ignore_articles", false)
    eq(order(books), "A Mango, Apple, The Zebra", "a memoised key survived the toggle")
end)

t.test("the key signature changes with the setting", function()
    set("sort_ignore_articles", nil)
    local on = SortEngine.keySignature()
    set("sort_ignore_articles", false)
    assert(SortEngine.keySignature() ~= on)
end)

t.test("both repository sort caches carry the signature", function()
    local repo = io.open("lib/bookshelf_book_repository.lua"):read("*a")
    local n = select(2, repo:gsub("SortEngine%.keySignature%(%)", ""))
    eq(n, 2, "a sorted cache ignores how its keys are derived")
end)

t.done()
