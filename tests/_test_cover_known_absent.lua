-- tests/_test_cover_known_absent.lua
-- A book KOReader has looked at and found NO cover for is a known "no", not
-- "unknown". The record used to say nil for it, and every reader that asks
-- "is has_cover known yet?" (has_cover == nil) asked again, forever: the
-- spine plan re-ran a full metadata build for every coverless face-out book
-- on every page turn (PW5, a fanfic-heavy Genres shelf with every book
-- face-out: 0.5-3.6 s of plan per turn, most of it untimed).
package.path = "./?.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()
local repo = io.open("lib/bookshelf_book_repository.lua"):read("*a")
local plan = io.open("lib/bookshelf_spine_shelf.lua"):read("*a")

local body = repo:match("\nlocal function _recordHasCover%(has_cover, info%)\n(.-)\nend\n")
local function rhc(has_cover, info)
    assert(body, "_recordHasCover not found")
    return load("local has_cover, info = ...\n" .. body, "rhc", "t", {})(has_cover, info)
end

t.test("a cover: true, unless the reader chose to ignore it", function()
    assert(rhc("Y", {}) == true)
    assert(rhc("Y", { ignore_cover = "Y" }) == false)
end)

t.test("looked and found none: false, a known answer", function()
    assert(rhc(nil, { cover_fetched = "Y" }) == false)
end)

t.test("not looked at yet: nil, unknown", function()
    assert(rhc(nil, {}) == nil)
    assert(rhc(nil, { has_meta = "Y" }) == nil, "metadata alone says nothing about the cover")
end)

t.test("the record carries it", function()
    assert(repo:find("has_cover   = _recordHasCover(has_cover, info),", 1, true))
end)

t.test("the spine plan enriches a face-out book's record at most once", function()
    assert(plan:find("if face_out and src.has_cover == nil and not src._cover_meta_tried", 1, true),
        "the guard does not remember an attempt")
    assert(plan:find("src._cover_meta_tried = true", 1, true), "the attempt is not recorded")
end)

local ck = repo:match("\nfunction Repo%.coverKnownAbsent%(filepath%)\n(.-)\nend\n")
local function absent(row, opts)
    opts = opts or {}
    assert(ck, "Repo.coverKnownAbsent not found")
    local env = {
        type = type, pcall = pcall,
        require = function() return { has = function(_s, fp) return opts.cached == fp end } end,
        _isRemotePath = function() return false end,
        _batchInfoFor = function() return row end,
        _recordHasCover = function(hc, info)
            if hc == "Y" then return not info.ignore_cover end
            if info.cover_fetched == "Y" then return false end
        end,
        getBookInfoMgr = function() return {} end,
        _hookedCoverFor = function() return opts.hooked end,
    }
    return load("local filepath = ...\n" .. ck, "ck", "t", env)("/b/a.epub")
end

t.test("coverKnownAbsent: only when KOReader looked and found none", function()
    assert(absent({ cover_fetched = "Y" }) == true)
    assert(absent({ has_cover = "Y", cover_fetched = "Y" }) == false)
    assert(absent({}) == false, "not looked yet")
    assert(absent(nil) == false, "no row in the batch")
end)

t.test("coverKnownAbsent: a cached cover or a cover-providing patch wins", function()
    assert(absent({ cover_fetched = "Y" }, { cached = "/b/a.epub" }) == false,
        "a cached cover means the row is stale (issue 451)")
    assert(absent({ cover_fetched = "Y" }, { hooked = true }) == false, "issue 500 wrapper")
end)

local spine = plan
t.test("a spine's colour for a known-coverless book is kept, not re-queried", function()
    local f = spine:match("\nfunction SpineShelf%.bookLook%(book%)\n(.-)\nend\n")
    assert(f, "bookLook not found")
    local i = f:find("coverKnownAbsent", 1, true)
    assert(i, "bookLook does not ask whether the cover is known absent")
    assert(i < f:find("Repo.getCoverBB(fp)", 1, true), "it must ask before decoding")
end)

-- Once per BOOK, not per record. A shelf switch whose fetch cache had expired
-- brought fresh light records (no has_cover, no mark), and the plan rebuilt
-- every face-out book's full metadata again: custom-metadata sidecars and
-- Hardcover data for ~1,800 books, the slow half of a bimodal switch on the
-- PW5 (1.4 s or 4 s). The build is kept per path and dropped when the book's
-- metadata changes (invalidateBook).
t.test("the face-out enrichment is remembered per book", function()
    assert(plan:find("local _meta_memo = {}", 1, true), "no per-book memo")
    local enrich = plan:match("src%._cover_meta_tried = true\n(.-)\n        end\n        local w_dp")
    assert(enrich and enrich:find("_meta_memo[src.filepath]", 1, true), "the enrichment ignores the memo")
    local inv = plan:match("\nfunction SpineShelf%.invalidateBook%(fp%)\n(.-)\nend\n")
    assert(inv and inv:find("_meta_memo[fp] = nil", 1, true), "a metadata change keeps the old build")
    assert(plan:find("_meta_memo = {}", plan:find("function SpineShelf.forgetLooks", 1, true), true),
        "Clear cover cache keeps the builds")
    assert(plan:find("local _meta_memo = {}", 1, true) < plan:find("function SpineShelf.invalidateBook", 1, true),
        "declared below invalidateBook, which then can't see it")
end)

t.done()
