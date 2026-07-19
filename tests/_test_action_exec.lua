-- Unit test for lib/bookshelf_action_exec.lua: the action-entry execution
-- switch routes each entry variant to the right call. KOReader runtime modules
-- are stubbed via package.loaded before dofile.
package.path = "./?.lua;./?/init.lua;" .. package.path

local calls = {}
package.loaded["ui/uimanager"] = {
    setDirty = function() end,
    nextTick = function(_, fn) if fn then fn() end end,
}
package.loaded["logger"] = { dbg=function() end, info=function() end,
    warn=function() end, err=function() end }
package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }
package.loaded["dispatcher"] = {
    execute = function(_, action) calls.dispatch = action end,
}
package.loaded["lib/bookshelf_plugin_scan"] = {
    resolve = function(key, method)
        calls.resolve = { key = key, method = method }
        return function() calls.launched = true end
    end,
}

local Exec = dofile("lib/bookshelf_action_exec.lua")
local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()

t.test("action entry dispatches the Dispatcher table", function()
    calls = {}
    Exec.dispatch({ action = { stats_calendar_view = true } })
    assert(calls.dispatch and calls.dispatch.stats_calendar_view == true,
        "Dispatcher:execute not called with the action table")
end)

t.test("plugin entry resolves then launches", function()
    calls = {}
    Exec.dispatch({ plugin = { key = "frotz", method = "showGames" } })
    assert(calls.resolve and calls.resolve.key == "frotz"
        and calls.resolve.method == "showGames", "PluginScan.resolve args wrong")
    assert(calls.launched == true, "resolved launcher not invoked")
end)

t.test("internal close calls bw:onClose", function()
    calls = {}
    local bw = { onClose = function() calls.closed = true end }
    Exec.dispatch({ internal = "close" }, bw)
    assert(calls.closed == true, "bw:onClose not called for internal=close")
end)

t.test("teardown action (exit) closes the shelf BEFORE dispatching (#290)", function()
    calls = {}
    local order = {}
    package.loaded["dispatcher"].execute =
        function(_, action) order[#order + 1] = "dispatch"; calls.dispatch = action end
    local bw = { onClose = function() order[#order + 1] = "close" end }
    Exec.dispatch({ action = { exit = true } }, bw)
    assert(order[1] == "close" and order[2] == "dispatch",
        "exit must close the shelf before dispatching; got " .. table.concat(order, ","))
    assert(calls.dispatch and calls.dispatch.exit == true, "exit action not dispatched")
end)

t.test("non-teardown action does NOT close the shelf", function()
    calls = {}
    package.loaded["dispatcher"].execute = function(_, action) calls.dispatch = action end
    local bw = { onClose = function() calls.closed = true end }
    Exec.dispatch({ action = { toggle_wifi = true } }, bw)
    assert(not calls.closed, "a non-teardown action must not close the shelf")
    assert(calls.dispatch and calls.dispatch.toggle_wifi == true, "action not dispatched")
end)

t.test("malformed entry is a no-op (no error)", function()
    calls = {}
    Exec.dispatch({})            -- no action/plugin/internal
    Exec.dispatch("not a table") -- defensive
    assert(next(calls) == nil, "expected no calls for malformed entries")
end)

t.done()
