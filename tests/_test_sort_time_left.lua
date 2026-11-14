-- tests/_test_sort_time_left.lua
-- Sort by time left to finish (issue 602): the minutes %book_time_left shows,
-- least first; a book with no estimate (never opened, finished, no reading
-- statistics) at the end either way. The answer comes from the repository
-- (statistics database), once per record.
-- Run from the plugin root: lua tests/_test_sort_time_left.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
package.loaded["logger"] = { dbg = function() end, info = function() end,
                             warn = function() end, err = function() end }
package.preload["lib/bookshelf_author_name"] = function()
    return dofile("lib/bookshelf_author_name.lua")
end
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq
local SortEngine = dofile("lib/bookshelf_sort_engine.lua")

local mins, asked = {}, 0
SortEngine.setTimeLeftResolver(function(fp) asked = asked + 1; return mins[fp] end)

local function order(recs, reverse)
    SortEngine.sort(recs, { { key = "time_left", reverse = reverse or false } })
    local out = {}
    for i, r in ipairs(recs) do out[i] = r.filepath or r.fp end
    return table.concat(out, ",")
end
local function books() return {
    { filepath = "/long", title = "A" }, { filepath = "/none", title = "B" },
    { filepath = "/short", title = "C" }, { filepath = "/mid", title = "D" },
} end

t.test("the key is registered and offered in the picker", function()
    local k = SortEngine.KEYS.time_left
    assert(k and type(k.comparator) == "function", "no time_left key")
    local offered = false
    for _i, key in ipairs(SortEngine.ORDER) do if key == "time_left" then offered = true end end
    assert(offered, "not in ORDER, so the picker never shows it")
end)

t.test("least time left first; a book with no estimate goes to the end", function()
    SortEngine.clearTimeLeftMemo()
    mins = { ["/long"] = 600, ["/short"] = 12, ["/mid"] = 95 }
    eq(order(books()), "/short,/mid,/long,/none")
end)

t.test("reversed: most first, and no estimate is still at the end", function()
    SortEngine.clearTimeLeftMemo()
    mins = { ["/long"] = 600, ["/short"] = 12, ["/mid"] = 95 }
    eq(order(books(), true), "/long,/mid,/short,/none")
end)

t.test("a book nearly done (0 minutes) leads, it is not 'no estimate'", function()
    SortEngine.clearTimeLeftMemo()
    mins = { ["/long"] = 600, ["/short"] = 0 }
    eq(order({ { filepath = "/long", title = "A" }, { filepath = "/short", title = "B" } }), "/short,/long")
end)

t.test("a folder view's file entry is asked by its path; a folder is not asked", function()
    SortEngine.clearTimeLeftMemo()
    mins, asked = { ["/f/b.epub"] = 5, ["/f/a.epub"] = 50 }, 0
    local recs = {
        { name = "a.epub", fp = "/f/a.epub", attr = { mode = "file" } },
        { name = "dir", fp = "/f/dir", attr = { mode = "directory" } },
        { name = "b.epub", fp = "/f/b.epub", attr = { mode = "file" } },
    }
    eq(order(recs), "/f/b.epub,/f/a.epub,/f/dir")
    eq(asked, 2)
end)

t.test("asked once per record, not once per comparison", function()
    SortEngine.clearTimeLeftMemo()
    mins, asked = {}, 0
    local recs = {}
    for i = 1, 40 do
        mins["/" .. i] = (i * 37) % 101
        recs[i] = { filepath = "/" .. i, title = tostring(i) }
    end
    order(recs)
    eq(asked, 40)
end)

t.test("a book with no estimate is not asked again", function()
    SortEngine.clearTimeLeftMemo()
    mins, asked = {}, 0
    local rec, x = { filepath = "/none", title = "A" }, { filepath = "/x", title = "B" }
    order({ rec, x })
    order({ rec, x })
    eq(asked, 2, "one ask a record")
end)

t.test("clearing the memo picks up what was read since", function()
    SortEngine.clearTimeLeftMemo()
    mins = { ["/a"] = 10, ["/b"] = 20 }
    local recs = { { filepath = "/a", title = "A" }, { filepath = "/b", title = "B" } }
    eq(order(recs), "/a,/b")
    mins = { ["/a"] = 30, ["/b"] = 20 }
    eq(order(recs), "/a,/b", "the memo should still answer until cleared")
    SortEngine.clearTimeLeftMemo()
    eq(order(recs), "/b,/a")
end)

t.test("a resolver that raises does not break the sort", function()
    SortEngine.clearTimeLeftMemo()
    SortEngine.setTimeLeftResolver(function() error("statistics database locked") end)
    eq(order({ { filepath = "/b", title = "B" }, { filepath = "/a", title = "A" } }), "/a,/b")
    SortEngine.setTimeLeftResolver(function(fp) asked = asked + 1; return mins[fp] end)
end)

t.test("the Sort page offers it with the reading sorts, in words for each direction", function()
    local src = io.open("lib/bookshelf_chip_editor.lua"):read("*a")
    local row = src:match('text = _%("Reading"%) }%)%s*add%(chips%((%b{})')
    assert(row and row:find('"time_left"', 1, true), "not on the Sort page's Reading row")
    local dir = src:match("local function _dirLabels%(key%)(.-)\nend\n")
    assert(dir, "_dirLabels moved")
    local line = dir:match('[^\n]*key == "time_left"[^\n]*')
    assert(line and line:find('_("Shortest first"), _("Longest first")', 1, true),
        "A-Z / Z-A for a length of time")
end)

t.done()
