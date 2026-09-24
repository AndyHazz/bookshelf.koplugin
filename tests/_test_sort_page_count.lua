-- tests/_test_sort_page_count.lua
-- The Pages sort orders by extracted page counts too.
--
-- Usage (from plugin root): lua tests/_test_sort_page_count.lua
--
-- Reddit report: "I'd like to have a chip that sorts books by length, but at
-- the moment it doesn't appear that it works with the extracted numbers."
-- Sort paths hand the comparator light records, which carry no count for a
-- reflowable book; the one path that backfilled skipped every book without a
-- sidecar, which is every book "Extract page counts" is for.

package.path = "./?.lua;./?/init.lua;" .. package.path
package.loaded["logger"] = { dbg = function() end, info = function() end,
                              warn = function() end, err = function() end }
package.preload["lib/bookshelf_author_name"] = function()
    return dofile("lib/bookshelf_author_name.lua")
end
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local SortEngine = dofile("lib/bookshelf_sort_engine.lua")

local store, asked = {}, 0
SortEngine.setPageCountResolver(function(fp) asked = asked + 1; return store[fp] end)

local function order(recs)
    SortEngine.sort(recs, { { key = "page_count", reverse = false } })
    local out = {}
    for i, r in ipairs(recs) do out[i] = r.filepath end
    return table.concat(out, ",")
end

t.test("a record with no count of its own sorts by the resolved one", function()
    SortEngine.clearPageCountMemo()
    store = { ["/b"] = 900, ["/c"] = 120 }
    local recs = { { filepath = "/a", page_count = 400 }, { filepath = "/b" }, { filepath = "/c" } }
    eq(order(recs), "/c,/a,/b")
end)

t.test("the record's own count wins over the resolver", function()
    SortEngine.clearPageCountMemo()
    store = { ["/a"] = 1 }
    local recs = { { filepath = "/a", page_count = 500 }, { filepath = "/b", page_count = 200 } }
    eq(order(recs), "/b,/a")
end)

t.test("asked once per record, not once per comparison", function()
    SortEngine.clearPageCountMemo()
    store, asked = {}, 0
    local recs = {}
    for i = 1, 40 do
        store["/" .. i] = (i * 37) % 101
        recs[i] = { filepath = "/" .. i }
    end
    order(recs)
    eq(asked, 40)
end)

t.test("a book with no count anywhere still sorts, and is not asked again", function()
    SortEngine.clearPageCountMemo()
    store, asked = {}, 0
    local rec = { filepath = "/none" }
    order({ rec, { filepath = "/x", page_count = 3 } })
    order({ rec, { filepath = "/x", page_count = 3 } })
    eq(asked, 1)
end)

t.test("clearing the memo picks up a new scan's counts", function()
    SortEngine.clearPageCountMemo()
    store = { ["/a"] = 100, ["/b"] = 200 }
    local recs = { { filepath = "/a" }, { filepath = "/b" } }
    eq(order(recs), "/a,/b")
    store = { ["/a"] = 300, ["/b"] = 200 }
    eq(order(recs), "/a,/b", "the memo should still answer until cleared")
    SortEngine.clearPageCountMemo()
    eq(order(recs), "/b,/a")
end)

t.done()
