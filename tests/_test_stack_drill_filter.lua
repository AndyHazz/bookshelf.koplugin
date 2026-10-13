-- tests/_test_stack_drill_filter.lua
-- GitHub issue 485: on a Series shelf with an extra filter (genre, language),
-- opening a stack showed only its first book. A stack's members are stubs
-- ({ filepath }) apart from its lead book, and the drill re-ran the shelf's
-- filter on those stubs: no genres, so they all failed. The drill now filters
-- on each member's real record and shows the members themselves.
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq
local Filter = dofile("lib/bookshelf_filter.lua")

t.test("keepMatching tests each member's real record and keeps the member", function()
    local lead = { filepath = "/b/1", title = "One", genres = { "Fiction" } }
    local s2, s3, s4 = { filepath = "/b/2" }, { filepath = "/b/3" }, { filepath = "/b/4" }
    local real = {
        ["/b/2"] = { filepath = "/b/2", title = "Two", genres = { "Fiction" } },
        ["/b/3"] = { filepath = "/b/3", title = "Three", genres = { "Satire" } },
        -- /b/4 unknown: the stub itself is tested, as before
    }
    local function recordFor(b) return (b.title == nil and real[b.filepath]) or b end
    local function fiction(r)
        for _i, g in ipairs(r.genres or {}) do if g == "Fiction" then return true end end
        return false
    end
    local kept = Filter.keepMatching({ lead, s2, s3, s4 }, recordFor, fiction)
    eq(#kept, 2, "kept " .. #kept)
    assert(kept[1] == lead and kept[2] == s2, "the members themselves are not what is kept, in order")
end)

t.test("the drill and its jump list filter members through Repo.filterMembers", function()
    local w = io.open("lib/bookshelf_widget.lua"):read("*a")
    local _, n = w:gsub("Repo%.filterMembers%(", "")
    eq(n, 2, "the drill fetch and the jump list do not both filter on real records")
    assert(not w:find("Repo.applyFilter(books, chip_tab.filter)", 1, true), "the drill still filters the stubs")
    local r = io.open("lib/bookshelf_book_repository.lua"):read("*a")
    local body = r:match("\nfunction Repo%.filterMembers%(books, filter%)\n(.-)\nend\n")
    assert(body and body:find("Repo.lightMetaFor(", 1, true) and body:find("_buildBookMetaLight(", 1, true)
        and body:find("Filter.keepMatching(", 1, true), "filterMembers does not look up members' real records")
end)

t.done()
