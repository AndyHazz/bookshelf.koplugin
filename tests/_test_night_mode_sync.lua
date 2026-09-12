-- tests/_test_night_mode_sync.lua
-- NightModeSync.repair(Screen): put the panel back in step with what
-- KOReader believes about night mode.
--
-- The bug it exists for, measured on a PW5:
--
--   settings night_mode = false
--   fb0 vinfo.grayscale = 0x2 (GRAYSCALE_8BIT_INVERTED)
--
-- On a device with canHWInvert, night mode is not painted -- the panel
-- inverts everything at refresh time, via a flag in the kernel's
-- fb_var_screeninfo. That flag outlives the KOReader process, and
-- Device:init() only ever SETS it:
--
--     self.orig_hw_nightmode = self.screen:getHWNightmode()
--     if G_reader_settings:isTrue("night_mode") then
--         self.screen:toggleNightMode()
--     end
--
-- There is no matching branch to clear it. So a session that ends without
-- Device:exit() (a crash, a forced relaunch) hands the next one an inverted
-- panel nobody knows about, and Device:exit() then preserves that value as
-- "the original" on every clean exit after -- the state is sticky.
--
-- With Screen.night_mode false and the panel inverting, chrome comes out
-- looking RIGHT by accident (day paint, inverted once, reads as night) while
-- every cover comes out NEGATIVE, because ImageWidget only pre-inverts
-- images when Screen.night_mode is true. That is the reported symptom:
-- "it comes back on night mode but all the covers are inverted".
--
-- Usage (from plugin root): lua tests/_test_night_mode_sync.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

local H = dofile("tests/_helpers.lua")
local t = H.runner()

local Sync = require("lib/bookshelf_night_mode_sync")

-- A stand-in for Device.screen: the two sources of truth, and a record of
-- what was asked of the hardware.
local function screen(software_night, panel_inverted, opts)
    opts = opts or {}
    local s = {
        night_mode = software_night,
        _panel = panel_inverted,
        calls = {},
    }
    if not opts.no_getter then
        s.getHWNightmode = function(self) return self._panel end
    end
    s.setHWNightmode = function(self, on)
        self.calls[#self.calls + 1] = on
        if opts.throws then error("cannot set variable screen info") end
        self._panel = on
    end
    return s
end

t.test("repair: an inverted panel under day mode is put back", function()
    -- The measured failure. Covers were coming out negative.
    local s = Sync.repair(screen(false, true))
    assert(s == true, "the desync should be reported as repaired")
end)

t.test("repair: the panel is set to what KOReader believes, not toggled", function()
    local sc = screen(false, true)
    Sync.repair(sc)
    assert(#sc.calls == 1, "expected one hardware write, got " .. #sc.calls)
    assert(sc.calls[1] == false,
        "the panel must follow Screen.night_mode; got " .. tostring(sc.calls[1]))
    assert(sc._panel == false, "the panel is still inverted")
end)

t.test("repair: a normal panel under night mode is put back too", function()
    -- The mirror case: night_mode survived in settings but the flag did not
    -- (a reboot clears it), so nothing would invert and night mode would
    -- paint as a day screen with negative covers.
    local sc = screen(true, false)
    assert(Sync.repair(sc) == true, "the mirror desync should repair too")
    assert(sc.calls[1] == true, "the panel should have been inverted")
end)

t.test("repair: agreement is left completely alone", function()
    for _, state in ipairs({ false, true }) do
        local sc = screen(state, state)
        assert(Sync.repair(sc) == false,
            "a healthy screen was reported as repaired (" .. tostring(state) .. ")")
        assert(#sc.calls == 0,
            "a healthy screen must not be written to (" .. tostring(state) .. ")")
    end
end)

t.test("repair: nil and false both mean day, and do not read as a desync", function()
    -- Screen.night_mode is a plain field. A device that has never toggled it
    -- may leave it nil rather than false, and getHWNightmode returns a real
    -- false -- comparing them raw would repair a screen that is already fine.
    local sc = screen(nil, false)
    assert(Sync.repair(sc) == false, "nil vs false is not a desync")
    assert(#sc.calls == 0, "nothing should have been written")
end)

t.test("repair: a device without the capability is a no-op", function()
    -- getHWNightmode is only defined where the panel can invert. Everywhere
    -- else night mode is a software inversion of the buffer, which cannot
    -- drift, and there is nothing to repair.
    local sc = screen(false, true, { no_getter = true })
    assert(Sync.repair(sc) == false, "no getter means nothing to compare")
    assert(#sc.calls == 0, "must not write to a screen that cannot invert")
end)

t.test("repair: a failed ioctl is swallowed, not thrown at init", function()
    -- setHWNightmode asserts on a failed FBIOPUT_VSCREENINFO. This runs
    -- during plugin init; a throw there would take the whole plugin down
    -- over a cosmetic repair.
    local sc = screen(false, true, { throws = true })
    local ok, res = pcall(Sync.repair, sc)
    assert(ok, "repair must not propagate a framebuffer error: " .. tostring(res))
    assert(res == false, "a failed repair should not claim success")
end)

t.test("repair: a missing screen is a no-op", function()
    assert(Sync.repair(nil) == false, "no screen, nothing to do")
end)

t.done()
