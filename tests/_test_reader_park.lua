-- tests/_test_reader_park.lua
-- Pure-Lua tests for lib/bookshelf_reader_park (hot reader parking: the
-- shelf splices above a live ReaderUI instead of closing the document).
-- KOReader runtime modules are stubbed via package.loaded before dofile.

package.path = "./?.lua;./?/init.lua;" .. package.path

local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()

-- Controllable stubs -------------------------------------------------------
local hot_park_enabled = true
local ticks = {}
local dirty_calls = {}

local closed_widgets = {}
local UIManager = {
    _window_stack = {},
    nextTick = function(_self, fn) ticks[#ticks + 1] = fn end,
    setDirty = function(_self, w, mode) dirty_calls[#dirty_calls + 1] = { w = w, mode = mode } end,
    show = function() end,
    close = function(_self, w) closed_widgets[#closed_widgets + 1] = w end,
    forceRePaint = function() end,
}
local function drainTicks()
    while #ticks > 0 do (table.remove(ticks, 1))() end
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
    hot_park_enabled = true
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
