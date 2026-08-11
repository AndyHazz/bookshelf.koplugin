-- tests/_test_update_routing.lua
-- Which updater call "Check for updates" makes, and which one the Developer
-- updates row makes.
--
-- The bug this pins: checkForUpdates used to divert to installBranch whenever
-- dev_branch was set. A branch name typed once to test a fix is never cleared,
-- so those users' "Check for updates" stopped checking releases for good - and
-- because the background check ignores dev_branch, they were told an update
-- existed and then silently got the branch reinstalled, restoring its version
-- so the notification returned on the next check. Only "Reset to latest stable
-- release" escaped, being the one path that cleared dev_branch.
--
-- Both methods live on the plugin table in main.lua, which cannot be loaded
-- standalone (it pulls the whole KOReader FM stack), so this extracts the two
-- functions' bodies by name and runs them against a stub plugin + updater. The
-- extraction is checked, so a rename fails the test rather than silently
-- passing.
package.path = "./?.lua;./?/init.lua;" .. package.path

local t = dofile("tests/_helpers.lua").runner()

local src = io.open("main.lua"):read("*a")

local function extract(name)
    local pat = "\nfunction Bookshelf:" .. name .. "%(%)\n(.-)\nend\n"
    local body = src:match(pat)
    assert(body, "could not find Bookshelf:" .. name .. "() in main.lua")
    return body
end

-- Compile a body with `self` and a stub environment in scope. Works under both
-- the harness's Lua 5.4 (load with an env argument) and the LuaJIT 5.1 the
-- plugin actually runs on (loadstring + setfenv), so this test is not tied to
-- whichever interpreter runs the suite.
local function compile(code, name, env)
    if _G.setfenv then                       -- Lua 5.1 / LuaJIT
        local f = assert(_G.loadstring(code, name))
        _G.setfenv(f, env)
        return f
    end
    return assert(load(code, name, "t", env))  -- 5.2+
end

-- Run one method body against a stub plugin, recording which updater call it
-- makes and which settings it writes.
local function run(name, plugin_fields)
    local calls, saved = {}, {}
    local env
    env = {
        pairs = pairs, type = type, tostring = tostring,
        _updater = function()
            return {
                check = function(cb)
                    calls[#calls + 1] = "check"
                    if cb then cb() end
                end,
                installBranch = function(branch, cb)
                    calls[#calls + 1] = "installBranch:" .. tostring(branch)
                    if cb then cb() end
                end,
            }
        end,
        BookshelfSettings = { save = function(k, v) saved[k] = v end },
        G_reader_settings = { flush = function() end },
    }
    local self_tbl = {}
    for k, v in pairs(plugin_fields or {}) do self_tbl[k] = v end
    local function invoke(method, tbl)
        local f = compile("local self = ... ; " .. extract(method), method, env)
        return f(tbl)
    end
    -- The bodies may call each other (installDevBranch falls back to the
    -- release check), so route those through the same stub world.
    self_tbl.checkForUpdates  = function(s) return invoke("checkForUpdates", s) end
    self_tbl.installDevBranch = function(s) return invoke("installDevBranch", s) end
    invoke(name, self_tbl)
    return calls, saved, self_tbl
end

t.test("Check for updates checks RELEASES even with a dev branch set", function()
    local calls = run("checkForUpdates", { dev_branch = "fix/something" })
    assert(#calls == 1, "expected one updater call, got " .. #calls)
    assert(calls[1] == "check",
        "checkForUpdates must call Updater.check, got " .. calls[1])
end)

t.test("Check for updates checks releases with no dev branch (unchanged)", function()
    local calls = run("checkForUpdates", { dev_branch = "" })
    assert(calls[1] == "check", "got " .. tostring(calls[1]))
end)

t.test("a successful release install clears a stale dev_branch", function()
    local _calls, saved, self_tbl = run("checkForUpdates", { dev_branch = "grimmory" })
    assert(saved.last_install_source == "release",
        "install source should record the release")
    assert(saved.dev_branch == "", "dev_branch should be cleared, got "
        .. tostring(saved.dev_branch))
    assert(self_tbl.dev_branch == "", "in-memory dev_branch should be cleared too")
end)

t.test("a release install with no branch set leaves dev_branch alone", function()
    local _calls, saved = run("checkForUpdates", { dev_branch = "" })
    assert(saved.dev_branch == nil, "no needless write when nothing was set")
end)

t.test("installDevBranch installs the branch", function()
    local calls, saved = run("installDevBranch", { dev_branch = "feature/x" })
    assert(calls[1] == "installBranch:feature/x", "got " .. tostring(calls[1]))
    assert(saved.last_install_source == "branch:feature/x",
        "install source should record the branch, got "
        .. tostring(saved.last_install_source))
end)

t.test("installDevBranch with no branch falls back to the release check", function()
    -- The row that calls it reads "Check for updates" in that state, so doing
    -- nothing would be a dead tap.
    local calls = run("installDevBranch", { dev_branch = "" })
    assert(calls[1] == "check", "got " .. tostring(calls[1]))
end)

t.done()
