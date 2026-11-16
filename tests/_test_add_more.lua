-- tests/_test_add_more.lua
-- "Add more": the ways to add the books that go with one book (its series,
-- its author, its folder), and the order they go in.
--
-- Usage (from plugin root): lua tests/_test_add_more.lua

package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local AddMore = dofile("lib/bookshelf_add_more.lua")

local function joined(list) return table.concat(list, " ") end
local function way(ways, kind, name)
    for _i, w in ipairs(ways) do
        if w.kind == kind and (name == nil or w.name == name) then return w end
    end
end

-- Three books of Strike, one Potter, one by the same author in no series.
local strike = { "/lib/g/strike1.epub", "/lib/g/strike2.epub", "/lib/g/strike3.epub" }
local data = {
    series = { Strike = strike, Potter = { "/lib/r/hp1.epub" } },
    author = {
        ["Robert Galbraith"] = { "/lib/g/solo.epub", "/lib/g/strike3.epub", "/lib/g/strike1.epub", "/lib/g/strike2.epub", "/lib/r/hp1.epub" },
        ["J. K. Rowling"] = { "/lib/r/hp1.epub" },
    },
    folder = { "/lib/g/strike2.epub", "/lib/g/solo.epub", "/lib/g/strike1.epub", "/lib/g/strike3.epub" },
    folder_name = "g",
}
local book = { filepath = "/lib/g/strike1.epub", series_name = "Strike", author = "Robert Galbraith",
               authors = { "Robert Galbraith" } }

t.test("the series comes in the series' own order, with this book in it", function()
    local w = way(AddMore.ways(book, data), "series", "Strike")
    eq(joined(w.paths), joined(strike))
end)

t.test("an author's books keep each series together, in order, books in no series last", function()
    local w = way(AddMore.ways(book, data), "author", "Robert Galbraith")
    eq(joined(w.paths), "/lib/r/hp1.epub /lib/g/strike1.epub /lib/g/strike2.epub /lib/g/strike3.epub /lib/g/solo.epub")
end)

t.test("the folder is ordered the same way", function()
    local w = way(AddMore.ways(book, data), "folder")
    eq(w.name, "g")
    eq(joined(w.paths), "/lib/g/strike1.epub /lib/g/strike2.epub /lib/g/strike3.epub /lib/g/solo.epub")
end)

t.test("a way that adds the same books as an earlier one is not offered twice", function()
    local only = { series = { S = { "/a/1", "/a/2" } }, author = { A = { "/a/2", "/a/1" } } }
    local ways = AddMore.ways({ filepath = "/a/1", series_name = "S", author = "A", authors = { "A" } }, only)
    eq(#ways, 1)
    eq(ways[1].kind, "series")
end)

t.test("a way that would add only this book is not offered", function()
    local lone = { series = {}, author = { A = { "/a/1" } }, folder = { "/a/1" }, folder_name = "a" }
    eq(#AddMore.ways({ filepath = "/a/1", author = "A", authors = { "A" } }, lone), 0)
end)

t.test("a book with a crowd of authors offers the first two", function()
    local crowd = { series = {}, author = { A = { "/a/1", "/a/2" }, B = { "/a/1", "/a/3" }, C = { "/a/1", "/a/4" } } }
    local ways = AddMore.ways({ filepath = "/a/1", authors = { "A", "B", "C" } }, crowd)
    eq(#ways, 2)
    eq(ways[1].name, "A"); eq(ways[2].name, "B")
end)

t.test("a single author field is used when there is no list of authors", function()
    local d = { series = {}, author = { A = { "/a/1", "/a/2" } } }
    eq(#AddMore.ways({ filepath = "/a/1", author = "A" }, d), 1)
end)

t.test("a book with no series, author or folder has nothing more to add", function()
    eq(#AddMore.ways({ filepath = "/a/1" }, { series = {}, author = {} }), 0)
    eq(#AddMore.ways(nil, data), 0)
    eq(#AddMore.ways(book, nil), 0)
end)

t.test("reading order: series by name, then place in the series, then no series by file name", function()
    local place = AddMore.placeFrom({ B = { "/b1", "/b2" }, A = { "/a1" } })
    eq(joined(AddMore.readingOrder({ "/z-solo", "/b2", "/a1", "/b1", "/c-solo" }, place)),
       "/a1 /b1 /b2 /c-solo /z-solo")
end)

t.test("reading order with no series information is by file name", function()
    eq(joined(AddMore.readingOrder({ "/x/b.epub", "/x/A.epub", "/x/c.epub" }, nil)), "/x/A.epub /x/b.epub /x/c.epub")
end)

t.test("the confirmation threshold is a handful of books", function()
    eq(AddMore.CONFIRM_ABOVE, 10)
end)

t.done()
