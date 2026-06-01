-- tests/_test_author_name.lua
-- Pure-Lua unit tests for bookshelf_author_name.lua.
-- Run from the plugin root: `lua tests/_test_author_name.lua`
--
-- Coverage focuses on the surname-extraction edge cases that surface
-- when Calibre's author_sort field is missing -- KOReader's calibre
-- sync plugin currently strips it, so this parser handles compound
-- surnames best-effort on those libraries. See GitHub issue #43 for
-- the upstream context.

local AuthorName = dofile("lib/bookshelf_author_name.lua")

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1
    else fail = fail + 1; io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n") end
end

local function eq(label, got, want)
    if got ~= want then
        error(label .. ": got " .. tostring(got) .. ", want " .. tostring(want))
    end
end

-- ─── Basic shapes ─────────────────────────────────────────────────────────────

test("Forename Surname", function()
    eq("Joe Abercrombie", AuthorName.surnameOf("Joe Abercrombie"), "Abercrombie")
    eq("Cormac McCarthy",  AuthorName.surnameOf("Cormac McCarthy"),  "McCarthy")
end)

test("Surname, Forename (comma form)", function()
    eq("Abercrombie, Joe",   AuthorName.surnameOf("Abercrombie, Joe"),   "Abercrombie")
    eq("McCarthy,  Cormac",  AuthorName.surnameOf("McCarthy,  Cormac"),  "McCarthy")
end)

test("single-word author", function()
    eq("Anonymous", AuthorName.surnameOf("Anonymous"), "Anonymous")
    eq("Aristotle", AuthorName.surnameOf("Aristotle"), "Aristotle")
end)

test("empty / nil input", function()
    eq("empty", AuthorName.surnameOf(""), "")
    eq("nil",   AuthorName.surnameOf(nil), "")
end)

-- ─── Multi-author splits ──────────────────────────────────────────────────────

test("multi-author via ampersand", function()
    eq("A & B",
        AuthorName.surnameOf("Joe Abercrombie & Brandon Sanderson"),
        "Abercrombie")
end)

test("multi-author via 'and'", function()
    eq("A and B",
        AuthorName.surnameOf("Joe Abercrombie and Brandon Sanderson"),
        "Abercrombie")
end)

test("multi-author via semicolon", function()
    eq("A ; B",
        AuthorName.surnameOf("Joe Abercrombie; Brandon Sanderson"),
        "Abercrombie")
end)

-- BIM returns multiple <dc:creator> entries newline-separated. A
-- "Forename Surname" co-author string has no comma/";"/"&" to split on,
-- so before the newline fix surnameOf walked the whole string and
-- returned the LAST author's surname -- splitting a co-authored title
-- away from the rest of its series under an [author_surname, series]
-- sort. (The Long Earth / Pratchett & Baxter case.)
test("multi-author via newline (Forename Surname)", function()
    eq("A\\nB",
        AuthorName.surnameOf("Terry Pratchett\nStephen Baxter"),
        "Pratchett")
end)

test("multi-author via newline (Surname, Forename)", function()
    eq("A\\nB comma-form",
        AuthorName.surnameOf("Pratchett, Terry\nBaxter, Stephen"),
        "Pratchett")
    eq("givenOf A\\nB",
        AuthorName.givenOf("Terry Pratchett\nStephen Baxter"),
        "Terry")
end)

-- ─── Particle handling (the v2.0.2 expansion) ─────────────────────────────────

test("classic Germanic particles", function()
    eq("van der",
        AuthorName.surnameOf("Joe van der Berg"),
        "van der Berg")
    eq("von Trapp",
        AuthorName.surnameOf("Maria von Trapp"),
        "von Trapp")
end)

test("Romance particles", function()
    eq("Le Guin",
        AuthorName.surnameOf("Ursula Le Guin"),
        "Le Guin")
    eq("de la Cruz",
        AuthorName.surnameOf("Melissa de la Cruz"),
        "de la Cruz")
    eq("di Lampedusa",
        AuthorName.surnameOf("Giuseppe di Lampedusa"),
        "di Lampedusa")
end)

test("Saint / St. (issue #43 reported case)", function()
    eq("St. Crowe",
        AuthorName.surnameOf("Nikki St. Crowe"),
        "St. Crowe")
    eq("St Crowe (no period)",
        AuthorName.surnameOf("Nikki St Crowe"),
        "St Crowe")
    eq("Saint Crowe",
        AuthorName.surnameOf("Nikki Saint Crowe"),
        "Saint Crowe")
end)

test("Arabic particles", function()
    eq("Al-something kept whole if attached",
        AuthorName.surnameOf("Omar Khayyam"),
        "Khayyam")
    eq("Al as separate token",
        AuthorName.surnameOf("Omar Al Khayyam"),
        "Al Khayyam")
    eq("Ibn patronymic",
        AuthorName.surnameOf("Muhammad Ibn Battuta"),
        "Ibn Battuta")
end)

test("Portuguese", function()
    eq("dos Santos",
        AuthorName.surnameOf("Jose dos Santos"),
        "dos Santos")
end)

test("Mc / Mac are NOT separators (attached to surname)", function()
    -- "Cormac McCarthy" should produce "McCarthy", not "Mc McCarthy" --
    -- Mc is a prefix of the surname itself, not a standalone particle.
    eq("McCarthy attached",
        AuthorName.surnameOf("Cormac McCarthy"),
        "McCarthy")
    eq("MacKenzie attached",
        AuthorName.surnameOf("Alister MacKenzie"),
        "MacKenzie")
end)

-- ─── Given name extraction ───────────────────────────────────────────────────

test("givenOf basic forms", function()
    eq("Forename Surname",
        AuthorName.givenOf("Joe Abercrombie"),
        "Joe")
    eq("Surname, Forename",
        AuthorName.givenOf("Abercrombie, Joe"),
        "Joe")
    eq("single-word author",
        AuthorName.givenOf("Anonymous"),
        "Anonymous")
end)

test("givenOf with particles", function()
    eq("van der",
        AuthorName.givenOf("Joe van der Berg"),
        "Joe")
    eq("St. Crowe (new)",
        AuthorName.givenOf("Nikki St. Crowe"),
        "Nikki")
end)

-- ─── Summary ─────────────────────────────────────────────────────────────────

io.write(string.format("\nauthor_name: %d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
