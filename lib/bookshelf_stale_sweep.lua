-- bookshelf_stale_sweep.lua
-- One-shot scan of CoverBrowser's bookinfo_cache for rows whose on-disk
-- file no longer matches the cached (filesize, filemtime). Reasons a
-- mismatch shows up:
--   * Syncthing pushed a replacement EPUB after enricher rewrote it
--   * User overwrote a file on the laptop and re-synced
--   * Calibre re-exported a book at a new path-collision-prone name
-- BIM has NO automatic invalidation -- once a row is written, the cover
-- bytes + metadata it holds are frozen until something explicitly deletes
-- the row. This sweep is that "something" for the cross-device sync case.
--
-- Stale criterion: SIZE mismatch only. Size catches enricher rewrites
-- (see ebook-enricher epub_meta.write_meta, which os.utime's mtime back
-- to the original to keep Recently-Added ordering stable) and plain edits
-- alike -- both change the byte count. We do NOT compare mtime: on
-- sync-heavy devices it drifts without the content changing and produces
-- false-positive purges that trigger a re-extraction storm contending for
-- the bookinfo_cache lock (issue #103). See the size-only check below.
--
-- For each stale row we run the SAME purge as the user-initiated Refresh
-- metadata path: BIM:deleteBookInfo (drops the persistent row) plus
-- ScaledCoverCache:drop (kicks the in-memory copy that would otherwise
-- shadow the freshly re-extracted bytes). The next shelf render of the
-- book finds getBookInfo() returning nil and the existing
-- _kickOffMissingMetaExtraction path takes over -- text-only for off-
-- screen books, full cover_specs for visible ones.
--
-- Cost on a 200-book library: one SQLite SELECT (~5ms) + 200 lfs.attributes
-- calls (~50ms total). Well under a second on a Kindle. The actual
-- re-extraction is throttled by the existing visible-first kickoff and
-- doesn't add to startup latency.

local logger      = require("logger")
local DataStorage = require("datastorage")
local lfs         = require("libs/libkoreader-lfs")

local _gettime
do
    local ok, s = pcall(require, "socket")
    _gettime = (ok and s and type(s.gettime) == "function")
        and function() return s.gettime() end
        or  os.clock
end

local StaleSweep = {}

-- Module-level "already ran this process" flag. Bookshelf:init fires
-- twice per KOReader session (once in FM, once in Reader); we only want
-- to sweep once. The flag survives both inits because the module table
-- is package.loaded'd across requires.
StaleSweep._ran = false

local function _openBimDb()
    local db_path = DataStorage:getSettingsDir() .. "/bookinfo_cache.sqlite3"
    if not lfs.attributes(db_path, "mode") then
        return nil   -- no cache yet (first run / CoverBrowser disabled)
    end
    local ok, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok then return nil end
    local ok2, conn = pcall(SQ3.open, db_path)
    if not ok2 then return nil end
    return conn
end

-- run(opts) -- opts.force=true to bypass the once-per-session guard.
-- Returns a small stats table for logging/tests:
--   { scanned=N, stale=N, missing=N }   (missing = row exists but file gone)
function StaleSweep:run(opts)
    opts = opts or {}
    if self._ran and not opts.force then
        return { scanned = 0, stale = 0, missing = 0, skipped = true }
    end
    -- self._ran is set at the SUCCESS path (after the SELECT completes),
    -- not at entry. If we error out on require/open/SELECT, the next
    -- init in the same KOReader session can retry. Catches the first-
    -- deploy race where the sweep module loads before BIM has finished
    -- its own startup.

    local t0 = _gettime()
    local stats = { scanned = 0, stale = 0, missing = 0 }

    local ok_bim, BIM = pcall(require, "bookinfomanager")
    if not (ok_bim and BIM and BIM.deleteBookInfo) then
        logger.dbg("[bookshelf stale-sweep] BIM unavailable, skipping")
        return stats
    end

    local db = _openBimDb()
    if not db then
        logger.dbg("[bookshelf stale-sweep] no bookinfo_cache.sqlite3 yet")
        return stats
    end

    -- Collect everything first, then close the connection BEFORE we call
    -- back into BIM (which opens its OWN connection). SQLite on Kindle
    -- doesn't always tolerate two writers to the same WAL file at once,
    -- and we want BIM's row deletes to commit cleanly.
    -- ljsqlite3: :rows() lives on the statement, not the connection.
    -- Connection has :exec / :rowexec / :prepare; statement-iteration
    -- requires a prepared :step() loop or a :rows() coroutine on the stmt.
    local rows = {}
    local ok_select, select_err = pcall(function()
        local stmt = db:prepare("SELECT directory, filename, filemtime, filesize FROM bookinfo WHERE in_progress = 0;")
        for r in stmt:rows() do
            rows[#rows + 1] = {
                directory = r[1],
                filename  = r[2],
                filemtime = tonumber(r[3]) or 0,
                filesize  = tonumber(r[4]) or 0,
            }
        end
        stmt:close()
    end)
    pcall(function() db:close() end)
    if not ok_select then
        logger.warn("[bookshelf stale-sweep] SELECT failed; skipping:", tostring(select_err))
        return stats
    end
    -- Scan succeeded; we've done useful work. Set the once-per-session
    -- guard now so a transient delete error below doesn't make us
    -- re-scan 200 rows every init for the rest of the session, while
    -- still allowing retry if the setup steps above failed.
    self._ran = true

    local stale_paths = {}
    -- Scan one row: an lfs.attributes stat + size compare. Split out so the
    -- chunked path below can drive it across event-loop ticks.
    local function scanRow(r)
        stats.scanned = stats.scanned + 1
        local fp   = r.directory .. r.filename
        local attr = lfs.attributes(fp)
        if not attr then
            stats.missing = stats.missing + 1
            -- File gone. Leave the row -- next shelf render won't surface
            -- it (the path isn't in the visible book list) and a future
            -- pass could pick it up if the user wants. Aggressive cleanup
            -- here risks deleting rows for files on temporarily-unmounted
            -- removable media.
        elseif attr.mode == "file" then
            -- Staleness = SIZE mismatch only. We deliberately do NOT compare
            -- mtime: on sync-heavy devices (Syncthing, Calibre re-export,
            -- the ebook-enricher) the file's mtime drifts away from the
            -- value BIM stored at extraction time without the *content*
            -- changing -- Syncthing propagates a host mtime, the enricher
            -- os.utime's mtime around, etc. Comparing mtime then flags
            -- perfectly-good rows as stale and purges them, which kicks off
            -- a background re-extraction storm that locks bookinfo_cache
            -- (non-WAL on Kobo -> 5s busy_timeout) and stalls the foreground
            -- hero/shelf reads for seconds at a time (issue #103: a sweep
            -- purged 11 of 21 rows in one pass). Size alone reliably catches
            -- real content changes -- an edit or enricher rewrite changes
            -- the byte count -- and a same-size content change is vanishingly
            -- rare. The one regression vs. the old test (a same-size in-place
            -- edit no longer auto-detected) is acceptable against the churn
            -- the mtime check caused.
            if attr.size ~= r.filesize then
                stale_paths[#stale_paths + 1] = fp
            end
        end
    end

    local function finishSweep()
        if #stale_paths == 0 then
            logger.dbg(string.format(
                "[bookshelf stale-sweep] scanned=%d stale=0 missing=%d in %.0fms",
                stats.scanned, stats.missing, (_gettime() - t0) * 1000))
            return stats
        end

        -- Purge stale entries via the same two-layer drop that Refresh
        -- metadata performs (commit f804285). BIM:deleteBookInfo drops the
        -- persistent row; ScaledCoverCache:drop drops the in-memory scaled
        -- bb. Together they ensure the next render misses both caches and
        -- triggers the existing kickoff extraction.
        --
        -- Wrap the loop in a transaction on BIM's own connection. Without
        -- this, each BIM:deleteBookInfo runs in autocommit mode -- one
        -- fsync per row on the Kindle's eMMC (~20ms each). Batching 114
        -- stale rows into a single COMMIT drops 2.3s to ~200ms.
        --
        -- BIM:openDbConnection() is idempotent (no-op if already open) and
        -- the first deleteBookInfo call below would call it anyway. We
        -- explicitly call it here so the BEGIN below has a connection to
        -- talk to. The pcall on BEGIN means a failure (mode incompatible,
        -- connection state issue) silently degrades to per-row autocommit
        -- -- correct but slow, never wrong.
        local ScaledCoverCache = require("lib/bookshelf_scaled_cover_cache")
        pcall(function() BIM:openDbConnection() end)
        local in_tx = false
        if BIM.db_conn then
            in_tx = pcall(function() BIM.db_conn:exec("BEGIN;") end)
        end
        for _i, fp in ipairs(stale_paths) do
            pcall(function() BIM:deleteBookInfo(fp) end)
            pcall(function() ScaledCoverCache:drop(fp) end)
            stats.stale = stats.stale + 1
        end
        if in_tx then
            pcall(function() BIM.db_conn:exec("COMMIT;") end)
        end

        -- Re-populate. Purging a row removes the book from every
        -- metadata-driven view (series stacks, grouping) until something
        -- re-extracts it. Relying on the lazy on-view kickoff means a purged
        -- book silently drops out of its series until the user happens to
        -- scroll past it -- a worse failure than a momentarily-stale cover.
        -- So fire a single background, TEXT-ONLY re-extraction for the
        -- purged paths (no cover_specs -> ~10x faster than full extraction;
        -- covers re-extract lazily on view via the existing kickoff, which
        -- is the sweep's original purpose). Best-effort: if BIM lacks the
        -- API, or a later folder-open terminates the job, the affected
        -- books fall back to lazy on-view extraction -- never worse than
        -- before this change.
        if #stale_paths > 0 and BIM.extractInBackground then
            local files = {}
            for _i, fp in ipairs(stale_paths) do
                files[#files + 1] = { filepath = fp }  -- text-only, no cover_specs
            end
            pcall(function() BIM:extractInBackground(files) end)
        end

        logger.info(string.format(
            "[bookshelf stale-sweep] purged %d stale (scanned=%d, missing=%d) in %.0fms",
            stats.stale, stats.scanned, stats.missing, (_gettime() - t0) * 1000))
        return stats
    end -- finishSweep

    -- The stat pass is one lfs.attributes per row. On fast flash that's
    -- ~0.5ms/row, but on slow media (Android SD card, issue 262 suspicion)
    -- a single synchronous pass over a big library can block the UI loop
    -- for many seconds right in the middle of startup. When a scheduler is
    -- available and the library is big, slice the scan across event-loop
    -- ticks; small libraries and the standalone test runner (no UIManager)
    -- keep the synchronous path and its return-value contract.
    local CHUNK_SIZE    = 100
    local CHUNK_DELAY_S = 0.05
    local ok_um, UIManager = pcall(require, "ui/uimanager")
    if ok_um and UIManager and UIManager.scheduleIn and #rows > CHUNK_SIZE then
        local idx = 1
        local function step()
            local last = math.min(idx + CHUNK_SIZE - 1, #rows)
            for i = idx, last do
                scanRow(rows[i])
            end
            idx = last + 1
            if idx <= #rows then
                UIManager:scheduleIn(CHUNK_DELAY_S, step)
            else
                finishSweep()
            end
        end
        step() -- first chunk inline; the rest ride the scheduler
        stats.async = true
        return stats -- partial by design; device callers ignore the return
    end

    for _i, r in ipairs(rows) do
        scanRow(r)
    end
    return finishSweep()
end

return StaleSweep
