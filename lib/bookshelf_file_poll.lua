-- lib/bookshelf_file_poll.lua
-- Pure decision logic for BookshelfWidget's new-file poll, extracted (like
-- bookshelf_drill_rekey) so the standalone test harness can cover it: the
-- widget itself can't load under tests/run.sh.
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

-- st = { shelf_on_stack, reader_active, reader_parked } (booleans)
function M.coveredDecision(st)
    if not st.shelf_on_stack then return "cancel" end
    if st.reader_active and not st.reader_parked then return "cancel" end
    return "idle"
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
