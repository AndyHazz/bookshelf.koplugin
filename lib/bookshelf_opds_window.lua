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

-- A persisted window may still carry a legacy `nav` field from before nav
-- entries rode `entries` as first-class records: it is tolerated (no error)
-- and simply left alone, never read or rewritten here.
function M.load(server_key, feed_url)
    local c = readCache()
    local w = c[cacheKey(server_key, feed_url)]
    if type(w) == "table" and type(w.entries) == "table" then
        return w
    end
    return { entries = {}, total = nil, next_url = nil, fetched_at = 0 }
end

function M.appendPage(win, mapped)
    if type(mapped) ~= "table" then return win end
    local seen = {}
    for _i, r in ipairs(win.entries) do seen[r.filepath] = true end
    -- Nav entries ride mapped.records like books (mapEntries puts them
    -- first) and dedupe on filepath the same way; no separate handling.
    for _i, r in ipairs(mapped.records or {}) do
        if not seen[r.filepath] then
            seen[r.filepath] = true
            win.entries[#win.entries + 1] = r
        end
    end
    win.next_url = mapped.next_url
    if mapped.total then win.total = mapped.total end
    if #win.entries > M.MAX_ENTRIES then
        local excess = #win.entries - M.MAX_ENTRIES
        for _ = 1, excess do table.remove(win.entries, 1) end
        win.trimmed = true
    end
    return win
end

-- Page out of the window. Each record is a SHALLOW COPY, never the stored
-- table: callers decorate what they get back (the repo attaches a live cover
-- BlitBuffer to the visible slice), and a decorated window entry would be
-- serialised on the next save. dump.lua has no representation for cdata, so it
-- emits a bare `,` and the whole sub-store stops parsing - LuaSettings then
-- falls back to {} and EVERY feed's cache is silently lost, not just the one
-- whose covers were drawn. The nested `opds` table stays shared: it is plain
-- data nothing decorates.
function M.slice(win, offset, limit)
    local page = {}
    for i = (offset or 0) + 1, math.min((offset or 0) + (limit or #win.entries), #win.entries) do
        local stored = win.entries[i]
        if type(stored) == "table" then
            local copy = {}
            for k, v in pairs(stored) do copy[k] = v end
            page[#page + 1] = copy
        else
            page[#page + 1] = stored
        end
    end
    local total = win.total or #win.entries
    local open_ended = (win.total == nil) and (win.next_url ~= nil)
    return page, total, open_ended
end

function M.needsFetch(win, offset, limit)
    return ((offset or 0) + (limit or 0)) > #win.entries and win.next_url ~= nil
end

-- Cover decoration is render state and must never be persisted - see slice().
-- Belt and braces: slice() hands out copies so no decorator can reach a stored
-- record, but one stray reference by any other route costs the user their whole
-- OPDS cache, so strip on the way out too. The sweep covers every window in the
-- store, not just the one being saved: save() re-serialises the entire cache
-- table, so a poisoned entry under any other feed breaks this write as well.
local COVER_KEYS = { "cover_bb", "cover_w", "cover_h", "has_cover" }
local function scrubCovers(cache)
    for _k, w in pairs(cache) do
        if type(w) == "table" and type(w.entries) == "table" then
            for _i, r in ipairs(w.entries) do
                if type(r) == "table" then
                    for _j = 1, #COVER_KEYS do r[COVER_KEYS[_j]] = nil end
                end
            end
        end
    end
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
    scrubCovers(c)
    -- No Store.flush() here or in reset(): Store.save routes "opds_cache" to
    -- its own sub-store file, which flushes itself on save, so the window is
    -- already durable. Store.flush() would re-serialise the MAIN bookshelf.lua
    -- instead - a ~140ms write this has no reason to trigger, once per fetch.
    Store.save(KEY, c)
end

function M.reset(server_key, feed_url)
    local c = readCache()
    c[cacheKey(server_key, feed_url)] = nil
    scrubCovers(c)   -- same whole-cache re-serialise as save(), same exposure
    Store.save(KEY, c)
end

return M
