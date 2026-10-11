-- OPDS feed and cover redirects, through the real fetch functions: Basic auth
-- follows a redirect to the same origin (and the same host's http -> https
-- upgrade), never to another host or port, and unsafe targets are refused.
--
-- socket.url is KOReader's real url.lua when it can be found (BOOKSHELF_SOCKET_URL,
-- or a desktop KOReader install), so parse/absolute are the ones the device
-- runs; otherwise fixed fixtures stand in for them.
--
-- Adapted from the test in Robin Bolinsson's fork (komadorirobin).
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t, eq = helpers.runner(), helpers.eq
local root = "https://catalog.test/opds"
local same = "https://catalog.test/opds/"
local foreign = "https://cdn.test/cover"
local plain_root = "http://catalog.test/opds"
local upgraded = "https://catalog.test/opds/"
local dest = "/cache/cover.jpg"
local requests, responses, files, resets, timeouts

package.loaded["socket"] = {
    skip = function(n, ...) return select(n + 1, ...) end,
    url = {},
}
local fixtures = {
    [root] = { scheme = "https", host = "catalog.test" },
    [same] = { scheme = "https", host = "catalog.test" },
    [foreign] = { scheme = "https", host = "cdn.test" },
    [plain_root] = { scheme = "http", host = "catalog.test" },
    ["https://CATALOG.test:443/opds/"] = { scheme = "https", host = "CATALOG.test", port = "443" },
    ["https://catalog.test:8443/opds/"] = { scheme = "https", host = "catalog.test", port = "8443" },
    ["https://catalog.test:8443/x"] = { scheme = "https", host = "catalog.test", port = "8443" },
    ["http://catalog.test/opds/"] = { scheme = "http", host = "catalog.test" },
    ["http://catalog.test:8080/opds"] = { scheme = "http", host = "catalog.test", port = "8080" },
    ["https://evil.test/opds/"] = { scheme = "https", host = "evil.test" },
    ["ftp://catalog.test/opds/"] = { scheme = "ftp", host = "catalog.test" },
    ["file:///etc/passwd"] = { scheme = "file" },
    ["https://other:secret@catalog.test/opds/"] = {
        scheme = "https", host = "catalog.test", userinfo = "other:secret",
    },
}
local url_path = os.getenv("BOOKSHELF_SOCKET_URL")
if not url_path then
    local f = io.open("/usr/lib/koreader/common/socket/url.lua", "r")
    if f then f:close(); url_path = "/usr/lib/koreader/common/socket/url.lua" end
end
package.loaded["socket.url"] = url_path and dofile(url_path) or {
    parse = function(url) return fixtures[url] end,
    absolute = function(base, location)
        if location == "/opds/" then return (base:gsub("^(%a+://[^/]+).*$", "%1")) .. "/opds/" end
        if location == "//cdn.test/cover" then return foreign end
        if location == "../opds/" then return same end
        return location
    end,
    unescape = function(s)
        return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
    end,
}
print("socket.url: " .. (url_path or "fixtures"))
package.loaded["mime"] = { b64 = function(s) return "encoded:" .. s end }
package.loaded["datastorage"] = { getSettingsDir = function() return "/cache" end }
package.loaded["logger"] = { dbg = function() end, warn = function() end, info = function() end }
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(path, key)
        if path == "/cache" then return key and "directory" or { mode = "directory" } end
    end,
}
package.loaded["socketutil"] = {
    LARGE_BLOCK_TIMEOUT = 10, LARGE_TOTAL_TIMEOUT = 30,
    set_timeout = function(_, block, total) timeouts[#timeouts + 1] = { block, total } end,
    reset_timeout = function() resets = resets + 1 end,
}
package.loaded["ltn12"] = { sink = {
    table = function(out)
        return function(chunk)
            if chunk then out[#out + 1] = chunk end
            return 1
        end
    end,
    file = function(file)
        return function(chunk)
            if chunk then return file:write(chunk) end
            file:close()
            return 1
        end
    end,
} }
local real_open = io.open
io.open = function(path, mode)
    if path ~= dest .. ".tmp" or mode ~= "wb" then return real_open(path, mode) end
    files[path] = ""
    local closed = false
    return {
        write = function(_, chunk)
            assert(not closed, "writing a closed file")
            files[path] = files[path] .. chunk
            return 1
        end,
        close = function()
            if closed then error("file already closed") end
            closed = true
        end,
    }
end
os.remove = function(path) files[path] = nil; return true end
os.rename = function(from, to)
    assert(files[from] ~= nil)
    files[to], files[from] = files[from], nil
    return true
end
package.loaded["socket.http"] = { request = function(req)
    requests[#requests + 1] = req
    assert(req.redirect == false, "automatic redirects can leak Authorization")
    local response = assert(responses[req.url], "unexpected URL: " .. req.url)
    if response.raise then error("transport failure") end
    req.sink(response.body or "redirect body")
    req.sink(nil)
    return 1, response.code or 200, { location = response.location }, "status"
end }

local Http = require("lib/bookshelf_http")
local Feed = require("lib/bookshelf_opds_feed")
local Cover = require("lib/bookshelf_cover_fetch")
local opts = { block_timeout = 2, total_timeout = 4 }
local function reset()
    requests, responses, files, resets, timeouts = {}, {}, { [dest] = "previous" }, 0, {}
    Feed.clearPacing()
end
local function fetch(kind, from)
    from = from or root
    if kind == "feed" then return Feed.fetch(from, "user", "p%40ss", opts) end
    return Cover.download(from, dest, "user", "p%40ss", opts)
end
local function auth(index, expected)
    local req = assert(requests[index])
    eq(req.user, expected and "user" or nil)
    eq(req.password, expected and "p%40ss" or nil)
    eq(req.headers.Authorization, expected and "Basic encoded:user:p@ss" or nil)
end
local function success(kind, result)
    eq(result, kind == "feed" and "payload" or dest)
    if kind == "cover" then
        eq(files[dest], "payload", "redirect body must not enter the final image")
        eq(files[dest .. ".tmp"], nil)
    end
    assert(resets >= #requests, "every hop resets global timeouts")
    for _, timeout in ipairs(timeouts) do
        eq(timeout[1], 2); eq(timeout[2], 4)
    end
end

for _, kind in ipairs({ "feed", "cover" }) do
    for _, code in ipairs({ 301, 302, 303, 307, 308 }) do
        t.test(kind .. " keeps same-origin auth on " .. code, function()
            reset()
            responses[root] = { code = code, location = "/opds/" }
            responses[same] = { body = "payload" }
            success(kind, fetch(kind))
            eq(#requests, 2); auth(1, true); auth(2, true)
        end)
    end
    t.test(kind .. " keeps auth on the same host's http -> https upgrade", function()
        reset()
        responses[plain_root] = { code = 301, location = upgraded }
        responses[upgraded] = { body = "payload" }
        success(kind, fetch(kind, plain_root))
        auth(1, true); auth(2, true)
    end)
    t.test(kind .. " drops auth on an upgrade from a non-default port", function()
        reset()
        local from = "http://catalog.test:8080/opds"
        responses[from] = { code = 301, location = upgraded }
        responses[upgraded] = { body = "payload" }
        success(kind, fetch(kind, from))
        auth(1, true); auth(2, false)
    end)
    t.test(kind .. " drops auth across origins, including a return hop", function()
        reset()
        responses[root] = { code = 302, location = "//cdn.test/cover" }
        responses[foreign] = { code = 307, location = same }
        responses[same] = { body = "payload" }
        success(kind, fetch(kind))
        auth(1, true); auth(2, false); auth(3, false)
    end)
    t.test(kind .. " drops auth on an https host change", function()
        reset()
        local target = "https://evil.test/opds/"
        responses[root] = { code = 302, location = target }
        responses[target] = { body = "payload" }
        success(kind, fetch(kind)); auth(2, false)
    end)
    t.test(kind .. " drops auth on a port change", function()
        reset()
        local target = "https://catalog.test:8443/opds/"
        responses[root] = { code = 302, location = target }
        responses[target] = { body = "payload" }
        success(kind, fetch(kind)); auth(2, false)
    end)
    t.test(kind .. " refuses unsafe redirect targets", function()
        for _, target in ipairs({ "http://catalog.test/opds/", "ftp://catalog.test/opds/",
                "file:///etc/passwd", "https://other:secret@catalog.test/opds/", "\n", "" }) do
            reset()
            responses[root] = { code = 302, location = target }
            local result, err = fetch(kind)
            eq(result, nil); eq(err, "unsafe redirect", target); eq(#requests, 1)
            eq(files[dest], "previous"); eq(files[dest .. ".tmp"], nil)
        end
    end)
    t.test(kind .. " bounds redirect loops", function()
        reset()
        responses[root] = { code = 302, location = root }
        local result, err = fetch(kind)
        eq(result, nil); eq(err, "too many redirects")
        eq(#requests, Http.MAX_REDIRECTS + 1)
        eq(files[dest], "previous"); eq(files[dest .. ".tmp"], nil)
    end)
    t.test(kind .. " keeps rate-limit handling after a redirect", function()
        reset()
        responses[root] = { code = 302, location = same }
        responses[same] = { code = 429 }
        local result, err = fetch(kind)
        eq(result, nil); eq(err, "ratelimited")
        eq(files[dest], "previous"); eq(files[dest .. ".tmp"], nil)
        if kind == "feed" then assert(Feed.paceFor(root) > 0) end
    end)
    t.test(kind .. " resets timeouts after a redirected request throws", function()
        reset()
        responses[root] = { code = 302, location = same }
        responses[same] = { raise = true }
        eq(fetch(kind), nil)
        assert(resets >= #requests)
        eq(files[dest], "previous"); eq(files[dest .. ".tmp"], nil)
    end)
end

t.test("default ports and host case preserve the origin", function()
    local target, keep = Http.redirectTarget(root, "https://CATALOG.test:443/opds/")
    eq(target, "https://CATALOG.test:443/opds/"); eq(keep, true)
    target, keep = Http.redirectTarget(root, "../opds/")
    eq(target, same); eq(keep, true)
end)
t.test("an upgrade to a non-default https port is not the same origin", function()
    local target, keep = Http.redirectTarget(plain_root, "https://catalog.test:8443/x")
    eq(target, "https://catalog.test:8443/x"); eq(keep, false)
end)
t.done()
