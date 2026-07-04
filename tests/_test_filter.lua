local Filter = dofile("lib/bookshelf_filter.lua")

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

test("dimensions returns eight in canonical order", function()
    local d = Filter.dimensions()
    eq("count", #d, 8)
    eq("d1", d[1].key, "statuses")
    eq("d2", d[2].key, "genres")
    eq("d3", d[3].key, "langs")
    eq("d4", d[4].key, "formats")
    eq("d5", d[5].key, "ratings")
    eq("d6", d[6].key, "collections")
    eq("d7", d[7].key, "series_membership")
    eq("d8", d[8].key, "folders")
    eq("folder kind", d[8].kind, "folder")
    eq("genre kind", d[2].kind, "multi")
    eq("series kind", d[7].kind, "choice")
end)

test("isActive false on empty / nil", function()
    eq("nil", Filter.isActive(nil), false)
    eq("empty", Filter.isActive({}), false)
    eq("empty statuses", Filter.isActive({ statuses = {} }), false)
    eq("empty folders", Filter.isActive({ folders = { include = {}, exclude = {} } }), false)
end)

test("isActive true when any dimension set", function()
    eq("statuses", Filter.isActive({ statuses = { unread = true } }), true)
    eq("genres", Filter.isActive({ genres = { ["Sci-Fi"] = true } }), true)
    eq("folder include", Filter.isActive({ folders = { include = { ["/a"] = true } } }), true)
    eq("folder exclude", Filter.isActive({ folders = { exclude = { ["/a"] = true } } }), true)
end)

test("signature is order-independent and distinguishes filters", function()
    local a = Filter.signature({ statuses = { unread = true, reading = true } })
    local b = Filter.signature({ statuses = { reading = true, unread = true } })
    eq("stable", a, b)
    local c = Filter.signature({ statuses = { unread = true } })
    if a == c then error("different filters must differ: " .. a) end
    eq("empty sig", Filter.signature({}), "")
end)

local function book(t) return t end

test("matches: no filter passes everything", function()
    local c = Filter.compile({})
    eq("empty", Filter.matches(book{ _status = "unread" }, c), true)
end)

test("matches: status within-dimension OR", function()
    local c = Filter.compile({ statuses = { unread = true, reading = true } })
    eq("unread", Filter.matches(book{ _status = "unread" }, c), true)
    eq("reading", Filter.matches(book{ _status = "reading" }, c), true)
    eq("finished", Filter.matches(book{ _status = "finished" }, c), false)
    eq("nil->unread", Filter.matches(book{}, c), true)
end)

test("matches: genre OR over multi-valued book.genres", function()
    local c = Filter.compile({ genres = { ["Sci-Fi"] = true, ["Fantasy"] = true } })
    eq("has one", Filter.matches(book{ genres = { "History", "Fantasy" } }, c), true)
    eq("has none", Filter.matches(book{ genres = { "History" } }, c), false)
    eq("nil genres", Filter.matches(book{ genres = nil }, c), false)
end)

test("matches: cross-dimension AND", function()
    local c = Filter.compile({ statuses = { unread = true }, langs = { en = true } })
    eq("both", Filter.matches(book{ _status = "unread", lang = "en" }, c), true)
    eq("wrong lang", Filter.matches(book{ _status = "unread", lang = "fr" }, c), false)
    eq("wrong status", Filter.matches(book{ _status = "reading", lang = "en" }, c), false)
    eq("missing lang", Filter.matches(book{ _status = "unread" }, c), false)
end)

test("matches: format exact", function()
    local c = Filter.compile({ formats = { EPUB = true } })
    eq("epub", Filter.matches(book{ format = "EPUB" }, c), true)
    eq("pdf", Filter.matches(book{ format = "PDF" }, c), false)
end)

test("matches: folder include is recursive prefix", function()
    local c = Filter.compile({ folders = { include = { ["/Books/Comics"] = true } } })
    eq("under", Filter.matches(book{ filepath = "/Books/Comics/x.cbz" }, c), true)
    eq("deeper", Filter.matches(book{ filepath = "/Books/Comics/Marvel/y.cbz" }, c), true)
    eq("sibling", Filter.matches(book{ filepath = "/Books/ComicsX/z.cbz" }, c), false)
    eq("outside", Filter.matches(book{ filepath = "/Books/Fiction/a.epub" }, c), false)
end)

test("matches: folder exclude wins over include", function()
    local c = Filter.compile({ folders = {
        include = { ["/Books"] = true },
        exclude = { ["/Books/Samples"] = true },
    } })
    eq("included", Filter.matches(book{ filepath = "/Books/Fiction/a.epub" }, c), true)
    eq("excluded", Filter.matches(book{ filepath = "/Books/Samples/s.epub" }, c), false)
end)

test("matches: exclude-only with no include", function()
    local c = Filter.compile({ folders = { exclude = { ["/Books/Samples"] = true } } })
    eq("kept", Filter.matches(book{ filepath = "/Books/Fiction/a.epub" }, c), true)
    eq("dropped", Filter.matches(book{ filepath = "/Books/Samples/s.epub" }, c), false)
end)

test("matches: trailing slash normalised", function()
    local c = Filter.compile({ folders = { include = { ["/Books/Comics/"] = true } } })
    eq("under", Filter.matches(book{ filepath = "/Books/Comics/x.cbz" }, c), true)
end)

test("matches: collection membership via injected resolver", function()
    local fake = {
        ["To Read"] = { ["/Books/a.epub"] = true, ["/Books/b.epub"] = true },
        ["Done"]    = { ["/Books/c.epub"] = true },
    }
    local resolver = function(name) return fake[name] or {} end
    local c = Filter.compile({ collections = { ["To Read"] = true } },
                             { collection_resolver = resolver })
    eq("member", Filter.matches(book{ filepath = "/Books/a.epub" }, c), true)
    eq("non-member", Filter.matches(book{ filepath = "/Books/c.epub" }, c), false)
end)

test("matches: multiple collections union (OR)", function()
    local fake = { A = { ["/x"] = true }, B = { ["/y"] = true } }
    local resolver = function(name) return fake[name] or {} end
    local c = Filter.compile({ collections = { A = true, B = true } },
                             { collection_resolver = resolver })
    eq("in A", Filter.matches(book{ filepath = "/x" }, c), true)
    eq("in B", Filter.matches(book{ filepath = "/y" }, c), true)
    eq("in neither", Filter.matches(book{ filepath = "/z" }, c), false)
end)

test("dimSummary per dimension", function()
    eq("any", Filter.dimSummary({}, "genres"), "any")
    eq("one", Filter.dimSummary({ genres = { ["Sci-Fi"] = true } }, "genres"), "Sci-Fi")
    -- multi values now list comma-separated, sorted
    local two = Filter.dimSummary({ langs = { en = true, fr = true } }, "langs")
    eq("two", two, "en, fr")
end)

test("dimSummary comma-joins; truncates to a budget with an ellipsis", function()
    -- no budget: full sorted list
    eq("two genres full",
        Filter.dimSummary({ genres = { ["Sci-Fi"] = true, ["Fantasy"] = true } }, "genres"),
        "Fantasy, Sci-Fi")
    -- budget that fits everything: no ellipsis
    eq("fits budget",
        Filter.dimSummary({ genres = { ["Sci-Fi"] = true, ["Fantasy"] = true } }, "genres", 40),
        "Fantasy, Sci-Fi")
    -- many genres + small budget: packs whole values then an ellipsis
    local many = {}
    for i = 1, 10 do many[string.format("Genre%02d", i)] = true end
    local s = Filter.dimSummary({ genres = many }, "genres", 30)
    assert(s:match("^Genre01"), "should start with the first sorted value: " .. s)
    assert(s:match("\xE2\x80\xA6$"), "should end with an ellipsis: " .. s)
    assert(not s:match("more"), "no +N more wording: " .. s)
    -- a single value longer than the budget is shown whole, no misleading tail
    local long = "ThisIsAnExtremelyLongGenreNameThatExceedsTheBudget"
    eq("single long, no ellipsis",
        Filter.dimSummary({ genres = { [long] = true } }, "genres", 20), long)
end)

test("dimSummary folders in/out", function()
    local f = { folders = { include = { ["/a"] = true }, exclude = { ["/b"] = true, ["/c"] = true } } }
    eq("folders", Filter.dimSummary(f, "folders"), "1 in, 2 out")
    eq("folders none", Filter.dimSummary({}, "folders"), "any")
end)

test("summary counts active dimensions", function()
    eq("none", Filter.summary({}), "none")
    eq("one", Filter.summary({ statuses = { unread = true } }), "1 active")
    eq("two", Filter.summary({ statuses = { unread = true }, langs = { en = true } }), "2 active")
end)

test("statusValues has the four canonical statuses", function()
    local v = Filter.statusValues()
    eq("count", #v, 4)
    eq("first value", v[1].value, "unread")
end)

test("matches: injected lang_canonical maps display label to raw code", function()
    -- Simulates the editor storing "English" while book.lang is "en".
    local lang_map = { English = "eng", en = "eng", eng = "eng" }
    local canonical = function(v) return lang_map[v] or v end
    local c = Filter.compile({ langs = { English = true } },
                             { lang_canonical = canonical })
    eq("en matches English", Filter.matches(book{ lang = "en" }, c), true)
    eq("fr does not match", Filter.matches(book{ lang = "fr" }, c), false)
    eq("eng matches English", Filter.matches(book{ lang = "eng" }, c), true)
end)

test("matches: injected genre_normalize maps display label to raw tag", function()
    -- Simulates the editor storing "Sci-Fi" while book.genres has "sci-fi".
    local normalize = function(v) return v:lower() end
    local c = Filter.compile({ genres = { ["Sci-Fi"] = true } },
                             { genre_normalize = normalize })
    eq("sci-fi matches Sci-Fi", Filter.matches(book{ genres = { "sci-fi" } }, c), true)
    eq("history does not match", Filter.matches(book{ genres = { "history" } }, c), false)
end)

-- ─── Rating dimension ────────────────────────────────────────────────────────

test("ratingValues: 6 entries, '5' first, 'unrated' last", function()
    local rv = Filter.ratingValues()
    eq("count", #rv, 6)
    eq("first value", rv[1].value, "5")
    eq("last value",  rv[6].value, "unrated")
    -- all have both value and label
    for i = 1, #rv do
        assert(rv[i].value ~= nil, "entry " .. i .. " missing value")
        assert(rv[i].label ~= nil, "entry " .. i .. " missing label")
    end
end)

test("matches: ratings filter matches book with rating=5 and rating=4, rejects rating=3", function()
    local c = Filter.compile({ ratings = { ["5"] = true, ["4"] = true } })
    eq("5 stars",   Filter.matches(book{ rating = 5 }, c), true)
    eq("4 stars",   Filter.matches(book{ rating = 4 }, c), true)
    eq("3 stars",   Filter.matches(book{ rating = 3 }, c), false)
    eq("nil rating (unrated) rejected", Filter.matches(book{ rating = nil }, c), false)
end)

test("matches: ratings filter unrated matches nil rating, rejects rated book", function()
    local c = Filter.compile({ ratings = { unrated = true } })
    eq("nil->unrated match", Filter.matches(book{ rating = nil }, c), true)
    eq("4 stars rejected",   Filter.matches(book{ rating = 4   }, c), false)
    -- rating=0 also maps to unrated (r > 0 guard)
    eq("zero->unrated match", Filter.matches(book{ rating = 0 }, c), true)
end)

test("matches: ratings cross-dimension AND with status", function()
    local c = Filter.compile({
        ratings  = { ["5"] = true },
        statuses = { finished = true },
    })
    eq("5 stars finished match",   Filter.matches(book{ rating = 5, _status = "finished" }, c), true)
    eq("5 stars reading reject",   Filter.matches(book{ rating = 5, _status = "reading"  }, c), false)
    eq("4 stars finished reject",  Filter.matches(book{ rating = 4, _status = "finished" }, c), false)
end)

test("dimSummary ratings: single selection shows friendly label", function()
    local s1 = Filter.dimSummary({ ratings = { ["5"] = true } }, "ratings")
    eq("5 stars label", s1, "5 stars")
    local su = Filter.dimSummary({ ratings = { unrated = true } }, "ratings")
    eq("unrated label", su, "Unrated")
    local sm = Filter.dimSummary({ ratings = { ["5"] = true, ["4"] = true } }, "ratings")
    eq("multi comma list", sm, "4 stars, 5 stars")
    local sa = Filter.dimSummary({}, "ratings")
    eq("any when empty", sa, "any")
end)

test("isActive true when ratings set", function()
    eq("ratings active", Filter.isActive({ ratings = { ["5"] = true } }), true)
    eq("empty ratings inactive", Filter.isActive({ ratings = {} }), false)
end)

test("signature includes ratings dimension", function()
    local s = Filter.signature({ ratings = { ["5"] = true, ["3"] = true } })
    -- must contain "ratings:3,5" (sorted)
    assert(s:find("ratings:3,5", 1, true), "expected ratings in signature: " .. s)
end)

-- ─── Series membership dimension ─────────────────────────────────────────────

test("seriesValues: 3 entries, 'both' first", function()
    local sv = Filter.seriesValues()
    eq("count", #sv, 3)
    eq("first value", sv[1].value, "both")
    eq("second value", sv[2].value, "standalone")
    eq("third value", sv[3].value, "in_series")
    for i = 1, #sv do assert(sv[i].label ~= nil, "entry " .. i .. " missing label") end
end)

test("isActive: series 'both'/absent inactive, standalone/in_series active", function()
    eq("absent", Filter.isActive({}), false)
    eq("both", Filter.isActive({ series_membership = "both" }), false)
    eq("standalone", Filter.isActive({ series_membership = "standalone" }), true)
    eq("in_series", Filter.isActive({ series_membership = "in_series" }), true)
end)

test("matches: standalone keeps no-series books, rejects in-series", function()
    local c = Filter.compile({ series_membership = "standalone" })
    eq("nil series kept",   Filter.matches(book{ series_name = nil }, c), true)
    eq("empty series kept", Filter.matches(book{ series_name = "" }, c), true)
    eq("in-series rejected", Filter.matches(book{ series_name = "Dune" }, c), false)
end)

test("matches: in_series keeps in-series books, rejects standalones", function()
    local c = Filter.compile({ series_membership = "in_series" })
    eq("in-series kept",   Filter.matches(book{ series_name = "Dune" }, c), true)
    eq("nil series rejected",   Filter.matches(book{ series_name = nil }, c), false)
    eq("empty series rejected", Filter.matches(book{ series_name = "" }, c), false)
end)

test("matches: series 'both' is a no-op", function()
    local c = Filter.compile({ series_membership = "both" })
    eq("in-series", Filter.matches(book{ series_name = "Dune" }, c), true)
    eq("standalone", Filter.matches(book{ series_name = nil }, c), true)
end)

test("matches: series membership ANDs with genre", function()
    local c = Filter.compile({ series_membership = "standalone", genres = { ["Sci-Fi"] = true } })
    eq("standalone sci-fi kept", Filter.matches(book{ series_name = nil, genres = { "Sci-Fi" } }, c), true)
    eq("in-series sci-fi rejected", Filter.matches(book{ series_name = "Dune", genres = { "Sci-Fi" } }, c), false)
    eq("standalone history rejected", Filter.matches(book{ series_name = nil, genres = { "history" } }, c), false)
end)

test("signature includes series membership", function()
    eq("both omitted", Filter.signature({ series_membership = "both" }), "")
    assert(Filter.signature({ series_membership = "standalone" }):find("sm:standalone", 1, true),
        "expected sm:standalone in signature")
end)

test("dimSummary: series membership", function()
    eq("absent -> any", Filter.dimSummary({}, "series_membership"), "any")
    eq("both -> any", Filter.dimSummary({ series_membership = "both" }, "series_membership"), "any")
    eq("standalone label", Filter.dimSummary({ series_membership = "standalone" }, "series_membership"),
        "Only standalone books")
end)

io.write(("filter: %d passed, %d failed\n"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
