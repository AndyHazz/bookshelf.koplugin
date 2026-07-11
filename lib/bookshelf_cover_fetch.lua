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

local function _ensureDir(dir)
    if not dir then return false end
    if lfs.attributes(dir, "mode") == "directory" then return true end
    local parent = dir:match("^(.*)/[^/]+$")
    if parent and lfs.attributes(parent, "mode") ~= "directory" then
        _ensureDir(parent)  -- mkdir -p: the online/<book> path is two levels deep
    end
    lfs.mkdir(dir)
    return lfs.attributes(dir, "mode") == "directory"
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

-- download(url, dest_path) -> path|nil, err
-- Fetch a binary resource to dest_path atomically (tmp then rename). Creates the
-- parent directory if needed. Overwrites any existing dest_path.
function CoverFetch.download(url, dest_path)
    if type(url) ~= "string" or url == "" or type(dest_path) ~= "string" then
        return nil, "bad args"
    end
    local parent = dest_path:match("^(.*)/[^/]+$")
    if not _ensureDir(parent) then return nil, "cache dir unavailable" end

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
    local ok_req2, code = pcall(function()
        socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
        local c = socket.skip(1, http.request({
            url = url, method = "GET",
            headers = { ["User-Agent"] = "KOReader-Bookshelf" },
            sink = ltn12.sink.file(file),
            redirect = true,
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
