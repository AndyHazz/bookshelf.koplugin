-- lib/bookshelf_file_poll.lua
-- Pure decision logic for BookshelfWidget's new-file poll, extracted (like
-- bookshelf_drill_rekey) so the standalone test harness can cover it: the
-- widget itself can't load under tests/run.sh. It also now decides the poll's
-- own cadence, rather than always ticking on a single fixed timer.
--
-- History: #304 made the poll cancel whenever the shelf isn't topmost, to stop
-- it waking the device for a whole reading session. That mechanism was broader
-- than the motive - it also killed the poll under TRANSIENT UIs (the stock
-- OPDS browser, terminal, ...), and because re-arming re-baselines the mtime
-- snapshot, a book downloaded while covered was never detected. The decision
-- is now: cancel only for the reading-session case (an active, non-parked
-- reader) or when the shelf left the window stack; otherwise idle - keep the
-- tick alive with no disk I/O so the pre-cover baseline survives.

local M = {}

M.ACTIVE_INTERVAL_S  = 5    -- input within IDLE_AFTER_S
M.IDLE_INTERVAL_S    = 60   -- no input for IDLE_AFTER_S or longer
M.IDLE_AFTER_S       = 60
M.COVERED_INTERVAL_S = 30   -- another widget is on top; the tick does no disk I/O

-- st = { shelf_on_stack, reader_active, reader_parked } (booleans)
function M.coveredDecision(st)
    if not st.shelf_on_stack then return "cancel" end
    if st.reader_active and not st.reader_parked then return "cancel" end
    return "idle"
end

-- st = {
--   wifi_on = true | false | nil   -- nil = unknown; treated as on
--   covered = boolean or nil       -- shelf not the topmost visible widget
--   idle_s  = number or nil        -- seconds since the last input; nil = 0
-- }
--
-- Measured on device (2026-09-16): on a Kobo, the autosuspend plugin sets its
-- RTC wake alarm for the earliest pending scheduled task plus one second. A
-- poll that is always due within a few seconds therefore wakes an idling
-- device roughly every 6 s to stat up to 200 top-level folders, rather than
-- letting it sleep through to suspend the way the stock file manager (which
-- schedules nothing) does. And with Wi-Fi off nothing can arrive over the
-- network to find - a USB copy already reaches the shelf via the
-- suspend/resume and USB-unplug paths, which run their own check - so the
-- poll has nothing useful to do until one of those events re-arms it.
--
-- Rule order: Wi-Fi off beats everything and returns nil (don't schedule);
-- otherwise covered beats idle; otherwise idle-for-a-while beats active; the
-- default is the active interval.
function M.nextInterval(st)
    if st.wifi_on == false then return nil end
    if st.covered then return M.COVERED_INTERVAL_S end
    if (st.idle_s or 0) >= M.IDLE_AFTER_S then return M.IDLE_INTERVAL_S end
    return M.ACTIVE_INTERVAL_S
end

-- The stock download destination (opdsbrowser.lua:1204, cloudstorage, news):
-- download_dir falling back to lastdir. No default exists; either may be
-- unset. read_setting is a function so this stays testable without
-- G_reader_settings.
function M.effectiveDownloadDir(read_setting)
    local d = read_setting("download_dir")
    if type(d) ~= "string" or d == "" then d = read_setting("lastdir") end
    if type(d) ~= "string" or d == "" then return nil end
    if d ~= "/" then d = d:gsub("/+$", "") end
    return d
end

return M
