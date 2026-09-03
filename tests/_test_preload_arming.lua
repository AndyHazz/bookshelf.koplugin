-- tests/_test_preload_arming.lua
-- When the next-page preload is allowed to start.
--
-- The preload waits PRELOAD_START_DELAY_S before decoding, to let the CURRENT
-- page's EPDC flush drain first. On the FIRST rebuild there is no current page:
-- nothing has been painted, so that delay lands in front of the first paint and
-- the shelf appears later. Measured on a PW5 over six runs each, time from
-- widget init to first paint: 2863ms best / ~2943ms median with the fixed
-- delay, 2535ms / ~2710ms once the preload waits for the paint. The two
-- distributions did not overlap.
--
-- Driven against the real method bodies, extracted by name and run under a stub
-- self, as _test_group_drill_kind and _test_opds_drill_restore do.
package.path = "./?.lua;./?/init.lua;" .. package.path

local t   = dofile("tests/_helpers.lua").runner()
local src = io.open("lib/bookshelf_widget.lua"):read("*a")

local function bodyOf(sig, name)
    local body = src:match("\nfunction BookshelfWidget:" .. sig .. "\n(.-)\nend\n")
    assert(body, "could not find BookshelfWidget:" .. name .. " - renamed?")
    return body
end

local function compile(code, env, name)
    if _G.setfenv then
        local f = assert(_G.loadstring(code, name))
        _G.setfenv(f, env)
        return f
    end
    return assert(load(code, name, "t", env))
end

local SCHEDULE = bodyOf("_schedulePreload%(direction%)", "_schedulePreload")
local ARM      = bodyOf("_armPendingPreload%(%)", "_armPendingPreload")
local CANCEL   = bodyOf("_cancelPreload%(%)", "_cancelPreload")

-- Records what got scheduled, so a test can prove the preload did NOT start.
local function harness(self_)
    local scheduled = {}
    local env = {
        ipairs = ipairs, pairs = pairs, type = type, tostring = tostring,
        table = table, string = string, math = math,
        PRELOAD_START_DELAY_S = 0.35,
        UIManager = {
            scheduleIn = function(_s, delay, fn)
                scheduled[#scheduled + 1] = { delay = delay, fn = fn }
            end,
            unschedule = function() end,
        },
    }
    env._G = env
    self_._cancelPreload        = function(s) compile("local self = ...\n" .. CANCEL, env, "cancel")(s) end
    self_._applyCoverCacheBudget = function() end
    self_._preloadStep          = function() end
    return env, scheduled,
        function(dir) compile("local self, direction = ...\n" .. SCHEDULE, env, "sched")(self_, dir) end,
        function() compile("local self = ...\n" .. ARM, env, "arm")(self_) end
end

t.test("before the first paint the preload is held, not scheduled", function()
    local self_ = { _first_paint_done = false }
    local _e, scheduled, schedule = harness(self_)
    schedule(1)
    assert(#scheduled == 0,
        "the preload was scheduled ahead of the first paint (" .. #scheduled .. " timers)")
    assert(self_._preload_pending, "it was dropped instead of held")
end)

t.test("the first paint starts the held preload", function()
    local self_ = { _first_paint_done = false }
    local _e, scheduled, schedule, arm = harness(self_)
    schedule(1)
    self_._first_paint_done = true
    arm()
    assert(#scheduled == 1, "the held preload never started")
    assert(scheduled[1].delay == 0.35, "it started at the wrong delay")
    assert(not self_._preload_pending, "it stayed armed and could fire twice")
end)

t.test("after the first paint it schedules immediately, as before", function()
    -- Page turns must be unaffected: by then the paint has happened and this
    -- takes the normal path with no extra wait.
    local self_ = { _first_paint_done = true }
    local _e, scheduled, schedule = harness(self_)
    schedule(1)
    assert(#scheduled == 1, "a page-turn preload stopped being scheduled")
    assert(not self_._preload_pending, "a page-turn preload was needlessly held")
end)

t.test("arming does nothing when nothing is held", function()
    local self_ = { _first_paint_done = true }
    local _e, scheduled, _schedule, arm = harness(self_)
    arm()
    assert(#scheduled == 0, "armed a preload that was never requested")
end)

t.test("cancelling clears the held preload too", function()
    -- Otherwise a preload cancelled before the paint would still fire when the
    -- paint landed, for a page the user has already navigated away from.
    local self_ = { _first_paint_done = false }
    local _e, scheduled, schedule, arm = harness(self_)
    schedule(1)
    self_:_cancelPreload()
    self_._first_paint_done = true
    arm()
    assert(#scheduled == 0, "a cancelled preload fired at the first paint")
end)

t.done()
