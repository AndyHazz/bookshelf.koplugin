-- tests/_test_face_out_first_unread.lua
-- "First unread in series": the NEXT one to read stands cover-forward.
--
-- THE REQUEST. "Please add an option for spines to show cover only the first
-- unread book in the series. Basically the next unread in the series." Once a
-- series is part-read, its first book is the least interesting cover on the
-- shelf -- the reader has finished it -- and the one worth showing is the one
-- they have not got to.
--
-- WHY IT IS DECIDED IN THE PLAN LOOP, not in _flattenItems where its sibling
-- `first_of_group` is set: "unread" is a question about STATUS, and status is
-- only resolved as the loop reaches each entry (light page records carry
-- none, so the sidecar is read there). The loop walks the flattened list in
-- order, so the first member of a run that comes up unread is the earliest
-- unread one.
--
-- Usage (from plugin root): lua tests/_test_face_out_first_unread.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq
local src = io.open("lib/bookshelf_spine_shelf.lua"):read("*a")

t.test("it is a reason like the others, so the set machinery carries it", function()
    -- faceOutSpec, faceOutEmpty, the picker's labels and the "N reasons"
    -- summary all iterate FACE_REASONS. Being in that list is what makes the
    -- new reason storable, toggleable and readable without touching any of it.
    local list = src:match("SpineShelf%.FACE_REASONS = (%b{})")
                 or src:match("SpineShelf%.FACE_REASONS = {(.-)}")
    assert(list, "FACE_REASONS moved")
    assert(list:find("first_unread", 1, true),
        "first_unread is not a face-out reason, so nothing can store it")
    -- ...and distinct from "first": a substring match would make the two
    -- indistinguishable to faceOutSave's single-reason shortcut.
    assert(list:find('"first"', 1, true), "the plain first-in-series reason is gone")
end)

t.test("the spec round-trips it, alone and in company", function()
    local body = src:match("\nfunction SpineShelf%.faceOutSpec%(v%)\n(.-)\nend\n")
    assert(body, "faceOutSpec moved")
    local env = { SpineShelf = { FACE_REASONS = { "favorites", "first",
        "first_unread", "reading", "unread", "recent" } },
        type = type, tonumber = tonumber, math = math, ipairs = ipairs }
    local spec = assert(load("return function(v)\n" .. body .. "\nend",
                             "spec", "t", env))()
    eq(spec("first_unread").first_unread, true, "the stored string does not resolve")
    local both = spec({ first = true, first_unread = true })
    assert(both.first and both.first_unread, "the two cannot be held together")
    eq(spec({ first_unread = true }).first, nil,
       "picking the next-unread should not also pick the series' first book")
    eq(spec(false).first_unread, nil, "None must clear it")
    eq(spec("all").first_unread, nil, "All is its own answer")
end)

t.test("only the first unread of a run faces out, and only inside a run", function()
    -- The marking, lifted out of the plan loop and driven directly. `f` is a
    -- flattened entry; the loop is what supplies run_idx and in_group.
    local block = src:match("(if f%.in_group and not first_unread_seen.-\n        end)")
    assert(block, "the first-unread marking moved or was renamed")
    local seen = {}
    local unread = { ["a2"] = true, ["a3"] = true, ["b1"] = true, ["c1"] = true }
    local env = {
        first_unread_seen = seen,
        SpineShelf = { isUnread = function(s) return unread[s.id] == true end },
    }
    local mark = assert(load(
        "return function(f, src)\n" .. block .. "\nend", "mark", "t", env))()
    -- Series A: book 1 finished, 2 and 3 unread -> only 2 faces out.
    local rows = {
        { { in_group = true,  run_idx = 1 }, { id = "a1" } },
        { { in_group = true,  run_idx = 1 }, { id = "a2" } },
        { { in_group = true,  run_idx = 1 }, { id = "a3" } },
        -- Series B: every book unread -> only the first.
        { { in_group = true,  run_idx = 2 }, { id = "b1" } },
        { { in_group = true,  run_idx = 2 }, { id = "b2" } },
        -- A standalone unread book is NOT a series.
        { { in_group = false, run_idx = 3 }, { id = "c1" } },
    }
    for _i = 1, #rows do mark(rows[_i][1], rows[_i][2]) end
    local out = {}
    for _i = 1, #rows do
        if rows[_i][1].first_unread_of_group then out[#out + 1] = rows[_i][2].id end
    end
    eq(table.concat(out, ","), "a2,b1",
       "expected the next unread of each series and nothing else")
end)

t.test("a fully-read series faces nothing out", function()
    local block = src:match("(if f%.in_group and not first_unread_seen.-\n        end)")
    local env = {
        first_unread_seen = {},
        SpineShelf = { isUnread = function() return false end },
    }
    local mark = assert(load(
        "return function(f, src)\n" .. block .. "\nend", "mark", "t", env))()
    local f = { in_group = true, run_idx = 1 }
    mark(f, { id = "x" })
    eq(f.first_unread_of_group, nil,
       "a series the reader has finished should show no cover at all")
end)

t.test("the plan reads the mark, and does not confuse it with first-in-series", function()
    local line = src:match("(or %(face_spec%.first_unread[^\n]+)")
    assert(line, "the plan never consults the new reason")
    assert(line:find("f.first_unread_of_group == true", 1, true),
        "it reads something other than the mark the loop sets")
    local plain = src:match("(or %(face_spec%.first and[^\n]+)")
    assert(plain and plain:find("f.first_of_group == true", 1, true),
        "the original first-in-series reason changed meaning")
end)

t.test("the picker groups the reasons the way a reader thinks", function()
    -- Reading state first, the two series reasons on one line, and the
    -- whole-shelf answers at the bottom with Favourites.
    local ed = io.open("lib/bookshelf_chip_editor.lua"):read("*a")
    local rows = ed:match("local sub_rows = {(.-)\n%s+}\n")
    assert(rows, "the picker's rows moved")
    local order = {}
    for name in rows:gmatch('toggle%("([%a_]+)"%)') do order[#order + 1] = name end
    eq(table.concat(order, ","), "unread,reading,first,first_unread,recent,favorites",
       "the picker's row order changed")
    assert(rows:find('toggle("first"),  toggle("first_unread")', 1, true),
        "the two series reasons should share a line")
    local ed_labels = ed:match("local FACE_LABELS = (%b{})")
    assert(ed_labels and ed_labels:find("first_unread", 1, true),
        "the new reason has no label, so its button would be blank")
end)

t.done()
