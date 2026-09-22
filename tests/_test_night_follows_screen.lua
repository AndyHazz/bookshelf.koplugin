-- tests/_test_night_follows_screen.lua
-- The shelf follows the SCREEN's night state, however it was changed.
--
-- Usage (from plugin root): lua tests/_test_night_follows_screen.lua
--
-- Issue 426. ZenOS's quick-settings Night button (modules/menu/patches/
-- quick_settings.lua, now open source) does what DeviceListener's handler
-- does -- Screen:toggleNightMode(), UIManager:ToggleNightMode(), save the
-- setting, a full refresh -- but broadcasts NO event. The shelf's
-- ToggleNightMode / SetNightMode handlers never ran, so the wallpaper cache
-- was never flipped: on the desktop rig, replaying that button verbatim, the
-- panel came out right (its colours already follow the screen) and the
-- wallpaper came out as a NEGATIVE of itself. Half and half.
--
-- The fix is the collate_mixed idiom already in paintTo: a change that
-- arrives with no event still ends in a paint, so compare the night state
-- the tree was BUILT for with the screen's, and when they differ, run the
-- very same night rebuild the event path runs. Once: the event path marks
-- its own rebuild pending, so a normal toggle is not rebuilt twice.

package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local src = io.open("lib/bookshelf_widget.lua"):read("*a")

local body = src:match("\nfunction BookshelfWidget:_followScreenNight%(%)\n(.-)\nend\n")
assert(body, "BookshelfWidget:_followScreenNight is missing")

local scheduled
local function follow(built, screen_night, pending)
    scheduled = {}
    local env = {
        Screen = { night_mode = screen_night },
        _scheduleNightModeRebuild = function(w, target)
            scheduled[#scheduled + 1] = target
            w._night_rebuild_pending = true
        end,
    }
    local fn = assert(load("return function(self)\n" .. body .. "\nend",
        "_followScreenNight", "t", env))()
    local w = { _built_night = built, _night_rebuild_pending = pending }
    fn(w)
    return w
end

t.test("a night toggle that sent no event gets the night rebuild", function()
    follow(false, true, nil)
    eq(#scheduled, 1, "the shelf ignored a screen that went to night")
    eq(scheduled[1], true, "it rebuilt for the wrong state")
end)

t.test("...and back to day the same way", function()
    follow(true, false, nil)
    eq(scheduled[1], false)
end)

t.test("no change, nothing scheduled", function()
    follow(true, true, nil); eq(#scheduled, 0)
    follow(false, false, nil); eq(#scheduled, 0)
end)

t.test("a rebuild already pending is not doubled", function()
    -- The event path's own: its handler marks it pending and rebuilds on the
    -- next tick, and DeviceListener's full refresh paints in between.
    follow(false, true, true)
    eq(#scheduled, 0, "a normal toggle would rebuild twice")
end)

t.test("paints of the same change schedule it once", function()
    local w = follow(false, true, nil)
    eq(#scheduled, 1)
    assert(w._night_rebuild_pending, "the first schedule did not mark itself pending")
end)

t.test("before the first rebuild there is nothing to compare", function()
    follow(nil, true, nil)
    eq(#scheduled, 0)
end)

-- ── the wiring ─────────────────────────────────────────────────────────────

t.test("paintTo checks before it paints", function()
    local paint = src:match("\nfunction BookshelfWidget:paintTo%(bb, x, y%)\n(.-)\nend\n")
    assert(paint, "paintTo moved")
    local check = paint:find("self:_followScreenNight()", 1, true)
    local first = paint:find("InputContainer.paintTo(self, bb, x, y)", 1, true)
    assert(check, "paintTo never asks whether the night state moved")
    assert(first and check < first, "the check runs after the frame it should have fixed")
end)

t.test("the event path marks its rebuild pending", function()
    local sched = src:match("\nlocal function _scheduleNightModeRebuild%(self, target_night%)\n(.-)\nend\n")
    assert(sched and sched:find("self._night_rebuild_pending = true", 1, true),
        "the event path does not say a night rebuild is coming")
end)

t.test("every rebuild records the state it built for and settles the flag", function()
    local rb = src:match("\nfunction BookshelfWidget:_rebuild%(%)\n(.-)\nend\n")
    assert(rb, "_rebuild moved")
    local head = rb:sub(1, 1500)
    assert(head:find("self._built_night = Screen.night_mode and true or false", 1, true),
        "the rebuild does not record which night state it baked")
    assert(head:find("self._night_rebuild_pending = nil", 1, true),
        "a rebuild leaves a stale pending flag, and the next real change is ignored")
end)

t.done()
