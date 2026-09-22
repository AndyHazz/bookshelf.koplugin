-- bookshelf_hero_tier.lua
-- A small RAM-only LRU of hero-height cover bbs, so the FIRST preview of a
-- book doesn't pay a BIM decode when the shelf already decoded that cover
-- for its own tile (measured: the decode is ~90ms on a PW5, and it is the
-- whole cold half of a preview tap's hero build).
--
-- Relationship to ScaledCoverCache: deliberately separate. The shared cache
-- keys one canonical bb per book and prefers larger, so feeding hero-size
-- copies into it for every shelf decode would inflate the canonical for the
-- whole library -- 4x the disk hydrate I/O on cold page turns and a
-- downscale on every warm shelf paint that is a 1:1 blit today. This tier
-- holds the hero-size copies OFF to the side, bounded by its own byte
-- budget, and hands each one over exactly once.
--
-- Population: SpineWidget calls noteSource(fp, bb) whenever it holds a
-- freshly decoded source cover for its own scaling -- adding one bb:scale
-- (a few ms) to work that already paid the ~37ms decode. Consumption:
-- SpineWidget's decode fallback calls take(fp, ...) before Repo.getCoverBB;
-- a hit TRANSFERS ownership to the caller (the entry leaves the tier), so
-- the downstream scale-and-free flow needs no special casing. After the
-- handoff the hero's scaled result lands in ScaledCoverCache as before, so
-- repeat previews stay on the shared warm path.
--
-- Lifetime: the tier OWNS its bbs -- nothing else holds a reference until
-- take() transfers one out -- so eviction can genuinely free() instead of
-- waiting on the GC finalizer the shared cache has to rely on.

-- Guarded: suites that load SpineWidget under stubs never provide a logger,
-- and this module must not be the reason they can't load it.
local ok_log, logger = pcall(require, "logger")
if not ok_log or type(logger) ~= "table" then
    local noop = function() end
    logger = { dbg = noop, info = noop, warn = noop, err = noop }
end

local HeroTier = {
    _cache  = {},   -- fp → bb (tier owns until take())
    _sizes  = {},   -- fp → resident bytes
    _order  = {},   -- LRU, oldest first
    _bytes  = 0,
    _budget = 6 * 1024 * 1024,
    -- The hero cover region's height in px, registered by HeroCard on each
    -- build (layout-dependent). nil until the first hero build: noteSource
    -- is a no-op then, which only costs a missed warm.
    target_h = nil,
    -- Session counters for the perf log / bench.
    _hits = 0, _misses = 0, _notes = 0, _evictions = 0,
}

local function _bbBytes(bb)
    local ok, n = pcall(function()
        local stride = tonumber(bb.stride) or (bb.getWidth and bb:getWidth()) or 0
        return stride * (bb.getHeight and bb:getHeight() or 0)
    end)
    return (ok and n and n > 0) and n or 0
end

local function _removeKey(self, fp)
    for i, k in ipairs(self._order) do
        if k == fp then
            table.remove(self._order, i)
            return
        end
    end
end

local function _dropEntry(self, fp, free_it)
    local bb = self._cache[fp]
    if not bb then return end
    self._cache[fp] = nil
    self._bytes = math.max(0, self._bytes - (self._sizes[fp] or 0))
    self._sizes[fp] = nil
    _removeKey(self, fp)
    if free_it and bb.free then pcall(function() bb:free() end) end
end

local function _evictIfNeeded(self)
    while #self._order > 1 and self._bytes > self._budget do
        local fp = self._order[1]
        -- Tier-owned: safe to really free (see the lifetime note above).
        _dropEntry(self, fp, true)
        self._evictions = self._evictions + 1
    end
end

function HeroTier:setBudget(bytes)
    if type(bytes) == "number" and bytes > 0 then
        self._budget = bytes
        _evictIfNeeded(self)
    end
end

-- noteSource(fp, src_bb): the caller holds a freshly decoded full-size
-- source cover. Stash a hero-height scaled COPY (aspect preserved) unless
-- one is already here or the target height isn't known yet. Never takes
-- ownership of src_bb; never raises (a failed scale only costs the warm).
function HeroTier:noteSource(fp, src_bb)
    if type(fp) ~= "string" or fp == "" or not src_bb then return end
    local th = self.target_h
    if not th or th <= 0 then return end
    if self._cache[fp] then return end
    local ok = pcall(function()
        local sh = src_bb:getHeight()
        local sw = src_bb:getWidth()
        if sh < 1 or sw < 1 then return end
        -- No minimum-size floor: a small embedded cover upscales at preview
        -- time EITHER way -- the hero's own path would scale these same
        -- source pixels to the same box -- so a short copy is quality-
        -- identical to a fresh decode and still saves the decode.
        local h = math.min(sh, th)
        local w = math.max(1, math.floor(sw * h / sh + 0.5))
        local copy = src_bb:scale(w, h)
        if not copy then return end
        self._cache[fp] = copy
        self._sizes[fp] = _bbBytes(copy)
        self._bytes = self._bytes + self._sizes[fp]
        self._order[#self._order + 1] = fp
        self._notes = self._notes + 1
        _evictIfNeeded(self)
    end)
    if not ok then
        -- Entry state is only mutated after a successful scale, so a
        -- failure here left nothing to clean up.
        logger.dbg("[bookshelf] hero tier noteSource failed for", fp)
    end
end

-- take(fp): remove and return the tier's bb for fp. No size gate: whatever
-- height was stashed, it was scaled from the same source pixels the caller
-- would otherwise re-decode, so the caller's own scale (either direction)
-- produces the identical image minus the decode. OWNERSHIP TRANSFERS to
-- the caller: free it or hand it to a disposable ImageWidget. nil on miss.
function HeroTier:take(fp)
    if type(fp) ~= "string" or fp == "" then return nil end
    local bb = self._cache[fp]
    if not bb then
        self._misses = self._misses + 1
        return nil
    end
    _dropEntry(self, fp, false)   -- transfer, don't free
    self._hits = self._hits + 1
    return bb
end

-- drop(fp): the book's cover changed (custom cover, re-extraction) -- a
-- stashed copy would resurrect the old art. Mirrors the shared cache's
-- invalidation hooks; call alongside them.
function HeroTier:drop(fp)
    _dropEntry(self, fp, true)
end

function HeroTier:clear()
    for fp in pairs(self._cache) do
        _dropEntry(self, fp, true)
    end
end

return HeroTier
