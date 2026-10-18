-- tests/_test_reading_goal_deferred.lua
-- The Reading goal card never waits for its figures. Cold, the statistics
-- queries and the sidecar reads cost 630ms on a PW5 inside the first
-- full-screen micro-modules open. It now draws the last figures (saved across
-- restarts, a rolled-over period reading 0), works the new ones out after the
-- next paint, and redraws itself when a number moved.
-- Run from the plugin root: lua tests/_test_reading_goal_deferred.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()

local saved = {}
package.loaded["lib/bookshelf_settings_store"] = {
    read = function(k, d) if saved[k] == nil then return d end return saved[k] end,
    save = function(k, v) saved[k] = v end,
}
package.loaded["lib/bookshelf_module_cache"] = {
    read = function(k) return saved[k] end,
    save = function(k, v) saved[k] = v end,
}
package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }
package.loaded["ffi/util"] = { template = function(s) return s end }
_G.G_reader_settings = { readSetting = function() return nil end }

local tasks = {}
package.loaded["ui/uimanager"] = {
    tickAfterNext = function(_, fn) tasks[#tasks + 1] = fn end,
}
local function runTasks()
    while #tasks > 0 do table.remove(tasks, 1)() end
end

local X = dofile("micromodules/reading_goal.lua")._test

local computed = 0
local figures = { today_secs = 600, week_secs = 3600, month_books = 1, year_books = 7 }
X.setCompute(function()
    computed = computed + 1
    local d = {}
    for k, v in pairs(figures) do d[k] = v end
    return d
end)

t.test("a first render draws at once and works the figures out after the paint", function()
    local redrawn = 0
    local data = X.queryAllData(function() redrawn = redrawn + 1 end)
    assert(computed == 0, "the figures were worked out inside render")
    assert(data and data.year_books == 0, "a first ever render should show zeros")
    runTasks()
    assert(computed == 1 and redrawn == 1, "computed " .. computed .. ", redrawn " .. redrawn)
    data = X.queryAllData()
    assert(data.year_books == 7 and data.today_secs == 600)
end)

t.test("fresh figures are served without another query", function()
    X.queryAllData(function() end)
    assert(#tasks == 0 and computed == 1, "queried again inside the cache window")
end)

t.test("after a restart the saved figures show straight away", function()
    X.forget()
    local data = X.queryAllData(function() end)
    assert(data.year_books == 7 and data.today_secs == 600,
        "the saved figures were not used: year=" .. tostring(data.year_books))
    runTasks()
end)

t.test("a period that rolled over since they were saved reads 0", function()
    saved.reading_goal_last.stamps.day = "2000-01-01"
    saved.reading_goal_last.stamps.month = "2000-01"
    X.forget()
    local data = X.queryAllData(function() end)
    assert(data.today_secs == 0 and data.month_books == 0, "yesterday's figures showed as today's")
    assert(data.year_books == 7, "this year's count should survive a new day")
    runTasks()
end)

t.test("the same figures arriving do not redraw, and one card is redrawn once", function()
    X.forget()
    local redrawn = 0
    local refresh = function() redrawn = redrawn + 1 end
    X.queryAllData(refresh)
    X.queryAllData(refresh)       -- the fit search renders the card again
    runTasks()
    assert(redrawn == 0, "redrew for figures that did not move, " .. redrawn)
    X.forget()
    figures.year_books = 8
    X.queryAllData(refresh); X.queryAllData(refresh)
    runTasks()
    assert(redrawn == 1, "one card should redraw once, got " .. redrawn)
end)

t.test("unavailable statistics still say so", function()
    X.forget()
    X.setCompute(function() return false end)
    X.queryAllData(function() end)
    runTasks()
    assert(X.queryAllData() == nil, "unavailable stats should read as nil")
end)

t.test("the picker preview never queries", function()
    X.forget()
    local before = computed
    X.queryAllData(nil, true)
    runTasks()
    assert(computed == before and #tasks == 0, "a preview started a query")
end)

t.done()
