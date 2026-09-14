-- tests/_test_sort_engine.lua
-- Pure-Lua unit tests for bookshelf_sort_engine.lua.
-- Run from the plugin root: `lua tests/_test_sort_engine.lua`
package.loaded["logger"] = { dbg = function() end, info = function() end,
                              warn = function() end, err = function() end }

-- Make the engine's pcall(require, "lib/bookshelf_author_name") succeed in
-- the pure-Lua test harness by preloading the real implementation under
-- the same lib/-prefixed name production code uses.
package.preload["lib/bookshelf_author_name"] = function()
    return dofile("lib/bookshelf_author_name.lua")
end

local SortEngine = dofile("lib/bookshelf_sort_engine.lua")

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1
    else fail = fail + 1; io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n") end
end

local function ids(list) local r = {} for i, b in ipairs(list) do r[i] = b.id end return r end
local function eq(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do if a[i] ~= b[i] then return false end end
    return true
end

test("registry: lists every required key", function()
    local expected = { "title", "filename", "author_name", "author_surname",
                       "series_name", "series_index", "last_opened",
                       "percent_read", "read_status", "read_status_active",
                       "date_added", "size", "book_count" }
    for _, k in ipairs(expected) do
        assert(SortEngine.KEYS[k], "missing key: " .. k)
        assert(type(SortEngine.KEYS[k].comparator) == "function",
               "key has no comparator: " .. k)
        assert(type(SortEngine.KEYS[k].label) == "string",
               "key has no label: " .. k)
    end
end)

test("sort: single-key ascending by title", function()
    local books = {
        { id = 1, title = "Charlie" },
        { id = 2, title = "Alice" },
        { id = 3, title = "Bob" },
    }
    SortEngine.sort(books, { { key = "title", reverse = false } })
    assert(eq(ids(books), { 2, 3, 1 }), "got " .. table.concat(ids(books), ","))
end)

test("sort: tied primary key falls back to title then filename (#205/#208)", function()
    -- All share last_opened, so the requested level ties; the implicit title
    -- fallback decides, deterministically (never arbitrary/unstable order).
    local books = {
        { id = 1, last_opened = 100, title = "Charlie", filename = "c.epub" },
        { id = 2, last_opened = 100, title = "Alice",   filename = "a.epub" },
        { id = 3, last_opened = 100, title = "Bob",     filename = "b.epub" },
    }
    SortEngine.sort(books, { { key = "last_opened", reverse = true } })
    assert(eq(ids(books), { 2, 3, 1 }), "tie -> title order; got " .. table.concat(ids(books), ","))
end)

test("sort: equal title falls back to filename (#205/#208)", function()
    -- User sorts by title (all equal) -> filename breaks the tie. Confirms the
    -- fallback still appends filename even when title is the explicit key.
    local books = {
        { id = 1, title = "Same", filename = "zzz.epub" },
        { id = 2, title = "Same", filename = "aaa.epub" },
        { id = 3, title = "Same", filename = "mmm.epub" },
    }
    SortEngine.sort(books, { { key = "title", reverse = false } })
    assert(eq(ids(books), { 2, 3, 1 }), "got " .. table.concat(ids(books), ","))
end)

test("sort: title uses natural order (Vol 2 before Vol 10) -- issue #104", function()
    local books = {
        { id = 1, title = "Series, Vol 10" },
        { id = 2, title = "Series, Vol 2" },
        { id = 3, title = "Series, Vol 1" },
        { id = 4, title = "Series, Vol 20" },
        { id = 5, title = "Series, Vol 3" },
    }
    SortEngine.sort(books, { { key = "title", reverse = false } })
    assert(eq(ids(books), { 3, 2, 5, 1, 4 }), "got " .. table.concat(ids(books), ","))
end)

test("sort: filename uses natural order -- issue #104", function()
    local books = {
        { id = 1, filename = "ch10.epub" },
        { id = 2, filename = "ch2.epub" },
        { id = 3, filename = "ch1.epub" },
    }
    SortEngine.sort(books, { { key = "filename", reverse = false } })
    assert(eq(ids(books), { 3, 2, 1 }), "got " .. table.concat(ids(books), ","))
end)

test("sort: natural order is case-insensitive", function()
    local books = {
        { id = 1, title = "banana 10" },
        { id = 2, title = "Apple 2" },
        { id = 3, title = "apple 10" },
    }
    SortEngine.sort(books, { { key = "title", reverse = false } })
    -- apple 2 < apple 10 (natural) < banana 10, regardless of case.
    assert(eq(ids(books), { 2, 3, 1 }), "got " .. table.concat(ids(books), ","))
end)

test("sort: zero-padded names unaffected by natural order", function()
    local books = {
        { id = 1, title = "Vol 03" },
        { id = 2, title = "Vol 01" },
        { id = 3, title = "Vol 10" },
        { id = 4, title = "Vol 02" },
    }
    SortEngine.sort(books, { { key = "title", reverse = false } })
    assert(eq(ids(books), { 2, 4, 1, 3 }), "got " .. table.concat(ids(books), ","))
end)

test("sort: single-key descending via reverse", function()
    local books = {
        { id = 1, title = "Charlie" },
        { id = 2, title = "Alice" },
        { id = 3, title = "Bob" },
    }
    SortEngine.sort(books, { { key = "title", reverse = true } })
    assert(eq(ids(books), { 1, 3, 2 }))
end)

test("sort: nil values land at the end on ascending", function()
    local books = {
        { id = 1, title = nil },
        { id = 2, title = "Alpha" },
        { id = 3, title = nil },
    }
    SortEngine.sort(books, { { key = "title", reverse = false } })
    assert(books[1].id == 2, "expected non-nil first, got id=" .. books[1].id)
    assert(books[2].title == nil and books[3].title == nil, "nil titles should follow")
end)

test("sort: nil values STAY at end under reverse", function()
    -- Reverse-immune nil-handling: missing values cluster at the end
    -- regardless of sort direction, so the user never sees a first page
    -- of empty entries when sorting descending.
    local books = {
        { id = 1, title = nil },
        { id = 2, title = "Alpha" },
        { id = 3, title = nil },
        { id = 4, title = "Charlie" },
    }
    SortEngine.sort(books, { { key = "title", reverse = true } })
    assert(books[1].id == 4, "Charlie (highest) should be first under reverse; got id=" .. books[1].id)
    assert(books[2].id == 2, "Alpha (second-highest) should be second under reverse")
    assert(books[3].title == nil and books[4].title == nil, "nils should stay at end")
end)

test("sort: empty string treated as nil for sort-to-end purposes", function()
    -- Books with author = "" (cachedSurname fallback for missing data)
    -- should sort the same as books with author = nil -- both at the end.
    local books = {
        { id = 1, author = "" },
        { id = 2, author = "Asimov" },
        { id = 3, author = nil },
    }
    SortEngine.sort(books, { { key = "author_surname", reverse = false } })
    assert(books[1].id == 2, "Asimov should sort first; got id=" .. books[1].id)
    -- Both id=1 (empty) and id=3 (nil) should be at the end; their
    -- relative order is implementation-defined (stable sort keeps insertion).
end)

test("sort: two-level (author_surname then series_index)", function()
    local books = {
        { id = 1, author_surname = "Asimov",  series_index = 2 },
        { id = 2, author_surname = "Tolkien", series_index = 1 },
        { id = 3, author_surname = "Asimov",  series_index = 1 },
    }
    SortEngine.sort(books, {
        { key = "author_surname", reverse = false },
        { key = "series_index",   reverse = false },
    })
    assert(eq(ids(books), { 3, 1, 2 }))
end)

test("sort: read_status order is unread < reading < on_hold < finished", function()
    local books = {
        { id = 1, read_status = "finished" },
        { id = 2, read_status = "reading"  },
        { id = 3, read_status = "unread"   },
        { id = 4, read_status = "on_hold"  },
    }
    SortEngine.sort(books, { { key = "read_status", reverse = false } })
    assert(eq(ids(books), { 3, 2, 4, 1 }))
end)

test("sort: read_status_active puts reading first, then unread", function()
    local books = {
        { id = 1, read_status = "finished" },
        { id = 2, read_status = "reading"  },
        { id = 3, read_status = "unread"   },
        { id = 4, read_status = "on_hold"  },
    }
    SortEngine.sort(books, { { key = "read_status_active", reverse = false } })
    assert(eq(ids(books), { 2, 3, 4, 1 }))
end)

test("sort: percent_read treats finished as 1.0 even if percent_finished < 1", function()
    local books = {
        { id = 1, percent_finished = 0.99, read_status = "finished" },
        { id = 2, percent_finished = 1.0,  read_status = "reading"  },
        { id = 3, percent_finished = 0.5,  read_status = "reading"  },
    }
    SortEngine.sort(books, { { key = "percent_read", reverse = true } })
    -- finished is 1.0; tie with id 2 broken by stable sort (insertion order)
    assert(books[1].id == 1 or books[1].id == 2, "finished should sort to top with reverse")
end)

-- ─── lfs-entry shape tests ────────────────────────────────────────────────────

test("sort: lfs-shape title sorts using doc_props.display_title", function()
    local entries = {
        { name = "c.epub", doc_props = { display_title = "Charlie" } },
        { name = "a.epub", doc_props = { display_title = "Alice" } },
        { name = "b.epub", doc_props = { display_title = "Bob" } },
    }
    SortEngine.sort(entries, { { key = "title", reverse = false } })
    assert(entries[1].doc_props.display_title == "Alice",
           "expected Alice first, got " .. tostring(entries[1].doc_props.display_title))
    assert(entries[2].doc_props.display_title == "Bob")
    assert(entries[3].doc_props.display_title == "Charlie")
end)

test("sort: lfs-shape title falls back to name when no doc_props", function()
    local entries = {
        { name = "Charlie.epub" },
        { name = "Alice.epub" },
        { name = "Bob.epub" },
    }
    SortEngine.sort(entries, { { key = "title", reverse = false } })
    assert(entries[1].name == "Alice.epub",
           "expected Alice.epub first, got " .. tostring(entries[1].name))
end)

test("sort: lfs-shape last_opened reads _last_read", function()
    local entries = {
        { name = "a.epub", _last_read = 200 },
        { name = "b.epub", _last_read = 100 },
        { name = "c.epub", _last_read = 300 },
    }
    SortEngine.sort(entries, { { key = "last_opened", reverse = true } })
    assert(entries[1].name == "c.epub",
           "expected c.epub (most recent) first, got " .. tostring(entries[1].name))
    assert(entries[3].name == "b.epub",
           "expected b.epub (oldest) last, got " .. tostring(entries[3].name))
end)

test("sort: lfs-shape size reads attr.size", function()
    local entries = {
        { name = "a.epub", attr = { size = 300 } },
        { name = "b.epub", attr = { size = 100 } },
        { name = "c.epub", attr = { size = 200 } },
    }
    SortEngine.sort(entries, { { key = "size", reverse = false } })
    assert(entries[1].name == "b.epub",
           "expected b.epub (smallest) first, got " .. tostring(entries[1].name))
    assert(entries[3].name == "a.epub",
           "expected a.epub (largest) last, got " .. tostring(entries[3].name))
end)

test("sort: lfs-shape date_added reads attr.modification", function()
    local entries = {
        { name = "a.epub", attr = { modification = 1000 } },
        { name = "b.epub", attr = { modification = 3000 } },
        { name = "c.epub", attr = { modification = 2000 } },
    }
    SortEngine.sort(entries, { { key = "date_added", reverse = true } })
    assert(entries[1].name == "b.epub",
           "expected b.epub (newest) first, got " .. tostring(entries[1].name))
    assert(entries[3].name == "a.epub",
           "expected a.epub (oldest) last, got " .. tostring(entries[3].name))
end)

-- ─── group-shape tests ───────────────────────────────────────────────────────
-- Group shapes (series / authors / genres / tags) carry: series_name, filepaths,
-- latest, kind. No title/filename/last_opened/book_count fields.

test("sort: group-shape name via series_name", function()
    local groups = {
        { series_name = "Foundation", filepaths = { "a", "b" }, latest = 100 },
        { series_name = "Asimov",     filepaths = { "c" },      latest = 200 },
    }
    -- "name" group sort maps to filename key (legacy "name" -> filename in
    -- _groupShapeCmp). Filename comparator falls back to series_name.
    SortEngine.sort(groups, { { key = "filename", reverse = false } })
    assert(groups[1].series_name == "Asimov",
           "expected Asimov first, got " .. tostring(groups[1].series_name))
end)

test("sort: group-shape last_opened reads latest", function()
    local groups = {
        { series_name = "A", latest = 100 },
        { series_name = "B", latest = 200 },
    }
    SortEngine.sort(groups, { { key = "last_opened", reverse = true } })
    assert(groups[1].series_name == "B",
           "expected B (latest=200) first, got " .. tostring(groups[1].series_name))
end)

test("sort: group-shape book_count reads #filepaths", function()
    local groups = {
        { series_name = "A", filepaths = { "x" } },
        { series_name = "B", filepaths = { "x", "y", "z" } },
    }
    SortEngine.sort(groups, { { key = "book_count", reverse = true } })
    assert(groups[1].series_name == "B",
           "expected B (3 books) first, got " .. tostring(groups[1].series_name))
end)

test("sort: status comparator recognises 'complete' alongside 'finished'", function()
    local books = {
        { id = 1, _status = "reading"  },
        { id = 2, _status = "complete" },
        { id = 3, _status = "unread"   },
    }
    SortEngine.sort(books, { { key = "read_status", reverse = false } })
    -- unread < reading < complete
    assert(books[1].id == 3, "expected unread first, got id=" .. books[1].id)
    assert(books[2].id == 1, "expected reading second, got id=" .. books[2].id)
    assert(books[3].id == 2, "expected complete last, got id=" .. books[3].id)
end)

test("sort: percent_read treats 'complete' as 1.0", function()
    local books = {
        { id = 1, percent_finished = 0.5,  _status = "reading"  },
        { id = 2, percent_finished = 0.85, _status = "complete" },
    }
    SortEngine.sort(books, { { key = "percent_read", reverse = true } })
    assert(books[1].id == 2,
           "expected complete (treated as 1.0) first, got id=" .. books[1].id)
end)

-- ─── author surname / given-name extraction tests ────────────────────────────

test("surname: Forename Surname form", function()
    local books = {
        { id = 1, authors = "Frank Herbert" },
        { id = 2, authors = "Isaac Asimov" },
    }
    SortEngine.sort(books, { { key = "author_surname", reverse = false } })
    assert(books[1].id == 2, "Asimov should sort before Herbert; got " .. books[1].id)
end)

test("surname: Surname, Forename form", function()
    local books = {
        { id = 1, authors = "Pratchett, Terry" },
        { id = 2, authors = "Adams, Douglas" },
    }
    SortEngine.sort(books, { { key = "author_surname", reverse = false } })
    assert(books[1].id == 2, "Adams should sort before Pratchett")
end)

test("surname: particle compound (Le Guin)", function()
    local books = {
        { id = 1, authors = "Ursula K. Le Guin" },
        { id = 2, authors = "Maya Angelou" },
    }
    SortEngine.sort(books, { { key = "author_surname", reverse = false } })
    -- Angelou < Le Guin
    assert(books[1].id == 2)
end)

test("surname: multi-author picks the first", function()
    local books = {
        { id = 1, authors = "Pratchett, Terry & Gaiman, Neil" },
        { id = 2, authors = "Asimov, Isaac" },
    }
    SortEngine.sort(books, { { key = "author_surname", reverse = false } })
    assert(books[1].id == 2)  -- Asimov < Pratchett
end)

test("surname: caches on record", function()
    local b = { authors = "Frank Herbert" }
    SortEngine.sort({ b, { authors = "Asimov, Isaac" } }, { { key = "author_surname", reverse = false } })
    assert(b._surname_cache == "herbert", "cache should be 'herbert' got " .. tostring(b._surname_cache))
end)

test("surname: group shape falls back to series_name", function()
    -- Authors-tab group shape: the author's full name is in series_name.
    local groups = {
        { series_name = "Frank Herbert", filepaths = {} },
        { series_name = "Isaac Asimov",  filepaths = {} },
    }
    SortEngine.sort(groups, { { key = "author_surname", reverse = false } })
    assert(groups[1].series_name == "Isaac Asimov")
end)

test("given: 'Surname, Forename' form", function()
    local books = {
        { id = 1, authors = "Pratchett, Terry" },
        { id = 2, authors = "Pratchett, Andrew" },
    }
    SortEngine.sort(books, { { key = "author_name", reverse = false } })
    assert(books[1].id == 2, "Andrew should sort before Terry")
end)

test("given: single-word authors sort alphabetically (not all tied at empty)", function()
    -- Folders named just by surname / handle (no forename) should still
    -- sort in alphabetical position when the user picks "Author (given
    -- name)". The parser treats the single word as both surname and given.
    local groups = {
        { id = 1, series_name = "Macintyre" },
        { id = 2, series_name = "Barnes" },
        { id = 3, series_name = "Grisham" },
    }
    SortEngine.sort(groups, { { key = "author_name", reverse = false } })
    assert(groups[1].id == 2, "Barnes should sort first; got id=" .. groups[1].id)
    assert(groups[2].id == 3, "Grisham should sort second; got id=" .. groups[2].id)
end)

-- ─── performance sanity test ─────────────────────────────────────────────────

test("perf: 3000 books, one parse per book during sort", function()
    local books = {}
    for i = 1, 3000 do
        books[i] = { id = i, authors = "Author " .. tostring(3000 - i) }
    end
    local t0 = os.clock()
    SortEngine.sort(books, { { key = "author_surname", reverse = false } })
    local t1 = os.clock()
    -- Less a hard ceiling, more a smoke test the memoization actually works.
    -- On a developer laptop this is <50ms. If it ever takes >2s the cache is broken.
    assert((t1 - t0) < 2.0, ("3000-book sort took %.3fs"):format(t1 - t0))
    -- Verify every book has a cached surname (memoization actually populated)
    local cached = 0
    for _, b in ipairs(books) do
        if b._surname_cache ~= nil then cached = cached + 1 end
    end
    assert(cached == 3000, "expected 3000 cached, got " .. cached)
end)

test("filename key derives from filepath when no filename field (#235)", function()
    -- Group-shape meta (_cacheGroupShapes) carries filepath + series_name but
    -- no `filename`. A "Filename" within-group sort must order by the real file
    -- name, NOT fall through to series_name (which clustered series members and
    -- pushed standalones to the end). Series books share a series_name; without
    -- the fix they'd cluster + tie to title, and the standalone would sort last.
    local books = {
        { id = 1, filepath = "/b/Greek Myths - 2 - Heroes.epub",  series_name = "Greek Myths" },
        { id = 2, filepath = "/b/Greek Myths - 1 - Mythos.epub",  series_name = "Greek Myths" },
        { id = 3, filepath = "/b/Mythology - Edith Hamilton.epub" },  -- standalone, no series
    }
    SortEngine.sort(books, { { key = "filename", reverse = false } })
    -- Real filename order (natsort): "Greek Myths - 1 - Mythos", "…- 2 - Heroes",
    -- "Mythology…" => ids 2, 1, 3. The old fallback-to-series_name tied the two
    -- series books on "Greek Myths" (no filename/title to break it) so they kept
    -- input order 1, 2 => a different result, which is what this guards against.
    assert(eq(ids(books), { 2, 1, 3 }),
        "expected filename order 2,1,3 (Mythos, Heroes, Mythology), got " .. table.concat(ids(books), ","))
end)

-- ── mixed group + standalone lists (issue #400) ────────────────────────────
--
-- A Series source with "standalone and books in series" hands the comparator
-- BOTH series-group shapes and standalone book shapes. Sorted by Name -- which
-- on a group chip is the series_name key -- every standalone used to land at
-- the end, because cachedSeriesKey read only `series_name or series` and a
-- standalone has neither. cmp's isMissing then fired and SORT_TO_END put the
-- lot behind the groups, so the shelf looked partitioned: all series first,
-- all loose books after, each run alphabetical.
--
-- Reported with photos from a Kindle Colorsoft: "The Dark Tower" (a 7-book
-- group) sat ahead of Abraham Lincoln, Cujo and Eye of the Needle, when by
-- name it belongs between Cujo and Eye.
--
-- The standalone shape already carries title/filename precisely so it can
-- interleave -- its own comment says the fields are there "so _groupShapeCmp
-- interleaves the mixed list for free" -- and the filename key already has the
-- mirror-image fallback from issue #235. This is the same repair on the series
-- key, scoped to shapes flagged `standalone` so real Book records keep today's
-- behaviour in the author / library / genre chains, where a seriesless book
-- sinking below an author's series runs is wanted.

test("sort: a standalone interleaves with group names, not after them", function()
    -- Leading articles are NOT stripped, for either kind: the reporter's own
    -- shelf shows "The Outsider: A Novel" sorting after "Eye of the Needle".
    -- So "The Dark Tower" belongs under T, among the other The- titles -- the
    -- point is that it takes a place in the sequence at all, rather than being
    -- hoisted above every loose book.
    local items = {
        { standalone = true, title = "Cujo" },
        { series_name = "The Dark Tower", filepaths = { "a", "b" } },
        { standalone = true, title = "Abraham Lincoln" },
        { standalone = true, title = "Eye of the Needle" },
        { standalone = true, title = "The Outsider: A Novel" },
    }
    table.sort(items, SortEngine.chainedComparator{
        { key = "series_name", reverse = false } })
    local names = {}
    for _i, it in ipairs(items) do
        names[#names + 1] = it.series_name or it.title
    end
    local got = table.concat(names, " | ")
    assert(got == "Abraham Lincoln | Cujo | Eye of the Needle | "
                  .. "The Dark Tower | The Outsider: A Novel",
        "the group did not take its alphabetical place, got: " .. got)
end)

test("sort: a standalone falls back to filename when it has no title", function()
    local items = {
        { series_name = "Zork", filepaths = { "a" } },
        { standalone = true, filename = "Alpha" },
    }
    table.sort(items, SortEngine.chainedComparator{
        { key = "series_name", reverse = false } })
    assert(items[1].filename == "Alpha",
        "a titleless standalone did not fall back to its filename")
end)

test("sort: a real BOOK with no series still sinks to the end", function()
    -- The scope guard. These chains -- author, library, genre -- sort
    -- author_surname then series_name, and a seriesless book belongs after
    -- that author's series runs rather than interleaved among them. Only
    -- shapes explicitly flagged `standalone` get the fallback.
    local items = {
        { title = "Aaa book", filename = "Aaa book" },          -- no series, no flag
        { series_name = "Zzz series", filepaths = { "a" } },
    }
    table.sort(items, SortEngine.chainedComparator{
        { key = "series_name", reverse = false } })
    assert(items[1].series_name == "Zzz series",
        "a seriesless BOOK record was interleaved; the fallback is not scoped "
        .. "to standalone shapes")
end)

io.write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
