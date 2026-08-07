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

-- CoverFetch stub: records every call (including the credentials it was
-- handed), "writes" the dest into the lfs stub's visible set on success, and
-- fails deterministically for one known URL so fetchMissing's skip-fail
-- semantics can be exercised.
local FAIL_URL = "http://example.com/covers/fail.jpg"
local download_calls = {}
package.loaded["lib/bookshelf_cover_fetch"] = {
    download = function(url, dest_path, user, password, opts)
        download_calls[#download_calls + 1] =
            { url = url, dest = dest_path, user = user, password = password,
              opts = opts }
        if url == FAIL_URL then return nil, "download failed (boom)" end
        _G._test_files[dest_path] = true
        return dest_path
    end,
}

-- OpdsSource stub: the REAL serverKey (cachePath hashes thumbnail URLs with
-- it, so the path assertions below must use the real hash), a stubbed
-- getServer standing in for the user's configured catalogue list. "authsrv"
-- carries credentials, "opensrv" is an anonymous server, anything else is
-- unknown - the record's server was deleted from opds.lua, or its filepath
-- doesn't parse.
local RealOpdsSource = dofile("lib/bookshelf_opds_source.lua")
local stub_servers = {
    authsrv = { key = "authsrv", title = "Calibre-Web", url = "http://cw/opds",
                username = "alice", password = "s3cret" },
    opensrv = { key = "opensrv", title = "dir2opds", url = "http://d2o/opds" },
}
local getserver_calls = {}
package.loaded["lib/bookshelf_opds_source"] = {
    serverKey = RealOpdsSource.serverKey,
    getServer = function(key)
        getserver_calls[#getserver_calls + 1] = key
        return stub_servers[key]
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

-- ---------- fetchMissing: credentials ----------
--
-- A password-protected catalogue 401s an unauthenticated thumbnail GET, so
-- covers never appear for it. The credentials the user already gave the stock
-- OPDS plugin have to ride along with the download.

t.test("fetchMissing passes the server's credentials to download", function()
    for i = #download_calls, 1, -1 do download_calls[i] = nil end
    local rec = { filepath = "OPDS://authsrv/1",
                  opds = { thumbnail_url = "http://cw/covers/a1.jpg" } }
    OpdsCovers.fetchMissing({ rec })
    eq(#download_calls, 1, "one download attempted")
    eq(download_calls[1].user, "alice", "download got the server's username")
    eq(download_calls[1].password, "s3cret", "download got the server's password")
end)

t.test("fetchMissing resolves each distinct server once per pass", function()
    for i = #download_calls, 1, -1 do download_calls[i] = nil end
    for i = #getserver_calls, 1, -1 do getserver_calls[i] = nil end
    OpdsCovers.fetchMissing({
        { filepath = "OPDS://authsrv/10", opds = { thumbnail_url = "http://cw/covers/a10.jpg" } },
        { filepath = "OPDS://authsrv/11", opds = { thumbnail_url = "http://cw/covers/a11.jpg" } },
        { filepath = "OPDS://opensrv/12", opds = { thumbnail_url = "http://d2o/covers/o12.jpg" } },
    })
    eq(#download_calls, 3, "all three downloaded")
    eq(#getserver_calls, 2, "getServer consulted once per distinct server key")
    eq(download_calls[2].user, "alice", "the second record of the same server still gets credentials")
    eq(download_calls[3].user, nil, "an anonymous server sends no username")
    eq(download_calls[3].password, nil, "an anonymous server sends no password")
end)

t.test("fetchMissing withholds credentials when the thumbnail is cross-host to the server", function()
    for i = #download_calls, 1, -1 do download_calls[i] = nil end
    -- authsrv's own origin is http://cw/opds; a feed pointing its thumbnail
    -- at a foreign host must not leak the server's credentials there.
    local rec = { filepath = "OPDS://authsrv/1",
                  opds = { thumbnail_url = "http://evil.example/covers/x.jpg" } }
    OpdsCovers.fetchMissing({ rec })
    eq(#download_calls, 1, "download still attempted (anonymously)")
    eq(download_calls[1].user, nil, "cross-host thumbnail: no username")
    eq(download_calls[1].password, nil, "cross-host thumbnail: no password")
end)

t.test("a record from an unknown server still downloads, without credentials", function()
    for i = #download_calls, 1, -1 do download_calls[i] = nil end
    local gone  = { filepath = "OPDS://deletedsrv/1",
                    opds = { thumbnail_url = "http://x/covers/g1.jpg" } }
    local weird = { filepath = "not-an-opds-filepath",
                    opds = { thumbnail_url = "http://x/covers/w1.jpg" } }
    OpdsCovers.fetchMissing({ gone, weird })
    eq(#download_calls, 2, "both still attempted")
    eq(download_calls[1].user, nil, "deleted server: no credentials, no error")
    eq(download_calls[2].user, nil, "unparseable filepath: no credentials, no error")
    assert(_G._test_files[OpdsCovers.cachePath(gone)], "unknown-server cover still landed")
end)

t.test("fetchMissing handles a nil records list gracefully", function()
    local done_count
    OpdsCovers.fetchMissing(nil, function(n) done_count = n end)
    eq(done_count, 0)
end)

t.test("fetchMissing tolerates a missing on_done callback (does not throw)", function()
    OpdsCovers.fetchMissing({}, nil)
end)

-- ---------- fetchMissing: freeze budget ----------
--
-- The pass runs serially on the main loop, so an unresponsive server must not
-- be able to hold the shelf. Two bounds: a tight per-request timeout (well
-- under socketutil's LARGE 10s/30s pair, which CoverFetch defaults to for the
-- cover picker's single user-initiated download), and a whole-batch deadline.

t.test("fetchMissing asks download for a tighter timeout than the LARGE default", function()
    for i = #download_calls, 1, -1 do download_calls[i] = nil end
    OpdsCovers.fetchMissing({
        { filepath = "OPDS://srv1/t1", opds = { thumbnail_url = "http://x/covers/t1.jpg" } },
    })
    eq(#download_calls, 1, "one download attempted")
    local o = download_calls[1].opts
    assert(type(o) == "table", "download was handed a timeout opts table")
    eq(o.block_timeout, OpdsCovers.THUMB_BLOCK_TIMEOUT, "per-request block timeout passed through")
    eq(o.total_timeout, OpdsCovers.THUMB_TOTAL_TIMEOUT, "per-request total timeout passed through")
    assert(o.block_timeout < 10 and o.total_timeout < 30,
        "thumbnail timeouts must be tighter than socketutil's LARGE pair")
end)

t.test("fetchMissing abandons the rest of the batch once the time budget is spent", function()
    for i = #download_calls, 1, -1 do download_calls[i] = nil end
    -- Fake clock: every download "costs" one second of wall time, so the pass
    -- stops after BATCH_BUDGET of them however many records are queued.
    local real_time = os.time
    local fake_now = 1000
    os.time = function() return fake_now end            -- luacheck: ignore
    local real_download = package.loaded["lib/bookshelf_cover_fetch"].download
    package.loaded["lib/bookshelf_cover_fetch"].download = function(...)
        fake_now = fake_now + 1
        return real_download(...)
    end

    local batch = {}
    for i = 1, OpdsCovers.BATCH_BUDGET + 10 do
        batch[i] = { filepath = "OPDS://srv1/b" .. i,
                     opds = { thumbnail_url = "http://x/covers/b" .. i .. ".jpg" } }
    end
    local done_count
    OpdsCovers.fetchMissing(batch, function(n) done_count = n end)

    os.time = real_time                                  -- luacheck: ignore
    package.loaded["lib/bookshelf_cover_fetch"].download = real_download

    eq(#download_calls, OpdsCovers.BATCH_BUDGET,
        "stopped at the budget instead of working through every record")
    eq(done_count, OpdsCovers.BATCH_BUDGET, "on_done still reports what did land")
    assert(#download_calls < #batch, "the tail of the batch was left for the next pass")
end)

t.done()
