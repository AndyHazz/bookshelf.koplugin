-- tests/_test_shelf_size_async.lua
-- The Shelf size card never waits for its count. Cold, the count read every
-- sidecar inside render and froze the first full-screen micro-modules open for
-- 3 seconds on a PW5 (taps made meanwhile then closed the view as it opened).
-- It now shows the last tally (kept across restarts), counts in steps on later
-- ticks, and redraws its card when the numbers move. It also recounts when the
-- library changes, so the full-screen view (which never bumps the start menu's
-- generation) no longer shows the numbers from before a book was finished.
-- Run from the plugin root: lua tests/_test_shelf_size_async.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()

-- A UIManager whose tasks run only when the test says so.
local tasks = {}
package.loaded["ui/uimanager"] = {
    nextTick   = function(_, fn) tasks[#tasks + 1] = fn end,
    tickAfterNext = function(_, fn) tasks[#tasks + 1] = fn end,
    scheduleIn = function(_, _s, fn) tasks[#tasks + 1] = fn end,
}
local function runTasks()
    local n = 0
    while #tasks > 0 do
        local fn = table.remove(tasks, 1)
        fn(); n = n + 1
        assert(n < 1000, "the count never finished")
    end
    return n
end

local store = {}
package.loaded["lib/bookshelf_settings_store"] = {
    read = function(k) return store[k] end,
    save = function(k, v) store[k] = v end,
}
package.loaded["lib/bookshelf_module_cache"] = package.loaded["lib/bookshelf_settings_store"]
package.loaded["lib/bookshelf_start_menu_modules"] = { menu_generation = 1 }
package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }

-- The library: a status per book, and a stepper that records how it was used.
local library, data_gen, stepper_made = {}, 1, 0
package.loaded["lib/bookshelf_book_repository"] = {
    dataGeneration = function() return data_gen end,
    countByStatusStepper = function()
        stepper_made = stepper_made + 1
        local books, i = {}, 0
        for _, s in ipairs(library) do books[#books + 1] = s end
        local counts = { unread = 0, reading = 0, on_hold = 0, finished = 0 }
        return function(n)
            local stop = math.min(#books, i + n)
            for j = i + 1, stop do counts[books[j]] = counts[books[j]] + 1 end
            i = stop
            if i < #books then return false end
            return true, #books, counts
        end
    end,
}

local function setLibrary(n_finished, n_unread)
    library = {}
    for _ = 1, n_finished do library[#library + 1] = "finished" end
    for _ = 1, n_unread do library[#library + 1] = "unread" end
end

local M = dofile("micromodules/shelf_size.lua")

t.test("a first ever render shows nothing yet and does not count inside render", function()
    setLibrary(10, 50)
    local redrawn = 0
    local total, counts = M._getCounts(function() redrawn = redrawn + 1 end)
    assert(total == nil and counts == nil, "a first ever render has no tally to show")
    assert(stepper_made == 0, "the library was walked inside render")
    local ticks = runTasks()
    assert(ticks > 1, "60 books should take more than one step, took " .. ticks)
    assert(redrawn == 1, "the card was not redrawn when the count landed")
    total, counts = M._getCounts()
    assert(total == 60 and counts.finished == 10, "got " .. tostring(total))
end)

t.test("the tally is kept for the next start", function()
    assert(store.shelf_size_tally and store.shelf_size_tally.total == 60,
        "the tally was not saved")
end)

t.test("an unchanged library does not count again", function()
    local made = stepper_made
    M._getCounts(function() end)
    assert(#tasks == 0 and stepper_made == made, "counted again with nothing changed")
end)

t.test("a finished book recounts without the start menu opening", function()
    setLibrary(11, 49)
    data_gen = data_gen + 1
    local redrawn = 0
    local total = M._getCounts(function() redrawn = redrawn + 1 end)
    assert(total == 60, "the old tally should show while counting")
    runTasks()
    local _t, counts = M._getCounts()
    assert(counts.finished == 11, "still the old finished count")
    assert(redrawn == 1, "the card was not redrawn")
end)

t.test("a count that ends with the same numbers does not redraw", function()
    data_gen = data_gen + 1
    local redrawn = 0
    M._getCounts(function() redrawn = redrawn + 1 end)
    runTasks()
    assert(redrawn == 0, "redrew for numbers that did not move")
end)

t.test("a change during a count runs another one", function()
    data_gen = data_gen + 1
    local redrawn = 0
    M._getCounts(function() redrawn = redrawn + 1 end)
    -- One step in, a book is finished.
    local first = table.remove(tasks, 1); first()
    setLibrary(12, 48)
    data_gen = data_gen + 1
    runTasks()
    local _t, counts = M._getCounts()
    assert(counts.finished == 12, "the change during the count was lost: " .. counts.finished)
    assert(redrawn >= 1, "the card never showed the new numbers")
end)

t.test("the picker preview never starts a count", function()
    data_gen = data_gen + 1
    local made = stepper_made
    M._getCounts(nil, true)
    runTasks()
    assert(stepper_made == made, "a preview started a count")
end)

t.done()
