-- tests/_test_face_out_ahead.lua
-- Which books ahead will face out, decided the way the plan decides it.
--
-- The covers of a Spines shelf's next pages are warmed in the background
-- (BookshelfWidget:_spineFaceOutJobs): only the books that will stand
-- cover-forward, or the warm-up decodes covers for spines (70-150 ms each on
-- a PW5, plus memory and disk). Whether a book faces out depends on the shelf
-- around it (first in series is first in SHELF order, recently added is the
-- newest N of the shelf), so the decision is one function the plan and the
-- warm-up share (SpineShelf.facesOut), and faceOutPaths walks a run of items
-- the way plan() does.
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq
local src = io.open("lib/bookshelf_spine_shelf.lua"):read("*a")

local function body(sig)
    return assert(src:match("\nfunction SpineShelf%." .. sig .. "\n(.-)\nend\n"), "SpineShelf." .. sig .. " moved")
end

local favs, colls, statuses, reads = {}, {}, {}, 0
local SS = {}
local env = setmetatable({
    SpineShelf = SS,
    _isFavourite = function(fp) return favs[fp] == true end,
    _inCollection = function(name, fp) return colls[name] and colls[name][fp] or false end,
}, { __index = _G })
local function def(name, sig, params)
    local f = assert(load("return function(" .. params .. ")\n" .. body(sig) .. "\nend", name, "t", env))()
    SS[name] = f
end
def("faceOutSpec", "faceOutSpec%(v%)", "v")
def("faceOutEmpty", "faceOutEmpty%(spec%)", "spec")
def("isFirstInSeries", "isFirstInSeries%(src%)", "src")
def("isUnread", "isUnread%(src%)", "src")
def("isUnreadStandalone", "isUnreadStandalone%(src%)", "src")
def("markSeriesHeads", "markSeriesHeads%(f, src, st%)", "f, src, st")
def("_flattenItems", "_flattenItems%(items%)", "items")
def("facesOut", "facesOut%(face_spec, f, src, fav, face_recent%)", "face_spec, f, src, fav, face_recent")
def("faceOutPaths", "faceOutPaths%(items, opts%)", "items, opts")
SS.FACE_REASONS = { "favorites", "first", "first_unread", "reading", "finished",
                    "on_hold", "unread", "standalone", "recent", "collection" }
SS.SpineShelf = SS
SS.isOnShelfModule = nil
-- Status as the plan resolves it: here, a table, counting the lookups.
SS.resolvedStatus = function(s) reads = reads + 1; return statuses[s.filepath] end
SS.recentSet = function() return nil end

local function book(fp, o) o = o or {}; o.filepath = fp; return o end
local function paths(items, face_out, extra)
    local opts = { face_out = face_out }
    for k, v in pairs(extra or {}) do opts[k] = v end
    return SS.faceOutPaths(items, opts)
end

t.test("every book, when every book faces out", function()
    local got = paths({ book("/a"), book("/b") }, "all")
    eq(#got, 2); eq(got[1], "/a")
end)

t.test("nothing when nothing faces out", function()
    eq(#paths({ book("/a") }, "none"), 0)
end)

t.test("favourites only, without reading a single status", function()
    favs = { ["/b"] = true }; reads = 0
    local got = paths({ book("/a"), book("/b"), book("/c") }, "favorites")
    eq(#got, 1); eq(got[1], "/b")
    eq(reads, 0)
    favs = {}
end)

t.test("by status, resolved as the plan resolves it", function()
    statuses = { ["/a"] = "reading", ["/b"] = "finished", ["/c"] = "on_hold" }
    eq(paths({ book("/a"), book("/b"), book("/c"), book("/d") }, "reading")[1], "/a")
    eq(paths({ book("/a"), book("/b"), book("/c"), book("/d") }, "finished")[1], "/b")
    eq(paths({ book("/a"), book("/b"), book("/c"), book("/d") }, "on_hold")[1], "/c")
    local unread = paths({ book("/a"), book("/b"), book("/c"), book("/d") }, "unread")
    eq(#unread, 1); eq(unread[1], "/d")
    statuses = {}
end)

t.test("first unread in series: the first unread of the series in shelf order", function()
    statuses = { ["/s1"] = "finished" }
    local items = { book("/s1", { series_name = "S", series_num = 1 }),
                    book("/s2", { series_name = "S", series_num = 2 }),
                    book("/s3", { series_name = "S", series_num = 3 }) }
    local got = paths(items, "first_unread")
    eq(#got, 1); eq(got[1], "/s2")
    -- Claimed on an earlier page: nothing here.
    eq(#paths(items, "first_unread", { series_next_claimed = { S = true } }), 0)
    statuses = {}
end)

t.test("first in series, a collection, and the recent set the caller hands in", function()
    local items = { book("/s1", { series_name = "S", series_num = 1 }), book("/x"), book("/y") }
    eq(paths(items, "first")[1], "/s1")
    colls = { Holiday = { ["/x"] = true } }
    eq(paths(items, { collection = "Holiday" })[1], "/x")
    colls = {}
    eq(paths(items, { recent = 1 }, { face_recent_set = { ["/y"] = true } })[1], "/y")
end)

t.test("a group's members, each decided on its own", function()
    favs = { ["/m2"] = true }
    local items = { { books = { book("/m1"), book("/m2") } }, book("/c") }
    local got = paths(items, "favorites")
    eq(#got, 1); eq(got[1], "/m2")
    favs = {}
end)

t.test("not a series box, an add tile or a feed's folder: no cover of a book's own", function()
    local got = paths({ book("/a", { _series_box = true }), book("/b", { add_subshelf = true }),
                        book("/c", { is_opds_nav = true }), book("/d") }, "all")
    eq(#got, 1); eq(got[1], "/d")
end)

t.test("the plan asks the same function", function()
    local plan = body("plan%(items, opts%)")
    assert(plan:find("face_out = SpineShelf.facesOut(face_spec, f, src, fav, face_recent)", 1, true),
        "plan() decides face-outs on its own again")
end)

t.test("statusUnread resolves through the same lookup", function()
    assert(body("statusUnread%(src%)"):find("SpineShelf.resolvedStatus(src)", 1, true))
end)

t.done()
