-- tests/_test_dispatch_action_names.lua
-- Every KOReader action we dispatch by name has to be a name KOReader knows.
--
-- THE REPORT (maintainer, testing the reading streak module for the start
-- menu): the "Reading insight" tap action does nothing.
--
-- THE BUG. The module dispatched "reading_insights_popup", which KOReader has
-- never registered. The statistics plugin registers exactly seven actions --
-- toggle_statistics, reading_progress, stats_time_range, stats_calendar_view,
-- stats_calendar_day_view, stats_sync, book_statistics -- and that is not one
-- of them.
--
-- WHY IT WAS INVISIBLE. Dispatcher:execute looks the key up in settingsList,
-- gets nil, and hands that to isActionEnabled, whose first test is
-- `if action and ...`. A nil action is simply reported disabled and skipped.
-- No error, no log line, no toast: a tap that goes nowhere. It shipped that
-- way from the module's first commit (a community PR) in June.
--
-- This test is the general guard. A dispatched action name is a string
-- crossing into another codebase with no compiler and no runtime complaint to
-- catch a typo or an invention, which is exactly the shape of bug that hides
-- for months.
--
-- Needs a KOReader tree to know what is registered, so it SKIPS without one
-- -- and CI has no KOReader (see the run.sh notes), so a green CI does not
-- prove this passed. Run it locally.
--
-- Usage (from plugin root): lua tests/_test_dispatch_action_names.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()

local KO = "/usr/lib/koreader"
local function exists(p)
    local f = io.open(p, "r"); if f then f:close(); return true end
    return false
end

if not exists(KO .. "/frontend/dispatcher.lua") then
    print("note: skipped, no KOReader tree at " .. KO)
    t.done()
    return
end

-- Harvest every action KOReader registers: the built-in table in
-- dispatcher.lua, plus registerAction calls anywhere in the tree (plugins
-- register their own at init).
local registered = {}
do
    local d = io.open(KO .. "/frontend/dispatcher.lua"):read("*a")
    -- settingsList entries: `    some_key = {category=...`
    for k in d:gmatch("\n%s*([%a_][%w_]*)%s*=%s*{%s*category=") do
        registered[k] = true
    end
    -- NB: this is a SHELL regex, not a Lua pattern. [%a_] is Lua syntax and
    -- matches nothing here, which silently harvested zero plugin actions and
    -- made the whole check pass for the wrong reason on the first run.
    local pipe = io.popen("grep -rhoE 'registerAction\\(\"[a-z_]+\"' " .. KO
                          .. " 2>/dev/null")
    if pipe then
        for line in pipe:lines() do
            local k = line:match('registerAction%("([%a_]+)"')
            if k then registered[k] = true end
        end
        pipe:close()
    end
end

t.test("KOReader's action list was actually harvested", function()
    -- Guard against the harvest silently finding nothing, which would make
    -- every assertion below pass for the wrong reason.
    local n = 0
    for _ in pairs(registered) do n = n + 1 end
    assert(n > 20, "only harvested " .. n .. " actions; the scrape is broken")
    assert(registered["stats_calendar_view"], "a known action is missing from the harvest")
    assert(registered["reading_progress"], "a known action is missing from the harvest")
end)

t.test("no module dispatches an action KOReader does not register", function()
    local bad = {}
    local pipe = assert(io.popen("grep -rn 'Dispatcher:execute' micromodules lib 2>/dev/null"))
    local sites = {}
    for line in pipe:lines() do sites[#sites + 1] = line end
    pipe:close()
    assert(#sites > 0, "no dispatch sites found; the scan is broken")

    for _, line in ipairs(sites) do
        local file = line:match("^([^:]+):")
        -- Literal keys only: `{ some_action = true }`. A computed key is
        -- checked at its source instead (see the next test).
        for key in line:gmatch("{%s*([%a_][%w_]*)%s*=%s*true%s*}") do
            if not registered[key] then
                bad[#bad + 1] = file .. " dispatches unknown action '" .. key .. "'"
            end
        end
    end
    assert(#bad == 0, table.concat(bad, "\n  "))
end)

t.test("the reading streak's two tap choices are both real", function()
    -- This module builds its key from a setting, so the literal scan above
    -- cannot see it. Both stored values must resolve to real actions.
    local src = io.open("micromodules/reading_streak.lua"):read("*a")
    local found = {}
    for key in src:gmatch('radio%(_%("[^"]+"%),%s*"([%a_]+)"%)') do
        found[#found + 1] = key
        assert(registered[key],
            "tap choice '" .. key .. "' is not an action KOReader registers")
    end
    assert(#found == 2, "expected two tap choices, found " .. #found)

    -- And the fallback the reader lands on if their stored value is
    -- unrecognised -- which is how the dead key migrates itself away.
    local fallback = src:match('if v ~= "[%a_]+" then v = "([%a_]+)" end')
    assert(fallback, "the tap fallback moved or was renamed")
    assert(registered[fallback],
        "the fallback '" .. fallback .. "' is not a real action either")
end)

t.done()
