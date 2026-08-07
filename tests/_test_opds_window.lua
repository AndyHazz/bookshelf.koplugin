-- tests/_test_opds_window.lua
-- Progressive feed window: append pages, slice for the shelf, know when a
-- page turn needs more network, persist bounded state.
package.path = "./?.lua;./?/init.lua;" .. package.path
package.loaded["logger"] = { dbg=function() end, info=function() end,
                             warn=function() end, err=function() end }
-- In-memory settings store stub matching lib/bookshelf_settings_store's API.
local store_data = {}
package.loaded["lib/bookshelf_settings_store"] = {
    read  = function(k, d) return store_data[k] ~= nil and store_data[k] or d end,
    save  = function(k, v) store_data[k] = v end,
    flush = function() end,
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
W.appendPage(win, { records = recs(1, 10), nav = {}, next_url = "http://h/f?p=2", total = 25 })
eq(#win.entries, 10, "10 entries after page 1")
local page, total, open_ended = W.slice(win, 0, 8)
eq(#page, 8, "slice of 8")
eq(total, 25, "known total reported")
eq(open_ended, false, "known total -> not open-ended")
ok(W.needsFetch(win, 8, 8) == true, "page 2 needs fetch (only 10 held)")
ok(W.needsFetch(win, 0, 8) == false, "page 1 held")

-- dedupe on filepath
W.appendPage(win, { records = recs(10, 12), nav = {}, next_url = nil, total = 25 })
eq(#win.entries, 12, "dedupe kept 12, not 13")
ok(W.needsFetch(win, 8, 8) == false, "no next_url -> nothing more to fetch")

-- unknown total: open-ended while next_url present
local win2 = W.load("k", "http://h/g")
W.appendPage(win2, { records = recs(1, 10, "OPDS://k/g"), nav = {}, next_url = "http://h/g?p=2", total = nil })
local _p2, total2, open2 = W.slice(win2, 0, 8)
eq(total2, 10, "unknown total = entries held")
eq(open2, true, "unknown total + next -> open-ended")

-- trim: cap at 1000, drop from front
local win3 = W.load("k", "http://h/big")
W.appendPage(win3, { records = recs(1, 1200, "OPDS://k/big"), nav = {}, next_url = nil, total = nil })
eq(#win3.entries, 1000, "trimmed to 1000")
eq(win3.entries[1].filepath, "OPDS://k/big201", "dropped from the front")
ok(win3.trimmed == true, "trim flagged")

-- persistence round-trip + LRU eviction at 20 feeds
W.save("k", "http://h/f", win)
local back = W.load("k", "http://h/f")
eq(#back.entries, 12, "persisted window reloads")
for i = 1, 25 do
    local wx = W.load("k", "http://h/feed" .. i)
    wx.fetched_at = i  -- deterministic age (no os.time in tests)
    W.appendPage(wx, { records = recs(1, 1, "OPDS://k/feed" .. i .. "/"), nav = {} })
    W.save("k", "http://h/feed" .. i, wx)
end
local cache = store_data["opds_cache"]
local count = 0
for _k in pairs(cache) do count = count + 1 end
ok(count <= 20, "LRU cap holds, got " .. count)

-- reset drops the window
W.reset("k", "http://h/f")
eq(#W.load("k", "http://h/f").entries, 0, "reset clears")

-- slice hands out COPIES. Callers decorate page records with a live cover
-- BlitBuffer; if that landed on the window's own entry it would be serialised
-- on the next save, and dump.lua has no representation for cdata -- the whole
-- store file stops parsing and every feed's cache is lost.
local win4 = W.load("k", "http://h/copy")
W.appendPage(win4, { records = {
    { filepath = "OPDS://k/copy1", title = "t1", opds = { thumbnail_url = "http://h/1.jpg" } },
    { filepath = "OPDS://k/copy2", title = "t2", opds = { thumbnail_url = "http://h/2.jpg" } },
}, nav = {} })
local p4 = W.slice(win4, 0, 2)
eq(#p4, 2, "slice returned both entries")
ok(p4[1] ~= win4.entries[1], "slice returns a fresh table, not the stored reference")
eq(p4[1].filepath, "OPDS://k/copy1", "slice copy carries the field values")
eq(p4[1].opds.thumbnail_url, "http://h/1.jpg", "slice copy carries the nested opds data")
p4[1].cover_bb = function() end        -- stand-in for a live BlitBuffer
p4[1].has_cover = true
p4[1].title = "mutated"
ok(win4.entries[1].cover_bb == nil, "decorating a sliced record leaves the window entry clean")
ok(win4.entries[1].has_cover == nil, "has_cover doesn't reach the window entry either")
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
W.appendPage(win5, { records = recs(1, 2, "OPDS://k/scrub"), nav = {} })
win5.fetched_at = 9999   -- newest, so the LRU pass can't evict it
win5.entries[1].cover_bb = function() end   -- stand-in for a BlitBuffer
win5.entries[1].cover_w, win5.entries[1].cover_h = 60, 90
win5.entries[1].has_cover = true
win5.entries[2].has_cover = true
W.save("k", "http://h/scrub", win5)
local saved = store_data["opds_cache"]["k|http://h/scrub"]
ok(saved ~= nil, "scrub window persisted")
ok(saved.entries[1].cover_bb == nil, "save strips cover_bb before persisting")
ok(saved.entries[1].cover_w == nil, "save strips cover_w")
ok(saved.entries[1].cover_h == nil, "save strips cover_h")
ok(saved.entries[1].has_cover == nil, "save strips has_cover")
ok(saved.entries[2].has_cover == nil, "save strips decoration from every entry, not just the first")
eq(saved.entries[1].filepath, "OPDS://k/scrub1", "save keeps the real record fields")
eq(findUnserialisable(store_data["opds_cache"], "opds_cache"), nil,
    "nothing unserialisable reaches the store")

print(string.format("%d pass, %d fail", pass, fail))
if fail > 0 then os.exit(1) end
