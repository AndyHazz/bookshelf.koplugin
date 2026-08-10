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
--     opts.user_agent            default "KOReader-Bookshelf"
--     opts.accept                optional Accept header
--     opts.block_timeout         seconds, default socketutil.LARGE_BLOCK_TIMEOUT
--     opts.total_timeout         seconds, default socketutil.LARGE_TOTAL_TIMEOUT
--     opts.curl_connect_timeout  seconds, default 5
--     opts.curl_max_time         seconds, default 15

local M = {}

function M.getJSON(url, opts)
    opts = opts or {}
    local json = require("json")
    local user_agent = opts.user_agent or "KOReader-Bookshelf"
    local ok_require, http, ltn12, socket, socketutil = pcall(function()
        return require("socket/http"), require("ltn12"),
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
        and string.format(" -H 'Accept: %s'", opts.accept) or ""
    local handle = io.popen(string.format(
        "curl -s -L --connect-timeout %d --max-time %d -H 'User-Agent: %s'%s %q",
        opts.curl_connect_timeout or 5, opts.curl_max_time or 15,
        user_agent, accept_arg, url))
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
