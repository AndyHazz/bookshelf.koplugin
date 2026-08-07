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

print(string.format("%d pass, %d fail", pass, fail))
if fail > 0 then os.exit(1) end
