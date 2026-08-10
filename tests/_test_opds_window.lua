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

local W = dofile("lib/bookshelf_opds_window.lua")

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
eq(#win.entries, 0, "fresh window empty")
ok(W.needsFetch(win, 0, 8) == false, "fresh window: nothing known, no next_url, no fetch signal")

-- first page arrives: 10 entries, total known
W.appendPage(win, { records = recs(1, 10), next_url = "http://h/f?p=2", total = 25 })
eq(#win.entries, 10, "10 entries after page 1")
local page, total, open_ended = W.slice(win, 0, 8)
eq(#page, 8, "slice of 8")
eq(total, 25, "known total reported")
eq(open_ended, false, "known total -> not open-ended")
ok(W.needsFetch(win, 8, 8) == true, "page 2 needs fetch (only 10 held)")
ok(W.needsFetch(win, 0, 8) == false, "page 1 held")

-- dedupe on filepath
W.appendPage(win, { records = recs(10, 12), next_url = nil, total = 25 })
eq(#win.entries, 12, "dedupe kept 12, not 13")
ok(W.needsFetch(win, 8, 8) == false, "no next_url -> nothing more to fetch")

-- nav records ride the same entries list as books and dedupe the same way
local win_nav = W.load("k", "http://h/nav")
local nav_rec = { kind = "opds_nav", is_remote = true, is_opds_nav = true,
                   filepath = "OPDS://k/nav/aaaa", label = "Fiction", title = "Fiction",
                   display_title = "Fiction", opds = { feed_url = "http://h/fiction" } }
W.appendPage(win_nav, { records = { nav_rec, recs(1, 1, "OPDS://k/nav/book")[1] } })
eq(#win_nav.entries, 2, "nav record and book record both appended")
eq(win_nav.entries[1].kind, "opds_nav", "nav record kept in entry order")
W.appendPage(win_nav, { records = { nav_rec } })
eq(#win_nav.entries, 2, "re-appending the same nav record dedupes by filepath")

-- unknown total: open-ended while next_url present
local win2 = W.load("k", "http://h/g")
W.appendPage(win2, { records = recs(1, 10, "OPDS://k/g"), next_url = "http://h/g?p=2", total = nil })
local _p2, total2, open2 = W.slice(win2, 0, 8)
eq(total2, 10, "unknown total = entries held")
eq(open2, true, "unknown total + next -> open-ended")

-- trim: cap at 1000, drop from front
local win3 = W.load("k", "http://h/big")
W.appendPage(win3, { records = recs(1, 1200, "OPDS://k/big"), next_url = nil, total = nil })
eq(#win3.entries, 1000, "trimmed to 1000")
eq(win3.entries[1].filepath, "OPDS://k/big201", "dropped from the front")
ok(win3.trimmed == true, "trim flagged")

-- persistence round-trip + LRU eviction at 20 feeds
W.save("k", "http://h/f", win)
local back = W.load("k", "http://h/f")
eq(#back.entries, 12, "persisted window reloads")
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
local cache = store_data["opds_cache"]
local count = 0
for _k in pairs(cache) do count = count + 1 end
eq(count, 26, "tiny feeds are not evicted by count (25 + the 12-entry window)")

-- reset drops the window
W.reset("k", "http://h/f")
eq(#W.load("k", "http://h/f").entries, 0, "reset clears")

-- a legacy persisted window carrying an old separate `nav` field still loads:
-- the field is tolerated (no error) and simply ignored, not materialised.
store_data["opds_cache"]["k|http://h/legacy"] = {
    entries = recs(1, 2, "OPDS://k/legacy"),
    nav = { { is_opds_nav = true, label = "Old Nav", feed_url = "http://h/old" } },
    total = nil, next_url = nil, fetched_at = 5,
}
local legacy = W.load("k", "http://h/legacy")
eq(#legacy.entries, 2, "legacy window's entries load despite the old nav field")

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
ok(p4[1] ~= win4.entries[1], "slice returns a fresh table, not the stored reference")
eq(p4[1].filepath, "OPDS://k/copy1", "slice copy carries the field values")
eq(p4[1].opds.thumbnail_url, "http://h/1.jpg", "slice copy carries the nested opds data")
p4[1].cover_bb = function() end        -- stand-in for a live BlitBuffer
p4[1].has_cover = true
p4[1].cover_image_path = "/tmp/opds_covers_test_settings/bookshelf_covers/opds/k/x.img"
p4[1].cover_borrowed = true
p4[1].downloaded = true
p4[1].description = "a mirrored feed summary"
p4[1].title = "mutated"
ok(win4.entries[1].cover_bb == nil, "decorating a sliced record leaves the window entry clean")
ok(win4.entries[1].has_cover == nil, "has_cover doesn't reach the window entry either")
ok(win4.entries[1].cover_image_path == nil, "cover_image_path doesn't reach the window entry either")
ok(win4.entries[1].cover_borrowed == nil, "cover_borrowed doesn't reach the window entry either")
ok(win4.entries[1].downloaded == nil, "downloaded doesn't reach the window entry either")
ok(win4.entries[1].description == nil, "description doesn't reach the window entry either")
eq(win4.entries[1].title, "t1", "a field mutation on the page doesn't reach the window entry")

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

local win5 = W.load("k", "http://h/scrub")
W.appendPage(win5, { records = recs(1, 2, "OPDS://k/scrub") })
win5.fetched_at = 9999   -- newest, so the LRU pass can't evict it
win5.entries[1].cover_bb = function() end   -- stand-in for a BlitBuffer
win5.entries[1].cover_w, win5.entries[1].cover_h = 60, 90
win5.entries[1].has_cover = true
win5.entries[1].cover_image_path = "/tmp/opds_covers_test_settings/bookshelf_covers/opds/k/y.img"
win5.entries[1].cover_borrowed = true
win5.entries[1].downloaded = true
win5.entries[1].description = "a mirrored feed summary"
win5.entries[1].opds = { feed_url = "http://h/scrub/1",
                         icon = "data:image/png;base64,AAAA" }
win5.entries[2].has_cover = true
W.save("k", "http://h/scrub", win5)
local saved = store_data["opds_cache"]["k|http://h/scrub"]
ok(saved ~= nil, "scrub window persisted")
ok(saved.entries[1].cover_bb == nil, "save strips cover_bb before persisting")
ok(saved.entries[1].cover_w == nil, "save strips cover_w")
ok(saved.entries[1].cover_h == nil, "save strips cover_h")
ok(saved.entries[1].has_cover == nil, "save strips has_cover")
ok(saved.entries[1].cover_image_path == nil, "save strips cover_image_path")
ok(saved.entries[1].cover_borrowed == nil, "save strips cover_borrowed")
ok(saved.entries[1].downloaded == nil, "save strips the downloaded decoration")
-- The nav-icon data URI lives under the nested opds table and is PERSISTED
-- state, not render decoration: the scrub must never touch it (a future
-- edit adding "icon" or "opds" to COVER_KEYS would break placeholder icons).
ok(saved.entries[1].opds ~= nil, "save keeps the nested opds table")
eq(saved.entries[1].opds.icon, "data:image/png;base64,AAAA",
   "save keeps opds.icon (nav-icon data uri survives the scrub)")
ok(saved.entries[1].description == nil,
    "save strips the description mirrored from opds.summary (the summary is already stored once)")
ok(saved.entries[2].has_cover == nil, "save strips decoration from every entry, not just the first")
eq(saved.entries[1].filepath, "OPDS://k/scrub1", "save keeps the real record fields")
eq(findUnserialisable(store_data["opds_cache"], "opds_cache"), nil,
    "nothing unserialisable reaches the store")

-- complete flag: the fetch loop marks a window complete when the feed chain
-- terminally ended. slice must then clamp the promised total to what is
-- actually cached (totalResults can over-promise: IA advertises more than its
-- next chain serves), and never call the window open-ended.
local winc = W.load("k", "http://h/complete")
W.appendPage(winc, { records = recs(1, 10), next_url = "http://h/c?p=2", total = 150 })
local _, t_before = W.slice(winc, 0, 8)
eq(t_before, 150, "incomplete window still promises totalResults")
winc.complete = true
winc.next_url = nil
local _, t_after, oe_after = W.slice(winc, 0, 8)
eq(t_after, 10, "complete window clamps total to cached entries")
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

-- Trim: the drop-from-front sliding window compacts in one pass. Order must
-- be preserved, the tail nil'd (no holes, no ghosts past the cap), and the
-- trimmed flag set so paging knows a re-fetch from the feed start may happen.
do
    local w2 = { entries = {}, total = nil, next_url = nil, fetched_at = 0 }
    W.appendPage(w2, { records = recs(1, W.MAX_ENTRIES), next_url = "n" })
    eq(#w2.entries, W.MAX_ENTRIES, "exactly at cap: no trim")
    ok(w2.trimmed == nil, "no trimmed flag at cap")
    W.appendPage(w2, { records = recs(W.MAX_ENTRIES + 1, W.MAX_ENTRIES + 7), next_url = "n" })
    eq(#w2.entries, W.MAX_ENTRIES, "capped after overflow")
    ok(w2.trimmed == true, "trimmed flag set")
    eq(w2.entries[1].filepath, "OPDS://k/8", "oldest 7 dropped from the front")
    eq(w2.entries[W.MAX_ENTRIES].filepath, "OPDS://k/" .. (W.MAX_ENTRIES + 7),
       "newest record kept at the tail")
    local holes = false
    for i = 1, W.MAX_ENTRIES do
        if type(w2.entries[i]) ~= "table" then holes = true break end
    end
    ok(not holes, "compaction leaves no holes")
    ok(w2.entries[W.MAX_ENTRIES + 1] == nil, "tail past the cap is nil'd")
end

-- Entry-weighted store eviction. The Gutenberg regression: every tapped book
-- saves a one-entry child window, and the old 20-FEED cap evicted the
-- earliest tapped book's window on each new tap - its tile lost the
-- flattened/borrowed cover on the exact repaint that showed the new one.
do
    store_data["opds_cache"] = nil
    local old_feeds, old_total = W.MAX_FEEDS, W.MAX_TOTAL_ENTRIES

    -- 30 one-entry child windows: far past the OLD cap of 20, well inside
    -- the entry budget - every one must stay resident.
    for i = 1, 30 do
        W.save("k", "http://h/child/" .. i,
               { entries = recs(i, i, "OPDS://c/"), fetched_at = 1000 + i })
    end
    local c = store_data["opds_cache"]
    local n = 0
    for _ in pairs(c) do n = n + 1 end
    eq(n, 30, "30 one-entry child windows all stay resident")

    -- Shrink the entry budget so the next save must evict: victims are the
    -- STALEST windows, the just-saved window is immune, and the budget holds.
    W.MAX_TOTAL_ENTRIES = 40   -- 30 resident + 11 incoming = 41 > 40
    W.save("k", "http://h/big",
           { entries = recs(1, 11, "OPDS://b/"), fetched_at = 5000 })
    c = store_data["opds_cache"]
    ok(c["k|http://h/big"] ~= nil, "just-saved window survives its own save")
    ok(c["k|http://h/child/1"] == nil, "stalest child evicted when the entry budget binds")
    ok(c["k|http://h/child/2"] ~= nil, "next-stalest survives (only what the budget demands)")
    ok(c["k|http://h/child/30"] ~= nil, "fresh children stay")
    local total = 0
    for _k, w in pairs(c) do total = total + #w.entries end
    ok(total <= 40, "total entries within budget, got " .. total)

    -- The feed-count backstop still converges a store of many tiny windows.
    W.MAX_TOTAL_ENTRIES = old_total
    W.MAX_FEEDS = 25
    W.save("k", "http://h/one-more",
           { entries = recs(1, 1, "OPDS://m/"), fetched_at = 6000 })
    c = store_data["opds_cache"]
    n = 0
    for _ in pairs(c) do n = n + 1 end
    eq(n, 25, "feed backstop evicts down to the cap")
    ok(c["k|http://h/one-more"] ~= nil, "newest window kept by the backstop")
    ok(c["k|http://h/child/2"] == nil, "backstop evicts stalest-first")

    W.MAX_FEEDS, W.MAX_TOTAL_ENTRIES = old_feeds, old_total
    store_data["opds_cache"] = nil
end

-- the constant Task 2's skip loop consumes
eq(W.UNUSABLE_PAGE_LIMIT, 3, "unusable-page skip limit exported")

print(string.format("%d pass, %d fail", pass, fail))
if fail > 0 then os.exit(1) end
