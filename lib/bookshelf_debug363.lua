-- lib/bookshelf_debug363.lua -- TEMPORARY diagnostic for issue 363
-- ("book description text size is not saved").
--
-- NOT PART OF A RELEASE. This module exists only on the debug/363 branch and
-- must never be merged to master.
--
-- WHY IT EXISTS. The reporter sees the description's font size revert, but only
-- when the popup is opened by LONG-PRESSING the hero and then switching to the
-- Description tab. Opening it by TAPPING the description keeps the size. The
-- two routes differ in exactly one way: the tap route calls
-- _showBookDetail(book) with no options, so the popup opens on its default tab,
-- while the long-press route passes { active = "edit" } and the reader switches
-- tabs afterwards. The maintainer cannot reproduce either way, on the same
-- device model the reporter uses.
--
-- The size is stored per tab (TAB_FONT_KEYS in bookshelf_reviews_modal), and
-- the key is resolved from whichever tab _active_tab points at. So the question
-- this build answers is narrow: at the moment the reader taps A+, is the tab
-- the code thinks is active the same one they are looking at? If a zoom on the
-- Description tab writes edit_font_size, the text would resize on screen (the
-- render uses the in-memory value) and be gone on reopen -- which is the
-- reported symptom exactly.
--
-- Writes BOTH ways on purpose:
--   * a toast, so the reporter can photograph one screen and answer it, with no
--     file transfer and no cable
--   * a log file, so the whole sequence is recoverable if the toast is missed
--
-- Everything is wrapped in pcall: a diagnostic build that crashes tells us
-- nothing and costs the reporter their home screen.

local Debug363 = {}

local _path
local function logPath()
    if _path then return _path end
    local ok, DataStorage = pcall(require, "datastorage")
    local dir = ok and DataStorage and DataStorage:getDataDir() or "/tmp"
    _path = dir .. "/bookshelf-363.log"
    return _path
end

-- The log file's own path, so an issue reply can tell the reporter where to
-- look without guessing at their platform's data directory.
function Debug363.path() return logPath() end

local function stamp()
    local ok, t = pcall(os.date, "%H:%M:%S")
    return ok and t or "??:??:??"
end

--- log(line) -- append one line to the log file. Silent on failure.
function Debug363.log(line)
    pcall(function()
        local f = io.open(logPath(), "a")
        if not f then return end
        f:write(stamp(), "  ", tostring(line), "\n")
        f:close()
    end)
end

--- toast(line) -- log it AND put it on screen. Used for the few moments that
--- actually answer the question, so the reporter is not asked to read a file.
function Debug363.toast(line)
    Debug363.log(line)
    pcall(function()
        local UIManager    = require("ui/uimanager")
        local Notification = require("ui/widget/notification")
        UIManager:show(Notification:new{ text = tostring(line), timeout = 4 })
    end)
end

--- describe(modal) -- the state that decides which key a zoom writes to.
--- Deliberately reports the tab the CODE believes is active, by index and by
--- id, next to the key that falls out of it.
function Debug363.describe(modal)
    local ok, out = pcall(function()
        local i    = modal._active_tab
        local tabs = modal._tabs
        local tab  = tabs and tabs[i]
        local ids  = {}
        for n = 1, #(tabs or {}) do
            ids[#ids + 1] = n .. "=" .. tostring(tabs[n] and tabs[n].id)
        end
        return string.format("tab %s id=%s key=%s size=%s | tabs[%s]",
            tostring(i),
            tostring(tab and tab.id),
            tostring(modal.__dbg_key and modal:__dbg_key() or "?"),
            tostring(modal.font_size),
            table.concat(ids, " "))
    end)
    return ok and out or "describe failed"
end

return Debug363
