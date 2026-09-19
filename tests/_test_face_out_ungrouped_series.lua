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

t.test("the plan asks it only where the book stands alone", function()
    local line = src:match("(or %(face_spec%.first and.-\n[^\n]-isFirstInSeries[^\n]+)")
    assert(line, "the plan never consults it")
    assert(line:find("f.first_of_group == true", 1, true),
        "the run-head rule must still come first, or grouped shelves change")
    assert(line:find("not f.in_group", 1, true),
        "inside a run the head answers; asking both would face out two books "
        .. "in the same run")
end)

-- ── first unread in series ────────────────────────────────────────────────
t.test("the first unread of a series faces out when nothing is grouped", function()
    local block = src:match("(local sname = src%.series_name.-\n        end)")
    assert(block, "the series first-unread marking moved or was renamed")
    local unread = { a2 = true, a3 = true, b1 = true, b2 = true, c1 = true }
    local env = {
        first_unread_series = {},
        type = type,
        SpineShelf = { isUnread = function(s) return unread[s.id] == true end },
    }
    local mark = assert(load("return function(f, src)\n" .. block .. "\nend",
                             "mark", "t", env))()
    local rows = {
        -- Series A, loose on a plain shelf: 1 is read, so 2 is next.
        { {}, { id = "a1", series_name = "A" } },
        { {}, { id = "a2", series_name = "A" } },
        { {}, { id = "a3", series_name = "A" } },
        -- Series B, all unread: only the first.
        { {}, { id = "b1", series_name = "B" } },
        { {}, { id = "b2", series_name = "B" } },
        -- No series: the plain "Unread" reason covers these, not this one.
        { {}, { id = "c1" } },
    }
    for _i = 1, #rows do mark(rows[_i][1], rows[_i][2]) end
    local out = {}
    for _i = 1, #rows do
        if rows[_i][1].first_unread_in_series then out[#out + 1] = rows[_i][2].id end
    end
    eq(table.concat(out, ","), "a2,b1",
       "expected the next unread of each series and nothing else")
end)

t.test("a book inside a run is left to the run rule", function()
    local block = src:match("(local sname = src%.series_name.-\n        end)")
    local env = {
        first_unread_series = {},
        type = type,
        SpineShelf = { isUnread = function() return true end },
    }
    local mark = assert(load("return function(f, src)\n" .. block .. "\nend",
                             "mark", "t", env))()
    local f = { in_group = true, run_idx = 1 }
    mark(f, { id = "x", series_name = "A" })
    eq(f.first_unread_in_series, nil,
       "a grouped shelf would face out the run head AND this one")
end)

t.test("a finished series faces nothing out", function()
    local block = src:match("(local sname = src%.series_name.-\n        end)")
    local env = {
        first_unread_series = {},
        type = type,
        SpineShelf = { isUnread = function() return false end },
    }
    local mark = assert(load("return function(f, src)\n" .. block .. "\nend",
                             "mark", "t", env))()
    local f = {}
    mark(f, { id = "x", series_name = "A" })
    eq(f.first_unread_in_series, nil, "nothing left to read, nothing to show")
end)

t.test("the plan reads the series mark alongside the run one", function()
    local line = src:match("(or %(face_spec%.first_unread and.-\n[^\n]+)")
    assert(line, "the plan never consults it")
    assert(line:find("f.first_unread_of_group == true", 1, true),
        "the run rule went missing")
    assert(line:find("f.first_unread_in_series == true", 1, true),
        "the series rule is set but never read")
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
