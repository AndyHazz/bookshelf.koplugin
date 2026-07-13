-- tests/_test_reader_park.lua
-- Pure-Lua tests for lib/bookshelf_reader_park (hot reader parking: the
-- shelf splices above a live ReaderUI instead of closing the document).
-- KOReader runtime modules are stubbed via package.loaded before dofile.

package.path = "./?.lua;./?/init.lua;" .. package.path

local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()

-- Controllable stubs -------------------------------------------------------
-- Fake clock: the module resolves its timer through socket.gettime, so
-- stubbing socket before dofile gives the tests full control of "now"
-- (drives the input-idle trigger).
local fake_now = 1000
package.loaded["socket"] = { gettime = function() return fake_now end }

local hot_park_enabled = true
local ticks = {}
local dirty_calls = {}

local closed_widgets = {}
local scheduled = {}
local UIManager = {
    _window_stack = {},
    nextTick = function(_self, fn) ticks[#ticks + 1] = fn end,
    setDirty = function(_self, w, mode) dirty_calls[#dirty_calls + 1] = { w = w, mode = mode } end,
    show = function() end,
    close = function(_self, w) closed_widgets[#closed_widgets + 1] = w end,
    forceRePaint = function() end,
    scheduleIn = function(_self, _s, fn) scheduled[#scheduled + 1] = fn end,
    unschedule = function(_self, fn)
        for i = #scheduled, 1, -1 do
            if scheduled[i] == fn then table.remove(scheduled, i) end
        end
    end,
}
local function drainTicks()
    while #ticks > 0 do (table.remove(ticks, 1))() end
end
-- Snapshot semantics: fires what is scheduled NOW; anything a fired
-- closure re-schedules stays queued for the next call (the deferral test
-- relies on this - a drain-until-empty loop would spin forever on the
-- finish's retry).
local function fireScheduled()
    local batch = scheduled
    scheduled = {}
    for _i, fn in ipairs(batch) do fn() end
end

local ReaderUI = { instance = nil }
local repo_calls = {}

package.loaded["ui/uimanager"] = UIManager
package.loaded["apps/reader/readerui"] = ReaderUI
package.loaded["ui/event"] = { new = function(_self, name) return { name = name } end }
package.loaded["logger"] = { dbg = function() end, info = function() end,
                             warn = function() end, err = function() end }
package.loaded["lib/bookshelf_settings_store"] = {
    nilOrTrue = function(k)
        if k == "hot_park" then return hot_park_enabled end
        return true
    end,
}
package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }
package.loaded["ui/widget/infomessage"] = {
    new = function(_self, o) return o or {} end,
}
package.loaded["lib/bookshelf_book_repository"] = {
    invalidateStatsCache     = function(fp) repo_calls[#repo_calls + 1] = "stats:" .. fp end,
    invalidateProgressCache  = function(fp) repo_calls[#repo_calls + 1] = "progress:" .. tostring(fp) end,
    invalidateReadStateCache = function() repo_calls[#repo_calls + 1] = "readstate" end,
}
package.loaded["ui/widget/booklist"] = {
    setBookInfoCacheProperty = function() end,
}
-- Controllable screen rotation for the orientation guard (issue #266).
-- park() resolves this lazily via require("device").screen only when a
-- pre-read rotation is recorded, so it stays inert for the other tests.
local screen_rotation = 0
package.loaded["device"] = {
    screen = {
        getRotationMode = function() return screen_rotation end,
        setRotationMode = function(_self, m) screen_rotation = m end,
        getWidth  = function() return 100 end,
        getHeight = function() return 100 end,
    },
}

local Park = dofile("lib/bookshelf_reader_park.lua")

-- Fixture builders ----------------------------------------------------------
local function makeRui(file)
    return {
        document     = { file = file },
        doc_settings = { readSetting = function() return 0.42 end },
        events       = {},
        handleEvent  = function(self, e) self.events[#self.events + 1] = e.name end,
        saved        = false,
        saveSettings = function(self) self.saved = true end,
        highlight    = { onClose = function() end },
    }
end
local function makePlugin(rui)
    return {
        ui = rui,
        raised = false, shown = false,
        _raiseInPlace = function(self) self.raised = true; return true end,
        show          = function(self) self.shown  = true end,
    }
end
local function reset()
    ticks = {}
    dirty_calls = {}
    repo_calls = {}
    closed_widgets = {}
    scheduled = {}
    hot_park_enabled = true
    screen_rotation = 0
    ReaderUI.instance = nil
    Park.noteRealClose()
    Park.consumeClosingToFM() -- drain any leftover one-shot
end

print("--- Park.park ---")

t.test("park returns false when the setting is off", function()
    reset()
    hot_park_enabled = false
    local rui = makeRui("/books/a.epub")
    ReaderUI.instance = rui
    assert(Park.park(makePlugin(rui)) == false)
    assert(Park.isParked() == false)
end)

t.test("park returns false with no live document", function()
    reset()
    local rui = makeRui("/books/a.epub")
    rui.document = nil
    ReaderUI.instance = rui
    assert(Park.park(makePlugin(rui)) == false)
end)

t.test("park returns false when the shelf is not on the stack", function()
    reset()
    local rui = makeRui("/books/a.epub")
    ReaderUI.instance = rui
    local plugin = makePlugin(rui)
    plugin._raiseInPlace = function() return false end
    assert(Park.park(plugin) == false)
    assert(Park.isParked() == false)
end)

t.test("successful park: chrome closed, shelf raised, state set", function()
    reset()
    local rui = makeRui("/books/a.epub")
    ReaderUI.instance = rui
    local plugin = makePlugin(rui)
    assert(Park.park(plugin) == true)
    assert(plugin.raised, "expected _raiseInPlace")
    assert(rui.events[1] == "CloseReaderMenu")
    assert(rui.events[2] == "CloseConfigMenu")
    assert(Park.isParked() == true)
    assert(Park.parkedFile() == "/books/a.epub")
    -- Deferred work has not run yet
    assert(rui.saved == false and plugin.shown == false)
    drainTicks()
    assert(rui.saved, "expected saveSettings flush on the tick")
    assert(plugin.shown, "expected warm show() on the tick")
    local seen = table.concat(repo_calls, ",")
    assert(seen:find("stats:/books/a%.epub"), "stats invalidation: " .. seen)
    assert(seen:find("readstate"), "read-state invalidation: " .. seen)
end)

-- Orientation guard (issue #266, reader-context regression): the pre-read rotation
-- lives on the canonical shelf widget (_live_widget), NOT on the reader-host
-- plugin's own self._widget (which is nil at park time - its show() has not
-- run). park() takes the widget as an argument so it reads the right one.
t.test("park declines when orientation changed (canonical widget arg)", function()
    reset()
    local rui = makeRui("/books/a.epub")
    ReaderUI.instance = rui
    local plugin = makePlugin(rui) -- reader-host plugin, no _widget
    local shelf = { _pre_read_rotation = 0 } -- shelf was portrait pre-read
    screen_rotation = 1 -- book was read in landscape
    assert(Park.park(plugin, shelf) == false,
        "must decline to park so the normal close restores portrait")
    assert(Park.isParked() == false)
end)

t.test("park still parks when orientation is unchanged", function()
    reset()
    local rui = makeRui("/books/a.epub")
    ReaderUI.instance = rui
    local plugin = makePlugin(rui)
    local shelf = { _pre_read_rotation = 0 }
    screen_rotation = 0 -- same orientation throughout
    assert(Park.park(plugin, shelf) == true,
        "same-orientation exits keep the instant-reopen park")
    assert(Park.isParked() == true)
end)

t.test("deferred park work is skipped after a real close in the gap", function()
    reset()
    local rui = makeRui("/books/a.epub")
    ReaderUI.instance = rui
    local plugin = makePlugin(rui)
    assert(Park.park(plugin) == true)
    Park.noteRealClose()
    drainTicks()
    assert(plugin.shown == false, "show() must not run for a dead park")
end)

print("--- isParked self-heal ---")

t.test("isParked self-heals when ReaderUI.instance changes", function()
    reset()
    local rui = makeRui("/books/a.epub")
    ReaderUI.instance = rui
    assert(Park.park(makePlugin(rui)) == true)
    ReaderUI.instance = makeRui("/books/b.epub") -- KOReader swapped readers
    assert(Park.isParked() == false)
    assert(Park.parkedFile() == nil)
end)

print("--- Park.unpark ---")

t.test("unpark splices the reader to the top and clears state", function()
    reset()
    local rui = makeRui("/books/a.epub")
    ReaderUI.instance = rui
    local shelf = {
        timer_stopped = false,
        _hero_current_memo = { stale = true },
        _stopStatusTimer = function(self) self.timer_stopped = true end,
    }
    UIManager._window_stack = { { widget = rui }, { widget = shelf } }
    assert(Park.park(makePlugin(rui)) == true)
    local cb_rui = nil
    assert(Park.unpark(shelf, function(r) cb_rui = r end) == true)
    assert(UIManager._window_stack[2].widget == rui, "reader must be topmost")
    assert(shelf.timer_stopped, "status timer must stop")
    assert(shelf._hero_current_memo == nil, "hero memo must drop")
    assert(cb_rui == rui, "after_open_callback receives the ReaderUI")
    assert(Park.isParked() == false)
    assert(#dirty_calls == 1 and dirty_calls[1].w == rui)
end)

t.test("unpark on a non-parked session is a false no-op", function()
    reset()
    assert(Park.unpark({}) == false)
end)

print("--- opportunistic finish (idle probe) ---")

-- Shared fixture: parked reader under the shelf, probe armed.
local function parkFixture()
    local rui = makeRui("/books/a.epub")
    rui.close_calls = 0
    rui.onClose = function()
        assert(Park.isFinishingClose(), "finishing flag must be up during onClose")
        rui.close_calls = rui.close_calls + 1
    end
    rui.showFileManager = function(_self, f) rui.fm_file = f end
    ReaderUI.instance = rui
    local plugin = makePlugin(rui)
    local shelf_widget = { _stopStatusTimer = function() end }
    plugin._widget = shelf_widget
    UIManager._window_stack = { { widget = rui }, { widget = shelf_widget } }
    assert(Park.park(plugin) == true)
    drainTicks() -- park's own refresh tick
    plugin.raised, plugin.shown = false, false
    return rui, plugin, shelf_widget
end

t.test("probe reschedules while input is recent, closes once idle", function()
    reset()
    local rui, plugin = parkFixture()
    assert(#scheduled == 1, "park must arm the idle probe")
    fake_now = fake_now + 5
    fireScheduled() -- only 5s idle: not yet
    assert(rui.close_calls == 0, "must not close while recently active")
    assert(#scheduled == 1, "probe must re-arm")
    fake_now = fake_now + 31
    fireScheduled() -- 36s idle: close
    assert(rui.close_calls == 1, "reader must real-close once idle")
    assert(rui.fm_file == "/books/a.epub")
    assert(plugin.raised and plugin.shown,
        "finish must re-raise and warm-show the shelf over the fresh FM")
    assert(Park.isParked() == false)
    drainTicks()
    assert(Park.isFinishingClose() == false, "flag must clear on the next tick")
end)

t.test("noteInput resets the idle clock", function()
    reset()
    local rui = parkFixture()
    fake_now = fake_now + 31
    Park.noteInput() -- user touched something just now
    fireScheduled()
    assert(rui.close_calls == 0, "fresh input must hold the close off")
    assert(#scheduled == 1, "probe re-armed")
end)

t.test("probe defers while something covers the shelf", function()
    reset()
    local rui = parkFixture()
    table.insert(UIManager._window_stack, { widget = {} }) -- popup on top
    fake_now = fake_now + 60
    fireScheduled()
    assert(rui.close_calls == 0, "must not finish under a live popup")
    assert(Park.isParked() == true, "still parked while deferred")
    assert(#scheduled == 1, "probe must re-arm")
    table.remove(UIManager._window_stack) -- popup dismissed
    fireScheduled()
    assert(rui.close_calls == 1, "finish runs once the shelf is topmost again")
end)

t.test("unpark cancels the probe", function()
    reset()
    local rui, _plugin, shelf = parkFixture()
    assert(Park.unpark(shelf) == true)
    assert(#scheduled == 0, "unpark must unschedule the probe")
    fake_now = fake_now + 60
    fireScheduled()
    assert(rui.close_calls == 0, "no real close after an unpark")
end)

t.test("a real close cancels the probe", function()
    reset()
    parkFixture()
    Park.noteRealClose()
    assert(#scheduled == 0, "noteRealClose must unschedule the probe")
end)

print("--- Park.finishToMenu ---")

t.test("menu tap while parked converts: close, then FM menu", function()
    reset()
    local rui = parkFixture()
    local menu_opened = false
    package.loaded["apps/filemanager/filemanager"] = {
        instance = { menu = { onShowMenu = function() menu_opened = true end } },
    }
    assert(Park.finishToMenu() == true)
    assert(rui.close_calls == 1, "menu conversion must real-close the book")
    assert(menu_opened, "the fresh FM menu must open after the finish")
    assert(Park.isParked() == false)
    package.loaded["apps/filemanager/filemanager"] = nil
end)

t.test("finishToMenu is a false no-op when not parked", function()
    reset()
    assert(Park.finishToMenu() == false)
end)

print("--- Park.runInFileManager ---")

t.test("parked: finishes the park, then runs the action with the reborn FM", function()
    reset()
    local fake_fm = { bookinfo = {} }
    package.loaded["apps/filemanager/filemanager"] = { instance = nil }
    local rui = parkFixture()
    -- showFileManager rebirths the FM: mirror that by setting the instance.
    rui.showFileManager = function(_self, f)
        rui.fm_file = f
        package.loaded["apps/filemanager/filemanager"].instance = fake_fm
    end
    local got_fm
    assert(Park.runInFileManager(function(fm) got_fm = fm end) == true)
    assert(rui.close_calls == 1, "must real-close the parked book first")
    assert(got_fm == fake_fm, "action must receive the reborn FileManager.instance")
    assert(Park.isParked() == false)
    package.loaded["apps/filemanager/filemanager"] = nil
end)

t.test("not parked: no finish, action still runs with the current FM", function()
    reset()
    local fake_fm = { bookinfo = {} }
    package.loaded["apps/filemanager/filemanager"] = { instance = fake_fm }
    local got_fm, ran = nil, false
    assert(Park.runInFileManager(function(fm) ran = true; got_fm = fm end) == false)
    assert(ran, "action must run even when not parked")
    assert(got_fm == fake_fm, "action gets the already-live FileManager.instance")
    package.loaded["apps/filemanager/filemanager"] = nil
end)

t.test("action errors are contained (pcall'd) and still finish the park", function()
    reset()
    package.loaded["apps/filemanager/filemanager"] = { instance = {} }
    local rui = parkFixture()
    rui.showFileManager = function() end
    -- A throwing action must not propagate or leave the park half-finished.
    assert(Park.runInFileManager(function() error("boom") end) == true)
    assert(rui.close_calls == 1)
    assert(Park.isParked() == false)
    package.loaded["apps/filemanager/filemanager"] = nil
end)

print("--- Park.closeShelfToFileManager ---")

t.test("not parked returns false", function()
    reset()
    assert(Park.closeShelfToFileManager({}) == false)
end)

t.test("closes the parked reader to the FileManager behind the shelf", function()
    reset()
    local rui = makeRui("/books/a.epub")
    local closed_file, fm_file
    rui.onClose = function(_self, _full)
        -- onCloseDocument consumes the one-shot during the real close
        assert(Park.consumeClosingToFM() == true,
            "closing-to-FM one-shot must be set during onClose")
        closed_file = rui.document.file
    end
    rui.showFileManager = function(_self, f) fm_file = f end
    ReaderUI.instance = rui
    local shelf = { _stopStatusTimer = function() end }
    UIManager._window_stack = { { widget = rui }, { widget = shelf } }
    assert(Park.park(makePlugin(rui)) == true)
    ticks = {} -- discard park's deferred refresh; this test is about the exit
    assert(Park.closeShelfToFileManager(shelf) == true)
    assert(Park.isParked() == false)
    assert(closed_file == nil, "real close must be deferred to the tick")
    drainTicks()
    assert(closed_file == "/books/a.epub", "reader must real-close on the tick")
    assert(fm_file == "/books/a.epub", "showFileManager must receive the file")
    local shelf_closed = false
    for _i, w in ipairs(closed_widgets) do
        if w == shelf then shelf_closed = true end
    end
    assert(shelf_closed, "shelf widget must be dismissed after FM shows")
    assert(Park.consumeClosingToFM() == false, "one-shot must not leak")
end)

t.done()
