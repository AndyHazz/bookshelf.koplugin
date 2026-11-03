-- tests/_test_lightmeta_stale_snapshot.lua
-- The light-meta snapshot is served even when the BIM db has moved on, and a
-- background refresh replaces it -- so the one launch cost we have seen reach
-- 15s (the batch SELECT over a blob-heavy bookinfo table, issue 262) leaves
-- the launch path. Pins: fresh vs stale vs older-format handling, and that the
-- refresh saves fresh rows and drops the derived map, once at a time.
--
-- Bodies are extracted by name; their upvalues become stubbable globals.
-- Run from the plugin root: lua tests/_test_lightmeta_stale_snapshot.lua

package.path = "./?.lua;./?/init.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()
local src = io.open("lib/bookshelf_book_repository.lua"):read("*a")

local function bodyOf(pat, name)
    local body = src:match(pat)
    assert(body, "could not find " .. name)
    return body
end
local function compile(code, env)
    if _G.setfenv then local f = assert(_G.loadstring(code)); _G.setfenv(f, env); return f end
    return assert(load(code, "body", "t", env))
end

local load_body = bodyOf("\nlocal function _loadRowSnapshot%(%)\n(.-)\nend\n", "_loadRowSnapshot")
local sched_body = bodyOf("\nlocal function _scheduleLightMetaRefresh%(%)\n(.-)\nend\n", "_scheduleLightMetaRefresh")

local function loader(stored, live_fp)
    local env = {
        type = type, pcall = pcall, string = string,
        _bimDbFingerprint = function() return live_fp end,
        _lightMetaPersist = function() return { load = function() return stored end } end,
    }
    return compile(load_body, env)
end

t.test("a matching fingerprint is fresh", function()
    local rows = { ["/b/a"] = { title = "A" } }
    local got, fresh = loader({ fingerprint = "v2:100:5", rows = rows }, "v2:100:5")()
    assert(got == rows and fresh == true)
end)

t.test("a moved db fingerprint of the same format is served STALE", function()
    local rows = { ["/b/a"] = { title = "A" } }
    local got, fresh = loader({ fingerprint = "v2:100:5", rows = rows }, "v2:140:9")()
    assert(got == rows, "stale rows must still be handed back")
    assert(fresh == false, "...flagged stale")
end)

t.test("an older snapshot format is never served, stale or not", function()
    -- v1 rows lack pages/description/has_cover: buildBookMeta's fast path
    -- would build records missing fields. nil forces the live batch.
    local got = loader({ fingerprint = "v1:100:5", rows = { x = {} } }, "v2:100:5")()
    assert(got == nil)
end)

t.test("garbage on disk is nil", function()
    assert(loader("not a table", "v2:1:1")() == nil)
    assert(loader({ rows = {} }, "v2:1:1")() == nil, "no fingerprint: nil")
end)

t.test("a write that only reached the -wal file moves the fingerprint", function()
    -- WAL mode leaves the main file untouched until a checkpoint; a
    -- fingerprint of the main file alone called the old snapshot fresh.
    local fp_body = bodyOf("\nlocal function _bimDbFingerprint%(%)\n(.-)\nend\n", "_bimDbFingerprint")
    local files = { ["/s/bookinfo_cache.sqlite3"] = { size = 100, modification = 5 } }
    local lfs = { attributes = function(path, key)
        local a = files[path]; return a and a[key] end }
    local env = {
        pcall = pcall, string = string, LIGHTMETA_SNAPSHOT_VERSION = 2,
        require = function(name)
            if name == "datastorage" then return { getSettingsDir = function() return "/s" end } end
            return lfs
        end,
    }
    local fingerprint = compile(fp_body, env)
    local no_wal = fingerprint()
    assert(no_wal == "v2:100:5", "no -wal file: the old form, got " .. tostring(no_wal))
    files["/s/bookinfo_cache.sqlite3-wal"] = { size = 4096, modification = 6 }
    local a = fingerprint()
    files["/s/bookinfo_cache.sqlite3-wal"].modification = 9
    local b = fingerprint()
    assert(a ~= no_wal and a ~= b, "a -wal write must change the fingerprint")
    assert(a:match("^v2:"), "same format version, so the old snapshot is served stale, not dropped")
end)

t.test("the cache serves stale rows now and schedules the refresh", function()
    local body = bodyOf("\nlocal function _getLightMetaCache%(home, depth%)\n(.-)\nend\n", "_getLightMetaCache")
    assert(body:match("snapshot, fresh = _loadRowSnapshot%(%)"),
        "the loader's fresh flag must be read")
    assert(body:match("if stale then _scheduleLightMetaRefresh%(%) end"),
        "a stale snapshot must schedule the background refresh")
    assert(body:match("stale%-snapshot"), "the perf line should name the stale source")
end)

local function refreshEnv(scheduled, counts, fp)
    return {
        pcall = pcall, pairs = pairs, string = string, type = type,
        require = function(name)
            if name == "ui/uimanager" then
                return { scheduleIn = function(_, _delay, fn) scheduled[#scheduled + 1] = fn end }
            end
            error("unexpected require " .. name)
        end,
        _lightmeta_refresh_pending = false,
        LIGHTMETA_REFRESH_DELAY_S = 2,
        _gettime = function() return 0 end,
        logger = { dbg = function() end },
        _bimDbFingerprint = function() return fp.value end,
        _loadBatchBookInfoFromBim = function()
            counts.batches = counts.batches + 1; return { ["/b/c"] = { title = "C" } } end,
        _saveRowSnapshot = function(rows)
            if counts.save_fails then error("disk full") end
            counts.saved = rows end,
        Repo = {
            invalidateLightMeta = function() counts.light = counts.light + 1 end,
            invalidateSeriesCache = function() counts.groups = counts.groups + 1 end,
        },
    }
end
local read_body = bodyOf("\nfunction LMFresh%.read%(%)\n(.-)\nend\n", "LMFresh.read")
local mem_body = bodyOf("\nfunction LMFresh%.memory%(%)\n(.-)\nend\n", "LMFresh.memory")
local function refresher(env)
    env.LMFresh = env.LMFresh or {}
    env.LMFresh.read = compile(read_body, env)
    return compile(sched_body, env)
end

t.test("the refresh saves fresh rows, drops the map, and runs once at a time", function()
    local scheduled, counts, fp = {}, { batches = 0, light = 0, groups = 0 }, { value = "v2:1:1" }
    local env = refreshEnv(scheduled, counts, fp)
    local run = refresher(env)
    run(); run()   -- second call while pending must not schedule twice
    assert(#scheduled == 1, "one refresh in flight at a time, got " .. #scheduled)
    assert(env._lightmeta_refresh_pending == true)
    scheduled[1]()
    assert(counts.batches == 1, "the live batch ran once")
    assert(counts.saved and counts.saved["/b/c"], "fresh rows were saved as the new snapshot")
    assert(counts.light == 1, "the derived map was dropped so readers reload")
    assert(env._lightmeta_refresh_pending == false, "pending flag cleared")
    assert(env.LMFresh.rows and env.LMFresh.rows["/b/c"],
        "the fresh rows are kept in memory, so the map does not depend on the save")
    assert(env.LMFresh.fp == "v2:1:1", "...with the BIM fingerprint they were read at")
end)

t.test("a refresh drops the shelves grouped from the stale rows (issue 581)", function()
    -- Series / Authors / Genres were built from the stale rows in the two
    -- seconds before the refresh: a book those rows lacked was in no series,
    -- and dropping only the light map left the Series shelf without it.
    local scheduled, counts = {}, { batches = 0, light = 0, groups = 0 }
    local run = refresher(refreshEnv(scheduled, counts, { value = "v2:1:1" }))
    run(); scheduled[1]()
    assert(counts.groups == 1, "the group shelves must be rebuilt from the fresh rows")
end)

t.test("BIM moving again later in the session gets another refresh (issue 581)", function()
    -- A library scan mid-session writes rows for new books. The rows read
    -- at launch were kept for the whole session, so the new books had no
    -- row and no series until KOReader was started again.
    local scheduled, counts, fp = {}, { batches = 0, light = 0, groups = 0 }, { value = "v2:1:1" }
    local env = refreshEnv(scheduled, counts, fp)
    local run = refresher(env)
    run(); scheduled[1]()
    local memory = compile(mem_body, env)
    local rows, fresh = memory()
    assert(rows and fresh == true, "unchanged BIM: the rows in memory are fresh")
    fp.value = "v2:9:9"
    rows, fresh = memory()
    assert(rows and fresh == false, "moved BIM: served, but stale")
    run()
    assert(#scheduled == 2, "a stale session asks for a second refresh")
end)

t.test("a failed save cannot re-arm the refresh loop", function()
    -- The bug class: save fails (read-only dir), the invalidate drops the
    -- map, the next reader loads the still-stale snapshot and schedules
    -- again -- a full table read every two seconds. Memory now wins, and
    -- it stays fresh while BIM does not move.
    local scheduled, counts = {}, { batches = 0, light = 0, groups = 0, save_fails = true }
    local env = refreshEnv(scheduled, counts, { value = "v2:1:1" })
    local run = refresher(env)
    run(); scheduled[1]()
    assert(counts.batches == 1 and env.LMFresh.rows, "the refresh completed despite the failed save")
    local _rows, fresh = compile(mem_body, env)()
    assert(fresh == true, "no second refresh: the fresh rows in memory satisfy the next reader")
end)

t.test("no BIM file: rows in memory count as fresh", function()
    local env = { LMFresh = { rows = { x = {} }, fp = "v2:1:1" },
                  _bimDbFingerprint = function() return nil end }
    local _rows, fresh = compile(mem_body, env)()
    assert(fresh == true, "nothing to compare against must not loop the refresh")
end)

t.test("Scan all library metadata reads the rows again itself (issue 581)", function()
    local main = io.open("main.lua"):read("*a")
    local scan = main:match("function Bookshelf:scanAllMetadata%(%)(.-)\nend\n")
    assert(scan and scan:find("Repo.reloadLightMeta()", 1, true),
        "the scan must not leave the next shelf on rows from before it")
    assert(src:find("\nfunction Repo.reloadLightMeta%(%)\n"), "Repo.reloadLightMeta is missing")
end)

t.test("the cache prefers a completed refresh's rows over the disk snapshot", function()
    local body = bodyOf("\nlocal function _getLightMetaCache%(home, depth%)\n(.-)\nend\n", "_getLightMetaCache")
    assert(body:match("snapshot, fresh = LMFresh%.memory%(%)"), "the cache must consult the in-memory fresh rows first")
end)

t.test("the refresh is declared AFTER the save it calls", function()
    -- The bug that shipped to the rig: _scheduleLightMetaRefresh was inserted
    -- above `local function _saveRowSnapshot`, so inside it the name resolved
    -- to a nil GLOBAL. The save failed silently, the invalidate then dropped
    -- the map, and the stale boot rescheduled itself every two seconds. The
    -- extracted-body tests above cannot see this (they stub the upvalues), so
    -- pin the declaration order in the source itself.
    local save_at    = src:find("\nlocal function _saveRowSnapshot%(rows%)")
    local refresh_at = src:find("\nlocal function _scheduleLightMetaRefresh%(%)")
    local cache_at   = src:find("\nlocal function _getLightMetaCache%(home, depth%)")
    assert(save_at and refresh_at and cache_at, "one of the three functions moved or was renamed")
    assert(save_at < refresh_at, "_saveRowSnapshot must be declared before the refresh that calls it")
    assert(refresh_at < cache_at, "the refresh must be declared before _getLightMetaCache, which calls it")
end)

t.test("with no event loop the stale rows simply stand", function()
    local env = {
        pcall = pcall, type = type,
        require = function() error("no uimanager here") end,
        _lightmeta_refresh_pending = false,
    }
    compile(sched_body, env)()
    assert(env._lightmeta_refresh_pending == false, "nothing scheduled, nothing pending")
end)

t.done()
