-- tests/_test_token_record.lua
-- Pure-Lua tests for the lazy token adapter.
-- Usage (from plugin root): lua tests/_test_token_record.lua
--
-- The property under test is one sentence: Tokens.expand must work on a
-- WRAPPED SHELF RECORD with no change to lib/bookshelf_tokens.lua. So the
-- expansions below go through the real Tokens module, unstubbed, against the
-- real shelf record shape (helpers.shelf_record), and the controls run the
-- SAME expansion on the SAME record unwrapped -- because a test that only
-- asserts the wrapped case cannot tell a working adapter from a fixture that
-- was carrying the answer all along, which is precisely how the column
-- accessors passed for five rounds while every one of these read empty on the
-- device.

package.path = "./?.lua;./?/init.lua;" .. package.path

package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }
package.loaded["lib/bookshelf_settings_store"] = {
    read   = function(_k, default) return default end,
    save   = function() end,
    isTrue = function() return false end,
    flush  = function() end,
}
package.loaded["lib/bookshelf_localdate"] = {
    localize = function(s) return s end,
}

-- ── The three disk-touching sources, stubbed and COUNTED ───────────────────
-- Every counter here is an assertion waiting to happen: the adapter's whole
-- justification is that it is cheaper than buildBook, and "cheaper" has to be
-- a number rather than a claim. Three separate counters, not one, because
-- three separate costs are being bounded and a single total would hide one of
-- them growing while another shrank.
local SIDECAR, FILESIZE, MTIME = {}, {}, {}
local calls = { progress = 0, size = 0, stat = 0, rh = 0, rh_walk = 0,
                stats = 0 }
local function resetCalls()
    calls.progress, calls.size, calls.stat = 0, 0, 0
    calls.rh, calls.rh_walk = 0, 0
    calls.stats = 0
end

-- statistics.sqlite3 roll-ups, keyed by filepath (what enrichStats fills).
local STATS = {
    ["/books/read.epub"] = {
        book_read_time_seconds = 27780,   -- 7h 43m
        book_pages_read        = 610,
        days_reading_book      = 12,
        pages_per_day          = 51,
        speed_pph              = 79,
        book_time_left_minutes = 0,
    },
}

package.loaded["lib/bookshelf_book_repository"] = {
    progressFor = function(fp)
        calls.progress = calls.progress + 1
        local s = SIDECAR[fp]
        if not s then return nil, nil, nil, nil, false end
        return s.pct, s.status, s.rating, s.pages, true
    end,
    fileSizeFor = function(fp)
        calls.size = calls.size + 1
        return FILESIZE[fp]
    end,
    -- Mirrors the real enrichStats contract: mutates the passed table,
    -- fills nothing when the book has no statistics row.
    enrichStats = function(book)
        calls.stats = calls.stats + 1
        local st = STATS[book.filepath]
        if not st then return end
        for k, v in pairs(st) do book[k] = v end
    end,
}

-- lfs, for the date_added stat. Keyed form only, which is what the resolver
-- asks for.
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(fp, key)
        calls.stat = calls.stat + 1
        if key == "modification" then return MTIME[fp] end
        return nil
    end,
}

-- ReadHistory. `hist` is mutated IN PLACE by the real one -- a freshly closed
-- book moves to slot 1 with a new time -- so the stub keeps one table and
-- reorders it, which is the shape the adapter's fingerprint has to cope with.
local RH = { hist = {} }
package.loaded["readhistory"] = setmetatable({}, {
    __index = function(_t, k)
        if k == "hist" then
            calls.rh = calls.rh + 1
            return RH.hist
        end
        return nil
    end,
})
-- "Was the map rebuilt?" measured with a probe rather than a total. Lua 5.1 /
-- LuaJIT's ipairs uses rawgeti, so the walk cannot be counted on the list --
-- only on what it hands back. Counting EVERY entry would conflate the walk
-- with the O(1) fingerprint check, which reads slot 1 on every row by design,
-- so only entries from slot 2 down are instrumented: nothing but a full walk
-- ever touches those.
local function countingEntry(e)
    return setmetatable({}, { __index = function(_t, k)
        calls.rh_walk = calls.rh_walk + 1
        return e[k]
    end })
end
local function setHistory(entries)
    for i = #RH.hist, 1, -1 do RH.hist[i] = nil end
    for i, e in ipairs(entries) do
        RH.hist[i] = (i == 1) and e or countingEntry(e)
    end
end

-- DocSettings, for the annotation counts. Counted like the three above: the
-- memo in front of it is the thing under test, and "memoised" has to be a
-- number rather than a claim.
local ANNOTATIONS = {}
local ds_calls = 0
package.loaded["docsettings"] = {
    hasSidecarFile = function(_self, fp) return ANNOTATIONS[fp] ~= nil end,
    open = function(_self, fp)
        ds_calls = ds_calls + 1
        return { readSetting = function(_s, key)
            if key == "annotations" then return ANNOTATIONS[fp] end
            return nil
        end }
    end,
}

-- Clock under the test's control, so the memo window can be crossed without
-- sleeping. The module resolves os.time() per call, so this is live.
local NOW = 1000
os.time = function() return NOW end

local helpers = dofile("tests/_helpers.lua")
local t       = helpers.runner()

local TokenRecord = require("lib/bookshelf_token_record")
local Tokens      = require("lib/bookshelf_tokens")

local shelfRecord = helpers.shelf_record
local eq          = helpers.eq

local function fresh(fp, extra)
    resetCalls()
    TokenRecord.forgetReadHistory()
    return shelfRecord(fp or "/books/salem.epub", extra)
end

-- ── The regression set ─────────────────────────────────────────────────────
--
-- Eight things the maintainer found empty on the device, one at a time, over
-- five rounds: Progress, Rating, Pages, Status, File size, Format, Added,
-- Opened. Five of the eight have a token today and are asserted here through
-- Tokens.expand end to end. Three -- File size, Added, Opened -- have NO
-- token in lib/bookshelf_tokens.lua at all (there is no %size, %added or
-- %opened; the nearest names, %page_count and %status, are already spoken
-- for), so they are asserted one level down, at the field the adapter
-- resolves. Adding those three expanders is a token-file change and is not
-- this task; the point of asserting the field is that when they are added
-- they will work without touching this module.
t.test("regression set: the five that have a token, through Tokens.expand",
function()
    local fp = "/books/salem.epub"
    local b = fresh(fp)
    SIDECAR[fp]  = { pct = 0.62, status = "reading", rating = 4, pages = 616 }
    FILESIZE[fp] = 1536000
    MTIME[fp]    = 1700000000
    setHistory{ { file = fp, time = 1755000000 } }

    local w = TokenRecord.wrap(b)
    local cases = {
        { "%book_pct",   "62%",     "Progress" },
        { "%rating",     "\xE2\x98\x85\xE2\x98\x85\xE2\x98\x85\xE2\x98\x85\xE2\x98\x86", "Rating" },
        { "%page_count", "616",     "Pages"    },
        { "%status",     "reading", "Status"   },
        { "%format",     "EPUB",    "Format"   },
    }
    for _i, c in ipairs(cases) do
        local got = Tokens.expand(c[1], w, {})
        assert(got == c[2], string.format(
            "%s (%s): wrapped record expanded to %q, expected %q",
            c[3], c[1], tostring(got), c[2]))
    end
end)

t.test("regression set: the control -- unwrapped, four of the five are empty",
function()
    -- The test that would have caught the bug. Without the adapter the shelf's
    -- own record answers nothing for the first four; %format is the odd one
    -- out because buildBookMeta really does set it, and it is here so the
    -- control cannot be read as "the fixture has nothing on it".
    local fp = "/books/salem.epub"
    local b = fresh(fp)
    SIDECAR[fp] = { pct = 0.62, status = "reading", rating = 4, pages = 616 }

    for _i, tok in ipairs{ "%book_pct", "%rating", "%page_count" } do
        assert(Tokens.expand(tok, b, {}) == "", string.format(
            "%s already expanded on a bare shelf record -- the fixture has "
            .. "grown a field the shelf does not supply, and this suite can "
            .. "no longer see the bug it exists for", tok))
    end
    -- %status has no empty form: its own contract floors at "unread", which
    -- is exactly the wrong answer for a book that is 62% read.
    assert(Tokens.expand("%status", b, {}) == "unread",
        "%status on a bare shelf record should read the never-opened floor")
    assert(Tokens.expand("%format", b, {}) == "EPUB",
        "%format is on the record itself and must not need the adapter")
end)

t.test("regression set: the other three, field AND token", function()
    local fp = "/books/salem.epub"
    local b = fresh(fp)
    FILESIZE[fp] = 1536000
    MTIME[fp]    = 1700000000
    setHistory{ { file = fp, time = 1755000000 } }

    -- Absent on the record the shelf renders...
    assert(b.size == nil and b.date_added == nil and b.last_opened == nil,
        "the shelf fixture is carrying one of the three; see helpers.shelf_record")
    -- ...and resolved through the wrapper.
    local w = TokenRecord.wrap(b)
    assert(w.size == 1536000,
        "File size: got " .. tostring(w.size))
    assert(w.date_added == 1700000000,
        "Added: got " .. tostring(w.date_added))
    assert(w.last_opened == 1755000000,
        "Opened: got " .. tostring(w.last_opened))

    -- %size / %added / %opened now exist, so the three go end to end like the
    -- five above rather than stopping at the field. This is the case the
    -- earlier revision of this test was written to become.
    local cases = {
        { "%size",   "1.5 MB",                            "File size" },
        { "%added",  os.date("%Y-%m-%d", 1700000000),     "Added"     },
        { "%opened", os.date("%Y-%m-%d", 1755000000),     "Opened"    },
    }
    for _i, c in ipairs(cases) do
        local got = Tokens.expand(c[1], w, {})
        assert(got == c[2], string.format(
            "%s (%s): wrapped record expanded to %q, expected %q",
            c[3], c[1], tostring(got), c[2]))
    end
end)

t.test("regression set: the control -- the other three are empty unwrapped",
function()
    local fp = "/books/salem.epub"
    local b = fresh(fp)
    FILESIZE[fp] = 1536000
    MTIME[fp]    = 1700000000
    setHistory{ { file = fp, time = 1755000000 } }
    for _i, tok in ipairs{ "%size", "%added", "%opened" } do
        assert(Tokens.expand(tok, b, {}) == "", string.format(
            "%s expanded on a BARE shelf record -- either the fixture grew a "
            .. "field the shelf does not supply, or the expander is reading "
            .. "something other than the field the adapter resolves", tok))
    end
end)

t.test("a catalogue row has no file, so it has no size and no dates", function()
    -- bookshelf_opds_feed.lua stamps attr = { size = 0, modification = 0 } on
    -- every record it parses. Rendered through the columns that preceded this,
    -- that put "0 B" down a whole Internet Archive feed; the adapter's OPDS
    -- guard is what stops the same happening to a token line.
    local b = fresh("OPDS://server/42")
    b.attr = { mode = "file", size = 0, modification = 0 }
    local w = TokenRecord.wrap(b)
    for _i, tok in ipairs{ "%size", "%added", "%opened" } do
        assert(Tokens.expand(tok, w, {}) == "", tok
            .. " rendered a measurement of a file that does not exist")
    end
    assert(calls.size == 0 and calls.stat == 0,
        "a catalogue row must cost no stats: size=" .. calls.size
        .. " stat=" .. calls.stat)
end)

-- ── Cost ───────────────────────────────────────────────────────────────────

t.test("four progress tokens on one row cost ONE sidecar lookup", function()
    local fp = "/books/salem.epub"
    local b = fresh(fp)
    SIDECAR[fp] = { pct = 0.62, status = "reading", rating = 4, pages = 616 }
    local w = TokenRecord.wrap(b)
    local out = Tokens.expand(
        "%book_pct %book_pct_left %rating %rating_number %status %page_count",
        w, {})
    assert(out == "62% 38% \xE2\x98\x85\xE2\x98\x85\xE2\x98\x85\xE2\x98\x85\xE2\x98\x86 4 reading 616",
        "unexpected expansion: " .. out)
    assert(calls.progress == 1, string.format(
        "six progress-derived tokens cost %d sidecar lookups; the fill has "
        .. "stopped answering its siblings", calls.progress))
end)

t.test("a warm wrapper touches nothing at all", function()
    local fp = "/books/salem.epub"
    local b = fresh(fp)
    SIDECAR[fp]  = { pct = 0.62, status = "reading", rating = 4, pages = 616 }
    FILESIZE[fp] = 1536000
    MTIME[fp]    = 1700000000
    setHistory{ { file = fp, time = 1755000000 } }
    local w = TokenRecord.wrap(b)

    local fmt = "%book_pct %rating %page_count %status"
    Tokens.expand(fmt, w, {})
    local _ = w.size, w.date_added, w.last_opened
    local cold = { calls.progress, calls.size, calls.stat }

    resetCalls()
    Tokens.expand(fmt, w, {})
    local __ = w.size, w.date_added, w.last_opened
    assert(calls.progress == 0 and calls.size == 0 and calls.stat == 0,
        string.format("a re-render of the same wrapper cost progress=%d "
            .. "size=%d stat=%d; cold was %d/%d/%d",
            calls.progress, calls.size, calls.stat,
            cold[1], cold[2], cold[3]))
end)

t.test("a page of rows is linear, not multiplied", function()
    -- 27 rows, the Paperwhite 5's list-mode page, every one of them naming
    -- every resolved field. The number that matters is not "small", it is
    -- "one per row per SOURCE" -- a fill that stopped answering its siblings
    -- would make this 27 x 4 and still look cheap next to buildBook.
    resetCalls()
    TokenRecord.forgetReadHistory()
    local hist = {}
    for i = 1, 27 do
        local fp = string.format("/books/b%02d.epub", i)
        SIDECAR[fp]  = { pct = i / 100, status = "reading", pages = 100 + i }
        FILESIZE[fp] = 1000 * i
        MTIME[fp]    = 1700000000 + i
        hist[i] = { file = fp, time = 1750000000 + i }
    end
    setHistory(hist)

    local after_first_row
    for i = 1, 27 do
        local fp = string.format("/books/b%02d.epub", i)
        local w = TokenRecord.wrap(shelfRecord(fp))
        Tokens.expand("%title %book_pct %rating %page_count %status", w, {})
        local _ = w.size, w.date_added, w.last_opened
        if i == 1 then after_first_row = calls.rh_walk end
    end
    assert(calls.progress == 27, "sidecar lookups: " .. calls.progress)
    assert(calls.size     == 27, "size lookups: "    .. calls.size)
    assert(calls.stat     == 27, "mtime stats: "     .. calls.stat)
    -- The ReadHistory map is the one thing that must NOT be per-row: building
    -- it walks the whole history (~50 entries on a real device) and 27 of
    -- those is the "multiply the disk touches" failure in miniature. The
    -- fingerprint check IS per row and is meant to be -- it is O(1).
    assert(after_first_row > 0, "the history was never walked at all")
    assert(calls.rh_walk == after_first_row, string.format(
        "the history was walked again after row 1 (%d entry reads, was %d "
        .. "after one row): the map is being rebuilt per row",
        calls.rh_walk, after_first_row))
    assert(calls.rh <= 27 + 1, string.format(
        "ReadHistory.hist was read %d times for 27 rows; the fingerprint "
        .. "check is no longer O(1)", calls.rh))
end)

t.test("a template that names no resolved field costs nothing", function()
    local b = fresh("/books/salem.epub")
    SIDECAR["/books/salem.epub"] = { pct = 0.62, status = "reading" }
    local w = TokenRecord.wrap(b)
    local out = Tokens.expand("%title by %author %format", w, {})
    assert(out == "T by  EPUB", "unexpected: " .. out)
    assert(calls.progress == 0 and calls.size == 0 and calls.stat == 0,
        string.format("a title/author/format line cost progress=%d size=%d "
            .. "stat=%d; laziness is not lazy", calls.progress, calls.size,
            calls.stat))
end)

t.test("a catalogue row never reaches the disk", function()
    -- OPDS:// is a pseudo-path with no file behind it. Statting one is both
    -- wasted work on every row of a feed and a measurement of a file that
    -- does not exist.
    resetCalls()
    TokenRecord.forgetReadHistory()
    local b = { filepath = "OPDS://gutenberg/1234", title = "Ulysses",
                format = "EPUB" }
    local w = TokenRecord.wrap(b)
    assert(Tokens.expand("%book_pct", w, {}) == "")
    assert(w.size == nil and w.date_added == nil and w.last_opened == nil)
    assert(calls.progress == 0 and calls.size == 0 and calls.stat == 0,
        string.format("a catalogue row cost progress=%d size=%d stat=%d",
            calls.progress, calls.size, calls.stat))
    -- A record with no filepath at all -- an lfs shape, a stub -- same answer.
    resetCalls()
    local w2 = TokenRecord.wrap({ title = "no path" })
    assert(w2.size == nil and w2.book_pct == nil)
    assert(calls.progress == 0 and calls.size == 0 and calls.stat == 0)
end)

-- ── Absence, and staying absent ────────────────────────────────────────────

t.test("a field with no value resolves once and stays nil", function()
    -- The trap the __index mechanism sets for itself: __index fires on EVERY
    -- read of an absent key, so a resolver that answers nil re-runs -- with
    -- its stat -- for as long as the wrapper lives. A never-opened book is
    -- the COMMON case, not the edge one, so getting this wrong would cost
    -- most of a library its laziness.
    local fp = "/books/never-opened.epub"
    local b = fresh(fp)          -- no SIDECAR, no FILESIZE, no MTIME, no history
    local w = TokenRecord.wrap(b)
    for _i = 1, 10 do
        assert(w.book_pct == nil, "book_pct should stay nil")
        assert(w.rating == nil, "rating should stay nil")
        assert(w.size == nil, "size should stay nil")
        assert(w.last_opened == nil, "last_opened should stay nil")
    end
    assert(calls.progress == 1, string.format(
        "ten reads of two absent progress fields cost %d lookups, not 1",
        calls.progress))
    assert(calls.size == 1, "size lookups: " .. calls.size)
end)

t.test("false is a value, not an absence", function()
    -- No resolved field is a boolean today, and the resolvers report absence
    -- with a private sentinel rather than with `false` precisely so the first
    -- one that is does not re-resolve on every read. What CAN be pinned today
    -- is the read-through half: a false on the record must come back as false
    -- and be memoised, not treated as "nothing here".
    local b = fresh("/books/salem.epub", { has_cover = false })
    local w = TokenRecord.wrap(b)
    assert(w.has_cover == false, "false read back as " .. tostring(w.has_cover))
    assert(rawget(w, "has_cover") == false,
        "false was not memoised onto the proxy, so every read re-enters "
        .. "__index -- which for a resolved field would mean a stat per read")
    -- And the absence sentinel is not false: a resolver answering nothing
    -- must not be able to hand `false` back as if it were a value.
    local b2 = fresh("/books/never-opened.epub")
    local w2 = TokenRecord.wrap(b2)
    assert(w2.rating == nil, "an unresolved field must be nil, not false; got "
        .. tostring(w2.rating))
end)

-- ── Precedence ─────────────────────────────────────────────────────────────

t.test("the record's own value always wins, including over a sibling fill",
function()
    -- BIM gives a page count for pre-paginated formats and none for reflowed
    -- EPUBs. Where it gives one, the sidecar's must not displace it -- and
    -- the subtle way to break that is through the sibling fill: asking for
    -- %book_pct runs the progress resolver, which answers page_count too.
    local fp = "/books/comic.cbz"
    local b = fresh(fp, { page_count = 44 })
    SIDECAR[fp] = { pct = 0.5, status = "reading", pages = 999 }
    local w = TokenRecord.wrap(b)
    assert(Tokens.expand("%book_pct", w, {}) == "50%")
    assert(w.page_count == 44, string.format(
        "the sidecar's count (%s) displaced BIM's (44)", tostring(w.page_count)))
    assert(Tokens.expand("%page_count", w, {}) == "44")
end)

t.test("a record that carries date_added is never stat'ed for it", function()
    local fp = "/books/known.epub"
    local b = fresh(fp, { attr = { modification = 1690000000 } })
    local w = TokenRecord.wrap(b)
    assert(w.date_added == 1690000000, "got " .. tostring(w.date_added))
    assert(calls.stat == 0, "stat'ed a record that already had the answer")
end)

-- ── The wrapper is not a record ────────────────────────────────────────────

t.test("wrapping does not mutate, and unwrap gets the original back", function()
    local fp = "/books/salem.epub"
    local b = fresh(fp)
    SIDECAR[fp] = { pct = 0.62, status = "reading", rating = 4, pages = 616 }
    local w = TokenRecord.wrap(b)
    Tokens.expand("%book_pct %rating %page_count %status", w, {})

    assert(b.book_pct == nil and b.rating == nil and b.status == nil
           and b.page_count == nil,
        "the adapter wrote resolved fields back onto the record; a record "
        .. "that has been rendered once would then be indistinguishable from "
        .. "a buildBook one everywhere else in the plugin")
    assert(TokenRecord.unwrap(w) == b, "unwrap did not return the record")
    assert(TokenRecord.isWrapper(w), "a wrapper must be identifiable")
    assert(not TokenRecord.isWrapper(b), "a plain record is not a wrapper")
    -- Idempotent both ways, so a boundary can call either without asking.
    assert(TokenRecord.unwrap(b) == b, "unwrap on a plain record must be a no-op")
    assert(TokenRecord.wrap(w) == w, "wrap must not stack proxies")
    assert(TokenRecord.wrap(nil) == nil and TokenRecord.wrap(7) == 7,
        "wrap must pass a non-table straight through")
end)

t.test("a write to the wrapper shadows; it does not reach the record",
function()
    local b = fresh("/books/salem.epub")
    local w = TokenRecord.wrap(b)
    w.title = "shadowed"
    assert(w.title == "shadowed")
    assert(b.title == "T", "a write through the wrapper mutated the record")
end)

t.test("pairs() over a wrapper is lossy, and that is pinned", function()
    -- Lua 5.1 / LuaJIT does not honour __pairs, so a wrapper CANNOT be made
    -- to enumerate like a record. This is the leak hazard stated as a test
    -- rather than as a comment: anything that copies, serialises or caches a
    -- record must unwrap first, and the way that goes wrong is silently, with
    -- a subset.
    local fp = "/books/salem.epub"
    local b = fresh(fp)
    SIDECAR[fp] = { pct = 0.62, status = "reading", rating = 4, pages = 616 }
    local w = TokenRecord.wrap(b)
    assert(w.book_pct == 0.62)
    local copied = {}
    for k, v in pairs(w) do copied[k] = v end
    assert(copied.book_pct == 0.62, "a resolved field should be enumerable")
    assert(copied.title == nil, string.format(
        "pairs() over a wrapper enumerated an UNRESOLVED record field (%s), "
        .. "which means this hazard has changed shape and the module header "
        .. "and every unwrap call site need re-reading", tostring(copied.title)))
    -- The supported way to copy.
    local safe = {}
    for k, v in pairs(TokenRecord.unwrap(w)) do safe[k] = v end
    assert(safe.title == "T", "unwrap then copy must get the whole record")
end)

-- ── ReadHistory ────────────────────────────────────────────────────────────

t.test("the ReadHistory map is rebuilt when the history moves", function()
    -- The real ReadHistory reorders `hist` in place, so the table's identity
    -- cannot be the cache key. Closing a book puts it at slot 1 with a new
    -- time, which is the change the fingerprint has to see.
    local fp = "/books/salem.epub"
    local other = "/books/other.epub"
    resetCalls()
    TokenRecord.forgetReadHistory()
    setHistory{ { file = other, time = 100 }, { file = fp, time = 50 } }
    assert(TokenRecord.wrap(shelfRecord(fp)).last_opened == 50)

    setHistory{ { file = fp, time = 900 }, { file = other, time = 100 } }
    assert(TokenRecord.wrap(shelfRecord(fp)).last_opened == 900,
        "the map went stale after the just-closed book moved to slot 1")
end)

t.test("a book with no history has no last_opened, rather than 1970",
function()
    resetCalls()
    TokenRecord.forgetReadHistory()
    setHistory{ { file = "/books/other.epub", time = 100 } }
    local w = TokenRecord.wrap(shelfRecord("/books/unread.epub"))
    assert(w.last_opened == nil, "got " .. tostring(w.last_opened))
end)

-- ── The contract, pinned at the source ─────────────────────────────────────

t.test("the adapter needs no change to bookshelf_tokens.lua", function()
    -- The one property the whole exercise rests on. If a token expander ever
    -- has to know about sidecars, the adapter has failed and the field
    -- belongs in its RESOLVERS instead -- there are sixty expanders and one
    -- adapter.
    -- Comment lines dropped first: that file's header explains at length
    -- which data sources it does NOT reach for, naming book_repository, and
    -- matching the prose would fire this on its own documentation.
    local code = {}
    for line in io.lines("lib/bookshelf_tokens.lua") do
        if not line:match("^%s*%-%-") then code[#code + 1] = line end
    end
    local src = table.concat(code, "\n")
    assert(not src:match("bookshelf_token_record"),
        "bookshelf_tokens.lua now knows about the adapter")
    assert(not src:match("progressFor") and not src:match("fileSizeFor"),
        "a token expander is reaching for a repository accessor; that work "
        .. "belongs in lib/bookshelf_token_record.lua's RESOLVERS")
    assert(not src:match("book_repository"),
        "bookshelf_tokens.lua now depends on the repository")
    assert(not src:match("readhistory"),
        "a token expander is reaching for ReadHistory; that work belongs in "
        .. "lib/bookshelf_token_record.lua's RESOLVERS")
end)

t.test("stats tokens answer through the wrapper like they do on the hero",
function()
    -- The Reddit report: %book_read_time showed in the hero and the line
    -- preview but never in an actual list row. The wrapper must make a shelf
    -- record answer what the enriched hero record answers.
    resetCalls()
    local rec = TokenRecord.wrap(fresh("/books/read.epub"))
    assert(rec.book_read_time_seconds == 27780,
        "book_read_time_seconds must resolve through enrichStats")
    assert(rec.book_pages_read == 610, "book_pages_read must resolve")
    assert(rec.speed_pph == 79, "speed_pph must resolve")
    -- One enrichment fills all six fields: sibling reads are free.
    assert(calls.stats == 1,
        "six stats fields must cost ONE enrichStats call, got " .. calls.stats)
end)

t.test("a book with no statistics answers empty, once", function()
    resetCalls()
    local rec = TokenRecord.wrap(fresh("/books/x.epub"))
    assert(rec.book_read_time_seconds == nil, "no stats row: nil")
    assert(rec.book_pages_read == nil, "no stats row: nil")
    assert(calls.stats == 1,
        "a missing stats row must not re-run the resolver per read, got "
        .. calls.stats)
end)

t.test("a catalogue row never pays for statistics", function()
    resetCalls()
    local b = fresh("OPDS://server/42")
    b.attr = { mode = "file", size = 0, modification = 0 }
    local rec = TokenRecord.wrap(b)
    local _ = rec.book_read_time_seconds
    assert(calls.stats == 0,
        "a catalogue row has no file, so it must cost no enrichStats call")
end)

t.test("every resolved field is one a shelf record really lacks", function()
    -- A resolver for a field buildBookMeta already sets would be dead weight
    -- that also looks like a bug (rule 1 means it can never run).
    local base = shelfRecord("/books/x.epub")
    for _i, k in ipairs(TokenRecord.RESOLVED_FIELDS) do
        assert(base[k] == nil, string.format(
            "%s is on the shelf record already; its resolver is unreachable", k))
    end
    -- 13 originally; +3 annotation counts, +avg_page_time_seconds and
    -- +book_pct_read as the orphaned and missing tokens were wired (#348). The
    -- count is asserted deliberately: a resolver appearing without someone
    -- noticing is how this file grows a field buildBookMeta already sets,
    -- which would then be unreachable.
    assert(#TokenRecord.RESOLVED_FIELDS == 18, string.format(
        "expected 18 resolved fields, found %d (%s)",
        #TokenRecord.RESOLVED_FIELDS,
        table.concat(TokenRecord.RESOLVED_FIELDS, ", ")))
end)

t.test("annotation counts are re-read after the memo window, not pinned forever", function()
    -- The memo had no TTL and no invalidation hook, unlike every other cache
    -- in this file -- whose own comment says an uninvalidated module-level
    -- memo "would be worse than the stat". Add a highlight in the reader, come
    -- back to the shelf, and %highlights showed the old count for the rest of
    -- the session.
    local fp = "/books/annotated.epub"
    ANNOTATIONS[fp] = { { drawer = "lighten" } }
    ds_calls = 0

    eq(tostring(TokenRecord.wrap(shelfRecord(fp)).highlights), "1")
    eq(ds_calls, 1, "first read should hit disk")

    -- a second read inside the window is memoised
    eq(tostring(TokenRecord.wrap(shelfRecord(fp)).highlights), "1")
    eq(ds_calls, 1, "second read inside the window should be memoised")

    -- the reader adds one, and the window passes
    ANNOTATIONS[fp] = { { drawer = "lighten" }, { drawer = "lighten" } }
    NOW = NOW + 3600
    eq(tostring(TokenRecord.wrap(shelfRecord(fp)).highlights), "2",
       "count went stale across the window")
    eq(ds_calls, 2, "expected exactly one more disk read")
end)

t.done()
