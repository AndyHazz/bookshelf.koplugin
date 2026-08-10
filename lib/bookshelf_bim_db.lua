-- lib/bookshelf_bim_db.lua
-- Open CoverBrowser's BIM cache (bookinfo_cache.sqlite3) read-write, fully
-- pcall-guarded. Was duplicated (divergently: one copy returned failure
-- reasons, one bare nil) in bookshelf_file_ops and bookshelf_stale_sweep; any
-- change to the filename, open mode or guards belongs here, once.
--
--   M.open() -> conn | nil, reason
-- reason is a short loggable token ("no-db", "no-sqlite", ...). "no-db" is
-- normal on first run / with CoverBrowser disabled, not an error.

local M = {}

function M.open()
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if not ok_ds then return nil, "no-datastorage" end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then return nil, "no-lfs" end
    local db_path = DataStorage:getSettingsDir() .. "/bookinfo_cache.sqlite3"
    if not lfs.attributes(db_path, "mode") then return nil, "no-db" end
    local ok_sq, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok_sq then return nil, "no-sqlite" end
    local ok_open, db = pcall(SQ3.open, db_path)
    if not (ok_open and db) then return nil, "open-failed" end
    return db
end

return M
