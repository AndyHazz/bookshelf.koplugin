-- tests/_test_opds_download.lua
-- OPDS acquisition download core (lib/bookshelf_opds_download): destination
-- directory selection, filename derivation, and the blocking fetch itself.
-- Pure-Lua: stubs socket/http, ltn12, socket, socketutil and
-- libs/libkoreader-lfs so download() runs unchanged against a fake transport
-- and a fake filesystem, cribbing the stub prelude style from
-- tests/_test_opds_covers.lua.
package.path = "./?.lua;./?/init.lua;" .. package.path

-- ---------- lfs stub ----------
-- A set of "existing" directories/files the test populates; download() only
-- ever checks the destination's PARENT directory (it never creates one --
-- that is destinationDir/the caller's job via effectiveDownloadDir), and
-- os.rename/os.remove below operate on a parallel in-memory file set.
_G._test_dirs = { ["/home/user"] = true, ["/home/user/books"] = true }
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(path, key)
        if not _G._test_dirs[path] then return nil end
        local a = { mode = "directory" }
        if key then return a[key] end
        return a
    end,
}

-- ---------- filesystem stub (os.rename / os.remove / io.open) ----------
-- download() writes to "<dest>.tmp" then renames onto dest. Track both the
-- tmp writes and the final file set so tests can assert atomicity: dest only
-- ever appears via a rename, never a direct write.
_G._test_files = {}
local real_open = io.open
io.open = function(path, mode)                        -- luacheck: ignore
    if mode ~= "wb" then return real_open(path, mode) end
    local buf = {}
    _G._test_files[path .. "@tmp_handle"] = buf
    return {
        write = function(_self, chunk) buf[#buf + 1] = chunk; return true end,
        close = function() _G._test_files[path] = table.concat(buf) end,
    }
end
os.rename = function(from, to)                         -- luacheck: ignore
    if _G._test_files[from] == nil then return nil, "no such file" end
    _G._test_files[to] = _G._test_files[from]
    _G._test_files[from] = nil
    return true
end
local removed_paths = {}
os.remove = function(path)                             -- luacheck: ignore
    removed_paths[#removed_paths + 1] = path
    if _G._test_files[path] == nil then return nil, "no such file" end
    _G._test_files[path] = nil
    return true
end

-- ---------- transport stub (socket/http, ltn12, socket, socketutil) ----------
-- One canned response per URL: { code = N, headers = {...}, body = "..." }.
-- The stub feeds the sink exactly like the real ltn12 file sink would (body
-- chunk(s) then a closing nil), so download()'s tmp-file handling is
-- exercised for real rather than bypassed.
local http_responses = {}
local requests = {}
package.loaded["socket/http"] = {
    request = function(reqt)
        requests[#requests + 1] = { url = reqt.url, user = reqt.user,
                                    password = reqt.password,
                                    headers = reqt.headers }
        local resp = http_responses[reqt.url] or { code = 200, body = "" }
        if reqt.sink then
            if resp.body and resp.body ~= "" then reqt.sink(resp.body) end
            reqt.sink(nil)
        end
        return 1, resp.code, resp.headers or {}, resp.status
    end,
}
package.loaded["ltn12"] = {
    sink = {
        -- Matches real ltn12.sink.file: a nil chunk closes the handle.
        file = function(handle)
            return function(chunk)
                if not chunk then handle:close(); return 1 end
                return handle:write(chunk)
            end
        end,
    },
}
package.loaded["socket"] = {
    skip = function(d, ...) return select(d + 1, ...) end,
}
local timeout_calls = {}
package.loaded["socketutil"] = {
    -- Both pairs, with KOReader's real values, so the test can assert WHICH
    -- one download() picks -- a book needs the FILE budget, not the LARGE
    -- (API-call) one.
    LARGE_BLOCK_TIMEOUT = 10, LARGE_TOTAL_TIMEOUT = 30,
    FILE_BLOCK_TIMEOUT  = 15, FILE_TOTAL_TIMEOUT  = 60,
    set_timeout = function(_self, b, t) timeout_calls[#timeout_calls + 1] = { b, t } end,
    reset_timeout = function() end,
}
package.loaded["logger"] = { dbg = function() end, info = function() end,
                             warn = function() end, err = function() end }

local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()
local eq = helpers.eq

local D = dofile("lib/bookshelf_opds_download.lua")

-- ================== destinationDir ==================

local function settings(tbl)
    return function(key) return tbl[key] end
end

t.test("destinationDir: nil when home_dir is unset (no fallback invented)", function()
    eq(D.destinationDir(settings({})), nil)
    eq(D.destinationDir(settings({ download_dir = "/home/user/books" })), nil)
end)

t.test("destinationDir: falls back to home_dir when nothing else is set", function()
    eq(D.destinationDir(settings({ home_dir = "/home/user" })), "/home/user")
end)

-- preferred (Bookshelf's own opds_download_dir, issue #319): an explicitly
-- chosen folder wins over the stock download dir, but only while it passes
-- the same inside-home_dir test AND still exists - a stale or outside choice
-- degrades to the normal rules rather than downloading somewhere invisible.
t.test("destinationDir: an explicit folder beats the stock download dir", function()
    _G._test_dirs["/home/user/Catalog"] = true
    eq(D.destinationDir(settings({
        home_dir = "/home/user",
        download_dir = "/home/user/books",
    }), "/home/user/Catalog"), "/home/user/Catalog")
end)

t.test("destinationDir: an explicit folder outside home_dir is refused", function()
    _G._test_dirs["/mnt/sd/Catalog"] = true
    eq(D.destinationDir(settings({
        home_dir = "/home/user",
        download_dir = "/home/user/books",
    }), "/mnt/sd/Catalog"), "/home/user/books", "falls back to the stock dir")
    eq(D.destinationDir(settings({ home_dir = "/home/user" }), "/mnt/sd/Catalog"),
       "/home/user", "and to home_dir when there is no stock dir")
end)

t.test("destinationDir: a vanished explicit folder degrades instead of failing", function()
    eq(D.destinationDir(settings({
        home_dir = "/home/user",
        download_dir = "/home/user/books",
    }), "/home/user/DeletedFolder"), "/home/user/books")
end)

t.test("destinationDir: trailing slashes and home itself are accepted", function()
    _G._test_dirs["/home/user/Catalog"] = true
    eq(D.destinationDir(settings({ home_dir = "/home/user/" }), "/home/user/Catalog/"),
       "/home/user/Catalog")
    _G._test_dirs["/home/user"] = true
    eq(D.destinationDir(settings({ home_dir = "/home/user" }), "/home/user"), "/home/user")
end)

t.test("destinationDir: empty or non-string preferred is ignored", function()
    eq(D.destinationDir(settings({ home_dir = "/home/user" }), ""), "/home/user")
    eq(D.destinationDir(settings({ home_dir = "/home/user" }), 42), "/home/user")
    eq(D.destinationDir(settings({ home_dir = "/home/user" }), nil), "/home/user")
end)

t.test("destinationDir: uses the effective download dir when it resolves inside home_dir", function()
    eq(D.destinationDir(settings({
        home_dir = "/home/user",
        download_dir = "/home/user/books",
    })), "/home/user/books")
end)

t.test("destinationDir: falls back to lastdir when download_dir is unset (inside home_dir)", function()
    eq(D.destinationDir(settings({
        home_dir = "/home/user",
        lastdir = "/home/user/books",
    })), "/home/user/books")
end)

t.test("destinationDir: falls back to home_dir when the effective dir resolves OUTSIDE home_dir", function()
    eq(D.destinationDir(settings({
        home_dir = "/home/user",
        download_dir = "/mnt/sd/books",
    })), "/home/user")
end)

t.test("destinationDir: trailing slashes on either side do not defeat the prefix match", function()
    eq(D.destinationDir(settings({
        home_dir = "/home/user/",
        download_dir = "/home/user/books/",
    })), "/home/user/books")
end)

t.test("destinationDir: a sibling directory that merely shares a prefix is NOT 'inside' home_dir", function()
    -- /home/user2 shares the string prefix "/home/user" but is not inside it.
    eq(D.destinationDir(settings({
        home_dir = "/home/user",
        download_dir = "/home/user2/books",
    })), "/home/user")
end)

t.test("destinationDir: the effective dir equal to home_dir itself counts as inside", function()
    eq(D.destinationDir(settings({
        home_dir = "/home/user",
        download_dir = "/home/user",
    })), "/home/user")
end)

-- ================== filenameFor ==================

t.test("filenameFor: maps each known acquisition type to its extension", function()
    local rec = { title = "Some Book" }
    local cases = {
        { "application/epub+zip", "epub" },
        { "application/pdf", "pdf" },
        { "application/x-mobipocket-ebook", "mobi" },
        { "application/fb2", "fb2" },
        { "application/x-fictionbook+xml", "fb2" },
        { "application/x-cbz", "cbz" },
        { "image/vnd.djvu", "djvu" },
        { "text/plain", "txt" },
        { "text/html", "html" },
    }
    for _, c in ipairs(cases) do
        local acq = { type = c[1], href = "http://x/book" }
        eq(D.filenameFor(rec, acq), "Some Book." .. c[2], "type " .. c[1])
    end
end)

-- Every type bookshelf_opds_feed keeps as downloadable must map to a real
-- extension here. A gap means the book lands as ".bin", which no KOReader
-- provider opens -- the download "succeeds" and the book is unopenable.
-- Iterates the feed module's OWN table rather than a hand-copy: a hand-copy
-- goes green when a tenth type is added to the feed filter and forgotten here,
-- which is precisely the drift this test exists to catch.
t.test("filenameFor: every SUPPORTED_TYPE the feed keeps has an extension (no .bin)", function()
    local Feed = dofile("lib/bookshelf_opds_feed.lua")
    assert(type(Feed.SUPPORTED_TYPE) == "table",
        "bookshelf_opds_feed must export SUPPORTED_TYPE for this guard to guard")
    local feed_types = {}
    for mtype in pairs(Feed.SUPPORTED_TYPE) do feed_types[#feed_types + 1] = mtype end
    table.sort(feed_types)
    assert(#feed_types > 0, "SUPPORTED_TYPE is empty")
    for _, mtype in ipairs(feed_types) do
        -- href with no extension of its own, so only the MIME map can answer.
        local name = D.filenameFor({ title = "T" }, { type = mtype, href = "http://x/get" })
        assert(name ~= "T.bin", mtype .. " has no extension mapping (fell through to .bin)")
    end
end)

-- The #318 gap: Booklore serves AZW3 as application/vnd.amazon.ebook and CBZ
-- as the registered application/vnd.comicbook+zip. Both were missing, so a
-- shelf of Kindle files or comics rendered as an empty category while an EPUB
-- shelf worked. Every type KOReader's DocumentRegistry knows is accepted now.
t.test("filenameFor: the formats KOReader opens all get real extensions", function()
    local cases = {
        { "application/vnd.amazon.ebook",       "azw3" },
        { "application/vnd.comicbook+zip",      "cbz"  },
        { "application/x-cbz",                  "cbz"  },
        { "application/vnd.comicbook-rar",      "cbr"  },
        { "application/vnd.comicbook+tar",      "cbt"  },
        { "application/vnd.ms-htmlhelp",        "chm"  },
        { "application/oxps",                   "xps"  },
        { "application/rtf",                    "rtf"  },
        { "application/vnd.palm",               "pdb"  },
        { "application/xhtml+xml",              "xhtml"},
        { "application/fb2+zip",                "fb2.zip" },
        { "application/zip",                    "zip"  },
        { "application/msword",                 "doc"  },
        { "application/vnd.oasis.opendocument.text", "odt" },
    }
    for _i, c in ipairs(cases) do
        eq(D.filenameFor({ title = "T" }, { type = c[1], href = "http://x/get" }),
           "T." .. c[2], c[1])
    end
end)

t.test("SUPPORTED_TYPE accepts those types (so the entry is not dropped)", function()
    local Feed = dofile("lib/bookshelf_opds_feed.lua")
    for _i, mtype in ipairs({ "application/vnd.amazon.ebook",
                              "application/vnd.comicbook+zip",
                              "application/vnd.comicbook-rar",
                              "application/vnd.ms-htmlhelp" }) do
        assert(Feed.SUPPORTED_TYPE[mtype], mtype .. " is not acquirable")
    end
end)

t.test("ambiguous and non-book types stay out", function()
    local Feed = dofile("lib/bookshelf_opds_feed.lua")
    -- octet-stream is "some binary" (Booklore's fallback for an unidentified
    -- file); image types in a feed are covers, not books.
    for _i, mtype in ipairs({ "application/octet-stream", "image/jpeg",
                              "image/png", "text/x-python" }) do
        assert(not Feed.SUPPORTED_TYPE[mtype], mtype .. " must not be acquirable")
    end
end)

t.test("the feed filter and the download extension map are ONE table", function()
    local Feed = dofile("lib/bookshelf_opds_feed.lua")
    assert(type(Feed.TYPE_EXT) == "table", "feed must export TYPE_EXT")
    for mtype in pairs(Feed.SUPPORTED_TYPE) do
        assert(Feed.TYPE_EXT[mtype], mtype .. " acquirable but has no extension")
    end
    for mtype, ext in pairs(Feed.TYPE_EXT) do
        assert(Feed.SUPPORTED_TYPE[mtype], mtype .. " has an extension but is not acquirable")
        assert(type(ext) == "string" and ext ~= "" and not ext:find("^%."),
            mtype .. " extension must be a bare suffix, got " .. tostring(ext))
    end
end)

t.test("filenameFor: unknown type falls back to the URL path's own extension", function()
    local rec = { title = "Weird Format" }
    local acq = { type = "application/x-something-odd", href = "http://x/dl/book.azw3" }
    eq(D.filenameFor(rec, acq), "Weird Format.azw3")
end)

t.test("filenameFor: URL fallback ignores a query string tail", function()
    local rec = { title = "Query Tail" }
    local acq = { type = "application/x-something-odd", href = "http://x/dl/book.azw3?token=abc123" }
    eq(D.filenameFor(rec, acq), "Query Tail.azw3")
end)

t.test("filenameFor: unknown type and no usable URL extension falls back to .bin", function()
    local rec = { title = "No Extension" }
    eq(D.filenameFor(rec, { type = "application/octet-stream", href = "http://x/dl/download" }), "No Extension.bin")
    eq(D.filenameFor(rec, { type = "application/octet-stream", href = "http://x/dl/" }), "No Extension.bin")
    eq(D.filenameFor(rec, { type = "application/octet-stream" }), "No Extension.bin")
end)

t.test("filenameFor: falls back to display_title, then a generic name, when title is missing", function()
    eq(D.filenameFor({ display_title = "Fallback Title" }, { type = "application/pdf" }), "Fallback Title.pdf")
    eq(D.filenameFor({}, { type = "application/pdf" }), "book.pdf")
    eq(D.filenameFor(nil, { type = "application/pdf" }), "book.pdf")
end)

-- ================== download ==================

local function reset()
    for k in pairs(http_responses) do http_responses[k] = nil end
    for i = #requests, 1, -1 do requests[i] = nil end
    for k in pairs(_G._test_files) do _G._test_files[k] = nil end
    for i = #removed_paths, 1, -1 do removed_paths[i] = nil end
    for i = #timeout_calls, 1, -1 do timeout_calls[i] = nil end
end

t.test("download: a 200 response writes the body atomically (tmp then rename)", function()
    reset()
    local url = "http://example.com/book.epub"
    http_responses[url] = { code = 200, body = "epub-bytes" }
    local dest = "/home/user/books/book.epub"

    local path, err = D.download(url, dest)

    eq(err, nil)
    eq(path, dest)
    eq(_G._test_files[dest], "epub-bytes")
    eq(_G._test_files[dest .. ".tmp"], nil, "tmp file must not remain after a successful rename")
end)

t.test("download: sends no credentials when user/password are omitted", function()
    reset()
    local url = "http://example.com/anon.epub"
    http_responses[url] = { code = 200, body = "x" }
    D.download(url, "/home/user/books/anon.epub")
    eq(requests[1].user, nil)
    eq(requests[1].password, nil)
end)

t.test("download: forwards optional basic-auth credentials to the request", function()
    reset()
    local url = "http://example.com/auth.epub"
    http_responses[url] = { code = 200, body = "x" }
    D.download(url, "/home/user/books/auth.epub", "alice", "s3cret")
    eq(requests[1].user, "alice")
    eq(requests[1].password, "s3cret")
end)

-- LuaSocket sets no Accept-Encoding of its own and cannot decode a
-- content-encoded body, so a server answering with Content-Encoding: gzip
-- would leave a gzipped file under an .epub name -- the download "succeeds"
-- and the book will not open. bookshelf_opds_feed.fetch and the stock OPDS
-- plugin's downloadFile both send identity; this is the transfer where it
-- matters most.
t.test("download: asks for an unencoded body (Accept-Encoding: identity)", function()
    reset()
    local url = "http://example.com/enc.epub"
    http_responses[url] = { code = 200, body = "x" }
    D.download(url, "/home/user/books/enc.epub")
    local h = requests[1].headers
    assert(type(h) == "table", "the request must carry a headers table")
    eq(h["Accept-Encoding"], "identity")
    eq(h["User-Agent"], "KOReader-Bookshelf", "the existing header must survive")
end)

t.test("download: a 404 fails clean, leaving no tmp file and no dest file", function()
    reset()
    local url = "http://example.com/missing.epub"
    http_responses[url] = { code = 404, body = "not found" }
    local dest = "/home/user/books/missing.epub"

    local path, err = D.download(url, dest)

    eq(path, nil)
    assert(type(err) == "string" and err ~= "", "expected an error string")
    eq(_G._test_files[dest], nil)
    eq(_G._test_files[dest .. ".tmp"], nil, "the failed tmp file must be cleaned up")
end)

t.test("download: 401 yields \"auth\" and cleans up the tmp file", function()
    reset()
    local url = "http://example.com/locked.epub"
    http_responses[url] = { code = 401, body = "" }
    local dest = "/home/user/books/locked.epub"

    local path, err = D.download(url, dest)

    eq(path, nil)
    eq(err, "auth")
    eq(_G._test_files[dest .. ".tmp"], nil)
end)

t.test("download: 403 also yields \"auth\"", function()
    reset()
    local url = "http://example.com/forbidden.epub"
    http_responses[url] = { code = 403, body = "" }
    local path, err = D.download(url, "/home/user/books/forbidden.epub")
    eq(path, nil)
    eq(err, "auth")
end)

t.test("download: an https-to-http redirect is refused as a downgrade, with the location surfaced", function()
    reset()
    local url = "https://example.com/book.epub"
    http_responses[url] = { code = 302, headers = { location = "http://plain.example.com/book.epub" } }
    local dest = "/home/user/books/book.epub"

    local path, err, location = D.download(url, dest)

    eq(path, nil)
    eq(err, "downgrade")
    eq(location, "http://plain.example.com/book.epub")
    eq(_G._test_files[dest], nil, "nothing must be written for a refused downgrade")
    eq(_G._test_files[dest .. ".tmp"], nil, "tmp file cleaned up on refusal")
end)

t.test("download: an https-to-https redirect target is not treated as a downgrade", function()
    reset()
    -- Same-scheme redirects are luasocket's own job to follow (redirect =
    -- true); this only pins that OUR downgrade check does not misfire on one
    -- that (for whatever reason) still reached us as a 3xx.
    local url = "https://example.com/book.epub"
    http_responses[url] = { code = 302, headers = { location = "https://example.com/moved.epub" } }
    local path, err = D.download(url, "/home/user/books/book.epub")
    eq(path, nil)
    assert(err ~= "downgrade", "a same-scheme redirect target must not be reported as a downgrade")
end)

t.test("download: an http-to-http redirect is never a downgrade (nothing to downgrade from)", function()
    reset()
    local url = "http://example.com/book.epub"
    http_responses[url] = { code = 302, headers = { location = "http://example.com/moved.epub" } }
    local path, err = D.download(url, "/home/user/books/book.epub")
    eq(path, nil)
    assert(err ~= "downgrade")
end)

t.test("download: uses socketutil's FILE timeout pair, not the LARGE (API) one", function()
    reset()
    local url = "http://example.com/timed.epub"
    http_responses[url] = { code = 200, body = "x" }
    D.download(url, "/home/user/books/timed.epub")
    eq(#timeout_calls, 1)
    -- 15s block / 60s total (stock OPDS plugin parity). The LARGE pair's 30s
    -- total cuts a real book off mid-transfer on a slow connection and the
    -- caller reports it as an ordinary unreachable-server failure.
    eq(timeout_calls[1][1], 15, "block timeout")
    eq(timeout_calls[1][2], 60, "total timeout")
end)

t.test("download: bad arguments are rejected without touching the transport", function()
    reset()
    local p1, e1 = D.download(nil, "/home/user/books/x.epub")
    local p2, e2 = D.download("http://x/y.epub", nil)
    local p3, e3 = D.download("", "/home/user/books/x.epub")
    eq(p1, nil); assert(e1)
    eq(p2, nil); assert(e2)
    eq(p3, nil); assert(e3)
    eq(#requests, 0, "no request must be attempted for bad arguments")
end)

t.test("download: destination directory unavailable fails clean without touching the transport", function()
    reset()
    local path, err = D.download("http://example.com/x.epub", "/no/such/dir/x.epub")
    eq(path, nil)
    assert(type(err) == "string" and err ~= "")
    eq(#requests, 0, "must not attempt the request when the destination dir cannot hold the file")
end)

t.test("download: overwrites an existing dest_path on success", function()
    reset()
    local dest = "/home/user/books/overwrite.epub"
    _G._test_files[dest] = "old-bytes"
    local url = "http://example.com/overwrite.epub"
    http_responses[url] = { code = 200, body = "new-bytes" }
    local path = D.download(url, dest)
    eq(path, dest)
    eq(_G._test_files[dest], "new-bytes")
end)

-- dest_path is a permanent library book, not a disposable cache file: the
-- original must survive a direct-rename failure and only be removed once a
-- fallback rename is actually going to be attempted, never up front.
t.test("download: only falls back to remove-then-rename after a failed direct rename, never deleting the original up front", function()
    reset()
    local dest = "/home/user/books/existing.epub"
    _G._test_files[dest] = "original-bytes"
    local url = "http://example.com/existing.epub"
    http_responses[url] = { code = 200, body = "new-bytes" }

    local real_rename = os.rename
    local attempt = 0
    local rename_calls = {}
    os.rename = function(from, to)                       -- luacheck: ignore
        attempt = attempt + 1
        rename_calls[#rename_calls + 1] = { dest_present_before = _G._test_files[dest] ~= nil }
        if attempt == 1 then
            -- Simulate a direct-rename failure unrelated to dest_path's
            -- presence (a stale lock, a cross-device link, ...).
            return nil, "simulated failure"
        end
        return real_rename(from, to)
    end

    local path, err = D.download(url, dest)

    os.rename = real_rename                              -- luacheck: ignore

    eq(err, nil)
    eq(path, dest)
    eq(#rename_calls, 2, "a direct rename is attempted before any fallback")
    eq(rename_calls[1].dest_present_before, true,
        "the original must still be present for the first (failed) rename attempt")
    eq(rename_calls[2].dest_present_before, false,
        "the original is removed only after the direct rename failed, right before the retry")
    eq(_G._test_files[dest], "new-bytes", "the fallback still lands the new file")
end)

t.test("download: a direct rename that succeeds never touches the original via os.remove", function()
    reset()
    local dest = "/home/user/books/clean.epub"
    _G._test_files[dest] = "original-bytes"
    local url = "http://example.com/clean.epub"
    http_responses[url] = { code = 200, body = "new-bytes" }

    D.download(url, dest)

    for _, p in ipairs(removed_paths) do
        assert(p ~= dest, "dest_path must not be passed to os.remove when the direct rename already succeeded")
    end
end)

-- ================== claimDest ==================
--
-- getSafeFilename sanitises but never uniquifies, so two DIFFERENT records can
-- name the same file. Overwriting then leaves both opds_downloads keys
-- pointing at one file and record A's Open launches record B's book.

local ACQ_A = { type = "application/epub+zip", href = "http://cat/a/1.epub" }
local ACQ_B = { type = "application/epub+zip", href = "http://cat/b/1.epub" }
local DEST  = "/home/user/books/Dune.epub"

t.test("claimDest: an unclaimed destination is returned unchanged", function()
    eq(D.claimDest(DEST, {}, "OPDS://s/a", ACQ_A), DEST)
    eq(D.claimDest(DEST, nil, "OPDS://s/a", ACQ_A), DEST)
    eq(D.claimDest(DEST, { ["OPDS://s/z"] = "/home/user/books/Other.epub" },
        "OPDS://s/a", ACQ_A), DEST)
end)

t.test("claimDest: the SAME record's own destination is returned unchanged", function()
    -- Re-downloading a book you already have -- including the other half of a
    -- collapsed edition pair, which shares the record -- is one book being
    -- replaced. That is what the caller's overwrite prompt is for.
    local map = { ["OPDS://s/a"] = DEST }
    eq(D.claimDest(DEST, map, "OPDS://s/a", ACQ_A), DEST)
    eq(D.claimDest(DEST, map, "OPDS://s/a", ACQ_B), DEST,
        "a different acquisition on the same record still overwrites")
end)

t.test("claimDest: a destination held by a DIFFERENT record is disambiguated", function()
    local map = { ["OPDS://s/a"] = DEST }
    local got = D.claimDest(DEST, map, "OPDS://s/b", ACQ_B)
    assert(got ~= DEST, "must not hand back the other record's file")
    assert(got:match("^/home/user/books/Dune %(%x+%)%.epub$"),
        "expected a suffixed sibling, got " .. tostring(got))
end)

t.test("claimDest: disambiguation is deterministic per acquisition URL", function()
    local map = { ["OPDS://s/a"] = DEST }
    local first  = D.claimDest(DEST, map, "OPDS://s/b", ACQ_B)
    local second = D.claimDest(DEST, map, "OPDS://s/b", ACQ_B)
    eq(second, first, "same acquisition must resolve to the same file, so a "
        .. "re-download of it still gets the plain overwrite prompt")
    local other = D.claimDest(DEST, map, "OPDS://s/c",
        { type = ACQ_B.type, href = "http://cat/c/1.epub" })
    assert(other ~= first, "different acquisition URLs must not collide again")
end)

t.test("claimDest: a destination with no extension gets the tag appended", function()
    local bare = "/home/user/books/Dune"
    local got = D.claimDest(bare, { ["OPDS://s/a"] = bare }, "OPDS://s/b", ACQ_B)
    assert(got:match("^/home/user/books/Dune %(%x+%)$"), "got " .. tostring(got))
end)

t.test("claimDest: a dotted DIRECTORY name is not mistaken for an extension", function()
    local dotted = "/home/user/sci.fi/Dune"
    local got = D.claimDest(dotted, { ["OPDS://s/a"] = dotted }, "OPDS://s/b", ACQ_B)
    assert(got:match("^/home/user/sci%.fi/Dune %(%x+%)$"),
        "the tag must land on the basename, got " .. tostring(got))
end)

t.test("claimDest: with no acquisition URL to hash, hands the destination back", function()
    -- Nothing to disambiguate WITH; the caller falls through to its overwrite
    -- prompt rather than inventing a name.
    local map = { ["OPDS://s/a"] = DEST }
    eq(D.claimDest(DEST, map, "OPDS://s/b", nil), DEST)
    eq(D.claimDest(DEST, map, "OPDS://s/b", { type = "application/epub+zip" }), DEST)
end)

-- ================== STORE_KEY / pruneMap ==================

t.test("STORE_KEY is the settings key both the widget and the repo read", function()
    eq(D.STORE_KEY, "opds_downloads")
end)

-- Rule: an entry survives only while its VALUE still stats as a file. The map
-- is keyed by OPDS pseudo-path (which never moves) and valued by the on-disk
-- path (which does), so this drops entries for books the user deleted -- and
-- for books they moved, which the read side already treats as "not downloaded".
local function isFile(set)
    return function(path) return set[path] == true end
end

t.test("pruneMap: keeps entries whose destination is still a file", function()
    local map = { ["OPDS://s/a"] = "/books/a.epub", ["OPDS://s/b"] = "/books/b.epub" }
    local out, removed = D.pruneMap(map, isFile({ ["/books/a.epub"] = true,
                                                  ["/books/b.epub"] = true }))
    eq(removed, 0)
    eq(out["OPDS://s/a"], "/books/a.epub")
    eq(out["OPDS://s/b"], "/books/b.epub")
end)

t.test("pruneMap: drops entries whose destination is gone", function()
    local map = { ["OPDS://s/a"] = "/books/a.epub", ["OPDS://s/gone"] = "/books/gone.epub" }
    local out, removed = D.pruneMap(map, isFile({ ["/books/a.epub"] = true }))
    eq(removed, 1)
    eq(out["OPDS://s/a"], "/books/a.epub")
    eq(out["OPDS://s/gone"], nil)
end)

t.test("pruneMap: drops malformed values without touching the good ones", function()
    local map = { ["OPDS://s/a"] = "/books/a.epub", ["OPDS://s/x"] = "",
                  ["OPDS://s/y"] = 42 }
    local out, removed = D.pruneMap(map, isFile({ ["/books/a.epub"] = true }))
    eq(removed, 2)
    eq(out["OPDS://s/a"], "/books/a.epub")
    eq(out["OPDS://s/x"], nil)
    eq(out["OPDS://s/y"], nil)
end)

t.test("pruneMap: prunes in place and hands the same table back", function()
    local map = { ["OPDS://s/gone"] = "/books/gone.epub" }
    local out = D.pruneMap(map, isFile({}))
    assert(out == map, "the caller stores the returned table; it must be the one it passed")
    eq(next(map), nil)
end)

t.test("pruneMap: a bad map or a missing stat function is a no-op", function()
    eq(D.pruneMap(nil, isFile({})), nil)
    local map = { ["OPDS://s/a"] = "/books/a.epub" }
    local out, removed = D.pruneMap(map, nil)
    assert(out == map, "with nothing to stat with, nothing can be judged dead")
    eq(removed, 0)
    eq(out["OPDS://s/a"], "/books/a.epub")
end)

-- A pruned entry stops counting as "taken", so an unrelated record that
-- legitimately wants that filename gets the plain path back rather than a
-- spurious (a1b2c3d4) suffix. This is the pairing the prune exists for.
t.test("pruneMap + claimDest: a dead entry no longer forces a suffix", function()
    local map = { ["OPDS://s/a"] = DEST }
    assert(D.claimDest(DEST, map, "OPDS://s/b", ACQ_B) ~= DEST,
        "precondition: a live entry under another key does force a suffix")
    D.pruneMap(map, isFile({}))
    eq(D.claimDest(DEST, map, "OPDS://s/b", ACQ_B), DEST)
end)

-- ================== rankAcquisitions ==================
--
-- Pure ranker: MIME order first (epub best for KOReader), a title tiebreak only
-- WITHIN a MIME group, and a "recommended" index handed back ONLY when the
-- choice is unambiguous.

local function types(list)
    local out = {}
    for i = 1, #list do out[i] = list[i].type end
    return out
end

t.test("rankAcquisitions: Gutenberg set puts epub3 first and recommends it", function()
    -- epub3, plain epub, epub (no images), kindle, txt -- in feed order.
    local acqs = {
        { type = "application/epub+zip", title = "EPUB3" },
        { type = "application/epub+zip", title = "EPUB" },
        { type = "application/epub+zip", title = "EPUB (no images)" },
        { type = "application/x-mobipocket-ebook", title = "Kindle" },
        { type = "text/plain", title = "Plain Text UTF-8" },
    }
    local ordered, rec = D.rankAcquisitions(acqs)
    eq(ordered[1].title, "EPUB3", "epub3 sorts to the top of the epub group")
    eq(ordered[2].title, "EPUB", "plain epub next")
    eq(ordered[3].title, "EPUB (no images)", "no-images epub sorts after its siblings")
    eq(ordered[4].type, "application/x-mobipocket-ebook", "kindle after the epub group")
    eq(ordered[5].type, "text/plain", "txt last")
    eq(rec, 1, "the top epub3 is the confident recommendation")
end)

t.test("rankAcquisitions: MIME order is epub > fb2 > mobi > pdf > cbz > djvu > txt > html", function()
    local acqs = {
        { type = "text/html" }, { type = "text/plain" }, { type = "image/vnd.djvu" },
        { type = "application/x-cbz" }, { type = "application/pdf" },
        { type = "application/x-mobipocket-ebook" }, { type = "application/fb2" },
        { type = "application/epub+zip" },
    }
    local ordered = D.rankAcquisitions(acqs)
    eq(types(ordered), {
        "application/epub+zip", "application/fb2", "application/x-mobipocket-ebook",
        "application/pdf", "application/x-cbz", "image/vnd.djvu",
        "text/plain", "text/html",
    })
end)

t.test("rankAcquisitions: kindle + pdf orders kindle first with NO badge", function()
    local ordered, rec = D.rankAcquisitions({
        { type = "application/pdf", title = "PDF" },
        { type = "application/x-mobipocket-ebook", title = "Kindle" },
    })
    eq(ordered[1].type, "application/x-mobipocket-ebook", "kindle outranks pdf")
    eq(ordered[2].type, "application/pdf")
    eq(rec, nil, "a non-epub top is never recommended")
end)

t.test("rankAcquisitions: a lone single acquisition gets NO badge", function()
    local ordered, rec = D.rankAcquisitions({ { type = "application/epub+zip", title = "EPUB" } })
    eq(#ordered, 1)
    eq(rec, nil, "with no choice to make, nothing is recommended")
end)

t.test("rankAcquisitions: two indistinguishable epubs order first but recommend nil", function()
    local ordered, rec = D.rankAcquisitions({
        { type = "application/epub+zip", title = "EPUB" },
        { type = "application/epub+zip", title = "EPUB" },
    })
    eq(ordered[1].type, "application/epub+zip", "epub group leads")
    eq(ordered[2].type, "application/epub+zip")
    eq(rec, nil, "neither strictly beats the other, so no confident badge")
end)

t.test("rankAcquisitions: a lone epub among other formats IS recommended", function()
    local ordered, rec = D.rankAcquisitions({
        { type = "application/pdf", title = "PDF" },
        { type = "application/epub+zip", title = "EPUB" },
        { type = "text/plain", title = "Plain Text" },
    })
    eq(ordered[1].type, "application/epub+zip")
    eq(rec, 1, "the sole epub among several formats is the confident choice")
end)

t.test("rankAcquisitions: never badge a no-images epub even when it is the only epub", function()
    local ordered, rec = D.rankAcquisitions({
        { type = "application/epub+zip", title = "EPUB (no images)" },
        { type = "application/x-mobipocket-ebook", title = "Kindle" },
    })
    eq(ordered[1].type, "application/epub+zip", "it still sorts to the top by MIME")
    eq(rec, nil, "but an images-stripped epub is never the recommendation")
end)

t.test("rankAcquisitions: the title tiebreak never moves a format across MIME groups", function()
    -- A pdf whose title contains "3" must NOT jump ahead of a plain epub: MIME
    -- is compared first, so the title rank only reorders within one group.
    local ordered = D.rankAcquisitions({
        { type = "application/pdf", title = "Version 3" },
        { type = "application/epub+zip", title = "EPUB" },
    })
    eq(ordered[1].type, "application/epub+zip", "epub still leads despite the pdf's '3'")
end)

t.test("rankAcquisitions: unknown types sort last, keeping feed order among themselves", function()
    local ordered = D.rankAcquisitions({
        { type = "application/x-weird-a" },
        { type = "application/epub+zip" },
        { type = "application/x-weird-b" },
    })
    eq(ordered[1].type, "application/epub+zip")
    eq(ordered[2].type, "application/x-weird-a", "unknowns keep their original order")
    eq(ordered[3].type, "application/x-weird-b")
end)

t.test("rankAcquisitions: a non-table argument yields an empty list and no badge", function()
    local ordered, rec = D.rankAcquisitions(nil)
    eq(#ordered, 0)
    eq(rec, nil)
end)

-- ================== 308 Permanent Redirect ==================
-- LuaSocket auto-follows same-scheme 301/302/303/307 but never 308 (its
-- shouldredirect list predates RFC 7538), so download() follows one manually.
-- The redirect target is server-controlled: credentials ride along ONLY when
-- it is same-origin with the URL the caller vetted.

t.test("download: a same-origin 308 is followed, credentials forwarded", function()
    reset()
    local a = "https://example.com/old/book.epub"
    local b = "https://example.com/new/book.epub"
    http_responses[a] = { code = 308, headers = { location = b } }
    http_responses[b] = { code = 200, body = "EPUB-BYTES" }
    local dest = "/home/user/books/moved.epub"

    local path, err = D.download(a, dest, "alice", "s3cret")

    eq(err, nil, "no error following a same-origin 308")
    eq(path, dest)
    eq(_G._test_files[dest], "EPUB-BYTES", "body written from the redirect target")
    eq(requests[2].url, b, "second request hits the Location")
    eq(requests[2].user, "alice", "same-origin: user forwarded")
    eq(requests[2].password, "s3cret", "same-origin: password forwarded")
end)

t.test("download: a cross-origin 308 is followed WITHOUT credentials", function()
    reset()
    local a = "https://example.com/book.epub"
    local b = "https://cdn.other.net/book.epub"
    http_responses[a] = { code = 308, headers = { location = b } }
    http_responses[b] = { code = 200, body = "EPUB-BYTES" }

    local path = D.download(a, "/home/user/books/cdn.epub", "alice", "s3cret")

    eq(path, "/home/user/books/cdn.epub")
    eq(requests[2].url, b)
    eq(requests[2].user, nil, "cross-origin: Basic auth must not leak")
    eq(requests[2].password, nil, "cross-origin: Basic auth must not leak")
end)

t.test("download: a relative 308 Location resolves against the request URL", function()
    reset()
    local a = "https://example.com/opds/old.epub"
    local b = "https://example.com/opds/moved/new.epub"
    http_responses[a] = { code = 308, headers = { location = "moved/new.epub" } }
    http_responses[b] = { code = 200, body = "EPUB-BYTES" }

    local path = D.download(a, "/home/user/books/rel.epub")

    eq(path, "/home/user/books/rel.epub")
    eq(requests[2].url, b, "relative Location resolved with feed.absolute")
end)

t.test("download: a 308 https-to-http downgrade is refused like any other", function()
    reset()
    local a = "https://example.com/book.epub"
    http_responses[a] = { code = 308,
                          headers = { location = "http://example.com/book.epub" } }

    local path, err, location = D.download(a, "/home/user/books/dg.epub")

    eq(path, nil)
    eq(err, "downgrade")
    eq(location, "http://example.com/book.epub")
    eq(#requests, 1, "a downgrade is never followed")
end)

t.test("download: a 308 loop terminates at the depth cap", function()
    reset()
    local a = "https://example.com/a.epub"
    local b = "https://example.com/b.epub"
    http_responses[a] = { code = 308, headers = { location = b } }
    http_responses[b] = { code = 308, headers = { location = a } }

    local path, err = D.download(a, "/home/user/books/loop.epub")

    eq(path, nil)
    eq(err, "download failed (308)")
    eq(#requests, 6, "initial request + 5 follows, then stop; got " .. #requests)
end)

t.test("download: a bare same-scheme 301 is still NOT manually followed", function()
    -- Same-scheme 301/302/303/307 are luasocket's job (redirect = true);
    -- reaching the manual branch with one means luasocket refused it, and
    -- the manual follow stays 308-only.
    reset()
    local a = "https://example.com/book.epub"
    http_responses[a] = { code = 301,
                          headers = { location = "https://example.com/elsewhere.epub" } }

    local path, err = D.download(a, "/home/user/books/301.epub")

    eq(path, nil)
    eq(err, "download failed (301)")
    eq(#requests, 1, "no manual follow for 301")
end)

t.done()
