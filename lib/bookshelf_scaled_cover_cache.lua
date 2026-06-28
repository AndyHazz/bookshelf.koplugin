-- bookshelf_scaled_cover_cache.lua
-- LRU of scaled cover bbs, keyed by filepath only ("canonical-dim"
-- caching). One entry per book, sized to the LARGEST render dims seen
-- across hero / shelf / expanded-shelf in this session.
local logger = require("logger")
-- Per-cover cache logging is verbose (one line per PUT/EVICT) and, because
-- Lua evaluates the string.format() argument before logger.dbg can discard it
-- at the info level, the format cost is paid on every cover even with debug
-- logging off. Gate it behind a constant so production pays nothing; flip to
-- true when diagnosing cache churn.
local _PERF_LOG = false
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
-- least as many pixels as the incoming bb, the incoming bb is ignored
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
--
-- clear() and remove() also don't free explicitly — they just drop the
-- cache's references and let GC do its thing. Existing widgets that are
-- still holding bbs keep working.

-- Resident byte size of a scaled cover bb. `stride` is the bytes-per-row of
-- the underlying C allocation, so `stride * h` is the true RAM footprint
-- INCLUDING any row padding -- and it scales correctly with both cover
-- dimensions and bit depth (1 byte/px on grayscale e-ink vs 4 bytes/px RGB32
-- on a colour panel) without the cache having to know the device type. This
-- is why the cache bounds memory by BYTES, not entry count: "128 covers" is
-- ~8 MiB of small grayscale shelf covers but could be ~150 MiB of large
-- colour hero covers -- the same number, wildly different RAM.
local function _bbBytes(bb)
    if not bb then return 0 end
    local ok, n = pcall(function()
        local h = (bb.getHeight and bb:getHeight()) or tonumber(bb.h) or 0
        local stride = tonumber(bb.stride)
        if stride and h > 0 then return stride * h end
        local w   = (bb.getWidth and bb:getWidth()) or 0
        local bpp = (bb.getBpp and bb:getBpp()) or 8
        return w * h * math.ceil(bpp / 8)
    end)
    return (ok and n) or 0
end

local ScaledCoverCache = {
    -- The cache is bounded by RAM, in BYTES -- the only unit that actually
    -- maps to memory, since per-entry size varies ~5x (shelf vs hero), ~4x
    -- (grayscale 1 B/px vs colour RGB32), and with DPI / layout. The user-
    -- facing setting is an MB budget that feeds _byte_budget (see the widget's
    -- _applyCoverCacheBudget); 24 MiB is the default RAM allocation.
    --
    -- _capacity is a non-user-facing entry-COUNT backstop, kept only to bound
    -- the O(n) _order scans in get/put and guard against a pathological
    -- many-tiny-covers case. It is set high enough that the byte budget always
    -- binds first for normal budgets, so in practice RAM is the sole limit.
    _capacity    = 1024,
    _byte_budget = 24 * 1024 * 1024,
    _bytes       = 0,  -- running sum of resident entry bytes (see _sizes)
    _cache    = {},    -- filepath → bb
    _order    = {},    -- list of filepaths, oldest at front, MRU at back
    _sizes    = {},    -- filepath → bytes, so evict/replace adjust _bytes O(1)
    _hits     = 0,     -- perf: cache hits this session
    _puts     = 0,     -- perf: cache misses (scales) this session
    _evictions= 0,     -- perf: evictions this session
}

-- setCapacity(n) — adjust the entry-COUNT backstop. Not user-facing: the RAM
-- bound is _byte_budget (driven by the MB setting). Retained for completeness
-- and any internal tuning; raising it lets more covers stay resident (until
-- the byte budget binds), lowering it evicts down immediately.
function ScaledCoverCache:setCapacity(n)
    n = tonumber(n)
    if not n then return end
    n = math.floor(n)
    if n < 1 then n = 1 end
    if n == self._capacity then return end
    self._capacity = n
    self:_evictIfNeeded()
end

-- setByteBudget(bytes) — hard cap on total resident cover bytes. Optional
-- override of the 24 MiB default; the caller (settings) may expose this so a
-- user with a large-RAM colour device can raise it, or a tight device lower
-- it. Evicts immediately if the new budget is smaller than current usage.
function ScaledCoverCache:setByteBudget(bytes)
    bytes = tonumber(bytes)
    if not bytes then return end
    bytes = math.floor(bytes)
    if bytes < 1 then return end
    if bytes == self._byte_budget then return end
    self._byte_budget = bytes
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
    -- Evict oldest until BOTH bounds hold: entry count <= capacity AND
    -- resident bytes <= byte budget. Keep at least the most-recently inserted
    -- entry (#order > 1 guard) so a single oversized cover can't evict itself
    -- and a freshly-cached page cover is never yanked out from under its paint.
    while #self._order > 1
          and (#self._order > self._capacity or self._bytes > self._byte_budget) do
        local key = table.remove(self._order, 1)
        self._cache[key] = nil
        self._bytes = self._bytes - (self._sizes[key] or 0)
        if self._bytes < 0 then self._bytes = 0 end
        self._sizes[key] = nil
        self._evictions = self._evictions + 1
        if _PERF_LOG then logger.dbg(string.format(
            "[bookshelf perf] ScaledCoverCache: EVICT fp=%s size=%d/%d bytes=%d/%d",
            key, #self._order, self._capacity, self._bytes, self._byte_budget)) end
    end
end

function ScaledCoverCache:get(filepath)
    if not filepath or filepath == "" then return nil end
    local bb = self._cache[filepath]
    if not bb then return nil end
    self._hits = self._hits + 1
    self:_removeKey(filepath)
    self._order[#self._order + 1] = filepath
    return bb
end

function ScaledCoverCache:has(filepath)
    if not filepath or filepath == "" then return false end
    return self._cache[filepath] ~= nil
end

function ScaledCoverCache:put(filepath, bb)
    if not filepath or filepath == "" then return bb end
    local existing = self._cache[filepath]
    if existing == bb then
        return bb
    end
    if existing then
        local ex_px = (existing.getWidth and existing:getWidth() or 0)
                    * (existing.getHeight and existing:getHeight() or 0)
        local new_px = (bb.getWidth and bb:getWidth() or 0)
                     * (bb.getHeight and bb:getHeight() or 0)
        if ex_px >= new_px then
            self:_removeKey(filepath)
            self._order[#self._order + 1] = filepath
            return existing
        end
        -- New is larger; replace cache reference. Do NOT free existing
        -- — other live widgets may still hold it (see lifetime note at
        -- top of module). LuaJIT will reclaim when the last reference
        -- drops. Drop the old entry's byte accounting; the new size is
        -- added below.
        self:_removeKey(filepath)
        self._bytes = self._bytes - (self._sizes[filepath] or 0)
        if self._bytes < 0 then self._bytes = 0 end
        self._sizes[filepath] = nil
    end
    self._cache[filepath] = bb
    self._order[#self._order + 1] = filepath
    local nbytes = _bbBytes(bb)
    self._sizes[filepath] = nbytes
    self._bytes = self._bytes + nbytes
    self._puts = self._puts + 1
    if _PERF_LOG then logger.dbg(string.format(
        "[bookshelf perf] ScaledCoverCache: PUT fp=%s %dx%d size=%d/%d bytes=%d/%d hits=%d puts=%d",
        filepath,
        (bb.getWidth and bb:getWidth() or 0),
        (bb.getHeight and bb:getHeight() or 0),
        #self._order, self._capacity, self._bytes, self._byte_budget,
        self._hits, self._puts)) end
    self:_evictIfNeeded()
    return bb
end

-- drop(filepath) — surgical eviction for a single book. Used when a
-- caller knows that book's source bytes have changed (Refresh metadata
-- after enricher cover swap, etc.) and the next render must re-decode
-- from BIM rather than serving stale scaled bytes. Same lifetime
-- contract as put/clear: drops the reference, doesn't bb:free().
function ScaledCoverCache:drop(filepath)
    if not filepath or filepath == "" then return end
    if self._cache[filepath] == nil then return end
    self._bytes = self._bytes - (self._sizes[filepath] or 0)
    if self._bytes < 0 then self._bytes = 0 end
    self._cache[filepath] = nil
    self._sizes[filepath] = nil
    self:_removeKey(filepath)
end

-- Backwards-compatible alias used by fork code predating upstream's drop().
function ScaledCoverCache:remove(filepath)
    return self:drop(filepath)
end

-- clear — drop the cache's references. Same lifetime contract as put:
-- we do NOT explicitly free; live widgets may still be holding bbs.
-- LuaJIT will reclaim once every reference is gone.
function ScaledCoverCache:clear()
    logger.dbg(string.format("[bookshelf perf] ScaledCoverCache: clear hits=%d puts=%d evictions=%d",
        self._hits, self._puts, self._evictions))
    self._cache     = {}
    self._order     = {}
    self._sizes     = {}
    self._bytes     = 0
    self._hits      = 0
    self._puts      = 0
    self._evictions = 0
end

return ScaledCoverCache
