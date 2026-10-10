-- tests/_test_series_recent_sort.lua
-- "Most recently read" on a series shelf (Reddit, 2026-10-10): standalone
-- books never opened took their FILE date as their read time, so a newly
-- added unread book sorted first, ahead of everything read, and the next
-- sort key (title) never reached the unread ones. A standalone's latest is
-- now its read time only, as the author and genre shelves already do
-- ("Adding a book to the device doesn't count as reading it").
--
-- Usage (from plugin root): lua tests/_test_series_recent_sort.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()
local repo = io.open("lib/bookshelf_book_repository.lua"):read("*a")

t.test("a standalone's latest is its read time, never its file date", function()
    local std = repo:match("standalones%[#standalones %+ 1%] = {(.-)\n            }")
    assert(std, "the standalone shape moved")
    assert(std:find("latest       = read_time[book.filepath] or 0,", 1, true),
        "an unread standalone sorts by its file date under Most recently read")
    assert(not std:find("read_time[book.filepath] or c.mtime", 1, true))
    assert(std:find("latest_added = c.mtime or 0,", 1, true), "date added lost its file date")
end)

t.test("a series' latest is its members' read time; a new unread book does not bring it forward", function()
    -- Maintainer, 2026-10-10: "Adding a book shouldn't count as reading it.
    -- Only when sorting by recently added should a series get bumped".
    assert(repo:find("local t = read_time[book.filepath] or 0\n            if t > g.latest then g.latest = t end", 1, true),
        "a series still takes its members' file dates as read time")
    assert(not repo:find("read_time[book.filepath] or c.mtime", 1, true), "a file date still counts as reading")
    assert(repo:find("if added > (g.latest_added or 0) then g.latest_added = added end", 1, true),
        "Most recently added lost the series' newest file date")
end)

t.test("the author and genre shelves keep read time only", function()
    assert(repo:find("local rt = read_time[book.filepath]\n                        if rt and rt > g.latest then g.latest = rt end", 1, true))
end)

t.done()
