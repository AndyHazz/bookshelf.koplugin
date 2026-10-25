-- tests/_test_book_facts_db.lua
-- The per-book facts store, driven against REAL SQLite.
--
-- Stubbing the database would prove nothing: the claims worth making here are
-- about what SQLite does (upsert merging, a batched IN read, NULLing one
-- column and leaving its neighbours), so a fake would only assert my own
-- assumptions back at me.
--
-- Needs KOReader's tree for ljsqlite3, and ffi/loadlib must be required FIRST.
-- Skips cleanly under a plain interpreter so run.sh stays green:
--   /usr/lib/koreader/luajit tests/_test_book_facts_db.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

local KO = os.getenv("KOREADER_DIR") or "/usr/lib/koreader"
local function have_koreader()
    local f = io.open(KO .. "/common/lua-ljsqlite3/init.lua", "r")
    if f then f:close(); return true end
    return false
end
if not have_koreader() then
    print("SKIP: no KOReader tree at " .. KO .. " (set KOREADER_DIR); needs real sqlite")
    os.exit(0)
end
package.path  = KO .. "/frontend/?.lua;" .. KO .. "/common/?.lua;"
             .. KO .. "/common/?/init.lua;" .. KO .. "/?.lua;" .. package.path
package.cpath = KO .. "/common/?.so;" .. KO .. "/libs/?.so;"
             .. KO .. "/?.so;" .. package.cpath
if not pcall(require, "ffi/loadlib") then
    print("SKIP: ffi/loadlib unavailable"); os.exit(0)
end
if not pcall(require, "lua-ljsqlite3/init") then
    print("SKIP: ljsqlite3 will not load here"); os.exit(0)
end

package.loaded["logger"] = { dbg=function() end, info=function() end,
                             warn=function() end, err=function() end }
local TMPDIR = os.getenv("TMPDIR") or "/tmp"
local DBDIR = TMPDIR .. "/bookshelf_facts_db_test"
-- The store lives in settings/bookshelf/ (lib/bookshelf_paths), which the
-- paths module makes once per session; a test that wipes it makes it again.
os.execute("rm -rf '" .. DBDIR .. "' && mkdir -p '" .. DBDIR .. "/bookshelf'")
package.loaded["datastorage"] = { getSettingsDir = function() return DBDIR end }

local Facts = require("lib/bookshelf_book_facts_db")

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1 else
        fail = fail + 1
        io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n")
    end
end
local function fresh()
    Facts.close()
    -- The store lives in settings/bookshelf/ (lib/bookshelf_paths), which the
-- paths module makes once per session; a test that wipes it makes it again.
os.execute("rm -rf '" .. DBDIR .. "' && mkdir -p '" .. DBDIR .. "/bookshelf'")
    Facts.forgetMemo()
end

test("facts: a page count survives a flush and a reopen", function()
    fresh()
    Facts.put("/b/a.epub", { p = 312, psrc = "page-list" })
    Facts.flush()
    Facts.close()
    Facts.forgetMemo()          -- next read must come off disk, not memory
    local e = Facts.get("/b/a.epub")
    assert(e and e.p == 312, "got " .. tostring(e and e.p))
    assert(e.psrc == "page-list", "got " .. tostring(e and e.psrc))
end)

test("facts: a look and a count merge onto one row", function()
    fresh()
    Facts.put("/b/a.epub", { p = 100 })
    Facts.put("/b/a.epub", { r = 10, g = 20, b = 30, a = 1.5 })
    Facts.flush()
    Facts.forgetMemo()
    local e = Facts.get("/b/a.epub")
    assert(e.p == 100, "the count was lost when the look was written")
    assert(e.r == 10 and e.g == 20 and e.b == 30, "the look did not land")
    assert(math.abs((e.a or 0) - 1.5) < 0.001, "aspect lost: " .. tostring(e.a))
end)

test("facts: status and sidecar mtime round-trip", function()
    fresh()
    Facts.put("/b/a.epub", { s = "reading", sk = true, m = 1234 })
    Facts.flush()
    Facts.forgetMemo()
    local e = Facts.get("/b/a.epub")
    assert(e.s == "reading", "got " .. tostring(e.s))
    assert(e.sk == true, "status_known did not round-trip: " .. tostring(e.sk))
    assert(e.m == 1234, "got " .. tostring(e.m))
end)

test("facts: dropping a book removes it", function()
    fresh()
    Facts.put("/b/a.epub", { p = 1 })
    Facts.flush()
    Facts.drop("/b/a.epub")
    Facts.flush()
    Facts.forgetMemo()
    assert(Facts.get("/b/a.epub") == nil, "the row is still there")
end)

test("facts: prefetch serves a whole page from one read", function()
    fresh()
    local fps = {}
    for i = 1, 40 do
        local fp = string.format("/b/p%02d.epub", i)
        fps[#fps + 1] = fp
        Facts.put(fp, { p = i * 10 })
    end
    Facts.flush()
    Facts.forgetMemo()
    Facts.prefetch(fps)
    Facts.close()               -- nothing may touch the database after this
    for i = 1, 40 do
        local e = Facts.get(string.format("/b/p%02d.epub", i))
        assert(e and e.p == i * 10,
            "book " .. i .. " was not prefetched: " .. tostring(e and e.p))
    end
end)

test("facts: NO CAP - a library far past the old 1200 keeps every count", function()
    -- The bug this store exists to end: the settings-file version discarded
    -- the WHOLE table past 1200 entries, because it had to rewrite the file
    -- in full. An hour of scanning vanished, silently, on any large library.
    fresh()
    local N = 3000
    for i = 1, N do
        Facts.put(string.format("/b/%05d.epub", i), { p = i })
    end
    Facts.flush()
    Facts.forgetMemo()
    assert(Facts.countRows() == N, "expected " .. N .. " rows, got " .. tostring(Facts.countRows()))
    for _, i in ipairs({ 1, 1199, 1200, 1201, 2500, N }) do
        local e = Facts.get(string.format("/b/%05d.epub", i))
        assert(e and e.p == i, "book " .. i .. " lost its count")
    end
end)

test("facts: clearing page counts leaves the looks alone", function()
    fresh()
    Facts.put("/b/a.epub", { p = 300, psrc = "ncx", r = 1, g = 2, b = 3 })
    Facts.put("/b/b.epub", { p = 400, psrc = "render", r = 4, g = 5, b = 6 })
    Facts.flush()
    local n = Facts.clearPageCounts()
    assert(n == 2, "expected 2 counts cleared, got " .. tostring(n))
    Facts.forgetMemo()
    for _, fp in ipairs({ "/b/a.epub", "/b/b.epub" }) do
        local e = Facts.get(fp)
        assert(e, "the row itself should survive: " .. fp)
        assert(e.p == nil, fp .. " kept its count")
        assert(e.psrc == nil, fp .. " kept its count source")
        assert(e.r ~= nil, fp .. " lost its look, which reset must not touch")
    end
end)

test("facts: clearing looks leaves page counts and status alone (#537)", function()
    fresh()
    Facts.put("/b/a.epub", { p = 300, psrc = "ncx", r = 90, g = 90, b = 90, a = 1.5, s = "reading", sk = true })
    Facts.put("/b/b.epub", { p = 400, psrc = "render", r = 4, g = 5, b = 6 })
    Facts.put("/b/c.epub", { p = 500, psrc = "ncx" })
    Facts.flush()
    -- One look still only in memory, written after the last flush.
    Facts.put("/b/d.epub", { r = 7, g = 8, b = 9 })
    local n = Facts.clearLooks()
    assert(n == 3, "expected 3 looks cleared, got " .. tostring(n))
    for pass = 1, 2 do
        if pass == 2 then Facts.forgetMemo() end
        for _, fp in ipairs({ "/b/a.epub", "/b/b.epub", "/b/d.epub" }) do
            local e = Facts.get(fp)
            assert(not (e and e.r), fp .. " kept its look (pass " .. pass .. ")")
        end
        local a = Facts.get("/b/a.epub")
        assert(a and a.p == 300 and a.psrc == "ncx", "the page count went with the look")
        assert(a.s == "reading", "the cached status went with the look")
        assert(Facts.get("/b/c.epub").p == 500, "a book with no look lost its count")
    end
end)

test("facts: clearing counts on an empty store is a no-op, not an error", function()
    fresh()
    assert(Facts.clearPageCounts() == 0, "nothing to clear")
end)

test("facts: legacy spine_looks entries migrate in", function()
    fresh()
    local legacy = {
        ["/b/a.epub"] = { r = 1, g = 2, b = 3, a = 1.6, p = 250, s = "reading", sk = true, m = 99 },
        ["/b/b.epub"] = { r = 4, g = 5, b = 6 },
        ["/b/c.epub"] = { p = 111 },
        ["not a table"] = 5,
    }
    local n = Facts.migrateFrom(legacy)
    assert(n == 3, "expected 3 books migrated, got " .. tostring(n))
    Facts.flush()
    Facts.forgetMemo()
    local a = Facts.get("/b/a.epub")
    assert(a.p == 250 and a.r == 1 and a.s == "reading" and a.sk == true and a.m == 99,
        "the full legacy entry did not come across")
    assert(Facts.get("/b/b.epub").r == 4, "a look-only entry did not come across")
    assert(Facts.get("/b/c.epub").p == 111, "a count-only entry did not come across")
end)

test("facts: an unopenable database degrades instead of taking the shelf down", function()
    -- A failed open must never propagate: this plugin has already been bitten
    -- by a poisoned SQLite handle breaking an unrelated feature for a whole
    -- session. Reads answer nil, writes are kept in memory for the session.
    fresh()
    package.loaded["datastorage"] = {
        getSettingsDir = function() return "/proc/nonexistent/nope" end,
    }
    Facts.close()
    Facts.forgetMemo()
    local ok = pcall(function()
        Facts.put("/b/x.epub", { p = 7 })
        Facts.flush()
        local e = Facts.get("/b/x.epub")
        assert(e and e.p == 7, "the session memo should still answer")
    end)
    package.loaded["datastorage"] = { getSettingsDir = function() return DBDIR end }
    Facts.close()
    assert(ok, "an unopenable database must not throw")
end)

test("facts: false clears a field, absent leaves it alone", function()
    fresh()
    Facts.put("/b/a.epub", { p = 200, s = "reading", sk = true, r = 9 })
    Facts.flush()
    -- A sidecar that moved under us clears the cached STATUS only.
    Facts.put("/b/a.epub", { s = false, sk = false, m = false })
    Facts.flush()
    Facts.forgetMemo()
    local e = Facts.get("/b/a.epub")
    assert(e.s == nil, "status should have been cleared, got " .. tostring(e.s))
    assert(e.sk == nil, "status_known should have been cleared")
    assert(e.p == 200, "the page count is not the sidecar's to invalidate")
    assert(e.r == 9, "the look should be untouched")
end)

-- ── Highlight counts, for the quote of the day ─────────────────────────────

test("facts: a highlight count and its sidecar time survive a reopen", function()
    fresh()
    Facts.put("/b/q.epub", { hl = 9, hm = 1234 })
    Facts.put("/b/none.epub", { hl = 0, hm = 99 })
    Facts.flush(); Facts.close(); Facts.forgetMemo()
    local e = Facts.get("/b/q.epub")
    assert(e and e.hl == 9 and e.hm == 1234, "the count was not kept: " .. tostring(e and e.hl))
    local found = Facts.highlightBooks()
    assert(found["/b/q.epub"] == 9, "a book with highlights is not listed")
    assert(found["/b/none.epub"] == nil, "a book without highlights is listed")
end)

test("facts: a count written this session is listed before a flush", function()
    fresh()
    Facts.put("/b/new.epub", { hl = 3, hm = 5 })
    assert(Facts.highlightBooks()["/b/new.epub"] == 3, "an unflushed count is missing")
end)

test("facts: an older database gains the highlight columns", function()
    fresh()
    Facts.close()
    local SQ3 = require("lua-ljsqlite3/init")
    local db = SQ3.open(DBDIR .. "/bookshelf/book_facts.sqlite3")
    db:exec([[CREATE TABLE book_facts (fp TEXT PRIMARY KEY, pages INTEGER, pages_src TEXT,
        r INTEGER, g INTEGER, b INTEGER, aspect REAL, status TEXT, status_known INTEGER,
        sidecar_mtime INTEGER);]])
    db:exec("INSERT INTO book_facts (fp, pages) VALUES ('/b/old.epub', 300);")
    db:close()
    Facts.forgetMemo()
    local e = Facts.get("/b/old.epub")
    assert(e and e.p == 300, "the old row was lost")
    Facts.put("/b/old.epub", { hl = 2, hm = 7 })
    Facts.flush(); Facts.forgetMemo()
    local e2 = Facts.get("/b/old.epub")
    assert(e2.hl == 2 and e2.p == 300, "the column was not added to the old table")
end)

test("facts: what readProgress read from a sidecar round-trips with its mtime", function()
    fresh()
    local U = string.char(31)
    local packed = table.concat({ "0.5", "reading", "", "320", "render", "12", "" }, U)
    Facts.put("/b/r.epub", { rp = packed, rpm = 99 })
    Facts.flush(); Facts.close(); Facts.forgetMemo()
    local e = Facts.get("/b/r.epub")
    assert(e and e.rpm == 99 and e.rp == packed, tostring(e and e.rp))
    -- A page count written later leaves it alone.
    Facts.put("/b/r.epub", { p = 300 })
    Facts.flush(); Facts.forgetMemo()
    assert(Facts.get("/b/r.epub").rpm == 99)
end)

io.write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
