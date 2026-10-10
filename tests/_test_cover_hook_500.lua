-- tests/_test_cover_hook_500.lua
-- Issue 500: a getBookInfo wrapper (the 2-fallbackcover.lua user patch) hands
-- back a cover the database does not have, but only to a get_cover=true call.
-- Most of Bookshelf's record builds ask with get_cover=false (the cover is in
-- the scaled cache, or the row is batched), so a fallback cover lasted one
-- draw. A complete, coverless row now gets one get_cover=true read per
-- session when getBookInfo is wrapped; an unpatched BIM pays nothing.
--
-- Usage (from plugin root): lua tests/_test_cover_hook_500.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()
local repo = io.open("lib/bookshelf_book_repository.lua"):read("*a")
local widget = io.open("lib/bookshelf_widget.lua"):read("*a")

t.test("a coverless complete row asks the wrapper once, only when getBookInfo is wrapped", function()
    local fn = repo:match("\nlocal function _hookedCoverFor%(bim, filepath, info%)\n(.-)\nend\n")
    assert(fn, "_hookedCoverFor moved")
    assert(fn:find('info.has_meta ~= "Y" or info.cover_fetched ~= "Y" or info.ignore_cover', 1, true),
        "rows the patch would not cover are probed")
    assert(fn:find("if not _getBookInfoIsWrapped(bim) then", 1, true), "an unpatched BIM is probed")
    assert(fn:find("_hook_cover_memo[filepath] = yes", 1, true), "the answer is not remembered per file")
    assert(fn:find("probe.cover_bb:free()", 1, true), "the probe's bitmap leaks")
    local wrapped = repo:match("\nlocal function _getBookInfoIsWrapped%(bim%)\n(.-)\nend\n")
    assert(wrapped and wrapped:find('bookinfomanager%.lua$', 1, true), "wrapping is not told from BIM's own function")
end)

t.test("buildBookMeta trusts the wrapper's cover on a get_cover=false read", function()
    assert(repo:find('if has_cover ~= "Y" and not want_cover and _hookedCoverFor(bim, filepath, info) then', 1, true),
        "a cached-cover build still reads the database's no cover")
    assert(repo:find("has_cover   = has_cover and not info.ignore_cover,", 1, true),
        "the record does not carry the wrapper's answer")
end)

t.test("the batched rows carry cover_fetched, and the memo goes with the walk cache", function()
    assert(repo:find('"pages, description, has_meta, has_cover, ignore_cover, ignore_meta, cover_sizetag, " ..\n                "cover_fetched "', 1, true),
        "the batch SELECT does not read cover_fetched")
    assert(repo:find("cover_fetched = col(16, i),", 1, true), "cover_fetched is not kept on the row")
    assert(repo:find("_hook_cover_memo   = {}", 1, true), "the per-file answers outlive a rescan")
end)

t.test("a wrapper installed after the first build gets one rebuild", function()
    assert(widget:find('if Repo.coverHookArrived and Repo.coverHookArrived() then', 1, true),
        "the first screen keeps its placeholders until something rebuilds it")
end)

t.done()
