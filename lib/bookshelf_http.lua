-- lib/bookshelf_http.lua
-- Shared blocking JSON GET: LuaSocket first, curl fallback for platforms
-- where LuaSocket's SSL crashes (Android, some desktops). This was copied
-- (divergently) into four micromodules and bookshelf_updater; the copies had
-- already drifted on timeouts and on whether the curl fallback was bounded.
--
-- Still BLOCKING - callers own keeping it off latency-sensitive paths (the
-- micromodules gate implicit fetches on an existing connection; user-initiated
-- paths run behind runWhenOnline). Both legs are bounded: socketutil timeouts
-- on the LuaSocket leg, --connect-timeout/--max-time on the curl leg (an
-- unbounded curl read blocks the UI loop indefinitely on a blackholing
-- server).
--
--   M.getJSON(url, opts) -> decoded table | nil
--   M.shellQuote(s)      -> s quoted for /bin/sh (the curl leg builds a
--                           command string, so every interpolated value
--                           must go through this, never string.format %q)
--     opts.user_agent            default "KOReader-Bookshelf"
--     opts.accept                optional Accept header
--     opts.block_timeout         seconds, default socketutil.LARGE_BLOCK_TIMEOUT
--     opts.total_timeout         seconds, default socketutil.LARGE_TOTAL_TIMEOUT
--     opts.curl_connect_timeout  seconds, default 5
--     opts.curl_max_time         seconds, default 15

local M = {}

--- Quote one argument for /bin/sh.
-- string.format("%q") is a LUA quote, not a shell quote: it emits a
-- DOUBLE-quoted string and leaves $ and backticks for the shell to expand, so
-- a URL carrying remote-controlled text (Open-Meteo's lat/lon, a trivia API
-- token) became command execution on any build that takes the curl leg.
-- Single quotes expand nothing, so the only character needing care is the
-- quote itself: close, emit an escaped literal quote, reopen.
-- basicAuthHeader(user, password) -> the Authorization value, or nil.
--
-- We build this ourselves rather than leaving it to luasocket's reqt.user /
-- reqt.password, because luasocket LOSES IT ON A REDIRECT (issue 434).
--
-- adjustheaders() computes the header into a table it creates, and assigns
-- that to nreqt.headers. On a 3xx, trequest calls tredirect(reqt, location)
-- with the ORIGINAL request and rebuilds the follow-up from
-- `headers = reqt.headers` -- our table, which never had the Authorization in
-- it -- while passing no user and no password at all. So the second request
-- goes out unauthenticated and the server answers 401.
--
-- Measured against a mock doing Flask's classic /opds -> /opds/ redirect:
--
--     curl -L :  /opds auth=YES   /opds/ auth=YES    -> 200
--     ours    :  /opds auth=YES   /opds/ auth=NONE   -> 401, err "auth"
--
-- Putting it in the caller's own headers table fixes both hops: adjustheaders
-- lowercases and overlays reqt.headers over its own defaults, so ours wins on
-- the first request, and tredirect forwards that same table on to the second.
--
-- url.unescape on the password is luasocket's own behaviour
-- (`mime.b64(reqt.user .. ":" .. url.unescape(reqt.password))`), mirrored
-- deliberately. It mangles a password containing a literal %, but this change
-- is about redirects; altering how a password is encoded would silently break
-- every catalog that authenticates today, and belongs in its own change.
--
-- Both halves or nothing, matching luasocket's `if reqt.user and reqt.password`,
-- so a catalog with no credentials sends no header rather than "Basic Og==".
function M.basicAuthHeader(user, password)
    if type(user) ~= "string" or type(password) ~= "string" then return nil end
    if user == "" or password == "" then return nil end
    local ok, mime = pcall(require, "mime")
    local ok_url, url = pcall(require, "socket.url")
    if not (ok and mime and ok_url and url) then return nil end
    return "Basic " .. mime.b64(user .. ":" .. url.unescape(password))
end

function M.shellQuote(s)
    local escaped = tostring(s or ""):gsub("'", "'\\''")
    return "'" .. escaped .. "'"
end

function M.getJSON(url, opts)
    opts = opts or {}
    local json = require("json")
    local user_agent = opts.user_agent or "KOReader-Bookshelf"
    local ok_require, http, ltn12, socket, socketutil = pcall(function()
        return require("socket.http"), require("ltn12"),
               require("socket"), require("socketutil")
    end)
    if ok_require then
        local body = {}
        local headers = { ["User-Agent"] = user_agent }
        if opts.accept then headers["Accept"] = opts.accept end
        local ok_req, code = pcall(function()
            socketutil:set_timeout(
                opts.block_timeout or socketutil.LARGE_BLOCK_TIMEOUT,
                opts.total_timeout or socketutil.LARGE_TOTAL_TIMEOUT)
            local c = socket.skip(1, http.request({
                url = url,
                method = "GET",
                headers = headers,
                sink = ltn12.sink.table(body),
                redirect = true,
            }))
            socketutil:reset_timeout()
            return c
        end)
        pcall(function() socketutil:reset_timeout() end)
        if ok_req and code == 200 then
            local ok, data = pcall(json.decode, table.concat(body))
            if ok then return data end
        end
    end
    local accept_arg = opts.accept
        and (" -H " .. M.shellQuote("Accept: " .. opts.accept)) or ""
    local handle = io.popen(string.format(
        "curl -s -L --connect-timeout %d --max-time %d -H %s%s %s",
        opts.curl_connect_timeout or 5, opts.curl_max_time or 15,
        M.shellQuote("User-Agent: " .. user_agent), accept_arg,
        M.shellQuote(url)))
    if handle then
        local body = handle:read("*a")
        handle:close()
        if body and body ~= "" then
            local ok, data = pcall(json.decode, body)
            if ok then return data end
        end
    end
    return nil
end

return M
