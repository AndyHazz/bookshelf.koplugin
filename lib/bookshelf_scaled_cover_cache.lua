-- bookshelf_scaled_cover_cache.lua
-- LRU of scaled cover bbs, keyed by filepath only ("canonical-dim"
-- caching). One entry per book, sized to the LARGEST render dims seen
-- across hero / shelf / expanded-shelf in this session.
local logger = require("logger")
--
-- Why filepath-only: the same book renders into slots of different
-- dimensions across the UI:
--   * hero cover     (~500 × 750 typical)
--   * standard shelf (~250 × 375 typical)
--   * expanded shelf (slot_h grown by row budget; slot_w usually
--                     unchanged but can shrink on small screens)
--
-- A (filepath, w, h) cache key produced 2-3 entries per book and
-- defeated cross-mode hits — hero ↔ shelf transitions and
-- expanded ↔ standard toggles missed entirely. With a single
-- canonical entry per book, consumers below the canonical size let
-- ImageWidget downscale at paint time (MuPDF, Kindle-safe in this
-- direction — the corruption was upscale-specific).
--
-- Put policy: prefer-larger. On put, if an existing entry has at
-- least as many pixels as the incoming bb, the incoming bb is freed
-- and the existing entry kept. If the incoming bb is larger, it
-- replaces. This means the FIRST consumer (often shelf) seeds the
-- cache at its size; HERO's later put overwrites with bigger; shelf
-- thereafter reads the larger hero bb and downscales. Stable.
--
-- Get returns whatever bb is cached. Consumers check the returned
-- bb's dimensions: if cached >= target in both axes, use it (with
-- ImageWidget downscale when smaller); if cached < target, fall
-- through to a fresh decode+scale (which will then replace the
-- cache entry per the prefer-larger rule).
--
-- Lifetime: the cache holds a strong reference to each cached bb.
-- Callers pass to ImageWidget with image_disposable=false. When the
-- cache drops an entry (eviction or prefer-larger replace) it just
-- nils its own reference — it does NOT call bb:free(). Other live
-- ImageWidgets may still hold the bb (e.g. a shelf SpineWidget whose
-- cover entry got upgraded to hero dims when the user tapped that
-- book into the hero); explicit free would yank C memory out from
-- under those widgets and the next partial repaint would render
-- garbage pixels. Blitbuffer sets up an ffi.gc finalizer at allocate
-- time (see ffi/blitbuffer.lua setAllocated(1)), so the C memory is
-- reclaimed automatically when the last Lua reference goes away.
-- Slight memory-reclaim latency, but no use-after-free.
--
-- clear() also doesn't free explicitly — it just drops the cache's
-- references and lets GC do its thing. Existing widgets that are
-- still holding bbs keep working.
--
-- Invalidation: none required during a session — BookInfoManager
-- only re-extracts thumbnails on user-initiated metadata refresh
-- (out of band; bookshelf doesn't poke this cache from those paths).

local ScaledCoverCache = {
    _capacity = 32,    -- ~6 MiB at 500×750×4 bytes; well within Kindle RAM
    _cache    = {},    -- filepath → bb
    _order    = {},    -- list of filepaths, oldest at front, MRU at back
    _hits     = 0,     -- perf: cache hits this session
    _puts     = 0,     -- perf: cache misses (scales) this session
    _evictions= 0,     -- perf: evictions this session
}

-- setCapacity(n) — change the max number of cached covers. Raising it
-- lets more covers (e.g. preloaded next-page / other-chip covers) stay
-- resident; lowering it evicts down to the new size immediately. Each
-- entry is ~187 KiB at standard shelf dims, so memory scales linearly --
-- the caller (settings) bounds n to a Kindle-safe range.
function ScaledCoverCache:setCapacity(n)
    n = tonumber(n)
    if not n then return end
    n = math.floor(n)
    if n < 1 then n = 1 end
    if n == self._capacity then return end
    self._capacity = n
    self:_evictIfNeeded()
end

function ScaledCoverCache:_removeKey(key)
    for i, k in ipairs(self._order) do
        if k == key then
            table.remove(self._order, i)
            return
        end
    end
end

function ScaledCoverCache:_evictIfNeeded()
    while #self._order > self._capacity do
        local key = table.remove(self._order, 1)
        -- Drop the cache's reference only. Don't call bb:free() — see
        -- lifetime note above; ImageWidgets that still hold this bb
        -- would render garbage pixels on the next paint.
        self._cache[key] = nil
        self._evictions = self._evictions + 1
        logger.dbg(string.format("[bookshelf perf] ScaledCoverCache: EVICT fp=%s size=%d/%d",
            key, #self._order, self._capacity))
    end
end

-- get(filepath) — returns the cached bb (any dimensions) or nil. On
-- hit, the entry is promoted to MRU so it survives further eviction.
-- Caller is responsible for checking the bb's dims against its target
-- slot and either using it (with ImageWidget downscale when bb dims
-- >= target dims) or treating as a miss (when bb dims < target dims).
function ScaledCoverCache:get(filepath)
    if not filepath or filepath == "" then return nil end
    local bb  = self._cache[filepath]
    if not bb then return nil end
    self._hits = self._hits + 1
    self:_removeKey(filepath)
    self._order[#self._order + 1] = filepath
    return bb
end

-- has(filepath) — boolean probe. Doesn't touch MRU order or counters.
-- Used upstream of the BIM cover decode to skip the zstd decompress
-- when the cover is already cached (spine_widget will paint from cache).
function ScaledCoverCache:has(filepath)
    if not filepath or filepath == "" then return false end
    return self._cache[filepath] ~= nil
end

-- put(filepath, bb) — insert or upgrade. Returns the bb now serving as
-- the cache entry for filepath, which is NOT always the bb the caller
-- passed in. Prefer-larger semantics:
--   * No existing entry: cache the new bb. Returns new bb.
--   * Existing entry with >= pixel count: keep existing, return the
--     existing bb. The caller's bb is unused; the caller MUST treat
--     the passed-in bb as if it were never put (don't paint with it
--     unless you have another path; if you owned it, free() it).
--   * Existing entry with < pixel count: install new as the cache
--     entry. The existing bb is no longer in the cache but is NOT
--     freed — other widgets may still hold references and need to
--     paint with it before LuaJIT's FFI finalizer reclaims it.
--     Returns new bb.
--
-- Callers should use the return value to decide what to paint with;
-- this avoids a redundant get() round-trip and makes the discard case
-- explicit at the call site.
function ScaledCoverCache:put(filepath, bb)
    if not filepath or filepath == "" then return bb end
    local existing = self._cache[filepath]
    if existing == bb then
        return bb  -- identity put (no-op)
    end
    if existing then
        local ex_px  = (existing.getWidth and existing:getWidth() or 0)
                     * (existing.getHeight and existing:getHeight() or 0)
        local new_px = (bb.getWidth      and bb:getWidth()      or 0)
                     * (bb.getHeight     and bb:getHeight()     or 0)
        if ex_px >= new_px then
            -- Keep existing; touch MRU. Do NOT free the caller's bb —
            -- they may have a use for it (e.g. paint it directly when
            -- the cache rejects the put). Returning existing tells the
            -- caller "use this instead".
            self:_removeKey(filepath)
            self._order[#self._order + 1] = filepath
            return existing
        end
        -- New is larger; replace cache reference. Do NOT free existing
        -- — other live widgets may still hold it (see lifetime note at
        -- top of module). LuaJIT will reclaim when the last reference
        -- drops.
        self:_removeKey(filepath)
    end
    self._cache[filepath] = bb
    self._order[#self._order + 1] = filepath
    self._puts = self._puts + 1
    logger.dbg(string.format("[bookshelf perf] ScaledCoverCache: PUT fp=%s %dx%d size=%d/%d hits=%d puts=%d",
        filepath,
        (bb.getWidth and bb:getWidth() or 0),
        (bb.getHeight and bb:getHeight() or 0),
        #self._order, self._capacity, self._hits, self._puts))
    self:_evictIfNeeded()
    return bb
end

-- clear — drop the cache's references. Same lifetime contract as put:
-- we do NOT explicitly free; live widgets may still be holding bbs.
-- LuaJIT will reclaim once every reference is gone.
function ScaledCoverCache:clear()
    logger.dbg(string.format("[bookshelf perf] ScaledCoverCache: clear hits=%d puts=%d evictions=%d",
        self._hits, self._puts, self._evictions))
    self._cache     = {}
    self._order     = {}
    self._hits      = 0
    self._puts      = 0
    self._evictions = 0
end

return ScaledCoverCache
