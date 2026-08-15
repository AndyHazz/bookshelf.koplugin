-- tests/_test_opds_db.lua
-- The SQLite window store, driven against REAL SQLite.
--
-- Stubbing the database would prove nothing here: every claim worth making is
-- about what SQLite does (dedupe via a unique index, LIMIT/OFFSET at depth,
-- ordering by seq), so a fake would just be me asserting my own assumptions
-- back at myself.
--
-- Needs KOReader's tree for ljsqlite3, and ffi/loadlib must be required FIRST
-- (ljsqlite3 calls ffi.loadlib, which KOReader installs and stock LuaJIT does
-- not have). Skips cleanly under a plain interpreter so run.sh stays green:
--   /usr/lib/koreader/luajit tests/_test_opds_db.lua
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
-- Point the module at a scratch directory rather than the real settings dir.
local TMPDIR = os.getenv("TMPDIR") or "/tmp"
local DBDIR = TMPDIR .. "/bookshelf_opds_db_test"
os.execute("rm -rf '" .. DBDIR .. "' && mkdir -p '" .. DBDIR .. "'")
package.loaded["datastorage"] = { getSettingsDir = function() return DBDIR end }

local DB = require("lib/bookshelf_opds_db")

local pass, fail = 0, 0
local function eq(got, want, label)
    if got == want then pass = pass + 1
    else fail = fail + 1; print("FAIL " .. label .. ": got " .. tostring(got) .. " want " .. tostring(want)) end
end
local function ok(cond, label)
    if cond then pass = pass + 1 else fail = fail + 1; print("FAIL " .. label) end
end

local function rec(i, extra)
    local r = { filepath = "OPDS://srv/book" .. i, title = "Book " .. i,
                author = "Author " .. i,
                opds = { image_url = "https://x/" .. i .. ".jpg",
                         summary = string.rep("blurb ", 20),
                         acquisitions = { { type = "application/epub+zip",
                                            href = "https://x/" .. i .. ".epub" } } } }
    for k, v in pairs(extra or {}) do r[k] = v end
    return r
end
local function page(from, to)
    local p = {}
    for i = from, to do p[#p + 1] = rec(i) end
    return p
end

ok(DB.open() ~= nil, "opens (and creates its schema)")

-- ── an unknown feed reads as blank, not as an error ─────────────────────────
local m = DB.meta("srv", "https://c/none")
eq(m.count, 0, "unknown feed has no entries")
eq(m.fetched_at, 0, "and has never been fetched")
eq(m.next_url, nil, "and has no next link")
eq(#DB.slice("srv", "https://c/none", 0, 10), 0, "slicing it yields nothing")

-- ── append + slice ──────────────────────────────────────────────────────────
local F = "https://c/list"
eq(DB.append("srv", F, page(1, 25)), 25, "a 25-record page inserts 25")
eq(DB.count("srv", F), 25, "and the feed holds 25")
local s = DB.slice("srv", F, 0, 10)
eq(#s, 10, "a slice returns the page size asked for")
eq(s[1].filepath, "OPDS://srv/book1", "in insertion order, from the start")
eq(s[10].title, "Book 10", "and the payload round-trips whole")
ok(type(s[1].opds) == "table" and s[1].opds.acquisitions[1].href
   == "https://x/1.epub", "including nested tables")

local s2 = DB.slice("srv", F, 20, 10)
eq(#s2, 5, "a slice past the end returns only what exists")
eq(s2[1].filepath, "OPDS://srv/book21", "at the right offset")

-- ── dedupe is the index's job now ───────────────────────────────────────────
eq(DB.append("srv", F, page(20, 30)), 5, "overlapping pages insert only the new records")
eq(DB.count("srv", F), 30, "so the feed grows by exactly the new ones")
local all = DB.slice("srv", F, 0, 100)
local seen = {}
for _i, r in ipairs(all) do
    ok(not seen[r.filepath], "no duplicate: " .. r.filepath)
    seen[r.filepath] = true
end
eq(#all, 30, "and the ordering survives a partial overlap")
eq(all[26].filepath, "OPDS://srv/book26", "with new records appended after the old")

-- ── depth: the reason this exists ───────────────────────────────────────────
DB.append("srv", F, page(31, 1200))
eq(DB.count("srv", F), 1200, "a feed can hold far more than the old 1000 cap")
local deep = DB.slice("srv", F, 1150, 10)
eq(#deep, 10, "and a page at depth 1150 still returns a full screen")
eq(deep[1].filepath, "OPDS://srv/book1151", "at the right place in the sequence")

-- ── metadata ────────────────────────────────────────────────────────────────
DB.setMeta("srv", F, { fetched_at = 12345, next_url = "https://c/list?p=2",
                       total = 9000, search = "https://c/s?q={t}" })
local meta = DB.meta("srv", F)
eq(meta.fetched_at, 12345, "fetched_at round-trips")
eq(meta.next_url, "https://c/list?p=2", "next_url round-trips")
eq(meta.total, 9000, "total round-trips")
eq(meta.search, "https://c/s?q={t}", "search link round-trips")
eq(meta.count, 1200, "and the count comes with it")
DB.setMeta("srv", F, { fetched_at = 999 })
eq(DB.meta("srv", F).next_url, "https://c/list?p=2",
   "a partial update leaves the other fields alone")
DB.clearNextUrl("srv", F)
eq(DB.meta("srv", F).next_url, nil, "a chain that ended can say so")

-- ── feeds are independent ───────────────────────────────────────────────────
local G = "https://c/other"
DB.append("srv", G, page(1, 5))
eq(DB.count("srv", G), 5, "a second feed holds its own entries")
eq(DB.count("srv", F), 1200, "and does not disturb the first")
eq(DB.slice("srv", G, 0, 10)[1].filepath, "OPDS://srv/book1",
   "even though the filepaths collide across feeds")

-- ── reset vs forget ─────────────────────────────────────────────────────────
DB.reset("srv", G)
eq(DB.count("srv", G), 0, "reset empties a feed")
eq(DB.meta("srv", G).fetched_at, 0, "and clears its chain state")
DB.append("srv", G, page(1, 3))
DB.forget("srv", G)
eq(DB.count("srv", G), 0, "forget removes it entirely")

-- ── eviction is a DELETE, not a walk ────────────────────────────────────────
for i = 1, 5 do
    local url = "https://c/f" .. i
    DB.append("srv", url, page(1, 10))
    DB.setMeta("srv", url, { fetched_at = 1000 + i })   -- f1 oldest
end
DB.evict(3, 1000000)
local st = DB.stats()
ok(st.feeds <= 3 + 1, "eviction respects the feed bound (the big feed survives)")
eq(DB.count("srv", "https://c/f1"), 0, "the stalest feed went first")
ok(DB.count("srv", "https://c/f5") > 0, "the freshest survived")

-- ── render decoration never reaches storage ─────────────────────────────────
-- The repo decorates the COPIES it hands out (cover paths, downloaded flags,
-- a description mirrored from opds.summary). Writing those back would persist
-- state that is re-derived from disk every render - and cover_bb is a
-- BlitBuffer, which the JSON encoder cannot encode at all, so an unscrubbed
-- record would fail to encode and be silently dropped rather than stored.
do
    local H = "https://c/scrub"
    local r = rec(1)
    r.cover_bb = function() end          -- stand-in for a BlitBuffer
    r.cover_w, r.cover_h = 60, 90
    r.has_cover = true
    r.cover_image_path = "/tmp/x.img"
    r.cover_borrowed = true
    r.downloaded = true
    r.description = "mirrored summary"
    r.opds.icon = "data:image/png;base64,AAAA"
    eq(DB.append("srv", H, { r }), 1, "a decorated record still stores")
    local back = DB.slice("srv", H, 0, 1)[1]
    ok(back ~= nil, "and comes back")
    for _i, k in ipairs{ "cover_bb", "cover_w", "cover_h", "has_cover",
                         "cover_image_path", "cover_borrowed", "downloaded",
                         "description" } do
        eq(back[k], nil, "decoration stripped: " .. k)
    end
    eq(back.filepath, "OPDS://srv/book1", "real fields survive")
    eq(back.title, "Book 1", "including the title")
    -- opds.icon is PERSISTED state, not decoration: a nav tile's placeholder
    -- icon comes from it.
    eq(back.opds.icon, "data:image/png;base64,AAAA", "the nested opds table is untouched")
end

-- ── a window without its identity degrades, it does not throw ───────────────
-- A window carries server_key + feed_url now, and everything that writes goes
-- through it. A caller that builds a bare table (the refresh path did) must
-- get "no cached feed" rather than an ljsqlite3 bind error per record - which
-- on device was hundreds of constraint warnings and a silently empty shelf.
do
    eq(DB.append(nil, nil, page(1, 5)), 0, "append with no key stores nothing")
    eq(DB.append("srv", nil, page(1, 5)), 0, "nor with half a key")
    eq(#DB.slice(nil, nil, 0, 10), 0, "slice with no key returns nothing")
    eq(DB.count(nil, nil), 0, "count with no key is zero")
    eq(DB.meta(nil, nil).count, 0, "meta with no key reads blank")
    -- And none of that created a phantom feed row.
    local st2 = DB.stats()
    DB.setMeta(nil, nil, { fetched_at = 1 })
    eq(DB.stats().feeds, st2.feeds, "no phantom feed row is created")
end

-- ── entries and their timestamp are never out of step ───────────────────────
-- A window holding records with no fetch stamp reads as "never fetched" to
-- every caller that asks the cache question that way - on device that was a
-- nav tile that did nothing at all when tapped, over a feed with 26 entries
-- already cached. The store keeps the invariant so no caller can recreate it.
do
    local S = "https://c/stamp"
    DB.forget(S)
    DB.append("srv", S, page(1, 3))
    ok(DB.meta("srv", S).fetched_at > 0, "appending entries stamps the feed")
    -- An existing stamp is not moved: fetched_at is when the feed was last
    -- REFRESHED, which the expiry rule reads, and appending page seven does
    -- not make page one newer.
    DB.setMeta("srv", S, { fetched_at = 500 })
    DB.append("srv", S, page(4, 6))
    eq(DB.meta("srv", S).fetched_at, 500, "an existing stamp is left alone")
    -- And a reset takes the stamp with the entries.
    DB.reset("srv", S)
    eq(DB.count("srv", S), 0, "reset empties it")
    eq(DB.meta("srv", S).fetched_at, 0, "and it reads as never fetched again")
end

-- ── the server's declared page size round-trips ─────────────────────────────
-- itemsPerPage is the only say the client gets about pagination: it cannot ask
-- for a page size, but the server tells it one, and the lookahead costs its
-- read-ahead depth in requests from it rather than guessing.
do
    local P = "https://c/paged"
    DB.forget("srv", P)
    DB.append("srv", P, page(1, 3))
    eq(DB.meta("srv", P).items_per_page, nil, "unset until the feed declares one")
    DB.setMeta("srv", P, { items_per_page = 25 })
    eq(DB.meta("srv", P).items_per_page, 25, "a declared page size round-trips")
    DB.setMeta("srv", P, { fetched_at = 7 })
    eq(DB.meta("srv", P).items_per_page, 25, "and survives an unrelated update")
end

-- ── a search link is a table, and must not take the write down with it ──────
-- mapEntries captures the feed's search link as {href, type} - never a bare
-- string - and the column is TEXT. Binding the table raised inside bind(),
-- which aborted the ENTIRE statement: next_url, items_per_page, total and
-- complete were all lost alongside it, silently, because with() catches and
-- logs. The visible damage was on the shelf, not in the database: any catalog
-- advertising search paged correctly in memory and came back from a reload
-- with no chain to follow, so its categories froze at the first page cached.
-- Found by driving the real catalogs from the desktop - Gutenberg advertises
-- search, textos.info does not, and only Gutenberg's chain kept vanishing.
do
    local W = "https://c/withsearch"
    DB.forget("srv", W)
    DB.setMeta("srv", W, {
        search   = { href = "https://c/osd.xml", type = "osd" },
        next_url = "https://c/withsearch?p=2",
        items_per_page = 25,
        total    = 900,
    })
    local m = DB.meta("srv", W)
    eq(type(m.search), "table", "a table search link round-trips as a table")
    eq(m.search and m.search.href, "https://c/osd.xml", "with its href")
    eq(m.search and m.search.type, "osd", "and its type")
    -- The columns that used to die with it.
    eq(m.next_url, "https://c/withsearch?p=2", "next_url survives the same write")
    eq(m.items_per_page, 25, "items_per_page survives it")
    eq(m.total, 900, "total survives it")
end

-- A value sqlite cannot bind at all costs its own column and no others.
do
    local U = "https://c/unbindable"
    DB.forget("srv", U)
    DB.setMeta("srv", U, { next_url = "https://c/u?p=2", total = print })
    local m = DB.meta("srv", U)
    eq(m.next_url, "https://c/u?p=2", "an unbindable column does not abort the write")
    eq(m.total, nil, "and that column alone is dropped")
end

DB.close()
os.execute("rm -rf '" .. DBDIR .. "'")
print(string.format("opds db: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
