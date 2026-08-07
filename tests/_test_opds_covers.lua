-- tests/_test_opds_covers.lua
-- Disk cache for OPDS feed thumbnails (lib/bookshelf_opds_covers). Pure-Lua:
-- stubs datastorage, lib/bookshelf_cover_fetch and libs/libkoreader-lfs so
-- cachePath/cachedPath/fetchMissing run unchanged against the lfs stub's
-- "existing files" set.
package.path = "./?.lua;./?/init.lua;" .. package.path

package.loaded["datastorage"] = {
    getSettingsDir = function() return "/tmp/opds_covers_test_settings" end,
}

-- lfs stub backed by a set of "existing" paths the test (and the download
-- stub below) populate. attributes(path) with no key returns a table when
-- the path is present, nil otherwise -- matching how the sketch calls it.
-- An entry is `true` (a default 1 KB, mtime-0 file) or { size = N, mtime = T }
-- when a test needs the cache sweep to see specific sizes/ages.
_G._test_files = {}
local function _attr(path)
    local e = _G._test_files[path]
    if not e then return nil end
    if type(e) ~= "table" then e = {} end
    return { mode = "file", size = e.size or 1024, modification = e.mtime or 0 }
end
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(path, key)
        local a = _attr(path)
        if not a then return nil end
        if key then return a[key] end
        return a
    end,
    -- Directory listing derived from the file set: immediate children only
    -- (so a <server>/ dir shows up as a name, not as a stat-able entry --
    -- exactly the two-level shape the sweep walks), plus the "." / ".."
    -- entries real lfs yields. Errors for a path with nothing under it, as
    -- lfs.dir does for a missing dir; the sweep's pcall is what handles that.
    dir = function(path)
        local names, seen, prefix = { ".", ".." }, {}, path .. "/"
        for p in pairs(_G._test_files) do
            if p:sub(1, #prefix) == prefix then
                local child = p:sub(#prefix + 1):match("^([^/]+)")
                if child and not seen[child] then
                    seen[child] = true
                    names[#names + 1] = child
                end
            end
        end
        if #names == 2 then error("cannot open " .. tostring(path)) end
        table.sort(names)
        local i = 0
        return function() i = i + 1; return names[i] end
    end,
}
package.loaded["logger"] = { dbg = function() end, info = function() end,
                             warn = function() end, err = function() end }

-- CoverFetch stub: records every call (including the credentials it was
-- handed), "writes" the dest into the lfs stub's visible set on success, and
-- fails deterministically for one known URL so fetchMissing's skip-fail
-- semantics can be exercised.
local FAIL_URL = "http://example.com/covers/fail.jpg"
local download_calls = {}
-- A file that has just been written is the NEWEST thing in the cache; the
-- counter keeps that true relative to any mtime a sweep test seeds, so the
-- cap sweep can't be "passed" by evicting the cover this very pass fetched.
local _dl_mtime = 1000000
package.loaded["lib/bookshelf_cover_fetch"] = {
    download = function(url, dest_path, user, password, opts)
        download_calls[#download_calls + 1] =
            { url = url, dest = dest_path, user = user, password = password,
              opts = opts }
        if url == FAIL_URL then return nil, "download failed (boom)" end
        _dl_mtime = _dl_mtime + 1
        _G._test_files[dest_path] = { size = 1024, mtime = _dl_mtime }
        return dest_path
    end,
}

-- OpdsSource stub: the REAL serverKey (cachePath hashes the selected cover
-- URL with it, so the path assertions below must use the real hash), a stubbed
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

t.test("cachePath is nil, not a match error, when filepath is not a string", function()
    -- credentialsFor already guards its own rec.filepath:match with a type
    -- check; cachePath needs the same guard now that the nav-tile cover
    -- borrow (lib/bookshelf_book_repository.lua) feeds it persisted-window
    -- entries whose shape isn't as tightly controlled as a freshly-mapped one.
    eq(OpdsCovers.cachePath({ filepath = nil, opds = { thumbnail_url = "http://x/y.jpg" } }), nil)
    eq(OpdsCovers.cachePath({ filepath = 42, opds = { thumbnail_url = "http://x/y.jpg" } }), nil)
    eq(OpdsCovers.cachePath({ filepath = {}, opds = { thumbnail_url = "http://x/y.jpg" } }), nil)
end)

t.test("cachePath falls back to 'unknown' server segment for an unrecognised filepath", function()
    local rec = { filepath = "not-an-opds-filepath", opds = { thumbnail_url = "http://x/y.jpg" } }
    local path = OpdsCovers.cachePath(rec)
    assert(path:find("/unknown/", 1, true), "expected an 'unknown' server segment, got " .. tostring(path))
end)

-- ---------- cachePath: full-size image preferred over thumbnail ----------
--
-- A feed entry may carry both links. The thumbnail is typically ~100px and
-- visibly soft on a high-DPI screen, so the full-size image wins whenever
-- both are present; a record with only a thumbnail still works (fallback).

local rec_both = {
    filepath = "OPDS://abcd1234/book-both",
    opds = { thumbnail_url = "http://example.com/covers/thumb-both.jpg",
             image_url     = "http://example.com/covers/full-both.jpg" },
}

t.test("cachePath hashes image_url, not thumbnail_url, when both are present", function()
    local expected = CACHE_ROOT .. "/abcd1234/"
        .. OpdsSource.serverKey("http://example.com/covers/full-both.jpg") .. ".img"
    eq(OpdsCovers.cachePath(rec_both), expected)
end)

t.test("cachePath is unaffected by the thumbnail_url when image_url is present", function()
    local same_image_other_thumb = {
        filepath = "OPDS://abcd1234/book-both-2",
        opds = { thumbnail_url = "http://example.com/covers/some-other-thumb.jpg",
                 image_url     = "http://example.com/covers/full-both.jpg" },
    }
    eq(OpdsCovers.cachePath(rec_both), OpdsCovers.cachePath(same_image_other_thumb),
        "same image_url must key identically regardless of thumbnail_url")
end)

t.test("cachePath falls back to thumbnail_url when the record has no image_url", function()
    -- rec_ok carries only thumbnail_url; already covered above, restated here
    -- to make the fallback explicit alongside the preference tests.
    local expected = CACHE_ROOT .. "/abcd1234/"
        .. OpdsSource.serverKey("http://example.com/covers/1.jpg") .. ".img"
    eq(OpdsCovers.cachePath(rec_ok), expected)
end)

-- ---------- cachedPath ----------

t.test("cachedPath nil when the cache file is absent", function()
    eq(OpdsCovers.cachedPath(rec_ok), nil)
end)

t.test("cachedPath nil for a record with no thumbnail_url (no path to check)", function()
    eq(OpdsCovers.cachedPath({ filepath = "OPDS://abcd1234/x" }), nil)
    eq(OpdsCovers.cachedPath({ filepath = "OPDS://abcd1234/x", opds = {} }), nil)
end)

t.test("cachedPath returns cachePath's value once the file exists on disk", function()
    local rec = { filepath = "OPDS://abcd1234/book-cp",
                  opds = { thumbnail_url = "http://example.com/covers/cp.jpg" } }
    eq(OpdsCovers.cachedPath(rec), nil, "not yet fetched")
    _G._test_files[OpdsCovers.cachePath(rec)] = true
    eq(OpdsCovers.cachedPath(rec), OpdsCovers.cachePath(rec), "now resolves once the stub reports the file present")
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

-- ---------- fetchMissing: full-size image preferred over thumbnail ----------

t.test("fetchMissing downloads image_url (not thumbnail_url) when a record has both", function()
    for i = #download_calls, 1, -1 do download_calls[i] = nil end
    local rec = { filepath = "OPDS://srv1/both",
                  opds = { thumbnail_url = "http://example.com/covers/thumb-fm.jpg",
                           image_url     = "http://example.com/covers/full-fm.jpg" } }
    OpdsCovers.fetchMissing({ rec })
    eq(#download_calls, 1, "one download attempted")
    eq(download_calls[1].url, "http://example.com/covers/full-fm.jpg",
        "the full-size image URL is downloaded")
    eq(download_calls[1].dest, OpdsCovers.cachePath(rec), "dest matches the image-keyed cachePath")
end)

t.test("fetchMissing falls back to thumbnail_url when a record has no image_url", function()
    for i = #download_calls, 1, -1 do download_calls[i] = nil end
    local rec = { filepath = "OPDS://srv1/thumb-only",
                  opds = { thumbnail_url = "http://example.com/covers/thumb-only.jpg" } }
    OpdsCovers.fetchMissing({ rec })
    eq(#download_calls, 1, "one download attempted")
    eq(download_calls[1].url, "http://example.com/covers/thumb-only.jpg",
        "falls back to the thumbnail URL")
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

-- The gate must key off whichever URL is actually downloaded, not always the
-- thumbnail: coverUrl prefers image_url, so a record whose image_url points
-- cross-host (even with a same-host thumbnail_url) must download anonymously
-- -- the credentials must not follow the request to the foreign image host.
t.test("fetchMissing withholds credentials when the SELECTED (image) url is cross-host, even with a same-host thumbnail", function()
    for i = #download_calls, 1, -1 do download_calls[i] = nil end
    local rec = { filepath = "OPDS://authsrv/1",
                  opds = { thumbnail_url = "http://cw/covers/same-host-thumb.jpg",
                           image_url     = "http://evil.example/covers/gate-cross.jpg" } }
    OpdsCovers.fetchMissing({ rec })
    eq(#download_calls, 1, "download still attempted (anonymously)")
    eq(download_calls[1].url, "http://evil.example/covers/gate-cross.jpg", "the cross-host image url is what gets downloaded")
    eq(download_calls[1].user, nil, "cross-host image: no username, despite a same-host thumbnail")
    eq(download_calls[1].password, nil, "cross-host image: no password, despite a same-host thumbnail")
end)

t.test("fetchMissing passes credentials when the SELECTED (image) url is same-host, even with a cross-host thumbnail", function()
    for i = #download_calls, 1, -1 do download_calls[i] = nil end
    local rec = { filepath = "OPDS://authsrv/1",
                  opds = { thumbnail_url = "http://evil.example/covers/thumb.jpg",
                           image_url     = "http://cw/covers/same-host-full.jpg" } }
    OpdsCovers.fetchMissing({ rec })
    eq(#download_calls, 1, "download attempted")
    eq(download_calls[1].url, "http://cw/covers/same-host-full.jpg", "the same-host image url is what gets downloaded")
    eq(download_calls[1].user, "alice", "same-host image: credentials sent, despite a cross-host thumbnail")
    eq(download_calls[1].password, "s3cret", "same-host image: credentials sent, despite a cross-host thumbnail")
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

-- ---------- cache byte cap ----------
--
-- Nothing bounded this directory: full-size cover images, one per entry the
-- user ever looked at, never removed. (The one thing that used to empty it was
-- an accident -- the Cover tab's working-dir sweep, which now skips opds/.)
-- The interim bound is dumb on purpose: total the files, and if they exceed
-- the cap drop oldest-by-mtime until they don't. Slice 3 owns the real design
-- (LRU on USE, not mtime, so a cover you look at every day isn't evicted for
-- being old).

-- os.remove is the sweep's only mutation; wire it to the stub's file set.
local removed_paths = {}
os.remove = function(path)                       -- luacheck: ignore
    removed_paths[#removed_paths + 1] = path
    if _G._test_files[path] then
        _G._test_files[path] = nil
        return true
    end
    return nil, "no such file"
end

local MB = 1024 * 1024
local function seedCache(specs)
    for k in pairs(_G._test_files) do _G._test_files[k] = nil end
    for i = #removed_paths, 1, -1 do removed_paths[i] = nil end
    for _i, s in ipairs(specs) do
        _G._test_files[CACHE_ROOT .. "/" .. s[1]] = { size = s[2], mtime = s[3] }
    end
end
local function present(rel) return _G._test_files[CACHE_ROOT .. "/" .. rel] ~= nil end

t.test("sweepCache leaves a cache under the byte cap alone", function()
    seedCache({
        { "srvA/aaa.img", 10 * MB, 100 },
        { "srvA/bbb.img", 10 * MB, 200 },
        { "srvB/ccc.img", 10 * MB, 300 },
    })
    OpdsCovers.sweepCache()
    eq(#removed_paths, 0, "30 MB is well under the cap; nothing may be deleted")
end)

t.test("sweepCache drops oldest-by-mtime until the total is back under the cap", function()
    -- 4 x 20 MB = 80 MB against a 64 MB cap: exactly one file has to go, and
    -- it must be the oldest, not the first one the directory walk happened to
    -- hand back (the seed deliberately puts the oldest last alphabetically).
    seedCache({
        { "srvA/newest.img", 20 * MB, 400 },
        { "srvA/mid.img",    20 * MB, 300 },
        { "srvB/older.img",  20 * MB, 200 },
        { "srvB/zoldest.img", 20 * MB, 100 },
    })
    OpdsCovers.sweepCache()
    eq(#removed_paths, 1, "only as many files as the cap actually needs")
    assert(not present("srvB/zoldest.img"), "the oldest file is the one dropped")
    assert(present("srvB/older.img"), "the next-oldest is still under the cap, so it stays")
    assert(present("srvA/mid.img"), "newer files survive")
    assert(present("srvA/newest.img"), "newer files survive")
end)

t.test("sweepCache keeps dropping until under the cap, oldest first", function()
    seedCache({
        { "srvA/f1.img", 30 * MB, 100 },
        { "srvA/f2.img", 30 * MB, 200 },
        { "srvA/f3.img", 30 * MB, 300 },
        { "srvA/f4.img", 30 * MB, 400 },
    })
    OpdsCovers.sweepCache()
    -- 120 MB -> drop f1 (90) -> drop f2 (60) -> under the 64 MB cap.
    eq(#removed_paths, 2, "two files dropped")
    assert(not present("srvA/f1.img") and not present("srvA/f2.img"), "the two oldest went")
    assert(present("srvA/f3.img") and present("srvA/f4.img"), "the two newest stayed")
end)

t.test("sweepCache never deletes anything outside the opds cache dir", function()
    seedCache({
        { "srvA/big1.img", 40 * MB, 100 },
        { "srvA/big2.img", 40 * MB, 200 },
    })
    -- A sibling under bookshelf_covers (the Cover tab's working material) and
    -- a file one level too deep: neither is this sweep's to touch.
    local sibling = "/tmp/opds_covers_test_settings/bookshelf_covers/emb_book.png"
    _G._test_files[sibling] = { size = 50 * MB, mtime = 1 }
    OpdsCovers.sweepCache()
    assert(_G._test_files[sibling] ~= nil, "a file outside opds/ must never be removed")
    for _i, p in ipairs(removed_paths) do
        assert(p:sub(1, #CACHE_ROOT) == CACHE_ROOT,
            "removed a path outside the opds cache dir: " .. p)
    end
    _G._test_files[sibling] = nil
end)

t.test("sweepCache tolerates a missing cache dir", function()
    seedCache({})
    OpdsCovers.sweepCache()                     -- lfs.dir errors; must not throw
    eq(#removed_paths, 0)
end)

t.test("fetchMissing sweeps the cache after a pass that downloaded something", function()
    seedCache({
        { "srvA/old.img", 40 * MB, 100 },
        { "srvA/new.img", 40 * MB, 200 },
    })
    local rec = { filepath = "OPDS://srvA/x",
                  opds = { thumbnail_url = "http://example.com/covers/sweep1.jpg" } }
    local seen_during_done
    OpdsCovers.fetchMissing({ rec }, function()
        seen_during_done = present("srvA/old.img")
    end)
    eq(seen_during_done, false, "the sweep runs before on_done, so the rebuild sees the truth")
    assert(present("srvA/new.img"), "the newer file stays")
    assert(_G._test_files[OpdsCovers.cachePath(rec)] ~= nil,
        "the cover just downloaded is the newest thing here and must survive its own sweep")
end)

t.test("fetchMissing does not sweep when the pass downloaded nothing", function()
    local real_sweep = OpdsCovers.sweepCache
    local sweeps = 0
    OpdsCovers.sweepCache = function() sweeps = sweeps + 1 end
    seedCache({})
    local cached = { filepath = "OPDS://srvA/c",
                     opds = { thumbnail_url = "http://example.com/covers/already.jpg" } }
    _G._test_files[OpdsCovers.cachePath(cached)] = true
    OpdsCovers.fetchMissing({ cached })
    eq(sweeps, 0, "nothing downloaded -> nothing new to bound")
    OpdsCovers.fetchMissing({ { filepath = "OPDS://srvA/d",
                                opds = { thumbnail_url = "http://example.com/covers/fresh.jpg" } } })
    eq(sweeps, 1, "a pass that downloaded something sweeps exactly once")
    OpdsCovers.sweepCache = real_sweep
end)

t.done()
