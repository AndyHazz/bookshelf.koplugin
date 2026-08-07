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
        requests[#requests + 1] = { url = reqt.url, user = reqt.user, password = reqt.password }
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
    LARGE_BLOCK_TIMEOUT = 10, LARGE_TOTAL_TIMEOUT = 30,
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
        { "text/plain", "txt" },
        { "text/html", "html" },
    }
    for _, c in ipairs(cases) do
        local acq = { type = c[1], href = "http://x/book" }
        eq(D.filenameFor(rec, acq), "Some Book." .. c[2], "type " .. c[1])
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

t.test("download: sets a tighter-than-default timeout is not required, but SOME timeout is set", function()
    reset()
    local url = "http://example.com/timed.epub"
    http_responses[url] = { code = 200, body = "x" }
    D.download(url, "/home/user/books/timed.epub")
    eq(#timeout_calls, 1)
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

t.done()
