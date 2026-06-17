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

return M
