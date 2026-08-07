-- lib/bookshelf_opds_window.lua
-- Progressive window over one OPDS feed: entries accumulate as the user pages
-- deeper (rel=next), the shelf slices out of it, and it persists in its own
-- sub-store so an OPDS chip renders instantly (and offline) on revisit.
-- Bounded two ways: MAX_ENTRIES per feed (drop-from-front sliding window;
-- paging far back after a trim re-fetches from the feed start) and MAX_FEEDS
-- per store (LRU on fetched_at). Network never happens here.

local Store = require("lib/bookshelf_settings_store")

local M = {}

M.MAX_ENTRIES = 1000
M.MAX_FEEDS   = 20
local KEY = "opds_cache"

local function cacheKey(server_key, feed_url)
    return server_key .. "|" .. feed_url
end

local function readCache()
    local c = Store.read(KEY)
    return type(c) == "table" and c or {}
end

function M.load(server_key, feed_url)
    local c = readCache()
    local w = c[cacheKey(server_key, feed_url)]
    if type(w) == "table" and type(w.entries) == "table" then
        w.nav = type(w.nav) == "table" and w.nav or {}
        return w
    end
    return { entries = {}, nav = {}, total = nil, next_url = nil, fetched_at = 0 }
end

function M.appendPage(win, mapped)
    if type(mapped) ~= "table" then return win end
    local seen = {}
    for _i, r in ipairs(win.entries) do seen[r.filepath] = true end
    for _i, r in ipairs(mapped.records or {}) do
        if not seen[r.filepath] then
            seen[r.filepath] = true
            win.entries[#win.entries + 1] = r
        end
    end
    if mapped.nav and #mapped.nav > 0 then win.nav = mapped.nav end
    win.next_url = mapped.next_url
    if mapped.total then win.total = mapped.total end
    if #win.entries > M.MAX_ENTRIES then
        local excess = #win.entries - M.MAX_ENTRIES
        for _ = 1, excess do table.remove(win.entries, 1) end
        win.trimmed = true
    end
    return win
end

function M.slice(win, offset, limit)
    local page = {}
    for i = (offset or 0) + 1, math.min((offset or 0) + (limit or #win.entries), #win.entries) do
        page[#page + 1] = win.entries[i]
    end
    local total = win.total or #win.entries
    local open_ended = (win.total == nil) and (win.next_url ~= nil)
    return page, total, open_ended
end

function M.needsFetch(win, offset, limit)
    return ((offset or 0) + (limit or 0)) > #win.entries and win.next_url ~= nil
end

function M.save(server_key, feed_url, win)
    local c = readCache()
    c[cacheKey(server_key, feed_url)] = win
    -- LRU: evict the stalest feeds beyond the cap.
    local keys = {}
    for k, w in pairs(c) do keys[#keys + 1] = { k = k, at = (w.fetched_at or 0) } end
    if #keys > M.MAX_FEEDS then
        table.sort(keys, function(a, b) return a.at < b.at end)
        for i = 1, #keys - M.MAX_FEEDS do c[keys[i].k] = nil end
    end
    Store.save(KEY, c)
    Store.flush()
end

function M.reset(server_key, feed_url)
    local c = readCache()
    c[cacheKey(server_key, feed_url)] = nil
    Store.save(KEY, c)
    Store.flush()
end

return M
