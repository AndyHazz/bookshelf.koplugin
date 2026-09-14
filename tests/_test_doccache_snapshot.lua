-- tests/_test_doccache_snapshot.lua
-- Issue 396: opening a book must not be able to kill KOReader.
--
-- ── WHAT HAPPENS ────────────────────────────────────────────────────────────
--
-- Opening a DIFFERENT book while one is parked leaves the parked ReaderUI on
-- the window stack, so ReaderUI:showReader's own ShowingReader broadcast finds
-- it and tears it down. broadcastEvent does NOT pcall its handlers, so anything
-- that throws in that teardown takes the whole app down, not just the open.
--
-- And something does throw. The teardown runs DocCache:serialize, which sorts
-- its cached files by access time (frontend/document/doccache.lua):
--
--     table.insert(sorted_caches, {file=file, time=lfs.attributes(file, "access")})
--     cached_size = cached_size + (lfs.attributes(file, "size") or 0)   -- guarded
--     ...
--     table.sort(sorted_caches, function(v1, v2) return v1.time > v2.time end)
--
-- lfs.attributes returns nil for a file that has gone, and only the `size` line
-- guards for it -- so a missing file makes the comparator compare nil with a
-- number. Reported from a device as "attempt to compare nil with number".
--
-- Its file list is a SNAPSHOT of every regular file in koreader/cache/, taken
-- at init and refreshed only at the END of serialize. That directory is shared:
-- it holds our own bookshelf.finishedcount and bookshelf.lightmeta, and other
-- plugins' files too. Any of them disappearing between snapshot and serialize
-- is enough.
--
-- ── WHY IT IS OURS TO CONTAIN ───────────────────────────────────────────────
--
-- The defect is upstream, but stock KOReader only reaches it by deliberately
-- going book > file browser > another book. Hot parking keeps a reader alive
-- behind the shelf, so "read one book, go back, open another" is the everyday
-- path. We made it reachable, so we refresh the snapshot before handing over.
--
-- Not fixed by closing the parked reader ourselves instead: main.lua documents
-- the switching teardown as deliberate ("a shelf-launched open of book B while
-- book A is parked real-closes A first ... Switches inherit provenance"), and
-- reordering it would disturb the _opened_book provenance the close path
-- depends on.
--
-- Usage (from plugin root): lua tests/_test_doccache_snapshot.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

local H = dofile("tests/_helpers.lua")
local t = H.runner()

local src = assert(io.open("lib/bookshelf_widget.lua")):read("*a")

local body = src:match("\n(function BookshelfWidget:_launchReader%(.-\nend)\n")
assert(body, "_launchReader moved or was renamed")

-- Anchored on the CALLS, not the words: the surrounding comment names both
-- showReader and refreshSnapshot in prose, and matching that would have let a
-- version with no call at all pass.
local at_refresh = body:find("DocCache:refreshSnapshot(", 1, true)
local at_show    = body:find("ReaderUI:showReader(", 1, true)

t.test("the launcher refreshes the doc cache snapshot", function()
    assert(at_refresh,
        "nothing refreshes DocCache's snapshot before the reader is handed over")
end)

t.test("it refreshes BEFORE showReader, not after", function()
    -- After is useless: the broadcast that tears the parked reader down
    -- happens inside showReader, so the stale entry has already been sorted.
    assert(at_show, "the ReaderUI:showReader call moved")
    assert(at_refresh and at_refresh < at_show,
        "the refresh lands after showReader, which is too late to help")
end)

t.test("the refresh cannot itself break an open", function()
    -- It reaches into a KOReader internal, so a build without it (or a future
    -- rename) must degrade to the old behaviour rather than stop books opening.
    local seg = body:sub(1, at_show or #body)
    assert(seg:find("pcall", 1, true),
        "the DocCache call is unguarded: a rename upstream would break opening")
end)

t.done()
