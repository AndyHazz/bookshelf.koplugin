-- tests/_test_hardcover_match.lua
-- Pure-Lua tests for the Hardcover "best guess" matcher port.

package.path = "./?.lua;./?/init.lua;" .. package.path

local Match = dofile("lib/bookshelf_hardcover_match.lua")

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1
    else fail = fail + 1; io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n") end
end
local function assertEq(a, b, msg)
    assert(a == b, (msg or "") .. " (got " .. tostring(a) .. ", want " .. tostring(b) .. ")")
end

test("exact title+author scores high and passes the gate", function()
    local t, a = Match.scoreMatch("Time Shelter", "Georgi Gospodinov",
                                  "Time Shelter", "Georgi Gospodinov")
    assert(t == 100, "identical title should be 100, got " .. t)
    assert(a == 100, "identical author should be 100, got " .. a)
end)

test("word-order variation still matches (token_set)", function()
    -- "Lastname, Firstname" vs "Firstname Lastname"
    local _, a = Match.scoreMatch("X", "Martin, George",
                                  "X", "George Martin")
    assert(a >= Match.AUTHOR_THRESHOLD,
        "reordered author should clear threshold, got " .. a)
end)

test("subtitle containment still matches (partial)", function()
    local t = select(1, Match.scoreMatch("Dune", "Frank Herbert",
                                          "Dune: The Graphic Novel, Book 1", "Frank Herbert"))
    assert(t >= Match.TITLE_THRESHOLD,
        "title-as-prefix should clear threshold via partial, got " .. t)
end)

test("empty inputs hard-miss (no false positive on sparse metadata)", function()
    local t, a = Match.scoreMatch("", "", "", "")
    assertEq(t, 0, "empty title")
    assertEq(a, 0, "empty author")
    local t2 = select(1, Match.scoreMatch("Dune", "", "Dune", ""))
    assertEq(t2, 0, "empty author on one side zeroes both")
end)

test("clearly different books fail the gate", function()
    local t, a = Match.scoreMatch("The Hobbit", "J.R.R. Tolkien",
                                  "Neuromancer", "William Gibson")
    assert(t < Match.TITLE_THRESHOLD or a < Match.AUTHOR_THRESHOLD,
        "unrelated book should not pass (t=" .. t .. ", a=" .. a .. ")")
end)

test("isNonCanonical flags adaptations and collections", function()
    assert(Match.isNonCanonical("Dune: The Graphic Novel", nil), "graphic novel")
    assert(Match.isNonCanonical("The Lord of the Rings Omnibus", nil), "omnibus")
    assert(Match.isNonCanonical("Foundation (Audiobook)", nil), "audiobook")
    assert(Match.isNonCanonical("A / B / C", nil), "multi-book / title")
    assert(Match.isNonCanonical("Dune", "The Hitchhiker's Guide on Radio"), "series marker")
    assert(not Match.isNonCanonical("Dune", "Dune Chronicles"), "plain novel is canonical")
end)

test("normaliseSeriesName drops leading 'the' and case", function()
    assertEq(Match.normaliseSeriesName("The Culture"), "culture")
    assertEq(Match.normaliseSeriesName("culture"), "culture")
    assertEq(Match.normaliseSeriesName(nil), "")
end)

test("pickBest chooses the confident canonical hit", function()
    local epub = { title = "A Dance with Dragons", author = "George R. R. Martin" }
    local cands = {
        { title = "A Game of Thrones", author = "George R. R. Martin", series_name = "A Song of Ice and Fire" },
        { title = "A Dance with Dragons", author = "George R. R. Martin", series_name = "A Song of Ice and Fire" },
    }
    local chosen = Match.pickBest(epub, cands)
    assert(chosen, "expected a match")
    assertEq(chosen.title, "A Dance with Dragons", "should pick the title-matching hit")
end)

test("pickBest prefers the canonical novel over a box set", function()
    local epub = { title = "Dune", author = "Frank Herbert" }
    local cands = {
        { title = "Dune (Boxed Set)", author = "Frank Herbert", series_name = "Dune" },
        { title = "Dune", author = "Frank Herbert", series_name = "Dune" },
    }
    local chosen = Match.pickBest(epub, cands)
    assert(chosen, "expected a match")
    assertEq(chosen.title, "Dune", "should prefer the standalone novel")
end)

test("pickBest rejects when only a non-canonical hit clears the gate", function()
    local epub = { title = "Dune", author = "Frank Herbert" }
    local cands = {
        { title = "Dune Omnibus", author = "Frank Herbert", series_name = "Dune" },
    }
    -- "Dune Omnibus" vs "Dune": partial gives a high title score, but it's the
    -- only hit and it's non-canonical -> rejected.
    local chosen = Match.pickBest(epub, cands)
    assert(chosen == nil, "a lone non-canonical hit must be rejected")
end)

test("pickBest returns nil when nothing clears the gate", function()
    local epub = { title = "The Hobbit", author = "J.R.R. Tolkien" }
    local cands = {
        { title = "Neuromancer", author = "William Gibson", series_name = "Sprawl" },
    }
    assert(Match.pickBest(epub, cands) == nil, "no confident match expected")
end)

test("pickBest tie-break prefers the series match", function()
    local epub = { title = "Foundation", author = "Isaac Asimov", series = "Foundation" }
    local cands = {
        { title = "Foundation", author = "Isaac Asimov", series_name = "Robot" },
        { title = "Foundation", author = "Isaac Asimov", series_name = "Foundation" },
    }
    local chosen = Match.pickBest(epub, cands)
    assert(chosen, "expected a match")
    assertEq(chosen.series_name, "Foundation", "series match should win the tie")
end)

io.stdout:write(("PASS %d  FAIL %d\n"):format(pass, fail))
if fail > 0 then os.exit(1) end
