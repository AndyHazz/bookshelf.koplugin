-- lib/bookshelf_reader_park.lua
--
-- Hot reader parking: leaving a book for the shelf does NOT close the
-- document. The BookshelfWidget overlay is spliced above the live ReaderUI
-- in UIManager's window stack (instant - no close I/O, no FM rebirth in
-- the visible path) and the reader lingers "parked" underneath. The real
-- close (1-3s of UI-thread-blocking disk I/O that cannot run in any
-- background - KOReader is single-threaded Lua) happens OPPORTUNISTICALLY,
-- at the first moment the user demonstrably isn't interacting:
--
--   * opening a DIFFERENT book (KOReader's ShowingReader teardown - the
--     block hides inside the load wait the user already expects);
--   * ~IDLE_FINISH_S of device-wide input idle (a probe rechecks every
--     PROBE_EVERY_S; input is stamped via a sendEvent wrap so popup
--     interaction counts as activity);
--   * a top-edge menu tap while parked (finishToMenu: brief "Closing
--     book…" then the real FileManager menu opens - the menu is always
--     the FM menu, occasionally a couple of seconds late);
--   * the explicit exits (Close Bookshelf / File browser -
--     closeShelfToFileManager) and KOReader exit (natural real close).
--
-- Within the parked window a same-book reopen is the reverse splice -
-- instant, no document load. After the finish, the FileManager is live
-- underneath the shelf again, so every legacy home-screen semantic
-- (FM menu, sleep screen, stats, crash recovery) is back to normal.
--
-- Deliberately NOT a trigger: suspend. Finishing under the screensaver
-- would have showFileManager/_raiseInPlace fighting the screensaver
-- widget for the top of the stack (the #84 minefield). Cost: sleeping
-- within seconds of exiting a book shows that book's sleep screen once.
--
-- State is in-memory only, by design (runtime flags don't survive
-- crashes, so never persist them): _parked is re-validated against
-- ReaderUI.instance identity on every read and self-heals to "not
-- parked" when they diverge.

local UIManager         = require("ui/uimanager")
local Event             = require("ui/event")
local logger            = require("logger")
local BookshelfSettings = require("lib/bookshelf_settings_store")
local _                 = require("lib/bookshelf_i18n").gettext

-- Wall-clock timer, same idiom as main.lua so [bookshelf perf] lines share
-- a clock across modules. Also drives the input-idle bookkeeping.
local _gettime
do
    local ok, s = pcall(require, "socket")
    _gettime = (ok and s and type(s.gettime) == "function")
        and function() return s.gettime() end
        or  os.time
end

local Park = {}

-- Device-idle window before the deferred finish runs, and how often the
-- probe rechecks. Finish lands between IDLE_FINISH_S and
-- IDLE_FINISH_S + PROBE_EVERY_S after the last input.
local IDLE_FINISH_S = 30
local PROBE_EVERY_S = 10

-- The ReaderUI instance currently parked beneath the shelf, and the
-- reader-context plugin instance that parked it (needed by the finish for
-- _raiseInPlace/show). Both nil when not parked.
local _parked = nil
local _parked_plugin = nil
-- One-shot: set while closeShelfToFileManager real-closes the parked
-- reader. Bookshelf:onCloseDocument consumes it to skip its re-show (the
-- destination is the raw FileManager, not the shelf).
local _closing_to_fm = false
-- The scheduled idle-probe closure (for unschedule), and the flag that
-- marks a finish in progress - Bookshelf:onCloseDocument and _takeOver
-- check it to skip their own re-shows while the close sequence runs.
local _pending_probe = nil
local _finishing_close = false
-- Wall-clock time of the last user input anywhere (stamped by the
-- sendEvent wrap below).
local _last_input = 0

function Park.enabled()
    return BookshelfSettings.nilOrTrue("hot_park")
end

local function _readerInstance()
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    if ok and ReaderUI then return ReaderUI.instance end
    return nil
end

function Park.isParked()
    if not _parked then return false end
    if _readerInstance() ~= _parked then
        -- The instance we parked is gone (a real close we didn't observe).
        _parked = nil
        _parked_plugin = nil
        return false
    end
    return true
end

function Park.parkedFile()
    if not Park.isParked() then return nil end
    return _parked.document and _parked.document.file or nil
end

local function _cancelPendingProbe()
    if _pending_probe then
        UIManager:unschedule(_pending_probe)
        _pending_probe = nil
    end
end

-- Called from Bookshelf:onCloseDocument - any real close invalidates
-- parking state, whether or not the closing reader was the parked one.
function Park.noteRealClose()
    _parked = nil
    _parked_plugin = nil
    _cancelPendingProbe()
end

-- One-shot consume for onCloseDocument: true exactly once per
-- closeShelfToFileManager exit.
function Park.consumeClosingToFM()
    if _closing_to_fm then
        _closing_to_fm = false
        return true
    end
    return false
end

-- True while a finish-close sequence is running. Checked by
-- Bookshelf:onCloseDocument (skip the nextTick re-show; the finish raises
-- and shows the shelf itself) and Bookshelf:_takeOver (the fresh FM-side
-- plugin init must not stack an extra show/softRefresh - the #35 double
-- EPDC flash).
function Park.isFinishingClose()
    return _finishing_close
end

-- Input stamping for the idle trigger. UIManager:sendEvent is the choke
-- point every input-driven event flows through regardless of which widget
-- is topmost, so popup/keyboard interaction counts as activity too (a
-- shelf-only stamp would let the idle clock run while the user is busy in
-- a dialog, then fire the block the moment they close it). Installed
-- lazily at first park, idempotent, negligible per-event cost.
local function _installInputStamp()
    if not UIManager.sendEvent or UIManager._bookshelf_input_stamp then return end
    UIManager._bookshelf_input_stamp = true
    local orig = UIManager.sendEvent
    UIManager.sendEvent = function(self_um, event, ...)
        local h = type(event) == "table" and event.handler
        if h == "onGesture" or h == "onKeyPress" or h == "onKeyRepeat" then
            _last_input = _gettime()
        end
        return orig(self_um, event, ...)
    end
end

-- Exposed for tests and for any host that wants to stamp explicitly.
function Park.noteInput()
    _last_input = _gettime()
end

-- The core close sequence: really close the parked reader behind the
-- opaque shelf and let the FileManager re-instantiate underneath. From
-- here on the stack looks exactly like a pre-parking book close (shelf
-- over live FM), so the system menu is the FM menu and every legacy
-- behaviour applies. This is _safeShow's close sequence minus the
-- message - the shelf is already up, painted, and stays on top
-- throughout. Synchronous and BLOCKING (1-3s worst case): callers choose
-- a moment the user isn't interacting.
-- Returns true when the close actually ran.
local function _finishCore(reason)
    if not Park.isParked() then return false end
    local rui, plugin = _parked, _parked_plugin
    _parked, _parked_plugin = nil, nil
    _cancelPendingProbe()
    local file = rui.document and rui.document.file
    local t0 = _gettime()
    _finishing_close = true
    pcall(function() rui:onClose(false) end)
    local t1 = _gettime()
    if rui.showFileManager then
        pcall(function() rui:showFileManager(file) end)
    end
    local t2 = _gettime()
    -- showFileManager raised the fresh FM ABOVE the shelf; splice the
    -- shelf back on top, then the warm show() restores rotation and
    -- refreshes shelf data (same pairing _safeShow uses).
    if plugin then
        pcall(function() plugin:_raiseInPlace() end)
        pcall(function() plugin:show() end)
    end
    -- Keep the flag through the NEXT tick so the FM-side _takeOver
    -- (scheduled by the fresh plugin init inside showFileManager) sees it
    -- and stands down - same idiom as _suppress_close_document_show.
    UIManager:nextTick(function() _finishing_close = false end)
    logger.dbg(string.format(
        "[bookshelf perf] park finish: reason=%s onClose=%.0fms showFM=%.0fms raise+show=%.0fms TOTAL=%.0fms",
        tostring(reason), (t1 - t0) * 1000, (t2 - t1) * 1000,
        (_gettime() - t2) * 1000, (_gettime() - t0) * 1000))
    return true
end

-- Idle probe: reschedules itself until the device has been input-idle
-- long enough AND the shelf is the topmost widget (finishing under a live
-- popup would bury it beneath the fresh FM), then runs the finish.
local function _probe(rui)
    _pending_probe = nil
    if _parked ~= rui then return end -- unparked or real-closed meanwhile
    if _readerInstance() ~= rui then
        _parked = nil
        _parked_plugin = nil
        return
    end
    local idle = _gettime() - _last_input
    local stack = UIManager._window_stack
    local top = stack and stack[#stack] and stack[#stack].widget
    local shelf_topmost = _parked_plugin and top == _parked_plugin._widget
    if idle >= IDLE_FINISH_S and shelf_topmost then
        _finishCore("idle")
        return
    end
    _pending_probe = function() _probe(rui) end
    UIManager:scheduleIn(PROBE_EVERY_S, _pending_probe)
end

-- park(plugin, widget) -> bool
-- plugin is the reader-context Bookshelf plugin instance (plugin.ui is the
-- live ReaderUI). widget is the canonical shelf widget (_live_widget) - the
-- reader-host plugin's own self._widget is nil at park time (its show() has
-- not run), so the orientation guard below must be handed the widget that
-- actually carries _pre_read_rotation. Returns false when parking does not
-- apply, so the caller can fall back to the full close path.
function Park.park(plugin, widget)
    if not Park.enabled() then return false end
    local rui = plugin and plugin.ui
    if not (rui and rui.document) then return false end
    -- Orientation changed while reading (e.g. a book read in landscape)?
    -- Decline to park and let the normal close run, so the shelf's pre-read
    -- orientation is restored right away. Parking keeps the reader's rotation
    -- (the restore in onShow is gated on not-parked to avoid corrupting the
    -- parked layout), which left the shelf stuck sideways until the deferred
    -- real close (issue #266). Only instant reopen for a differently-oriented
    -- book is given up; same-orientation exits still park.
    --
    -- Read the rotation from the canonical widget (passed in), falling back to
    -- plugin._widget only for callers that still have it: the earlier fix read
    -- plugin._widget directly, which is nil in the reader host, so the guard
    -- silently no-opped and differently-oriented reads parked anyway.
    local shelf = widget or (plugin and plugin._widget)
    local pre = shelf and shelf._pre_read_rotation
    if pre ~= nil then
        local Screen = require("device").screen
        if Screen and Screen.getRotationMode and Screen:getRotationMode() ~= pre then
            return false
        end
    end
    -- Close the reader chrome first - the same prelude KOReader's own
    -- switchDocument uses. A menu or config panel left open would sit
    -- orphaned above the shelf after the splice.
    rui:handleEvent(Event:new("CloseReaderMenu"))
    rui:handleEvent(Event:new("CloseConfigMenu"))
    if rui.highlight and rui.highlight.onClose then
        pcall(function() rui.highlight:onClose() end)
    end
    -- Splice the shelf above the reader. False when the shelf widget is
    -- not on the stack (book opened from the raw FileManager): there is
    -- nothing to raise, so the fallback close path applies (#110 intent).
    if not plugin:_raiseInPlace() then return false end
    _parked = rui
    _parked_plugin = plugin
    _installInputStamp()
    -- Parking itself is user input for idle purposes.
    _last_input = _gettime()
    local file = rui.document.file
    UIManager:nextTick(function()
        if _parked ~= rui then return end -- real-closed in the gap
        -- Flush progress so a crash while parked loses nothing AND the
        -- shelf refresh below reads fresh percent/status from the sidecar.
        pcall(function() rui:saveSettings() end)
        -- Parity with ReaderUI:onClose's cache write so KOReader's own
        -- lists (History, CoverBrowser) do not show stale progress while
        -- the book is parked. pcall'd: BookList differs across versions.
        pcall(function()
            local BookList = require("ui/widget/booklist")
            BookList.setBookInfoCacheProperty(file, "percent_finished",
                rui.doc_settings:readSetting("percent_finished"))
        end)
        -- The invalidations Bookshelf:onCloseDocument performs on a real
        -- close: this file's stats/progress changed, and read-state
        -- sorted chips (Recent) hold a stale cached order.
        local ok_repo, Repo = pcall(require, "lib/bookshelf_book_repository")
        if ok_repo and Repo then
            if Repo.invalidateStatsCache then Repo.invalidateStatsCache(file) end
            if Repo.invalidateProgressCache then Repo.invalidateProgressCache(file) end
            if Repo.invalidateReadStateCache then Repo.invalidateReadStateCache() end
        end
        -- Warm-path show: softRefresh (hero swap + spine refresh +
        -- deferred shelf re-sort). The rotation restore inside show() is
        -- gated on not-parked, so this cannot yank rotation under the
        -- live reader.
        plugin:show()
    end)
    -- Arm the idle probe: the finish runs at the first quiet moment.
    _cancelPendingProbe()
    _pending_probe = function() _probe(rui) end
    UIManager:scheduleIn(PROBE_EVERY_S, _pending_probe)
    return true
end

-- unpark(live_widget, after_open_callback) -> bool
-- Splice the parked reader back above the shelf. live_widget is the
-- BookshelfWidget singleton (its status timer and hero memo need the same
-- pre-read treatment _launchReader gives them). after_open_callback, when
-- given (bookmark jumps), runs immediately with the live ReaderUI - the
-- document is already open.
function Park.unpark(live_widget, after_open_callback)
    if not Park.isParked() then return false end
    local rui = _parked
    _parked = nil
    _parked_plugin = nil
    _cancelPendingProbe()
    local stack = UIManager._window_stack
    if not stack then return false end
    local idx
    for i, entry in ipairs(stack) do
        if entry.widget == rui then
            idx = i
            break
        end
    end
    if not idx then return false end
    if live_widget then
        if live_widget._stopStatusTimer then
            pcall(function() live_widget:_stopStatusTimer() end)
        end
        -- Progress changes during the resumed read; the memoised hero
        -- record must not survive into the next return (#103 parity with
        -- _launchReader).
        live_widget._hero_current_memo = nil
        -- Same _launchReader parity: an unpark IS bookshelf opening the
        -- book, so the eventual close returns to the shelf.
        live_widget._opened_book = true
    end
    if idx ~= #stack then
        local entry = table.remove(stack, idx)
        table.insert(stack, entry)
    end
    -- "full": matches what a real book open uses (UIManager:show(reader,
    -- "full")), so the transition reads as a normal open - the flash
    -- clears shelf ghosting under the page. Revisit "ui" on device if the
    -- flash reads as slow.
    UIManager:setDirty(rui, "full")
    if after_open_callback then pcall(after_open_callback, rui) end
    return true
end

-- finishToMenu() -> bool
-- The top-edge menu gesture landed while still parked: the user wants the
-- system menu, and the correct one is the FileManager menu - which needs
-- the FM to exist. Convert on the spot: run the finish synchronously,
-- then open the fresh FM's menu. No "Closing book…" message here - a
-- transient message between menu-tap and menu-open read as confusing
-- rather than reassuring; the menu simply arrives ~1s late, once per
-- book at most.
function Park.finishToMenu()
    if not Park.isParked() then return false end
    _finishCore("menu")
    local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
    local fm = ok_fm and FileManager and FileManager.instance
    if fm and fm.menu and fm.menu.onShowMenu then
        pcall(function() fm.menu:onShowMenu() end)
    end
    return true
end

-- closeShelfToFileManager(live_widget) -> bool
-- Explicit exit from a parked shelf to the raw FileManager ("Close
-- Bookshelf", or the File-browser menu tab tapped while parked). Order
-- matters: the parked reader real-closes BEHIND the still-visible shelf
-- (no flash of the book page), KOReader's showFileManager then raises FM
-- above the shelf, and only then is the shelf widget dismissed
-- underneath. onCloseDocument consumes the one-shot to skip its re-show
-- and to stand the next onShow takeover down (the #110 raw-FM idiom).
function Park.closeShelfToFileManager(live_widget)
    if not Park.isParked() then return false end
    local rui = _parked
    _parked = nil
    _parked_plugin = nil
    _cancelPendingProbe()
    local file = rui.document and rui.document.file
    -- Same feedback affordance (and opt-out setting) as the fallback
    -- close path: the onClose below blocks for the sidecar/DocCache work.
    local msg
    if BookshelfSettings.nilOrTrue("show_close_msg") then
        local ok_im, InfoMessage = pcall(require, "ui/widget/infomessage")
        if ok_im and InfoMessage then
            msg = InfoMessage:new{ text = _("Closing book…"), timeout = 0.0 }
            UIManager:show(msg)
            UIManager:setDirty(msg, function() return "partial", msg.dimen end)
        end
    end
    UIManager:forceRePaint()
    _closing_to_fm = true
    UIManager:nextTick(function()
        pcall(function() rui:onClose(false) end)
        -- onCloseDocument consumed the one-shot during onClose; clear it
        -- anyway in case that handler never ran (defensive - a stuck
        -- one-shot would silently eat the next real close's re-show).
        _closing_to_fm = false
        if rui.showFileManager then
            pcall(function() rui:showFileManager(file) end)
        end
        if live_widget then
            pcall(function() UIManager:close(live_widget) end)
        end
        if msg then UIManager:close(msg) end
    end)
    return true
end

return Park
