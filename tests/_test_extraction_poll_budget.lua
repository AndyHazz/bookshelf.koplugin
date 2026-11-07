-- tests/_test_extraction_poll_budget.lua
-- The shelf watches the books it asked BIM for and repaints them when their
-- covers land. Its 60 s budget was meant for a stuck extraction, but when BIM
-- is busy with a long job of someone else's (a library re-scan, 1,285 books
-- after a bulk edit on the PW5), the visible page waits its turn for minutes:
-- the watch gave up first, and the covers that then landed were never shown.
-- While BIM is still extracting, it keeps watching, at its slowest pace.
-- Run from the plugin root: lua tests/_test_extraction_poll_budget.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq

local src = io.open("lib/bookshelf_widget.lua"):read("*a")
local body = src:match("\nfunction BookshelfWidget:_scheduleExtractionPoll%(%)\n(.-)\nend\n")
assert(body, "_scheduleExtractionPoll moved")

local now, busy, scheduled = 1000, false, {}
local env = setmetatable({
    BIM_POLL_INTERVALS_S = { 0.4, 0.6, 1.0, 2.0, 3.0 },
    BIM_POLL_TOTAL_BUDGET_S = 60,
    BIM_POLL_BUSY_S = 5,
    logger = { dbg = function() end },
    UIManager = { scheduleIn = function(_s, secs, fn) scheduled[#scheduled + 1] = { secs = secs, fn = fn } end },
    os = { time = function() return now end },
    require = function(name)
        if name == "bookinfomanager" then
            return { isExtractingInBackground = function() return busy end }
        end
        return require(name)
    end,
}, { __index = _G })
local schedule = assert(load("return function(self)\n" .. body .. "\nend", "sched", "t", env))()

local function shelf()
    return { _bim_poll_files = { { filepath = "/b/1.epub" } }, _bim_poll_started_at = 1000,
             _bim_poll_empty_streak = 9, _pollExtraction = function() end }
end

t.test("within the budget it polls at the streak's pace", function()
    now, busy, scheduled = 1030, false, {}
    local s = shelf()
    schedule(s)
    eq(#scheduled, 1); eq(scheduled[1].secs, 3.0)
end)

t.test("past the budget with BIM idle it gives up, as before", function()
    now, busy, scheduled = 1061, false, {}
    local s = shelf()
    schedule(s)
    eq(#scheduled, 0); eq(s._bim_poll_files, nil)
end)

t.test("past the budget while BIM is still extracting, it keeps watching", function()
    now, busy, scheduled = 1000 + 600, true, {}
    local s = shelf()
    schedule(s)
    eq(#scheduled, 1, "gave up while BIM was still working through the queue")
    assert(scheduled[1].secs >= 3, "polled faster than its slowest pace past the budget")
    assert(s._bim_poll_files, "dropped the watch list")
end)

t.done()
