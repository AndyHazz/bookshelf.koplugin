-- tests/_test_opds_covers.lua
-- Disk cache for OPDS feed thumbnails (lib/bookshelf_opds_covers). Pure-Lua:
-- stubs datastorage, lib/bookshelf_cover_fetch and libs/libkoreader-lfs so
-- cachePath/fetchMissing run unchanged; cachedCoverBB is only checked for its
-- nil-when-absent path since ui/renderimage doesn't exist under this harness.
package.path = "./?.lua;./?/init.lua;" .. package.path

package.loaded["datastorage"] = {
    getSettingsDir = function() return "/tmp/opds_covers_test_settings" end,
}

-- lfs stub backed by a set of "existing" paths the test (and the download
-- stub below) populate. attributes(path) with no key returns a table when
-- the path is present, nil otherwise -- matching how the sketch calls it.
_G._test_files = {}
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(path, key)
        if not _G._test_files[path] then return nil end
        if key == "mode" then return "file" end
        return { mode = "file" }
    end,
}

-- CoverFetch stub: records every call, "writes" the dest into the lfs stub's
-- visible set on success, and fails deterministically for one known URL so
-- fetchMissing's skip-fail semantics can be exercised.
local FAIL_URL = "http://example.com/covers/fail.jpg"
local download_calls = {}
package.loaded["lib/bookshelf_cover_fetch"] = {
    download = function(url, dest_path)
        download_calls[#download_calls + 1] = { url = url, dest = dest_path }
        if url == FAIL_URL then return nil, "download failed (boom)" end
        _G._test_files[dest_path] = true
        return dest_path
    end,
}

local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()
local eq = helpers.eq

local OpdsCovers = dofile("lib/bookshelf_opds_covers.lua")
local OpdsSource = require("lib/bookshelf_opds_source")

local CACHE_ROOT = "/tmp/opds_covers_test_settings/bookshelf_covers/opds"

local rec_ok = {
    filepath = "OPDS://abcd1234/book-1",
    opds = { thumbnail_url = "http://example.com/covers/1.jpg" },
}

-- ---------- cachePath ----------

t.test("cachePath is shaped <cacheDir>/<server>/<hash(thumbnail_url)>.img", function()
    local expected = CACHE_ROOT .. "/abcd1234/"
        .. OpdsSource.serverKey("http://example.com/covers/1.jpg") .. ".img"
    eq(OpdsCovers.cachePath(rec_ok), expected)
end)

t.test("cachePath is stable across repeated calls", function()
    local p1 = OpdsCovers.cachePath(rec_ok)
    local p2 = OpdsCovers.cachePath(rec_ok)
    eq(p1, p2)
end)

t.test("cachePath differs for a different thumbnail URL (hash segment)", function()
    local other = {
        filepath = "OPDS://abcd1234/book-2",
        opds = { thumbnail_url = "http://example.com/covers/2.jpg" },
    }
    assert(OpdsCovers.cachePath(rec_ok) ~= OpdsCovers.cachePath(other),
        "distinct thumbnail URLs must not collide")
end)

t.test("cachePath nil when the record has no thumbnail_url", function()
    eq(OpdsCovers.cachePath({ filepath = "OPDS://abcd1234/x", opds = {} }), nil)
    eq(OpdsCovers.cachePath({ filepath = "OPDS://abcd1234/x" }), nil)
    eq(OpdsCovers.cachePath(nil), nil)
end)

t.test("cachePath falls back to 'unknown' server segment for an unrecognised filepath", function()
    local rec = { filepath = "not-an-opds-filepath", opds = { thumbnail_url = "http://x/y.jpg" } }
    local path = OpdsCovers.cachePath(rec)
    assert(path:find("/unknown/", 1, true), "expected an 'unknown' server segment, got " .. tostring(path))
end)

-- ---------- cachedCoverBB ----------

t.test("cachedCoverBB nil when the cache file is absent (no fake render pipeline)", function()
    eq(OpdsCovers.cachedCoverBB(rec_ok), nil)
end)

t.test("cachedCoverBB nil for a record with no thumbnail (no path to check)", function()
    eq(OpdsCovers.cachedCoverBB({ filepath = "OPDS://abcd1234/x" }), nil)
end)

-- ---------- fetchMissing ----------

local rec_cached      = { filepath = "OPDS://srv1/1", opds = { thumbnail_url = "http://example.com/covers/c1.jpg" } }
local rec_missing_a   = { filepath = "OPDS://srv1/2", opds = { thumbnail_url = "http://example.com/covers/m2.jpg" } }
local rec_missing_bad = { filepath = "OPDS://srv1/3", opds = { thumbnail_url = FAIL_URL } }
local rec_missing_b   = { filepath = "OPDS://srv1/4", opds = { thumbnail_url = "http://example.com/covers/m4.jpg" } }
local rec_no_thumb    = { filepath = "OPDS://srv1/5" }

-- Pre-seed rec_cached's cache file as already present, before fetchMissing runs.
_G._test_files[OpdsCovers.cachePath(rec_cached)] = true

t.test("fetchMissing skips cached, downloads each missing URL once, tolerates a failure, counts, calls on_done", function()
    for i = #download_calls, 1, -1 do download_calls[i] = nil end

    local done_count
    OpdsCovers.fetchMissing(
        { rec_cached, rec_missing_a, rec_missing_bad, rec_missing_b, rec_no_thumb },
        function(n) done_count = n end
    )

    eq(#download_calls, 3, "download attempted only for the 3 missing-with-thumbnail records")
    eq(done_count, 2, "on_done receives the count of SUCCESSFUL fetches")

    local by_url = {}
    for _, c in ipairs(download_calls) do by_url[c.url] = c end

    eq(by_url["http://example.com/covers/c1.jpg"], nil, "cached record's URL is never downloaded")
    assert(by_url["http://example.com/covers/m2.jpg"], "missing record before the failure was fetched")
    assert(by_url[FAIL_URL], "the failing URL was attempted")
    assert(by_url["http://example.com/covers/m4.jpg"],
        "a failing download must not abort the remaining records")

    eq(by_url["http://example.com/covers/m2.jpg"].dest, OpdsCovers.cachePath(rec_missing_a),
        "download is called with the record's cachePath as dest")

    -- The successful fetches actually landed in the (stub) cache.
    assert(_G._test_files[OpdsCovers.cachePath(rec_missing_a)], "m2 cache file recorded as present")
    assert(_G._test_files[OpdsCovers.cachePath(rec_missing_b)], "m4 cache file recorded as present")
    eq(_G._test_files[OpdsCovers.cachePath(rec_missing_bad)], nil, "failed fetch leaves no cache file")
end)

t.test("fetchMissing handles a nil records list gracefully", function()
    local done_count
    OpdsCovers.fetchMissing(nil, function(n) done_count = n end)
    eq(done_count, 0)
end)

t.test("fetchMissing tolerates a missing on_done callback", function()
    OpdsCovers.fetchMissing({}, nil)
end)

t.done()
