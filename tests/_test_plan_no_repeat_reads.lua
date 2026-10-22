-- tests/_test_plan_no_repeat_reads.lua
-- The spine plan runs per page turn and per shelf rebuild, over every book on
-- the shelf (1,700 spines on a Genres shelf). Profiled on the PW5 after the
-- cover fixes, two settled answers were still recomputed per book per plan:
--   * a book with NO page count opened its sidecar (readProgress, then a
--     sidecar-location lookup in persistProgress: several file stats on the
--     Kindle's slow storage) on every plan, though its status was already
--     known and nothing about its sidecar had changed: 18% of a turn;
--   * the p(N) file-name marker was matched twice per spine: 10%.
package.path = "./?.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()
local plan = io.open("lib/bookshelf_spine_shelf.lua"):read("*a")
local repo = io.open("lib/bookshelf_book_repository.lua"):read("*a")

t.test("the sidecar is read only while the book's status is unknown", function()
    assert(plan:find("if (not known or check_stable) and src.filepath", 1, true),
        "the plan still re-reads a known book's sidecar when it has no count")
    assert(not plan:find("if (not (pages or thick.scan) or not known or check_stable)", 1, true),
        "the old condition is still there")
end)

local body = repo:match("\nlocal function pageCountFromFilename%(filepath%)\n(.-)\nend\n")
t.test("the file-name marker is remembered per path", function()
    assert(body and body:find("_filename_pages", 1, true), "no memo")
end)

t.test("the file-name marker still reads the same", function()
    local env = { type = type, tonumber = tonumber, _filename_pages = {}, NONE = false }
    local f = load("local filepath = ...\n" .. body, "pcf", "t", env)
    assert(f("/b/Some Book p(412).epub") == 412)
    assert(f("/b/Some Book P(7).epub") == 7)
    assert(f("/b/Some Book.epub") == nil)
    assert(f("/b/Some Book.epub") == nil, "a miss is remembered as a miss")
    assert(f(nil) == nil)
end)

t.done()
