-- tests/_test_face_out_recent_shelfwide.lua
-- "Recently added N" means N on the SHELF, not N on every screen.
--
-- WHAT WAS WRONG. The reason is answered by SpineShelf.recentSet, whose own
-- comment says "over the shelf's WHOLE item list, not the visible page" -- but
-- it was called from inside plan(), and plan() is handed one screen in the
-- render pass. So the intent was right and the wiring never matched it: with
-- the reason set to 5, five books stood cover-forward on page one, five more
-- on page two, and so on. Measured on the rig across four screens: nineteen
-- books faced out before, five after.
--
-- THE RULE, which the other two "across the shelf" reasons still need: work
-- it out ONCE from the chip's full item list and hand it to plan() as data.
-- Never derive it from the slice plan() receives -- that slice is a screen in
-- the render pass and the whole chip in the pagination pass, and a reason
-- that reads it cannot tell which.
--
-- Usage (from plugin root): lua tests/_test_face_out_recent_shelfwide.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq
local src = io.open("lib/bookshelf_spine_shelf.lua"):read("*a")

-- recentSet drives cleanly: plain tables in, a filepath set out.
local body = src:match("\nfunction SpineShelf%.recentSet%(flat, n%)\n(.-)\nend\n")
assert(body, "recentSet moved or was renamed")
local recentSet = assert(load("local flat, n = ...\n" .. body,
                              "recentSet", "t",
                              { ipairs = ipairs, tonumber = tonumber,
                                table = table, math = math }))
local function flat(...)
    local out = {}
    for _i, b in ipairs({ ... }) do out[#out + 1] = { book = b } end
    return out
end

t.test("the newest N win, whatever order they arrive in", function()
    local set = recentSet(flat(
        { filepath = "/a", date_added = 10 },
        { filepath = "/b", date_added = 50 },
        { filepath = "/c", date_added = 30 }), 2)
    eq(set["/b"], true); eq(set["/c"], true)
    eq(set["/a"], nil, "the oldest should not face out")
end)

t.test("a library that records no dates still answers, and stably", function()
    -- Ties sort by filepath rather than being dropped: a library that has
    -- never recorded date_added would otherwise face out nothing at all,
    -- with no way for the reader to tell why.
    local one = recentSet(flat({ filepath = "/b" }, { filepath = "/a" },
                               { filepath = "/c" }), 2)
    local two = recentSet(flat({ filepath = "/c" }, { filepath = "/a" },
                               { filepath = "/b" }), 2)
    eq(one["/a"], true); eq(one["/b"], true)
    eq(two["/a"], one["/a"], "the same books, whatever order they came in")
    eq(two["/b"], one["/b"])
end)

t.test("N larger than the shelf is not an error", function()
    local set = recentSet(flat({ filepath = "/a", date_added = 1 }), 5)
    eq(set["/a"], true)
end)

t.test("no reason, no set", function()
    eq(recentSet(flat({ filepath = "/a" }), nil), nil)
    eq(recentSet(flat({ filepath = "/a" }), 0), nil)
    eq(recentSet({}, 3), nil)
end)

-- ── the whole-list wrapper, and who calls it ─────────────────────────────
t.test("recentSetForItems flattens first, so a group's books count", function()
    local wrap = src:match("\nfunction SpineShelf%.recentSetForItems%(items, n%)\n(.-)\nend\n")
    assert(wrap, "recentSetForItems moved or was renamed")
    assert(wrap:find("_flattenItems", 1, true),
        "a group item carries its books rather than being one, so the list "
        .. "has to be flattened before the newest can be picked from it")
end)

t.test("plan prefers the set it is handed", function()
    local line = src:match("(local face_recent = opts%.face_recent_set[^\n]*\n[^\n]*\n[^\n]*)")
    assert(line, "plan no longer takes a precomputed set")
    assert(line:find("if face_recent == nil then", 1, true),
        "a caller that hands none must still get the old answer, not none")
end)

t.test("both plan callers hand it one, from the WHOLE list", function()
    -- This used to count TWO computations of the set, one at each plan call.
    -- The seven options the two passes must agree on now come from one
    -- helper, _spinePlanBase, so the set is computed once there, from the
    -- list each caller names -- and what has to stay true is which list that
    -- is: the render reaches past the PAGE it draws to the chip's whole list.
    local w = io.open("lib/bookshelf_widget.lua"):read("*a")
    local n = select(2, w:gsub("face_recent_set = self:_spineFaceRecent", ""))
    eq(n, 1, "the face-out set is computed somewhere other than _spinePlanBase: " .. n)
    local base = w:match("\nfunction BookshelfWidget:_spinePlanBase%(content_w, shelf_h, all_items%)\n(.-)\nend\n")
    assert(base and base:find("face_recent_set = self:_spineFaceRecent(all_items)", 1, true),
        "_spinePlanBase no longer builds the set from the list it is handed")
    -- the render pass is handed a PAGE; it must reach past it for this
    local render = w:match("\nfunction BookshelfWidget:_buildSpineRows%(.-%)\n(.-)\nend\n")
    local call = render and render:match("self:_spinePlanBase%(.-%)\n")
    assert(call and call:find("_draft_items_cache", 1, true),
        "the render pass is computing the set from the page it renders")
    -- and pagination plans the whole list, so it hands that over
    local pages = w:match("\nfunction BookshelfWidget:_spinePageFirsts%(build%)\n(.-)\nend\n")
    assert(pages and pages:find("self:_spinePlanBase(d.content_w, d.shelf_h, items)", 1, true),
        "pagination no longer hands the whole list it plans")
end)

t.test("the memo cannot outlive the list it describes", function()
    local w = io.open("lib/bookshelf_widget.lua"):read("*a")
    local fn = w:match("\nfunction BookshelfWidget:_spineFaceRecent%(all_items%)\n(.-)\nend\n")
    assert(fn, "_spineFaceRecent moved or was renamed")
    assert(fn:find("c.face_recent_for == all_items", 1, true),
        "the memo must be tied to the very list it was computed from")
    assert(fn:find("c.face_recent_n == n", 1, true),
        "...and to N, or changing the reason's count would not take effect")
    assert(fn:find("self._spine_fetch_cache", 1, true),
        "it belongs on the fetch cache, which a chip switch and a chip edit "
        .. "both replace")
end)

t.done()
