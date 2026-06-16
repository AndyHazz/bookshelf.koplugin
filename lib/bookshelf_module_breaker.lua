--[[
Open-crash breaker for the start menu.

A micro-module's render runs on every menu open. Two cheap protections:

  * guard(fn): runs the render under pcall, so a Lua error degrades to a
    fallback "(error)" row instead of taking down the whole build. It does NO
    disk writes - this is the hot path (once per module per open) and the
    earlier per-render arm/disarm of a persisted marker flushed the 100 KB+
    bookshelf.lua to e-ink storage twice per module, which dominated the menu's
    open time (~115ms floor per module on PW5). Prevention now lives in
    safeText (lib/bookshelf_text_safe), so per-module crash pinning isn't worth
    a flush per render.

  * armOpen / endOpen / openCrashed: ONE persisted "open in progress" marker.
    Armed before the menu is shown, cleared once the first paint returns. If a
    paint-pass segfault (or a render hard-crash safeText didn't prevent) kills
    the app before the clear, the marker survives on disk and the next open
    detects it and comes up in SAFE MODE (all modules suppressed) so the user
    can still get in. Two writes per open, total.

The store is injected (read/save/delete, matching lib/bookshelf_settings_store)
so the logic is unit-testable without KOReader's LuaSettings.
]]

local M = {}

-- "An open is in progress and hasn't completed a paint yet." Survives a crash
-- because the real store flushes on save.
M.OPEN_KEY = "start_menu_open_inflight"

-- Run a module render under pcall. Returns (true, result) or (false, err).
-- No store access: the hot path stays off disk.
function M.guard(fn)
    local ok, res = pcall(fn)
    if not ok then return false, res end
    return true, res
end

-- Mark that an open is in progress (before the menu is shown). Durable: the
-- real store flushes, so it survives a crash before the first paint.
function M.armOpen(store)
    store.save(M.OPEN_KEY, true)
end

-- Clear the open marker once the first paint has succeeded.
function M.endOpen(store)
    store.delete(M.OPEN_KEY)
end

-- True if an open armed but never completed a paint (it crashed). Read at the
-- start of the next open, BEFORE armOpen re-arms it.
function M.openCrashed(store)
    return store.read(M.OPEN_KEY) == true
end

--[[
Light-touch crash marker for the HOME-SCREEN hero micro-module grid.

The hero repaints on every shelf render - far more often than the start menu
opens - so the start-menu marker (a key in the 100KB+ settings store, flushed
to e-ink on every save) is too heavy here. The hero marker is instead a 0-byte
sentinel FILE: arming creates it, surviving the paint removes it. That's a
directory-entry write, not a settings flush, and it's just as durable against a
segfault (the kernel keeps buffered writes across a process crash; only a power
cut would lose them, which this doesn't defend against).

Semantics mirror armOpen/endOpen/openCrashed: arm before the hero paints, clear
once the paint returns; if the file survives to the next launch the paint
crashed, so the home screen comes up with the cover hero (modules suppressed)
instead of locking the user out (issue #163). Path is resolved lazily and
guarded so the standalone test runner (no DataStorage) can still load this.
]]
function M.heroMarkerPath()
    local ok, DataStorage = pcall(require, "datastorage")
    if ok and DataStorage then
        return DataStorage:getSettingsDir() .. "/bookshelf_hero_inflight"
    end
    return nil
end

-- Create the sentinel (arm). No-op if the path is unavailable.
function M.armFile(path)
    if not path then return end
    local f = io.open(path, "w")
    if f then f:close() end
end

-- Remove the sentinel - the paint survived (or we're recovering from a crash).
function M.endFile(path)
    if path then os.remove(path) end
end

-- True if the sentinel survived a previous arm, i.e. the paint crashed before
-- endFile ran. Uses lfs when present, else an io.open probe.
function M.fileCrashed(path)
    if not path then return false end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok_lfs and lfs and lfs.attributes then
        return lfs.attributes(path, "mode") ~= nil
    end
    local f = io.open(path, "r")
    if f then f:close(); return true end
    return false
end

return M
