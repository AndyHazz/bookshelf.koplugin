-- tests/_test_http.lua
-- lib/bookshelf_http.getJSON: the shared luasocket-then-curl JSON GET that
-- replaced five divergent copies. Asserts the per-caller knobs (user agent,
-- Accept, socket timeouts, curl bounds) actually reach the wire, and that
-- both legs stay bounded - the unbounded curl fallback was a confirmed
-- UI-freeze finding.
package.path = "./?.lua;./?/init.lua;" .. package.path

local t = dofile("tests/_helpers.lua").runner()

-- ── LuaSocket leg stubs ─────────────────────────────────────────────────────
local http_state = { code = 200, body = '{"ok":true}' }
local seen = {}   -- last request: url, headers, timeouts

package.loaded["json"] = {
    decode = function(s)
        if s == '{"ok":true}' then return { ok = true } end
        error("unparseable: " .. tostring(s))
    end,
}
package.loaded["socket"] = {
    skip = function(n, ...) return select(n + 1, ...) end,
}
package.loaded["socketutil"] = {
    LARGE_BLOCK_TIMEOUT = 10, LARGE_TOTAL_TIMEOUT = 30,
    set_timeout = function(self, block, total)
        seen.block, seen.total = block, total
    end,
    reset_timeout = function() end,
}
package.loaded["ltn12"] = {
    sink = {
        table = function(body)
            return function(chunk) if chunk then body[#body + 1] = chunk end return 1 end
        end,
    },
}
package.loaded["socket/http"] = {
    request = function(req)
        seen.url, seen.headers = req.url, req.headers
        if http_state.body then req.sink(http_state.body) end
        return 1, http_state.code, {}, "HTTP/1.1"
    end,
}

local HTTP = dofile("lib/bookshelf_http.lua")

t.test("200 decodes through the LuaSocket leg", function()
    seen = {}
    local data = HTTP.getJSON("https://api.example/x")
    assert(data and data.ok == true)
    assert(seen.url == "https://api.example/x")
end)

t.test("default UA and LARGE timeouts", function()
    seen = {}
    HTTP.getJSON("https://api.example/x")
    assert(seen.headers["User-Agent"] == "KOReader-Bookshelf", seen.headers["User-Agent"])
    assert(seen.headers["Accept"] == nil, "no Accept header unless asked")
    assert(seen.block == 10 and seen.total == 30, "LARGE_* defaults")
end)

t.test("opts.user_agent / accept / timeouts reach the request", function()
    seen = {}
    HTTP.getJSON("https://api.example/x", {
        user_agent = "KOReader-Bookshelf-Weather",
        accept = "application/vnd.github.v3+json",
        block_timeout = 2, total_timeout = 10,
    })
    assert(seen.headers["User-Agent"] == "KOReader-Bookshelf-Weather")
    assert(seen.headers["Accept"] == "application/vnd.github.v3+json")
    assert(seen.block == 2 and seen.total == 10)
end)

-- ── curl fallback ───────────────────────────────────────────────────────────
local real_popen = io.popen
local popen_cmd, popen_body

local function stub_popen()
    io.popen = function(cmd)
        popen_cmd = cmd
        return {
            read  = function() return popen_body end,
            close = function() end,
        }
    end
end

t.test("non-200 falls through to curl", function()
    http_state.code = 500
    stub_popen()
    popen_body = '{"ok":true}'
    local data = HTTP.getJSON("https://api.example/x")
    assert(data and data.ok == true, "curl leg must supply the result")
    assert(popen_cmd:find("'https://api.example/x'", 1, true)
        or popen_cmd:find('"https://api.example/x"', 1, true), popen_cmd)
    io.popen = real_popen
    http_state.code = 200
end)

t.test("curl leg is bounded and carries the headers", function()
    http_state.code = 500
    stub_popen()
    popen_body = '{"ok":true}'
    HTTP.getJSON("https://api.example/x", {
        user_agent = "UA-X", accept = "application/foo",
        curl_connect_timeout = 7, curl_max_time = 21,
    })
    assert(popen_cmd:find("--connect-timeout 7", 1, true), popen_cmd)
    assert(popen_cmd:find("--max-time 21", 1, true), popen_cmd)
    assert(popen_cmd:find("User-Agent: UA-X", 1, true), popen_cmd)
    assert(popen_cmd:find("Accept: application/foo", 1, true), popen_cmd)
    io.popen = real_popen
    http_state.code = 200
end)

t.test("curl defaults: --connect-timeout 5 --max-time 15", function()
    http_state.code = 500
    stub_popen()
    popen_body = '{"ok":true}'
    HTTP.getJSON("https://api.example/x")
    assert(popen_cmd:find("--connect-timeout 5", 1, true), popen_cmd)
    assert(popen_cmd:find("--max-time 15", 1, true), popen_cmd)
    io.popen = real_popen
    http_state.code = 200
end)

t.test("empty curl body -> nil (no decode attempt)", function()
    http_state.code = 500
    stub_popen()
    popen_body = ""
    assert(HTTP.getJSON("https://api.example/x") == nil)
    io.popen = real_popen
    http_state.code = 200
end)

t.test("undecodable body on both legs -> nil", function()
    http_state.body = "<html>gateway error</html>"
    stub_popen()
    popen_body = "<html>gateway error</html>"
    assert(HTTP.getJSON("https://api.example/x") == nil)
    io.popen = real_popen
    http_state.body = '{"ok":true}'
end)

t.test("LuaSocket absent entirely -> curl leg still works", function()
    -- Force the four-module pcall-require to fail on the first one.
    package.loaded["socket/http"] = nil
    package.preload["socket/http"] = function() error("no luasocket") end
    stub_popen()
    popen_body = '{"ok":true}'
    local data = HTTP.getJSON("https://api.example/x")
    assert(data and data.ok == true)
    io.popen = real_popen
    package.preload["socket/http"] = nil
end)

-- ── shell quoting (the curl leg builds a shell command string) ───────────────
-- string.format("%q") is a LUA quote, not a shell quote: it emits a
-- DOUBLE-quoted string and leaves $ and backticks alone, so /bin/sh expands
-- them. Any URL carrying remote-controlled text (a geocoding lat/lon, a trivia
-- API token) then becomes command execution on builds that take the curl leg.
t.test("curl leg single-quotes the URL so the shell cannot expand it", function()
    http_state.code = 500
    stub_popen()
    popen_body = '{"ok":true}'
    HTTP.getJSON("https://api.example/x?q=$(id)`whoami`")
    assert(popen_cmd:find("'https://api.example/x?q=$(id)`whoami`'", 1, true),
        "URL must be single-quoted: " .. tostring(popen_cmd))
    assert(not popen_cmd:find('"https://api.example', 1, true),
        "URL must not be double-quoted: " .. tostring(popen_cmd))
    io.popen = real_popen
    http_state.code = 200
end)

t.test("curl leg escapes a single quote inside the URL", function()
    http_state.code = 500
    stub_popen()
    popen_body = '{"ok":true}'
    HTTP.getJSON("https://api.example/x?q=a'b")
    assert(popen_cmd:find([[?q=a'\''b']], 1, true),
        "embedded quote must close/escape/reopen: " .. tostring(popen_cmd))
    io.popen = real_popen
    http_state.code = 200
end)

t.test("header values are escaped, not just wrapped in literal quotes", function()
    http_state.code = 500
    stub_popen()
    popen_body = '{"ok":true}'
    -- A quote in the value breaks hand-written 'User-Agent: %s' quoting and
    -- lets the rest of the value out of the quoted context.
    HTTP.getJSON("https://api.example/x", { user_agent = "UA'$(id)" })
    assert(not popen_cmd:find("UA'$(id)", 1, true),
        "raw quote reached the command line: " .. tostring(popen_cmd))
    assert(popen_cmd:find([[UA'\''$(id)]], 1, true),
        "value must be quote-escaped: " .. tostring(popen_cmd))
    io.popen = real_popen
    http_state.code = 200
end)

-- The decisive one: hand the argument the module actually composed to a REAL
-- shell and prove no substitution happened. Recovery is quote-agnostic (last
-- whitespace-delimited token) so that against the old %q this fails because
-- the shell EXPANDED the argument, not because the quote style changed.
t.test("REAL shell does not expand $(...) in the composed URL argument", function()
    http_state.code = 500
    stub_popen()
    popen_body = '{"ok":true}'
    local marker = "https://api.example/x?q=$(id)"  -- no spaces: one shell token
    HTTP.getJSON(marker)
    io.popen = real_popen
    http_state.code = 200

    local arg = popen_cmd:match("(%S+)%s*$")
    assert(arg, "could not recover the URL argument from: " .. tostring(popen_cmd))
    local h = real_popen("printf '%s' " .. arg)
    local got = h:read("*a"); h:close()
    assert(got == marker,
        "shell EXPANDED the argument: expected the literal " .. marker
        .. " but got " .. tostring(got))
end)

t.done()
