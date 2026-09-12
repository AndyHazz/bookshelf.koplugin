-- bookshelf_night_mode_sync.lua
-- Put the panel back in step with what KOReader believes about night mode.
--
-- ── WHY ─────────────────────────────────────────────────────────────────────
--
-- On a device with canHWInvert (every recent Kindle, among others), night
-- mode is not painted. KOReader paints the same day-mode pixels it always
-- does, and the PANEL inverts them at refresh time, because of a flag in the
-- kernel's fb_var_screeninfo:
--
--     vinfo.grayscale = GRAYSCALE_8BIT_INVERTED   -- 0x2
--
-- Images are the exception. ImageWidget pre-inverts what it draws when
-- Screen.night_mode is set, so that the panel's inversion cancels it out and
-- the picture arrives the right way up:
--
--     if Screen.night_mode and self.original_in_nightmode and not self.is_icon
--
-- So there are two pieces of state that have to agree: the flag on the fb
-- device, and Screen.night_mode in this process. When they do not, covers
-- come out NEGATIVE while the chrome looks fine -- fine by accident, since
-- day paint inverted once reads as night.
--
-- They can come apart because the flag is kernel-side and outlives the
-- process, while Device:init() only ever SETS it:
--
--     self.orig_hw_nightmode = self.screen:getHWNightmode()
--     if G_reader_settings:isTrue("night_mode") then
--         self.screen:toggleNightMode()
--     end
--
-- There is no branch that clears it. A session that ends without
-- Device:exit() -- a crash, a battery pull, a forced relaunch -- leaves the
-- panel inverted, and the next startup with night mode off walks straight
-- past it. Worse, Device:exit() restores orig_hw_nightmode on the way out,
-- so once a session has started in the broken state it hands the same broken
-- state to the next one. Measured on a PW5 mid-report: settings night_mode
-- false, fb0 vinfo.grayscale 0x2.
--
-- ── WHAT WE DO ──────────────────────────────────────────────────────────────
--
-- One comparison at init. If the flag disagrees with Screen.night_mode, the
-- flag is wrong by definition -- Screen.night_mode is what every widget in
-- the process paints against -- so the panel is set to match it. Nothing
-- happens on a device without the capability, and nothing happens when the
-- two already agree, which is every healthy startup.
--
-- This repairs state that belongs to KOReader rather than to us, which is
-- not something a plugin should do lightly. It earns its place because the
-- damage lands squarely on our shelf: a wall of negative covers, with no way
-- to paint around it, and no way for a reader to guess that the fix is to
-- toggle a setting that already looks correct.

local NightModeSync = {}

local function bool(v)
    return v and true or false
end

--- repair(screen) -> true if the panel was out of step and has been reset.
--
-- `screen` is Device.screen. Returns false for every not-applicable case
-- (no screen, no HW inversion on this device, already in step) and for a
-- repair that failed, so the caller can log the one event worth logging.
function NightModeSync.repair(screen)
    if type(screen) ~= "table" then return false end
    -- getHWNightmode is only meaningful where the panel can invert; the
    -- generic framebuffer returns a hardcoded false, and so does the linux
    -- one when canHWInvert/canModifyFBInfo say no. Either way, a device that
    -- inverts in software cannot drift: there is no second copy of the state.
    if type(screen.getHWNightmode) ~= "function"
            or type(screen.setHWNightmode) ~= "function" then
        return false
    end

    local ok_get, panel = pcall(screen.getHWNightmode, screen)
    if not ok_get then return false end

    -- night_mode is a plain field, and starts life absent rather than false.
    local believed = bool(screen.night_mode)
    if bool(panel) == believed then return false end

    -- setHWNightmode asserts on a failed FBIOPUT_VSCREENINFO. This runs
    -- during init, where a throw would take the plugin down over a cosmetic
    -- repair, so it is contained.
    local ok_set = pcall(screen.setHWNightmode, screen, believed)
    return bool(ok_set)
end

return NightModeSync
