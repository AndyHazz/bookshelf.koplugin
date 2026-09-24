-- tests/_test_scan_progress.lua
-- A background job's progress lives in the shelf's status line.
--
-- Usage (from plugin root): lua tests/_test_scan_progress.lua
--
-- Device report: the "Paginating" message sat in the bottom-left corner with
-- no padding, and "it's not really running in the background because any tap
-- on the screen cancels the run" -- Trapper's TrapWidget takes the whole
-- screen as its tap range. Only Stop may stop the job now.

package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local stack, top, dirty = {}, nil, 0
local clock = 100
package.loaded["lib/bookshelf_gettime"] = function() return clock end
package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }
package.loaded["ui/uimanager"] = {
    _window_stack = stack,
    isWidgetShown = function(_s, w)
        for _i, e in ipairs(stack) do if e.widget == w then return true end end
        return false
    end,
    getTopmostVisibleWidget = function() return top end,
    setDirty = function() dirty = dirty + 1 end,
}

local P = dofile("lib/bookshelf_scan_progress.lua")

local shelf = { rebuilds = 0, repaints = 0 }
function shelf:_rebuild() self.rebuilds = self.rebuilds + 1 end
function shelf:refreshStatusLine() self.repaints = self.repaints + 1 end

local function reset()
    P._reset()
    for i = #stack, 1, -1 do stack[i] = nil end
    stack[1] = { widget = shelf }
    top = shelf
    shelf.rebuilds, shelf.repaints = 0, 0
end

t.test("start and finish lay the shelf out again; ticks only repaint the line", function()
    reset()
    local job = P.begin{ title = "x", shelf = function() return shelf end }
    eq(shelf.rebuilds, 1, "the line may not have been showing at all")
    assert(P.active() and P.job() == job)
    clock = clock + 2
    P.update{ fraction = 0.5 }
    eq(shelf.repaints, 1); eq(shelf.rebuilds, 1)
    P.finish()
    eq(shelf.rebuilds, 2); assert(not P.active())
end)

t.test("ticks faster than once a second are not painted, unless forced", function()
    reset()
    P.begin{ title = "x", shelf = function() return shelf end }
    clock = clock + 2; P.update{ fraction = 0.1 }
    clock = clock + 0.2; P.update{ fraction = 0.2 }
    eq(shelf.repaints, 1, "an e-ink panel refreshed for every step")
    P.update{ fraction = 0.3, force = true }
    eq(shelf.repaints, 2)
    eq(P.job().fraction, 0.3, "a skipped paint still keeps the value")
end)

t.test("no repaint while something else is on top of the shelf", function()
    reset()
    P.begin{ title = "x", shelf = function() return shelf end }
    top = {}
    P.update{ fraction = 0.5, force = true }
    eq(shelf.repaints, 0)
end)

t.test("Stop interrupts Trapper only while a subprocess is running", function()
    reset()
    local job = P.begin{ title = "x", shelf = function() return shelf end }
    local resumed = 0
    job.dismiss_callback = function() resumed = resumed + 1 end
    P.stop()
    assert(job.stopped)
    eq(resumed, 0, "between calls, resuming would land in the wrong yield")
    job.stopped = false
    job.in_run = true
    P.stop()
    eq(resumed, 1)
    P.stop()
    eq(resumed, 1, "a second Stop is a no-op")
end)

t.test("a book the user opened pauses the job; a parked one does not", function()
    reset()
    P.begin{ title = "x", shelf = function() return shelf end }
    assert(not P.reading())
    table.insert(stack, 1, { widget = { name = "ReaderUI" } })   -- parked, below
    assert(not P.reading(), "a parked reader held the job")
    stack[#stack + 1] = { widget = { name = "ReaderUI" } }       -- opened, above
    assert(P.reading())
end)

t.test("the reader's copy of the status line never shows the job", function()
    local rs = io.open("lib/bookshelf_reader_status.lua"):read("*a")
    local call = rs:match("pcall%(HeroCard%.buildStatusRow,([^%)]*)%)")
    assert(call, "reader status no longer builds the row")
    local _n, commas = call:gsub(",", "")
    eq(commas, 3, "the reader passed allow_job")
end)

t.done()
