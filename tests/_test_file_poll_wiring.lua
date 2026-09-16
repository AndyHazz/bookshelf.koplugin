-- tests/_test_file_poll_wiring.lua
-- The new-file poll's cadence is decided by bookshelf_file_poll.nextInterval
-- (Wi-Fi gate, idle backoff, covered rate); this pins how the widget feeds
-- and obeys that decision, and which events re-arm the poll.
--
-- WHAT NEEDS PINNING. A Kobo's autosuspend enters standby with an RTC alarm
-- for the next scheduled task plus one second, so a poll always due within
-- 5 s chopped standby into 6 s slices while the shelf idled. The stock file
-- manager schedules nothing. The poll now asks nextInterval every time it
-- re-arms; nil means "no tick until an event": Wi-Fi coming up, a resume, a
-- USB unplug (NotCharging). Each of those re-arms at the active rate so the
-- first check after the event is prompt, whatever the idle clock says.
--
-- Usage (from plugin root): lua tests/_test_file_poll_wiring.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq
local src  = io.open("lib/bookshelf_widget.lua"):read("*a")
local park = io.open("lib/bookshelf_reader_park.lua"):read("*a")

local function extract(source, name)
    local pat = "\nfunction " .. name:gsub("[%.%(%)]", "%%%0") .. "\n(.-)\nend\n"
    local body = source:match(pat)
    assert(body, name .. " not found")
    return (body:gsub("%-%-[^\n]*", ""))
end

local function loadMethod(name, env, params)
    local fn, err = load("return function(" .. (params or "self") .. ")\n" .. extract(src, name) .. "\nend", name, "t", env)
    assert(fn, err)
    return fn()
end

-- _armFilePoll -------------------------------------------------------------
local function armEnv()
    local e = { calls = {} }
    e.UIManager = {
        unschedule = function(_, fn) e.calls[#e.calls + 1] = "unschedule" end,
        scheduleIn = function(_, s, fn) e.calls[#e.calls + 1] = "scheduleIn:" .. tostring(s) end,
    }
    return e
end
local function armSelf(decision)
    local w = { _file_poll_fn = function() end, asked = {} }
    w._filePollInterval = function(_, covered) w.asked[#w.asked + 1] = tostring(covered); return decision end
    return w
end

t.test("_armFilePoll: nothing to arm when the poll was never started or was cancelled", function()
    local e = armEnv()
    loadMethod("BookshelfWidget:_armFilePoll(opts)", e, "self, opts")({}, nil)
    eq(#e.calls, 0)
end)

t.test("_armFilePoll: the decision's interval is scheduled after unscheduling any pending tick", function()
    local e = armEnv()
    local w = armSelf(60)
    loadMethod("BookshelfWidget:_armFilePoll(opts)", e, "self, opts")(w, nil)
    eq(table.concat(e.calls, ","), "unschedule,scheduleIn:60")
    eq(w.asked[1], "nil", "not covered")
end)

t.test("_armFilePoll: a nil decision leaves no tick pending (Wi-Fi off) but keeps the poll started", function()
    local e = armEnv()
    local w = armSelf(nil)
    loadMethod("BookshelfWidget:_armFilePoll(opts)", e, "self, opts")(w, nil)
    eq(table.concat(e.calls, ","), "unschedule")
    assert(w._file_poll_fn, "the baseline-carrying poll must survive")
end)

t.test("_armFilePoll: a forced interval skips the decision (first tick, Wi-Fi up, USB unplug)", function()
    local e = armEnv()
    local w = armSelf(nil)
    loadMethod("BookshelfWidget:_armFilePoll(opts)", e, "self, opts")(w, { interval = 5 })
    eq(table.concat(e.calls, ","), "unschedule,scheduleIn:5")
    eq(#w.asked, 0, "decision not consulted")
end)

t.test("_armFilePoll: the covered flag reaches the decision", function()
    local e = armEnv()
    local w = armSelf(30)
    loadMethod("BookshelfWidget:_armFilePoll(opts)", e, "self, opts")(w, { covered = true })
    eq(w.asked[1], "true")
    eq(e.calls[2], "scheduleIn:30")
end)

-- _filePollInterval --------------------------------------------------------
local function intervalEnv(mods)
    local e = {}
    local seen = {}
    e.seen = seen
    e.require = function(name)
        if name == "lib/bookshelf_file_poll" then
            return { nextInterval = function(st) seen.st = st; return 7 end }
        end
        local m = mods[name]
        if m == nil then error("no module " .. name) end
        return m
    end
    e.pcall, e.type = pcall, type
    return e
end

t.test("_filePollInterval: Wi-Fi state, idle clock and covered flag are handed to the decision", function()
    local e = intervalEnv{
        ["ui/network/manager"]      = { isWifiOn = function() return false end },
        ["lib/bookshelf_reader_park"] = { idleSeconds = function() return 42 end },
    }
    local r = loadMethod("BookshelfWidget:_filePollInterval(covered)", e, "self, covered")({}, true)
    eq(r, 7)
    eq(e.seen.st.wifi_on, false); eq(e.seen.st.idle_s, 42); eq(e.seen.st.covered, true)
end)

t.test("_filePollInterval: a host that cannot say leaves Wi-Fi unknown (nil), never false", function()
    local e = intervalEnv{ ["lib/bookshelf_reader_park"] = { idleSeconds = function() return 0 end } }
    loadMethod("BookshelfWidget:_filePollInterval(covered)", e, "self, covered")({}, nil)
    eq(e.seen.st.wifi_on, nil)
    local e2 = intervalEnv{
        ["ui/network/manager"]      = { isWifiOn = function() error("no lipc") end },
        ["lib/bookshelf_reader_park"] = { idleSeconds = function() return 0 end },
    }
    loadMethod("BookshelfWidget:_filePollInterval(covered)", e2, "self, covered")({}, nil)
    eq(e2.seen.st.wifi_on, nil)
end)

-- Wiring: who re-arms, and nothing schedules the poll directly any more ----
t.test("the first tick after start or resume is at the active rate, whatever the idle clock says", function()
    local body = extract(src, "BookshelfWidget:_startFilePoll()")
    assert(body:find("_armFilePoll{ interval = FilePoll.ACTIVE_INTERVAL_S }", 1, true), "_startFilePoll must force the first tick")
    assert(not body:find("scheduleIn(", 1, true), "_startFilePoll must not schedule directly")
end)

t.test("both branches of the tick go through _armFilePoll", function()
    local body = extract(src, "BookshelfWidget:_filePollTick()")
    assert(not body:find("scheduleIn(", 1, true), "_filePollTick must not schedule directly")
    assert(body:find("_armFilePoll{ covered = true }", 1, true), "covered branch")
    assert(body:find("self:_armFilePoll()", 1, true), "uncovered branch")
end)

t.test("Wi-Fi up and a USB unplug re-arm promptly; Wi-Fi down re-evaluates", function()
    assert(extract(src, "BookshelfWidget:onNetworkConnected()"):find("_armFilePoll{ interval", 1, true))
    assert(extract(src, "BookshelfWidget:onNotCharging()"):find("_armFilePoll{ interval", 1, true))
    assert(extract(src, "BookshelfWidget:onNetworkDisconnected()"):find("self:_armFilePoll()", 1, true))
end)

t.test("the widget no longer keeps its own cadence constants", function()
    assert(not src:find("\nlocal FILE_POLL_INTERVAL_S", 1, true), "FILE_POLL_INTERVAL_S should live in bookshelf_file_poll")
    assert(not src:find("\nlocal FILE_POLL_COVERED_INTERVAL_S", 1, true))
end)

t.test("the parking module exposes the idle clock", function()
    assert(park:find("\nfunction Park.idleSeconds()\n", 1, true), "Park.idleSeconds missing")
end)

t.done()
