-- tests/_test_stale_sweep.lua
-- Verifies bookshelf_stale_sweep purges rows where on-disk file
-- size/mtime no longer matches BIM's cached values, and only those rows.
-- Usage: cd into the plugin dir, then `lua tests/_test_stale_sweep.lua`.

package.path = "./?.lua;./?/init.lua;" .. package.path

-- ---------- Stub KOReader modules ----------
package.loaded["logger"] = {
    info = function() end, warn = function() end, dbg = function() end,
}
package.loaded["datastorage"] = {
    getSettingsDir = function() return "/tmp/_test_sweep_settings" end,
}
-- lfs stub backed by a table the tests mutate. mode="file" by default
-- for any entry; entries absent from the table simulate "file gone".
_G._test_files = {}
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(path, key)
        if key == "mode" then
            -- For the db_path itself we return "file" so _openBimDb proceeds.
            if path == "/tmp/_test_sweep_settings/bookinfo_cache.sqlite3" then
                return "file"
            end
            return _G._test_files[path] and "file" or nil
        end
        local f = _G._test_files[path]
        if not f then return nil end
        return { mode = "file", size = f.size, modification = f.mtime }
    end,
}
-- ljsqlite3 stub: open returns a fake connection whose rows() iterator
-- walks a table set by the test.
_G._test_db_rows = {}
-- ljsqlite3 stub: open returns a fake connection whose prepare() returns
-- a fake statement whose rows() iterator walks _test_db_rows. Mirrors
-- ljsqlite3's actual API where rows() lives on the statement, not the
-- connection.
-- A paged statement ("... rowid > ? ... LIMIT n") is honoured: the rows
-- after the bound rowid (a row's rowid is its index), n at most, rowid
-- first. _G._test_on_row runs for every row read (a test's read cost).
_G._test_rows_read = 0
package.loaded["lua-ljsqlite3/init"] = {
    open = function(_path)
        return {
            prepare = function(_self, sql)
                local paged = sql:find("rowid > ?", 1, true) ~= nil
                local limit = tonumber(sql:match("LIMIT (%d+)")) or math.huge
                local with_id = sql:find("^SELECT rowid") ~= nil
                local after = 0
                return {
                    bind = function(_s, v) after = v end,
                    reset = function() end,
                    rows = function(_self2)
                        local i, n = paged and after or 0, 0
                        return function()
                            i = i + 1
                            local r = _G._test_db_rows[i]
                            if not r or n >= limit then return nil end
                            n = n + 1
                            _G._test_rows_read = _G._test_rows_read + 1
                            if _G._test_on_row then _G._test_on_row() end
                            if with_id then return { i, r.directory, r.filename, r.filemtime, r.filesize } end
                            return { r.directory, r.filename, r.filemtime, r.filesize }
                        end
                    end,
                    close = function() end,
                }
            end,
            close = function() end,
        }
    end,
}
-- BIM stub records deletes + exec calls (so we can verify BEGIN/COMMIT
-- are issued around the delete loop). openDbConnection is a no-op; the
-- sweep just needs BIM.db_conn to exist for the transaction wrap.
_G._test_bim_deleted = {}
_G._test_bim_execs = {}
_G._test_bim_extracted = {}   -- list of file-lists passed to extractInBackground
local _bim_stub
_bim_stub = {
    db_conn = {
        exec = function(_self, sql)
            _G._test_bim_execs[#_G._test_bim_execs + 1] = sql
        end,
    },
    openDbConnection = function(_self) end,
    deleteBookInfo = function(_self, fp)
        _G._test_bim_deleted[#_G._test_bim_deleted + 1] = fp
    end,
    extractInBackground = function(_self, files)
        _G._test_bim_extracted[#_G._test_bim_extracted + 1] = files
    end,
}
package.loaded["bookinfomanager"] = _bim_stub
-- ScaledCoverCache stub records which paths got dropped.
_G._test_scc_dropped = {}
package.loaded["lib/bookshelf_scaled_cover_cache"] = {
    drop = function(_self, fp)
        _G._test_scc_dropped[#_G._test_scc_dropped + 1] = fp
    end,
}

-- ---------- Helpers ----------
local function reset()
    _G._test_files = {}
    _G._test_db_rows = {}
    _G._test_bim_deleted = {}
    _G._test_bim_execs = {}
    _G._test_bim_extracted = {}
    _G._test_scc_dropped = {}
    -- Re-require so module-level _ran flag resets between tests.
    package.loaded["lib/bookshelf_stale_sweep"] = nil
end

local function assertEq(a, b, msg)
    if a ~= b then
        error(string.format("FAIL %s: expected %s, got %s",
            msg or "", tostring(b), tostring(a)), 2)
    end
end

-- ---------- Tests ----------

local function test_fresh_rows_left_alone()
    reset()
    _G._test_db_rows = {
        { directory = "/books/", filename = "a.epub", filemtime = 100, filesize = 1000 },
        { directory = "/books/", filename = "b.epub", filemtime = 200, filesize = 2000 },
    }
    _G._test_files = {
        ["/books/a.epub"] = { size = 1000, mtime = 100 },
        ["/books/b.epub"] = { size = 2000, mtime = 200 },
    }
    local Sweep = require("lib/bookshelf_stale_sweep")
    local stats = Sweep:run()
    assertEq(stats.scanned, 2, "scanned count")
    assertEq(stats.stale, 0, "stale count")
    assertEq(#_G._test_bim_deleted, 0, "no BIM deletes")
    assertEq(#_G._test_scc_dropped, 0, "no SCC drops")
end

local function test_size_mismatch_purges()
    reset()
    _G._test_db_rows = {
        { directory = "/books/", filename = "a.epub", filemtime = 100, filesize = 1000 },
    }
    _G._test_files = {
        ["/books/a.epub"] = { size = 9999, mtime = 100 },  -- size changed, mtime preserved
    }
    local Sweep = require("lib/bookshelf_stale_sweep")
    local stats = Sweep:run()
    assertEq(stats.stale, 1, "one stale row")
    assertEq(_G._test_bim_deleted[1], "/books/a.epub", "BIM delete fired")
    assertEq(_G._test_scc_dropped[1], "/books/a.epub", "SCC drop fired")
end

local function test_mtime_only_mismatch_left_alone()
    -- Regression guard for issue #103: an mtime change WITHOUT a size
    -- change must NOT mark a row stale. Sync/enricher mtime drift was
    -- purging good rows and triggering a re-extraction storm that locked
    -- bookinfo_cache and stalled the hero.
    reset()
    _G._test_db_rows = {
        { directory = "/books/", filename = "a.epub", filemtime = 100, filesize = 1000 },
    }
    _G._test_files = {
        ["/books/a.epub"] = { size = 1000, mtime = 999 },  -- mtime drifted, size unchanged
    }
    local Sweep = require("lib/bookshelf_stale_sweep")
    local stats = Sweep:run()
    assertEq(stats.stale, 0, "mtime-only drift is not stale")
    assertEq(#_G._test_bim_deleted, 0, "no purge on mtime-only drift")
    assertEq(#_G._test_bim_extracted, 0, "no re-extraction on mtime-only drift")
end

local function test_missing_file_not_purged()
    reset()
    _G._test_db_rows = {
        { directory = "/books/", filename = "gone.epub", filemtime = 100, filesize = 1000 },
    }
    _G._test_files = {}   -- file gone
    local Sweep = require("lib/bookshelf_stale_sweep")
    local stats = Sweep:run()
    assertEq(stats.missing, 1, "missing count")
    assertEq(stats.stale, 0, "no stale (don't purge missing)")
    assertEq(#_G._test_bim_deleted, 0, "no BIM delete for missing file")
end

local function test_once_per_session_guard()
    reset()
    _G._test_db_rows = {
        { directory = "/books/", filename = "a.epub", filemtime = 100, filesize = 1000 },
    }
    _G._test_files = { ["/books/a.epub"] = { size = 9999, mtime = 100 } }
    local Sweep = require("lib/bookshelf_stale_sweep")
    local first  = Sweep:run()
    local second = Sweep:run()
    assertEq(first.stale, 1, "first run purges")
    assertEq(second.skipped, true, "second run skipped")
    assertEq(#_G._test_bim_deleted, 1, "only one purge total")
end

local function test_force_bypasses_guard()
    reset()
    _G._test_db_rows = {
        { directory = "/books/", filename = "a.epub", filemtime = 100, filesize = 1000 },
    }
    _G._test_files = { ["/books/a.epub"] = { size = 9999, mtime = 100 } }
    local Sweep = require("lib/bookshelf_stale_sweep")
    Sweep:run()
    local second = Sweep:run({ force = true })
    assertEq(second.stale, 1, "force re-runs")
end

local function test_mixed_fresh_and_stale_only_purges_stale()
    reset()
    _G._test_db_rows = {
        { directory = "/books/", filename = "fresh.epub", filemtime = 100, filesize = 1000 },
        { directory = "/books/", filename = "stale.epub", filemtime = 200, filesize = 2000 },
        { directory = "/books/", filename = "gone.epub",  filemtime = 300, filesize = 3000 },
    }
    _G._test_files = {
        ["/books/fresh.epub"] = { size = 1000, mtime = 100 },
        ["/books/stale.epub"] = { size = 8888, mtime = 200 },
    }
    local Sweep = require("lib/bookshelf_stale_sweep")
    local stats = Sweep:run()
    assertEq(stats.scanned, 3, "scanned all rows")
    assertEq(stats.stale, 1, "purged one")
    assertEq(stats.missing, 1, "noted one missing")
    assertEq(_G._test_bim_deleted[1], "/books/stale.epub", "purged the right one")
end

local function test_deletes_wrapped_in_transaction()
    reset()
    _G._test_db_rows = {
        { directory = "/books/", filename = "a.epub", filemtime = 100, filesize = 1000 },
        { directory = "/books/", filename = "b.epub", filemtime = 200, filesize = 2000 },
    }
    _G._test_files = {
        ["/books/a.epub"] = { size = 1, mtime = 1 },   -- stale
        ["/books/b.epub"] = { size = 2, mtime = 2 },   -- stale
    }
    local Sweep = require("lib/bookshelf_stale_sweep")
    Sweep:run()
    -- BEGIN must come before any delete, COMMIT after the last one.
    assertEq(_G._test_bim_execs[1], "BEGIN;", "first exec is BEGIN")
    assertEq(_G._test_bim_execs[#_G._test_bim_execs], "COMMIT;", "last exec is COMMIT")
    assertEq(#_G._test_bim_deleted, 2, "both deletes ran inside the transaction")
end

local function test_select_failure_allows_retry()
    reset()
    -- Force the SELECT to throw by stubbing prepare() to nil. Sweep
    -- should log the warning, NOT set the once-per-session guard, and
    -- a follow-up run with the stub restored should proceed normally.
    local saved_open = package.loaded["lua-ljsqlite3/init"].open
    package.loaded["lua-ljsqlite3/init"].open = function()
        return { prepare = function() error("boom") end, close = function() end }
    end
    local Sweep = require("lib/bookshelf_stale_sweep")
    local first = Sweep:run()
    assertEq(first.scanned, 0, "no rows scanned on failure")
    -- Restore the working stub and re-run. Without the fix this is
    -- skipped because _ran was prematurely set; with the fix it
    -- proceeds.
    package.loaded["lua-ljsqlite3/init"].open = saved_open
    _G._test_db_rows = {
        { directory = "/books/", filename = "a.epub", filemtime = 100, filesize = 1000 },
    }
    _G._test_files = { ["/books/a.epub"] = { size = 1, mtime = 1 } }
    local second = Sweep:run()
    assertEq(second.skipped, nil, "retry not skipped after prior failure")
    assertEq(second.stale, 1, "retry actually processes the stale row")
end

local function test_purged_books_queued_for_reextraction()
    reset()
    _G._test_db_rows = {
        { directory = "/books/", filename = "a.epub", filemtime = 100, filesize = 1000 },
        { directory = "/books/", filename = "b.epub", filemtime = 200, filesize = 2000 },
    }
    _G._test_files = {
        ["/books/a.epub"] = { size = 1, mtime = 1 },   -- stale
        ["/books/b.epub"] = { size = 2, mtime = 2 },   -- stale
    }
    local Sweep = require("lib/bookshelf_stale_sweep")
    Sweep:run()
    -- After purging, the sweep must queue the purged paths for background
    -- re-extraction so they don't drop out of series/grouping views.
    assertEq(#_G._test_bim_extracted, 1, "extractInBackground called once")
    local files = _G._test_bim_extracted[1]
    assertEq(#files, 2, "both purged paths queued")
    -- Text-only: no cover_specs (covers re-extract lazily on view)
    assertEq(files[1].cover_specs, nil, "text-only extraction (no cover_specs)")
    local paths = { files[1].filepath, files[2].filepath }
    table.sort(paths)
    assertEq(paths[1], "/books/a.epub", "queued path a")
    assertEq(paths[2], "/books/b.epub", "queued path b")
end

local function test_no_extraction_when_nothing_purged()
    reset()
    _G._test_db_rows = {
        { directory = "/books/", filename = "a.epub", filemtime = 100, filesize = 1000 },
    }
    _G._test_files = { ["/books/a.epub"] = { size = 1000, mtime = 100 } }  -- fresh
    local Sweep = require("lib/bookshelf_stale_sweep")
    Sweep:run()
    assertEq(#_G._test_bim_extracted, 0, "no extraction fired when nothing stale")
end


-- A big library on slow storage (discussion 590: 5,900 books, a stat at up
-- to ~13 ms): the sweep runs in slices of a few milliseconds, the first one
-- off the startup path, and still checks every row.
local function test_big_library_sliced_by_time()
    reset()
    local clock, queue = 0, {}
    local real_lfs = package.loaded["libs/libkoreader-lfs"]
    local attrs = real_lfs.attributes
    package.loaded["libs/libkoreader-lfs"] = {
        attributes = function(...) clock = clock + 0.013; return attrs(...) end,
    }
    package.loaded["lib/bookshelf_gettime"] = function() return clock end
    package.loaded["ui/uimanager"] = { scheduleIn = function(_s, _d, fn) queue[#queue + 1] = fn end }
    -- Reading a row cold: ~1.3 ms on a PW5 (each row's record holds its
    -- cover, so 2,071 rows read 2.7 s from flash in one SELECT).
    _G._test_rows_read = 0
    _G._test_on_row = function() clock = clock + 0.0013 end
    for i = 1, 300 do
        _G._test_db_rows[i] = { directory = "/books/", filename = i .. ".epub", filemtime = 1, filesize = 10 }
        _G._test_files["/books/" .. i .. ".epub"] = { size = (i == 250) and 11 or 10, mtime = 1 }
    end
    local ok, err = pcall(function()
        local Sweep = require("lib/bookshelf_stale_sweep")
        local stats = Sweep:run()
        assertEq(stats.scanned, 0, "rows checked inline, before the first scheduled slice")
        assertEq(_G._test_rows_read, 0, "the rows were read inline, before the first slice")
        local slices, longest = 0, 0
        while #queue > 0 do
            local fn = table.remove(queue, 1)
            local before, c0 = stats.scanned, clock
            fn()
            slices = slices + 1
            if clock - c0 > longest then longest = clock - c0 end
            -- Only the last may find nothing left (reading on from a slice
            -- that stopped on the final row).
            assert(stats.scanned > before or #queue == 0, "a slice checked nothing")
        end
        assertEq(stats.scanned, 300, "every row checked")
        assertEq(stats.stale, 1, "the changed book found")
        assert(longest <= 0.04, "a slice held the shelf for " .. longest .. " s")
        assert(slices >= 100, "rows were checked in big batches")
    end)
    package.loaded["libs/libkoreader-lfs"] = real_lfs
    package.loaded["lib/bookshelf_gettime"] = nil
    package.loaded["ui/uimanager"] = nil
    _G._test_on_row = nil
    if not ok then error(err, 0) end
end

-- ---------- Runner ----------
local tests = {
    { "fresh rows left alone",                     test_fresh_rows_left_alone },
    { "size mismatch purges",                      test_size_mismatch_purges },
    { "mtime-only drift left alone (#103)",        test_mtime_only_mismatch_left_alone },
    { "missing file not purged",                   test_missing_file_not_purged },
    { "once-per-session guard",                    test_once_per_session_guard },
    { "force bypasses guard",                      test_force_bypasses_guard },
    { "mixed: only purges stale",                  test_mixed_fresh_and_stale_only_purges_stale },
    { "deletes wrapped in transaction",            test_deletes_wrapped_in_transaction },
    { "SELECT failure allows retry",               test_select_failure_allows_retry },
    { "purged books queued for re-extraction",     test_purged_books_queued_for_reextraction },
    { "no extraction when nothing purged",         test_no_extraction_when_nothing_purged },
    { "a big library is checked in short slices",  test_big_library_sliced_by_time },
}

local failed = 0
for _i, t in ipairs(tests) do
    local ok, err = pcall(t[2])
    if ok then
        print(string.format("  PASS  %s", t[1]))
    else
        print(string.format("  FAIL  %s\n         %s", t[1], err))
        failed = failed + 1
    end
end
print(string.format("\n%d/%d passed", #tests - failed, #tests))
os.exit(failed == 0 and 0 or 1)
