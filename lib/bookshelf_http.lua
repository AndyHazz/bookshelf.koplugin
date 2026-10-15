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
-- But tredirect forwards it to ANY host, so a catalog (or anything able to
-- answer for it) could send the password on to a server of its choosing with
-- one 302. A request carrying this header must therefore never use automatic
-- redirects: pass redirect = false and follow each hop yourself, keeping the
-- credentials only when redirectTarget says the target is the same origin.
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

-- Hops a manually followed redirect chain may take before giving up.
M.MAX_REDIRECTS = 5

-- A response body held in memory (a feed, JSON, a cover) stops here: a server
-- that keeps sending, broken or hostile, would otherwise fill the reader's
-- memory. Far above any real one (a few hundred kB; a big unpaged calibre feed
-- a few MB).
M.MAX_BODY = 16 * 1024 * 1024

-- cappedSink(t, max) -> an ltn12 sink like ltn12.sink.table(t) that aborts
-- the transfer, "response too large", once more than max bytes have come.
function M.cappedSink(t, max)
    max = max or M.MAX_BODY
    local n = 0
    return function(chunk, err)
        if chunk then
            n = n + #chunk
            if n > max then return nil, "response too large" end
            t[#t + 1] = chunk
        end
        return 1
    end
end

function M.isRedirect(code)
    return code == 301 or code == 302 or code == 303
        or code == 307 or code == 308
end

local DEFAULT_PORT = { http = 80, https = 443 }

-- redirectTarget(source, location) -> target, keep_auth | nil
-- Resolves a 3xx Location against the url that answered with it, and says
-- whether credentials may go along. nil means do not follow at all: a
-- non-http(s) scheme, an https -> http downgrade, credentials embedded in the
-- target, control characters, or anything that does not parse.
--
-- keep_auth is true for the same origin (scheme, host, port; host case and
-- default ports ignored), and for the one safe change of origin: the same
-- host upgrading http on its default port to https on its default port. A
-- catalog saved as http:// whose server now insists on https would otherwise
-- start failing with "Authentication failed" the day this landed.
function M.redirectTarget(source, location)
    if type(source) ~= "string" or type(location) ~= "string"
            or location == "" or location:find("[%z%c]") then
        return nil
    end
    local ok, url = pcall(require, "socket.url")
    if not (ok and url) then return nil end
    local target = url.absolute(source, location)
    local from, to = url.parse(source), url.parse(target)
    if not (from and to and to.host and to.host ~= "") then return nil end
    local from_scheme = (from.scheme or ""):lower()
    local to_scheme = (to.scheme or ""):lower()
    if to_scheme ~= "http" and to_scheme ~= "https" then return nil end
    if from_scheme == "https" and to_scheme ~= "https" then return nil end
    if to.userinfo or to.user or to.password then return nil end
    local from_port = tonumber(from.port) or DEFAULT_PORT[from_scheme]
    local to_port = tonumber(to.port) or DEFAULT_PORT[to_scheme]
    local keep = (from.host or ""):lower() == to.host:lower() and (
        (from_scheme == to_scheme and from_port == to_port)
        or (from_scheme == "http" and to_scheme == "https"
            and from_port == 80 and to_port == 443))
    return target, keep
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
                sink = M.cappedSink(body),
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
