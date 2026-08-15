-- tests/_test_opds_window.lua
-- Progressive feed window: append pages, slice for the shelf, know when a
-- page turn needs more network, persist bounded state.
package.path = "./?.lua;./?/init.lua;" .. package.path
package.loaded["logger"] = { dbg=function() end, info=function() end,
                             warn=function() end, err=function() end }
-- In-memory settings store stub matching lib/bookshelf_settings_store's API.
-- flush() is counted, not ignored: Store.flush() re-serialises the MAIN
-- bookshelf.lua (a ~140ms write), and the OPDS cache lives in its own
-- sub-store that Store.save already flushes, so this module must never call it.
local store_data = {}
local flush_calls = 0
package.loaded["lib/bookshelf_settings_store"] = {
    read  = function(k, d) return store_data[k] ~= nil and store_data[k] or d end,
    save  = function(k, v) store_data[k] = v end,
    flush = function() flush_calls = flush_calls + 1 end,
}

-- In-memory stand-in for the SQLite layer, faithful to the contract that
-- matters here: dedupe on (feed, filepath), insertion order by seq,
-- LIMIT/OFFSET slicing, and metadata that updates only the keys it is given.
-- The real thing has its own suite against real SQLite (_test_opds_db); this
-- one is about the WINDOW's logic - totals, open-endedness, when a page turn
-- needs network - which is worth testing without a database in the way.
local db_feeds, db_rows = {}, {}
local function fkey(sk, url) return tostring(sk) .. "|" .. tostring(url) end
package.loaded["lib/bookshelf_opds_db"] = {
    meta = function(sk, url)
        local k = fkey(sk, url)
        local f = db_feeds[k]
        local rows = db_rows[k] or {}
        if not f then
            return { fetched_at = 0, complete = false, trimmed = false, count = 0 }
        end
        return { fetched_at = f.fetched_at or 0, next_url = f.next_url,
                 total = f.total, complete = f.complete or false,
                 trimmed = f.trimmed or false, search = f.search,
                 count = #rows }
    end,
    setMeta = function(sk, url, m)
        local k = fkey(sk, url)
        db_feeds[k] = db_feeds[k] or {}
        for field, v in pairs(m or {}) do
            if v ~= nil then db_feeds[k][field] = v end
        end
    end,
    clearNextUrl = function(sk, url)
        local f = db_feeds[fkey(sk, url)]
        if f then f.next_url = nil end
    end,
    append = function(sk, url, records)
        local k = fkey(sk, url)
        db_feeds[k] = db_feeds[k] or {}
        db_rows[k] = db_rows[k] or {}
        local rows, seen, added = db_rows[k], {}, 0
        for _i, r in ipairs(rows) do seen[r.filepath] = true end
        for _i, r in ipairs(records or {}) do
            if type(r) == "table" and type(r.filepath) == "string"
                    and not seen[r.filepath] then
                seen[r.filepath] = true
                rows[#rows + 1] = r
                added = added + 1
            end
        end
        return added
    end,
    slice = function(sk, url, offset, limit)
        local rows = db_rows[fkey(sk, url)] or {}
        local out = {}
        for i = (offset or 0) + 1, math.min((offset or 0) + (limit or #rows), #rows) do
            local copy = {}
            for kk, vv in pairs(rows[i]) do copy[kk] = vv end
            out[#out + 1] = copy
        end
        return out
    end,
    count = function(sk, url) return #(db_rows[fkey(sk, url)] or {}) end,
    reset = function(sk, url)
        db_rows[fkey(sk, url)] = {}
        db_feeds[fkey(sk, url)] = nil
    end,
    forget = function(sk, url)
        db_rows[fkey(sk, url)] = nil; db_feeds[fkey(sk, url)] = nil
    end,
    evict = function() end,
    stats = function() return { feeds = 0, entries = 0 } end,
}

local W = dofile("lib/bookshelf_opds_window.lua")

-- The window no longer materialises its records, so a test that wants them
-- asks for them the way the shelf does.
local function entriesOf(win) return W.slice(win, 0, (win.count or 0) + 1) end

local pass, fail = 0, 0
local function eq(got, want, label)
    if got == want then pass = pass + 1
    else fail = fail + 1; print("FAIL " .. label .. ": got " .. tostring(got) .. " want " .. tostring(want)) end
end
local function ok(c, l) if c then pass = pass + 1 else fail = fail + 1; print("FAIL " .. l) end end

local function recs(from, to, prefix)
    local t = {}
    for i = from, to do t[#t + 1] = { filepath = (prefix or "OPDS://k/") .. i, title = "t" .. i } end
    return t
end

-- fresh window
local win = W.load("k", "http://h/f")
eq((win.count or 0), 0, "fresh window empty")
-- A fresh window wants a fetch. It holds nothing and has never been seen to
-- end, so the slice runs past what is cached and there is every reason to ask.
-- (This used to read false, because the rule required a next_url that a
-- never-fetched feed cannot have - the repo compensated with a separate
-- "count 0 and never stamped" clause.)
ok(W.needsFetch(win, 0, 8) == true, "fresh window: nothing cached, so fetch")

-- first page arrives: 10 entries, total known
W.appendPage(win, { records = recs(1, 10), next_url = "http://h/f?p=2", total = 25 })
eq((win.count or 0), 10, "10 entries after page 1")
local page, total, open_ended = W.slice(win, 0, 8)
eq(#page, 8, "slice of 8")
eq(total, 10, "a declared total is not reported; the cached count is")
eq(open_ended, true, "and an incomplete feed is open-ended whatever it declared")
ok(W.needsFetch(win, 8, 8) == true, "page 2 needs fetch (only 10 held)")
ok(W.needsFetch(win, 0, 8) == false, "page 1 held")

-- dedupe on filepath
W.appendPage(win, { records = recs(10, 12), next_url = nil, total = 25 })
eq((win.count or 0), 12, "dedupe kept 12, not 13")
-- No next_url is NOT "nothing more to fetch" unless the feed has been seen to
-- end. A window that lost its chain must be recoverable, or it freezes at
-- whatever it happens to hold - which is exactly what a bug left behind on
-- Internet Archive: entries cached, no next link, needsFetch forever false.
ok(W.needsFetch(win, 8, 8) == true,
   "chain lost but never seen to end -> ask again")
win.complete = true
ok(W.needsFetch(win, 8, 8) == false,
   "complete is the only honest 'there is no more'")
win.complete = false

-- nav records ride the same entries list as books and dedupe the same way
local win_nav = W.load("k", "http://h/nav")
local nav_rec = { kind = "opds_nav", is_remote = true, is_opds_nav = true,
                   filepath = "OPDS://k/nav/aaaa", label = "Fiction", title = "Fiction",
                   display_title = "Fiction", opds = { feed_url = "http://h/fiction" } }
W.appendPage(win_nav, { records = { nav_rec, recs(1, 1, "OPDS://k/nav/book")[1] } })
eq((win_nav.count or 0), 2, "nav record and book record both appended")
eq(entriesOf(win_nav)[1].kind, "opds_nav", "nav record kept in entry order")
W.appendPage(win_nav, { records = { nav_rec } })
eq((win_nav.count or 0), 2, "re-appending the same nav record dedupes by filepath")

-- unknown total: open-ended while next_url present
local win2 = W.load("k", "http://h/g")
W.appendPage(win2, { records = recs(1, 10, "OPDS://k/g"), next_url = "http://h/g?p=2", total = nil })
local _p2, total2, open2 = W.slice(win2, 0, 8)
eq(total2, 10, "no declared total: entries held")
eq(open2, true, "no declared total + next -> open-ended")

-- NO trim. A feed keeps everything it has been given: the old 1000-entry cap
-- with drop-from-front existed to bound a settings file that had to be
-- rewritten whole on every save, and a row per entry has no such problem.
-- Truncating a feed the reader was paging through was always a symptom of the
-- storage, never a decision.
local win3 = W.load("k", "http://h/big")
W.appendPage(win3, { records = recs(1, 1200, "OPDS://k/big"), next_url = nil, total = nil })
eq((win3.count or 0), 1200, "a feed keeps every entry it is given")
eq(entriesOf(win3)[1].filepath, "OPDS://k/big1", "nothing is dropped from the front")
local deep = W.slice(win3, 1150, 10)
eq(#deep, 10, "and a page past the old cap still slices")
eq(deep[1].filepath, "OPDS://k/big1151", "at the right depth")

-- persistence round-trip + LRU eviction at 20 feeds
W.save("k", "http://h/f", win)
local back = W.load("k", "http://h/f")
eq((back.count or 0), 12, "persisted window reloads")
-- 25 additional one-entry feeds: past the OLD 20-feed cap, but tiny windows
-- must all stay resident now that eviction is entry-weighted (the Gutenberg
-- child-window regression; the budget/backstop bounds are exercised in the
-- dedicated eviction block further down).
for i = 1, 25 do
    local wx = W.load("k", "http://h/feed" .. i)
    wx.fetched_at = i  -- deterministic age (no os.time in tests)
    W.appendPage(wx, { records = recs(1, 1, "OPDS://k/feed" .. i .. "/") })
    W.save("k", "http://h/feed" .. i, wx)
end
-- Eviction is the storage layer's job now (a DELETE ordered by staleness,
-- covered against real SQLite in _test_opds_db). What matters here is that
-- saving a tiny feed does not disturb the others.
eq(W.count("k", "http://h/feed7"), 1, "a tiny feed keeps its entry")
eq(W.count("k", "http://h/feed25"), 1, "and so does the newest")

-- reset drops the window
W.reset("k", "http://h/f")
eq((W.load("k", "http://h/f").count or 0), 0, "reset clears")

-- A legacy persisted window carrying an old separate `nav` field is the
-- migration's problem now, not load()'s: it reads the old settings table once
-- and writes rows. Nothing here can construct that state any more, and
-- inventing a fake of it would only test the fake.

-- search: captured from mapped.search, replaced wholesale on append like the
-- old nav field was (not merged, not cleared by a page that carries none).
local win_search = W.load("k", "http://h/search")
eq(win_search.search, nil, "fresh window has no search")
W.appendPage(win_search, { records = recs(1, 1, "OPDS://k/search"),
                           search = { href = "http://h/opensearch.xml", type = "osd" } })
eq(win_search.search.href, "http://h/opensearch.xml", "search captured on first page")
eq(win_search.search.type, "osd", "search type captured")

-- a later page with no search field (link only appears on the first page,
-- or wasn't re-sent) leaves the last known value alone
W.appendPage(win_search, { records = recs(2, 2, "OPDS://k/search") })
eq(win_search.search.href, "http://h/opensearch.xml",
    "search survives a page with no search field (absence doesn't clobber)")

-- but a page that DOES carry a new search link replaces it wholesale
W.appendPage(win_search, { records = {},
                           search = { href = "http://h/search?q={searchTerms}", type = "template" } })
eq(win_search.search.type, "template", "search replaced wholesale when a new one arrives")
eq(win_search.search.href, "http://h/search?q={searchTerms}", "search href replaced wholesale")

-- persistence round-trip: search is two plain strings, serialises fine
win_search.fetched_at = 9999 -- newest, so the LRU pass above can't evict it
W.save("k", "http://h/search", win_search)
local back_search = W.load("k", "http://h/search")
eq(back_search.search.type, "template", "search survives persistence round-trip")
eq(back_search.search.href, "http://h/search?q={searchTerms}", "search href survives persistence round-trip")

eq(back.search, nil, "load tolerates absence of a search field entirely")

-- Durability comes from Store.save routing to the OPDS sub-store (which
-- flushes its own file); the main settings file must not be rewritten.
eq(flush_calls, 0, "neither save nor reset flushes the main settings file")

-- slice hands out COPIES. Callers decorate page records with a live cover
-- BlitBuffer; if that landed on the window's own entry it would be serialised
-- on the next save, and dump.lua has no representation for cdata -- the whole
-- store file stops parsing and every feed's cache is lost.
local win4 = W.load("k", "http://h/copy")
W.appendPage(win4, { records = {
    { filepath = "OPDS://k/copy1", title = "t1", opds = { thumbnail_url = "http://h/1.jpg" } },
    { filepath = "OPDS://k/copy2", title = "t2", opds = { thumbnail_url = "http://h/2.jpg" } },
} })
local p4 = W.slice(win4, 0, 2)
eq(#p4, 2, "slice returned both entries")
ok(p4[1] ~= entriesOf(win4)[1], "slice returns a fresh table, not the stored reference")
eq(p4[1].filepath, "OPDS://k/copy1", "slice copy carries the field values")
eq(p4[1].opds.thumbnail_url, "http://h/1.jpg", "slice copy carries the nested opds data")
p4[1].cover_bb = function() end        -- stand-in for a live BlitBuffer
p4[1].has_cover = true
p4[1].cover_image_path = "/tmp/opds_covers_test_settings/bookshelf_covers/opds/k/x.img"
p4[1].cover_borrowed = true
p4[1].downloaded = true
p4[1].description = "a mirrored feed summary"
p4[1].title = "mutated"
ok(entriesOf(win4)[1].cover_bb == nil, "decorating a sliced record leaves the window entry clean")
ok(entriesOf(win4)[1].has_cover == nil, "has_cover doesn't reach the window entry either")
ok(entriesOf(win4)[1].cover_image_path == nil, "cover_image_path doesn't reach the window entry either")
ok(entriesOf(win4)[1].cover_borrowed == nil, "cover_borrowed doesn't reach the window entry either")
ok(entriesOf(win4)[1].downloaded == nil, "downloaded doesn't reach the window entry either")
ok(entriesOf(win4)[1].description == nil, "description doesn't reach the window entry either")
eq(entriesOf(win4)[1].title, "t1", "a field mutation on the page doesn't reach the window entry")

-- save() scrubs cover decoration defensively, whatever route put it there.
local function findUnserialisable(v, path, seen)
    if type(v) == "function" or type(v) == "userdata" then return path end
    if type(v) ~= "table" then return nil end
    seen = seen or {}
    if seen[v] then return nil end
    seen[v] = true
    for k, sub in pairs(v) do
        local hit = findUnserialisable(sub, path .. "." .. tostring(k), seen)
        if hit then return hit end
    end
    return nil
end

-- Records go in carrying everything a parsed feed gives them, including the
-- nested opds table whose icon is a nav tile's data-uri placeholder. Stripping
-- RENDER decoration (cover paths, downloaded flags, a cover_bb the encoder
-- cannot handle) happens at the write boundary in bookshelf_opds_db, and is
-- tested there against real SQLite and the real encoder. What this suite owns
-- is the round trip.
local win5 = W.load("k", "http://h/scrub")
local scrub_recs = recs(1, 2, "OPDS://k/scrub")
scrub_recs[1].opds = { feed_url = "http://h/scrub/1",
                       icon = "data:image/png;base64,AAAA" }
W.appendPage(win5, { records = scrub_recs })
win5.fetched_at = 9999   -- newest, so the LRU pass can't evict it
W.save("k", "http://h/scrub", win5)
local saved = W.load("k", "http://h/scrub")
eq((saved.count or 0), 2, "the window persisted both entries")
eq(entriesOf(saved)[1].filepath, "OPDS://k/scrub1", "with its real record fields")
eq(entriesOf(saved)[1].opds.icon, "data:image/png;base64,AAAA",
   "and the nested opds table, whose icon is persisted state not decoration")
-- slice hands back COPIES: decorating what you got must never reach storage.
local borrowed = entriesOf(saved)[1]
borrowed.cover_image_path = "/tmp/decorated.img"
eq(entriesOf(W.load("k", "http://h/scrub"))[1].cover_image_path, nil,
   "decorating a sliced record leaves the stored one untouched")

-- complete flag: the fetch loop marks a window complete when the feed chain
-- terminally ended. The reported total is the cached count either way - a
-- declared totalResults is never displayed, because the only catalog that
-- sends one sends a 10000 result-window cap over a chain that dies short of
-- 800 - but completing a window also drops the "+".
local winc = W.load("k", "http://h/complete")
W.appendPage(winc, { records = recs(1, 10), next_url = "http://h/c?p=2", total = 150 })
local _, t_before = W.slice(winc, 0, 8)
eq(t_before, 10, "incomplete window reports what it holds, not the declared 150")
winc.complete = true
winc.next_url = nil
local _, t_after, oe_after = W.slice(winc, 0, 8)
eq(t_after, 10, "complete window still reports its cached entries")
eq(oe_after, false, "complete window is not open-ended")
ok(W.needsFetch(winc, 90, 8) == false, "complete window never asks for a fetch")

-- complete with NO totalResults (total nil): clamp still applies, and the
-- open-ended flag (total nil + next_url nil) stays false.
local winc2 = W.load("k", "http://h/complete2")
W.appendPage(winc2, { records = recs(1, 4), next_url = nil, total = nil })
winc2.complete = true
local _, t2, oe2 = W.slice(winc2, 0, 8)
eq(t2, 4, "complete, no totalResults: total is the cached count")
eq(oe2, false, "complete, no totalResults: not open-ended")

-- NO trim, and no cap on how deep a feed may go. The old drop-from-front
-- sliding window existed to bound a settings file that had to be rewritten in
-- full on every save; storage is a row per entry now and has no such problem.
-- A reader paging deep into a catalogue keeps what they have paged through.
do
    local w2 = W.load("k", "http://h/deep")
    W.appendPage(w2, { records = recs(1, 1500, "OPDS://k/deep"), next_url = "n" })
    eq((w2.count or 0), 1500, "a feed holds far more than the old 1000 cap")
    eq(w2.trimmed, false, "and nothing is flagged as trimmed, because nothing was")
    eq(entriesOf(w2)[1].filepath, "OPDS://k/deep1", "the first record is still first")
    local tail = W.slice(w2, 1499, 1)
    eq(tail[1].filepath, "OPDS://k/deep1500", "and the newest is still last")
    -- The operation this whole change was for: a page from the middle of a
    -- deep feed, without materialising the feed.
    local mid = W.slice(w2, 1200, 10)
    eq(#mid, 10, "a page at depth 1200 slices")
    eq(mid[1].filepath, "OPDS://k/deep1201", "at the right offset")
end

-- Eviction moved to the storage layer, where it is a DELETE ordered by
-- staleness rather than a walk over every window weighing it (covered against
-- real SQLite in _test_opds_db). The rationale it protects is still worth
-- recording here, because it is about OPDS and not about databases: a
-- Gutenberg-style catalogue models every work as a one-entry subcatalog, so
-- browsing creates a child window per tapped book. A cap counted in FEEDS
-- treated those the same as a large category window and evicted the earliest
-- tapped book's window on each new tap - whose tile then lost its
-- flattened/borrowed cover on the very repaint that showed the new one. The
-- budget is therefore counted in ENTRIES, so tiny child windows cost what they
-- weigh.
do
    for i = 1, 30 do
        local w = W.load("k", "http://h/child/" .. i)
        W.appendPage(w, { records = recs(i, i, "OPDS://c/") })
        w.fetched_at = 1000 + i
        W.save("k", "http://h/child/" .. i, w)
    end
    eq(W.count("k", "http://h/child/1"), 1, "a one-entry child window persists")
    eq(W.count("k", "http://h/child/30"), 1, "and so does the newest")
    -- Saving one feed must not disturb another: the whole reason the old store
    -- had to rewrite everything is gone.
    local other = W.load("k", "http://h/child/15")
    eq((other.count or 0), 1, "an untouched feed still holds its entry")
    ok(W.MAX_TOTAL_ENTRIES ~= nil and W.MAX_FEEDS ~= nil,
       "the budgets the storage layer enforces are still declared here")
end


-- ── fetchUrl: where the next request goes ──────────────────────────────────
-- The companion to needsFetch. It was written out twice, in the fetch walk
-- and in the read-ahead, and the copies drifted - the read-ahead went on
-- requiring next_url after the walk had learned that a missing chain means
-- LOST, not finished. A feed in that state then had nothing that would ever
-- fetch for it, and paging past what it held read "no books yet" forever.
local winf = W.load("k", "http://h/fetchurl")
eq(W.fetchUrl(winf, "http://h/fetchurl"), "http://h/fetchurl",
   "a window with nothing cached starts at the top")
W.appendPage(winf, { records = recs(1, 5, "OPDS://k/fu"), next_url = "http://h/fu?p=2" })
eq(W.fetchUrl(winf, "http://h/fetchurl"), "http://h/fu?p=2",
   "a held chain is followed")
-- The state a bug left Internet Archive windows in: entries, no chain, never
-- seen to end. Re-walking costs requests and adds nothing twice, and is the
-- only way back; treating it as an ending freezes the category permanently.
winf.next_url = nil
eq(W.fetchUrl(winf, "http://h/fetchurl"), "http://h/fetchurl",
   "a LOST chain restarts from the top rather than reading as finished")
winf.complete = true
eq(W.fetchUrl(winf, "http://h/fetchurl"), nil,
   "and a feed seen to end asks for nothing")
-- Agrees with needsFetch, which is the whole reason they sit together: any
-- window that says there is more must also say where it is.
eq(W.needsFetch(winf, 0, 999), false, "complete: needsFetch agrees")
winf.complete = false
ok(W.needsFetch(winf, 0, 999) and W.fetchUrl(winf, "http://h/fetchurl") ~= nil,
   "incomplete: needsFetch says yes and fetchUrl has somewhere to go")

print(string.format("%d pass, %d fail", pass, fail))
if fail > 0 then os.exit(1) end
