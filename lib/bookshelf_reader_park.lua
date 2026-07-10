-- lib/bookshelf_reader_park.lua
--
-- Hot reader parking: leaving a book for the shelf does NOT close the
-- document. The BookshelfWidget overlay is spliced above the live ReaderUI
-- in UIManager's window stack; the reader stays loaded ("parked")
-- underneath. Returning to the same book is the reverse splice - no
-- document load, no FileManager involvement at all. Opening a DIFFERENT
-- book rides KOReader's normal ShowingReader teardown of the parked
-- instance (a real close, paying the deferred DocCache serialize at a
-- moment the user expects a load). Any KOReader-initiated close (History
-- switch, end-of-book action, exit) also real-closes; Bookshelf's
-- onCloseDocument calls noteRealClose() so this module's state can never
-- outlive the instance it points at.
--
-- State is in-memory only, by design (runtime flags don't survive crashes,
-- so never persist them): _parked is re-validated against
-- ReaderUI.instance identity on every read and self-heals to "not parked"
-- when they diverge.

local UIManager         = require("ui/uimanager")
local Event             = require("ui/event")
local BookshelfSettings = require("lib/bookshelf_settings_store")

local Park = {}

-- The ReaderUI instance currently parked beneath the shelf, or nil.
local _parked = nil

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
        return false
    end
    return true
end

function Park.parkedFile()
    if not Park.isParked() then return nil end
    return _parked.document and _parked.document.file or nil
end

-- Called from Bookshelf:onCloseDocument - any real close invalidates
-- parking state, whether or not the closing reader was the parked one.
function Park.noteRealClose()
    _parked = nil
end

-- park(plugin) -> bool
-- plugin is the reader-context Bookshelf plugin instance (plugin.ui is the
-- live ReaderUI). Returns false when parking does not apply, so the caller
-- can fall back to the full close path.
function Park.park(plugin)
    if not Park.enabled() then return false end
    local rui = plugin and plugin.ui
    if not (rui and rui.document) then return false end
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

return Park
