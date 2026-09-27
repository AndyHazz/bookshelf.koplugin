-- tests/_test_filter_keeps_progress.lua
-- Issue 463: a shelf with a status filter, sorted by Progress, came out in
-- title order. The filter pass read each book's sidecar for its status, set
-- _progress_fetched, and dropped the percentage it had just read; the sort's
-- prefetch then skipped every book so marked, so they reached the sort with a
-- status and no percentage, all tied, and fell back to the title. Whatever
-- the filter pass reads it must keep, because the mark says it was read.
-- Run from the plugin root: lua tests/_test_filter_keeps_progress.lua
package.path = "./?.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()
local src = io.open("lib/bookshelf_book_repository.lua"):read("*a")
local body = src:match("_recordMatches = function%(b, compiled%).-\nend\n")

t.test("the filter pass keeps the percentage and page count it reads", function()
    assert(body, "_recordMatches moved")
    assert(body:find("b._pct", 1, true), "the percentage read for the filter is thrown away")
    assert(body:find("b.page_count", 1, true), "the page count read for the filter is thrown away")
    assert(body:find("_progress_fetched = true", 1, true))
end)

t.done()
