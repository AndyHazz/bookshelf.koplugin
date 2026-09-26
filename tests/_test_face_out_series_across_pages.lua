-- tests/_test_face_out_series_across_pages.lua
-- Issue 458: "First unread in series" gave a series that runs across a page
-- boundary a second face-out on the next page. A book standing on its own is
-- marked by its series NAME, and plan() is handed one screen, so the next
-- screen's first unread of the same series looked like the series' first.
--
-- The fix: the render works out which series had their first unread BEFORE
-- the page (SpineShelf.seriesClaimedBefore, over the chip's whole list) and
-- plan() starts the page with those already taken. Rig repro: a 10-book
-- unread series from item 6, one row a page -- page 1 faced out Part 1 and
-- page 2 Part 7; after, page 2 faces out nothing, and with Parts 1-6 finished
-- page 2 faces out Part 7 again.
--
-- Usage (from plugin root): lua tests/_test_face_out_series_across_pages.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq
local src = io.open("lib/bookshelf_spine_shelf.lua"):read("*a")
local wsrc = io.open("lib/bookshelf_widget.lua"):read("*a")

local body = src:match("\nfunction SpineShelf%.seriesClaimedBefore%(all_items, first_idx, window_items%)\n(.-)\nend\n")
assert(body, "seriesClaimedBefore moved or was renamed")

local asked
local function claimed(all, first_idx, window, unread)
    asked = {}
    local SS = { statusUnread = function(it) asked[#asked + 1] = it.title; return unread[it.title] == true end }
    local fn = assert(load("return function(all_items, first_idx, window_items)\n" .. body .. "\nend",
        "claimed", "t", { SpineShelf = SS, type = type, ipairs = ipairs, math = math, next = next, pairs = pairs }))()
    return fn(all, first_idx, window)
end

local function book(title, series) return { filepath = "/b/" .. title, title = title, series_name = series } end

local ALL = {
    book("f0"), book("s1", "Saga"), book("s2", "Saga"), book("f1"), book("o1", "Other"),
    book("s3", "Saga"), book("s4", "Saga"), book("f2"),
}

t.test("an unread book of the series before the page claims it", function()
    local win = { ALL[6], ALL[7], ALL[8] }             -- page starts at s3
    local c = claimed(ALL, 6, win, { s1 = true, s2 = true, s3 = true, s4 = true })
    assert(c and c.Saga, "Saga's first unread (s1) came up before this page")
    eq(c.Other, nil, "a series not on this page is not looked at")
end)

t.test("a series read so far up to the page claims nothing", function()
    local win = { ALL[6], ALL[7], ALL[8] }
    local c = claimed(ALL, 6, win, { s3 = true, s4 = true })
    eq(c, nil, "s1 and s2 are finished, so the page's s3 is the first unread")
end)

t.test("only books of the page's series have their status resolved", function()
    local win = { ALL[6], ALL[7] }
    claimed(ALL, 6, win, {})
    for _i, title in ipairs(asked) do
        assert(title == "s1" or title == "s2", "resolved status for " .. title .. ", which cannot matter")
    end
end)

t.test("the first page, a page of no series, and a group need nothing", function()
    eq(claimed(ALL, 1, { ALL[1], ALL[2] }, { s1 = true }), nil, "nothing is before page 1")
    eq(claimed(ALL, 4, { ALL[4], ALL[8] }, { s1 = true }), nil, "no series on the page")
    local group = { books = { ALL[6] }, label = "Saga", series_name = "Saga" }
    eq(claimed(ALL, 6, { group }, { s1 = true }), nil, "a group is planned whole, not by name")
end)

t.test("plan() starts the page with the claimed series taken", function()
    assert(src:find("for name in pairs(opts.series_next_claimed or {}) do", 1, true),
        "plan must seed series_state.series_next from opts.series_next_claimed")
end)

t.test("the render passes it, only for the reason and a list from the cursor", function()
    local i = wsrc:find("opts.series_next_claimed = SpineShelf.seriesClaimedBefore(all, self._cursor, items)", 1, true)
    assert(i, "_buildSpineRows must hand plan() the series claimed before the page")
    local ctx = wsrc:sub(i - 700, i)
    assert(ctx:find("spec.first_unread", 1, true), "only when First unread in series is on")
    assert(ctx:find("all[self._cursor] == items[1]", 1, true), "and only when the page is the list from the cursor")
end)

t.done()
