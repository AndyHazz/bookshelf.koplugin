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
package.loaded["lua-ljsqlite3/init"] = {
    open = function(_path)
        return {
            prepare = function(_self, _sql)
                return {
                    rows = function(_self2)
                        local i = 0
                        return function()
                            i = i + 1
                            local r = _G._test_db_rows[i]
                            if not r then return nil end
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
