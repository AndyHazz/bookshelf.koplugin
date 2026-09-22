-- tests/_test_face_out_ungrouped_series.lua
-- The two series face-out reasons mean something on a shelf with no groups.
--
-- THE REPORT (issue 425). "I have toggled the option to face out first in
-- series and I can see several spines for first in series books, but they do
-- not face out." A Home shelf in spine mode, the reason switched on, nothing
-- standing cover-forward.
--
-- WHY. Both reasons were answered by the shelf's RUNS: a series group's first
-- member, or the first book of a folder section. A plain shelf has no runs --
-- every book is its own item and its own run -- so there were no heads to
-- mark and the reasons could never fire. Where a book stands on its own, its
-- own series is the only thing that can answer, so that is what answers.
--
-- A book already inside a run is left to the head rule, so a grouped shelf
-- renders exactly as it did.
--
-- Usage (from plugin root): lua tests/_test_face_out_ungrouped_series.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq
local src = io.open("lib/bookshelf_spine_shelf.lua"):read("*a")

-- ── first in series ───────────────────────────────────────────────────────
local body = src:match("\nfunction SpineShelf%.isFirstInSeries%(src%)\n(.-)\nend\n")
assert(body, "isFirstInSeries moved or was renamed")
local isFirst = assert(load("return function(src)\n" .. body .. "\nend",
                            "isFirstInSeries", "t",
                            { type = type, tonumber = tonumber }))()

t.test("book one of a named series is the first in it", function()
    assert(isFirst{ series_name = "Discworld", series_num = "1" })
    assert(isFirst{ series_name = "Discworld", series_num = 1 },
        "the number is a string on these records, but not always")
end)

t.test("...however the index was written down", function()
    -- Calibre hands back a float, some libraries zero-pad.
    assert(isFirst{ series_name = "Discworld", series_num = "1.0" })
    assert(isFirst{ series_name = "Discworld", series_num = "01" })
end)

t.test("a later book is not", function()
    eq(isFirst{ series_name = "Discworld", series_num = "2" }, false)
    eq(isFirst{ series_name = "Discworld", series_num = "0" }, false)
end)

t.test("an index with no series is not first of anything", function()
    -- An embedded "#1" with no name gets a number and no series (the issue
    -- 127 guard in the repository drops the empty name). Facing those out
    -- would put a cover on every book whose metadata happens to say 1.
    eq(isFirst{ series_num = "1" }, false)
    eq(isFirst{ series_name = "", series_num = "1" }, false)
end)

t.test("a series with no index answers no rather than erroring", function()
    eq(isFirst{ series_name = "Discworld" }, false)
    eq(isFirst{ series_name = "Discworld", series_num = "" }, false)
    eq(isFirst{ series_name = "Discworld", series_num = "one" }, false)
    eq(isFirst(nil), false)
end)

-- ── the marking, driven for real ──────────────────────────────────────────
local function marker(unread)
    local mbody = src:match("\nfunction SpineShelf%.markSeriesHeads%(f, src, st%)\n(.-)\nend\n")
    assert(mbody, "markSeriesHeads moved or was renamed")
    local SS = { isFirstInSeries = isFirst,
                 isUnread = function(s) return unread[s.id] == true end }
    local mark = assert(load("return function(f, src, st)\n" .. mbody .. "\nend", "mark", "t",
        { SpineShelf = SS, type = type, tostring = tostring }))()
    local st = { run_has_series = {}, run_next = {}, series_first = {}, series_next = {} }
    return function(f, s) mark(f, s, st) end, st
end

local function run(mark, rows, field)
    for _i = 1, #rows do mark(rows[_i][1], rows[_i][2]) end
    local out = {}
    for _i = 1, #rows do
        if rows[_i][1][field] then out[#out + 1] = rows[_i][2].id end
    end
    return table.concat(out, ",")
end

t.test("on a plain shelf, first in series is book one of it", function()
    local mark = marker({})
    eq(run(mark, {
        { {}, { id = "a2", series_name = "A", series_num = "2" } },
        { {}, { id = "a1", series_name = "A", series_num = "1" } },
        { {}, { id = "c1" } },
    }, "series_first"), "a1")
end)

-- ── first unread in series ────────────────────────────────────────────────
t.test("the first unread of a series faces out when nothing is grouped", function()
    local mark = marker({ a2 = true, a3 = true, b1 = true, b2 = true, c1 = true })
    eq(run(mark, {
        -- Series A, loose on a plain shelf: 1 is read, so 2 is next.
        { {}, { id = "a1", series_name = "A" } },
        { {}, { id = "a2", series_name = "A" } },
        { {}, { id = "a3", series_name = "A" } },
        -- Series B, all unread: only the first.
        { {}, { id = "b1", series_name = "B" } },
        { {}, { id = "b2", series_name = "B" } },
        -- No series: the plain "Unread" reason covers these, not this one.
        { {}, { id = "c1" } },
    }, "series_next"), "a2,b1", "expected the next unread of each series and nothing else")
end)

t.test("a finished series faces nothing out", function()
    local mark = marker({})
    local f = {}
    mark(f, { id = "x", series_name = "A" })
    eq(f.series_next, nil, "nothing left to read, nothing to show")
end)

-- ── issue 444: an author shelf ────────────────────────────────────────────
-- An author group is ONE run. Both reasons used to be answered by the run, so
-- each author got a single cover whatever series their books were in.
local function authorShelf()
    -- Sorted author > series > title, as the reporter had it. Run 1 is one
    -- author with two series and a standalone.
    return {
        { { in_group = true, run_idx = 1, first_of_group = true }, { id = "x0", series_name = "X", series_num = "0.5" } },
        { { in_group = true, run_idx = 1 }, { id = "x1", series_name = "X", series_num = "1" } },
        { { in_group = true, run_idx = 1 }, { id = "x2", series_name = "X", series_num = "2" } },
        { { in_group = true, run_idx = 1 }, { id = "y1", series_name = "Y", series_num = "1" } },
        { { in_group = true, run_idx = 1 }, { id = "y2", series_name = "Y", series_num = "2" } },
        { { in_group = true, run_idx = 1 }, { id = "s" } },
    }
end

local function hasSeries(st, rows)
    for _i = 1, #rows do
        if rows[_i][2].series_name then st.run_has_series[rows[_i][1].run_idx] = true end
    end
end

t.test("every series under an author gets its first book faced out", function()
    local mark, st = marker({})
    local rows = authorShelf(); hasSeries(st, rows)
    eq(run(mark, rows, "series_first"), "x0,y1",
       "the first of each series shown, a 0.5 prequel included; not just the author's first")
end)

t.test("...and its next unread one", function()
    local mark, st = marker({ x1 = true, x2 = true, y1 = true, y2 = true, s = true })
    local rows = authorShelf(); hasSeries(st, rows)
    eq(run(mark, rows, "series_next"), "x1,y1",
       "one cover per series, and the standalone is not a series")
end)

t.test("a series two authors share is answered under each", function()
    local mark, st = marker({ a = true, b = true })
    local rows = {
        { { in_group = true, run_idx = 1 }, { id = "a", series_name = "Shared" } },
        { { in_group = true, run_idx = 2 }, { id = "b", series_name = "Shared" } },
    }
    hasSeries(st, rows)
    eq(run(mark, rows, "series_next"), "a,b")
end)

t.test("a series shelf is unchanged: each run is its series", function()
    local mark, st = marker({ a2 = true, b1 = true })
    local rows = {
        { { in_group = true, run_idx = 1, first_of_group = true }, { id = "a1", series_name = "A" } },
        { { in_group = true, run_idx = 1 }, { id = "a2", series_name = "A" } },
        { { in_group = true, run_idx = 2, first_of_group = true }, { id = "b1", series_name = "B" } },
    }
    hasSeries(st, rows)
    eq(run(mark, rows, "series_first"), "a1,b1")
end)

t.test("the plan fills run_has_series before the walk", function()
    assert(src:find("has_series[f.run_idx] = true", 1, true),
        "without it every author run is read as a folder section")
    local walk = src:find("SpineShelf.markSeriesHeads(f, src, series_state)", 1, true)
    local fill = src:find("has_series[f.run_idx] = true", 1, true)
    assert(walk and fill < walk, "filled after the books it describes were marked")
end)

t.test("group members carry the series number as written (issue 444)", function()
    -- Author, genre and rating groups built their member records with only
    -- series_index. The spine's foot and isFirstInSeries read series_num, so
    -- every book on an author shelf lost its number.
    local repo = io.open("lib/bookshelf_book_repository.lua"):read("*a")
    local n = 0
    for rec in repo:gmatch("series_index = tonumber%(book%.series_num%),(.-)\n") do
        n = n + 1
    end
    local built = 0
    for _ in repo:gmatch("series_index = tonumber%(book%.series_num%),\n[^\n]*\n?[^\n]*\n?[^\n]*\n?%s*series_num   = book%.series_num,") do
        built = built + 1
    end
    assert(n >= 2, "the group member builders moved")
    eq(built, n, "a group member builder drops the series number")
    assert(repo:find("series_index = b.series_index,\n                series_num   = b.series_num,", 1, true),
        "the cached group shape drops it on the way through")
end)

-- ── the record has to carry the name ──────────────────────────────────────
t.test("the light page records carry the series NAME, not just the number", function()
    -- The plan hydrates light records with a small stub. It carried
    -- series_num and not series_name, so isFirstInSeries would have said no
    -- to every book on a page that had been hydrated.
    local stub = src:match("(hyd = {.-})")
    assert(stub, "the hydration stub moved or was renamed")
    assert(stub:find("series_name", 1, true),
        "without the name the reason cannot fire on a hydrated page")
    assert(src:match("bk%.series_name = hyd%.series_name"),
        "the stub carries it but nothing copies it onto the record")
end)

t.done()
