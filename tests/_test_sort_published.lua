-- tests/_test_sort_published.lua
-- Sort by publication year (issue 580): the year %published shows, oldest
-- first; books with no known year at the end either way; the answers are
-- remembered per record and dropped when background reads bring new dates.
-- Run from the plugin root: lua tests/_test_sort_published.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
package.loaded["logger"] = { dbg = function() end, info = function() end,
                             warn = function() end, err = function() end }
package.preload["lib/bookshelf_author_name"] = function()
    return dofile("lib/bookshelf_author_name.lua")
end
local years, asked = {}, 0
package.loaded["lib/bookshelf_published"] = {
    forRecord = function(b) asked = asked + 1; return years[b.filepath] or "" end,
}
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq
local SortEngine = dofile("lib/bookshelf_sort_engine.lua")

local function order(list)
    local out = {}
    for i, b in ipairs(list) do out[i] = b.filepath end
    return table.concat(out, ",")
end
local function books() return {
    { filepath = "/new", title = "A" }, { filepath = "/none", title = "B" },
    { filepath = "/old", title = "C" }, { filepath = "/mid", title = "D" },
} end

t.test("the key is registered and offered in the picker", function()
    local k = SortEngine.KEYS.published
    assert(k and type(k.comparator) == "function", "no published key")
    local offered = false
    for _i, key in ipairs(SortEngine.ORDER) do if key == "published" then offered = true end end
    assert(offered, "not in ORDER, so the picker never shows it")
end)

t.test("oldest first; a book with no year goes to the end", function()
    years = { ["/new"] = "2020", ["/old"] = "1850", ["/mid"] = "1923" }
    SortEngine.clearPublishedMemo()
    eq(order(SortEngine.sort(books(), { { key = "published" } })), "/old,/mid,/new,/none")
end)

t.test("reversed: newest first, and still no year at the end", function()
    years = { ["/new"] = "2020", ["/old"] = "1850", ["/mid"] = "1923" }
    SortEngine.clearPublishedMemo()
    eq(order(SortEngine.sort(books(), { { key = "published", reverse = true } })), "/new,/mid,/old,/none")
end)

t.test("each record is asked once per sort, not on every comparison", function()
    years = { ["/new"] = "2020", ["/old"] = "1850", ["/mid"] = "1923" }
    SortEngine.clearPublishedMemo()
    asked = 0
    SortEngine.sort(books(), { { key = "published" } })
    assert(asked <= 4, "asked " .. asked .. " times for 4 books")
end)

t.test("a date read later is seen once the memo is cleared", function()
    years = {}
    SortEngine.clearPublishedMemo()
    local list = books()
    SortEngine.sort(list, { { key = "published" } })
    years = { ["/none"] = "1700" }
    SortEngine.clearPublishedMemo()
    SortEngine.sort(list, { { key = "published" } })
    eq(list[1].filepath, "/none")
end)

t.test("wiring: new dates clear the memo; a year-sorted shelf re-sorts, debounced", function()
    local pub = io.open("lib/bookshelf_published.lua"):read("*a")
    assert(pub:find('require("lib/bookshelf_sort_engine").clearPublishedMemo()', 1, true),
        "background dates must clear the sort's memo")
    local w = io.open("lib/bookshelf_widget.lua"):read("*a")
    local body = w:match("\nfunction BookshelfWidget:_refreshPublished%(fps%)\n(.-)\nend\n")
    assert(body and body:find("self:_sortsByPublished()", 1, true), "no re-sort for a year-sorted shelf")
    assert(body:find("UIManager:unschedule(self._published_resort)", 1, true), "re-sort is not debounced")
    assert(body:find('Repo.invalidateBookCache("published")', 1, true), "the sorted lists keep the old order")
end)

t.test("a folder view's file entry (fp, attr) sorts by its year too", function()
    years = { ["/f/old.epub"] = "1850", ["/f/new.epub"] = "2020" }
    SortEngine.clearPublishedMemo()
    local list = { { name = "new.epub", fp = "/f/new.epub", attr = { mode = "file" } },
                   { name = "old.epub", fp = "/f/old.epub", attr = { mode = "file" } },
                   { name = "Sub", fp = "/f/Sub", attr = { mode = "directory" } } }
    SortEngine.sort(list, { { key = "published" } })
    eq(list[1].fp, "/f/old.epub"); eq(list[2].fp, "/f/new.epub")
end)

t.test("the shelf editor offers it, with dated directions", function()
    local ed = io.open("lib/bookshelf_chip_editor.lua"):read("*a")
    assert(ed:find('add(chips({ "title", "author_name", "author_surname", "filename", "published" }))', 1, true),
        "Publication year is not on the Sort page")
    assert(ed:find('if key == "last_opened" or key == "date_added" or key == "added_or_opened"\n            or key == "published" then', 1, true),
        "its directions read A-Z / Z-A")
    assert(ed:find("    published    = true,", 1, true), "it should default to newest first")
end)

t.done()
