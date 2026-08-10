-- bookshelf_cover_fetch.lua
-- Generic, source-agnostic network primitives for the Cover picker's online
-- search: a JSON GET, a binary download to a file, a Wi-Fi gate. No knowledge
-- of any specific API -- bookshelf_cover_sources builds the URLs. Modelled on
-- bookshelf_hardcover._downloadImage (User-Agent, socketutil timeouts, atomic
-- tmp->rename). KOReader's patched socket/http resolves https transparently
-- (its SCHEMES table routes https through ssl.https), so both schemes work
-- through the one require.

local DataStorage = require("datastorage")
local lfs         = require("libs/libkoreader-lfs")
local logger      = require("logger")

local CoverFetch = {}

function CoverFetch.cacheDir()
    return DataStorage:getSettingsDir() .. "/bookshelf_covers"
end

-- Online downloads are TRANSIENT (a chosen cover is copied into the book's .sdr
-- on apply, so nothing here is load-bearing). Keep them under one "online" tree,
-- per book, so the whole lot can be wiped at the start of each search -- bounding
-- disk use to a single search's worth rather than accumulating forever.
local function _onlineRoot()
    return CoverFetch.cacheDir() .. "/online"
end

function CoverFetch.onlineDir(book_fp)
    return _onlineRoot() .. "/" .. tostring(book_fp):gsub("[^%w_.-]", "_")
end

-- Recursively delete the online cache (two levels: online/<book>/<files>).
function CoverFetch.resetOnlineCache()
    local root = _onlineRoot()
    if lfs.attributes(root, "mode") ~= "directory" then return end
    local ok_iter, iter, dobj = pcall(lfs.dir, root)
    if not ok_iter then return end
    for sub in iter, dobj do
        if sub ~= "." and sub ~= ".." then
            local p = root .. "/" .. sub
            if lfs.attributes(p, "mode") == "directory" then
                local ok2, it2, d2 = pcall(lfs.dir, p)
                if ok2 then
                    for f in it2, d2 do
                        if f ~= "." and f ~= ".." then pcall(os.remove, p .. "/" .. f) end
                    end
                end
                pcall(lfs.rmdir, p)
            else
                pcall(os.remove, p)
            end
        end
    end
    pcall(lfs.rmdir, root)
end

-- Shared recursive, pcall-hardened helper (lib/bookshelf_fs); mkdir -p
-- semantics kept - the online/<book> path is two levels deep.
local function _ensureDir(dir)
    return require("lib/bookshelf_fs").ensureDir(dir)
end

-- runWhenOnline(fn[, on_error]) -> ok
-- Ensure connectivity (prompting the user to enable Wi-Fi if needed) then run
-- fn. Never forces a silent connection. Mirrors Hardcover._runWhenOnline.
function CoverFetch.runWhenOnline(fn, on_error)
    local ok_net, NetworkMgr = pcall(require, "ui/network/manager")
    if ok_net and NetworkMgr and type(NetworkMgr.runWhenOnline) == "function" then
        local ok_run = pcall(function()
            NetworkMgr:runWhenOnline(function()
                local ok, err = pcall(fn)
                if not ok and on_error then on_error(tostring(err)) end
            end)
        end)
        if ok_run then return true end
    end
    local ok, err = pcall(fn)
    if not ok then
        if on_error then on_error(tostring(err)) end
        return false, err
    end
    return true
end

-- Shared GET. Returns the response body string (or nil, err). accept: an
-- optional Accept header value.
local function _requestString(url, accept)
    local ok_req, http, ltn12, socket, socketutil = pcall(function()
        return require("socket/http"),
               require("ltn12"),
               require("socket"),
               require("socketutil")
    end)
    if not ok_req then return nil, "socket unavailable" end
    local chunks = {}
    local ok, code = pcall(function()
        socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
        local c = socket.skip(1, http.request({
            url = url, method = "GET",
            headers = {
                ["User-Agent"] = "KOReader-Bookshelf",
                ["Accept"] = accept or "*/*",
            },
            sink = ltn12.sink.table(chunks),
            redirect = true,
        }))
        socketutil:reset_timeout()
        return c
    end)
    pcall(function() socketutil:reset_timeout() end)
    if not ok then return nil, "request failed" end
    if code ~= 200 then return nil, "http " .. tostring(code) end
    return table.concat(chunks)
end

-- getJson(url) -> table|nil, err
function CoverFetch.getJson(url)
    local body, err = _requestString(url, "application/json")
    if not body then return nil, err end
    local ok_json, json = pcall(require, "rapidjson")
    if not (ok_json and json and json.decode) then return nil, "no json decoder" end
    local ok_dec, decoded = pcall(json.decode, body)
    if not ok_dec or type(decoded) ~= "table" then return nil, "json decode failed" end
    return decoded
end

-- Pure-Lua base64 decode (no luasocket `mime` dependency, which is a C module
-- not always resolvable and impossible to unit-test standalone). Used only for
-- inline data: cover URIs, which are small thumbnails, so integer arithmetic
-- per 4-char group is plenty fast. Ignores whitespace/newlines and honours
-- "=" padding. Exposed on the module so it can be tested directly.
local _B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local _b64rev
function CoverFetch._base64decode(s)
    if type(s) ~= "string" then return nil end
    if not _b64rev then
        _b64rev = {}
        for i = 1, #_B64 do _b64rev[_B64:sub(i, i)] = i - 1 end
    end
    s = s:gsub("[^A-Za-z0-9+/=]", "")
    local out, i, n = {}, 1, #s
    while i <= n do
        local c1 = _b64rev[s:sub(i, i)]
        local c2 = _b64rev[s:sub(i + 1, i + 1)]
        local ch3, ch4 = s:sub(i + 2, i + 2), s:sub(i + 3, i + 3)
        local c3, c4 = _b64rev[ch3], _b64rev[ch4]
        i = i + 4
        if not c1 or not c2 then break end
        out[#out + 1] = string.char((c1 * 4 + math.floor(c2 / 16)) % 256)
        if ch3 ~= "=" and c3 then
            out[#out + 1] = string.char(((c2 % 16) * 16 + math.floor(c3 / 4)) % 256)
            if ch4 ~= "=" and c4 then
                out[#out + 1] = string.char(((c3 % 4) * 64 + c4) % 256)
            end
        end
    end
    return table.concat(out)
end

-- download(url, dest_path[, user, password]) -> path|nil, err
-- Fetch a binary resource to dest_path atomically (tmp then rename). Creates the
-- parent directory if needed. Overwrites any existing dest_path.
--
-- user/password are OPTIONAL HTTP basic-auth credentials, handed straight to
-- http.request the way OpdsFeed.fetch does. Password-protected OPDS catalogues
-- 401 an anonymous thumbnail GET, so without them covers never appear. Both are
-- needed for luasocket to build the Authorization header; omitting them (the
-- non-OPDS callers) leaves the request exactly as it was.
--
-- opts (OPTIONAL) = { block_timeout = n, total_timeout = n } overrides the
-- socketutil LARGE pair for this one request. The cover picker's download is a
-- single, user-initiated, progress-backed fetch and keeps the generous default;
-- the OPDS thumbnail fill is a serial batch on the main loop and asks for a
-- much tighter budget so an unresponsive server cannot freeze the shelf.
function CoverFetch.download(url, dest_path, user, password, opts)
    if type(url) ~= "string" or url == "" or type(dest_path) ~= "string" then
        return nil, "bad args"
    end
    local auth_user = (type(user) == "string" and user ~= "") and user or nil
    local auth_pass = (type(password) == "string" and password ~= "") and password or nil
    local parent = dest_path:match("^(.*)/[^/]+$")
    if not _ensureDir(parent) then return nil, "cache dir unavailable" end

    -- Inline data: URI. Some OPDS feeds (Project Gutenberg's category/search
    -- feeds are the common case) embed the cover thumbnail directly in the
    -- feed as data:<mime>[;base64],<payload> instead of linking it. There is
    -- nothing to fetch: decode the payload and write it straight to the cache.
    -- MUST precede the HTTP path -- KOReader's socket/http has no "data"
    -- scheme and throws indexing its scheme table, which is exactly why these
    -- covers never appeared (every passive fetch failed fast, so only a tap's
    -- separate path ever produced one).
    local data_spec, data_body = url:match("^data:([^,]*),(.*)$")
    if data_spec then
        local bytes
        if data_spec:find("base64", 1, true) then
            bytes = CoverFetch._base64decode(data_body)
        else
            bytes = (data_body:gsub("%%(%x%x)", function(h)
                return string.char(tonumber(h, 16))
            end))
        end
        if type(bytes) ~= "string" or bytes == "" then return nil, "empty data uri" end
        local dtmp = dest_path .. ".tmp"
        local df = io.open(dtmp, "wb")
        if not df then return nil, "cannot open temp file" end
        df:write(bytes)
        df:close()
        pcall(os.remove, dest_path)
        if not os.rename(dtmp, dest_path) then
            pcall(os.remove, dtmp)
            return nil, "rename failed"
        end
        return dest_path
    end

    local ok_req, http, ltn12, socket, socketutil = pcall(function()
        return require("socket/http"),
               require("ltn12"),
               require("socket"),
               require("socketutil")
    end)
    if not ok_req then return nil, "socket unavailable" end

    local tmp = dest_path .. ".tmp"
    local file = io.open(tmp, "wb")
    if not file then return nil, "cannot open temp file" end
    local block_t = (opts and opts.block_timeout) or socketutil.LARGE_BLOCK_TIMEOUT
    local total_t = (opts and opts.total_timeout) or socketutil.LARGE_TOTAL_TIMEOUT
    local ok_req2, code = pcall(function()
        socketutil:set_timeout(block_t, total_t)
        local c = socket.skip(1, http.request({
            url = url, method = "GET",
            headers = { ["User-Agent"] = "KOReader-Bookshelf" },
            sink = ltn12.sink.file(file),
            redirect = true,
            user = auth_user,
            password = auth_pass,
        }))
        socketutil:reset_timeout()
        return c
    end)
    pcall(function() socketutil:reset_timeout() end)
    if not ok_req2 or code ~= 200 then
        pcall(os.remove, tmp)
        return nil, "download failed (" .. tostring(code) .. ")"
    end
    pcall(os.remove, dest_path)
    if not os.rename(tmp, dest_path) then
        pcall(os.remove, tmp)
        return nil, "rename failed"
    end
    return dest_path
end

return CoverFetch
