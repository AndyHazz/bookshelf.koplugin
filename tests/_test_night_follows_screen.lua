-- tests/_test_night_follows_screen.lua
-- The shelf follows the SCREEN's night state, however it was changed.
--
-- Usage (from plugin root): lua tests/_test_night_follows_screen.lua
--
-- Issue 426. Another plugin's night toggle can do what DeviceListener's
-- handler does -- Screen:toggleNightMode(), UIManager:ToggleNightMode(), save
-- the setting, a full refresh -- but broadcast NO event. The shelf's
-- ToggleNightMode / SetNightMode handlers never ran, so the wallpaper cache
-- was never flipped: on the desktop rig, replaying that toggle verbatim, the
-- panel came out right (its colours already follow the screen) and the
-- wallpaper came out as a NEGATIVE of itself. Half and half.
--
-- The fix is the collate_mixed idiom already in paintTo: a change that
-- arrives with no event still ends in a paint, so compare the night state
-- the tree was BUILT for with the screen's, and when they differ, rebuild
-- right there, inside the paint. Not on the next tick: the switch's own full
-- refresh would paint the old tree first, every baked colour wrong for a
-- frame, and the shadows flashed (maintainer, 2026-09-23). The event path's
-- deferred rebuild then finds nothing pending and stands down.

package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local src = io.open("lib/bookshelf_widget.lua"):read("*a")

local body = src:match("\nfunction BookshelfWidget:_followScreenNight%(%)\n(.-)\nend\n")
assert(body, "BookshelfWidget:_followScreenNight is missing")

local flips, rebuilds
local function follow(built, screen_night, pending)
    flips, rebuilds = {}, 0
    local env = {
        Screen = { night_mode = screen_night },
        pcall = pcall,
        require = function(name)
            assert(name == "lib/bookshelf_wallpaper")
            -- preInvert with "invert wallpaper in night mode" off: the
            -- cached picture follows the frame, as it always has.
            return { flipNight = function(t) flips[#flips + 1] = t end,
                     preInvert = function(n) return n and true or false end }
        end,
    }
    local fn = assert(load("return function(self)\n" .. body .. "\nend",
        "_followScreenNight", "t", env))()
    local w = { _built_night = built, _night_rebuild_pending = pending }
    function w:_rebuild()
        rebuilds = rebuilds + 1
        self._built_night = env.Screen.night_mode and true or false
        self._night_rebuild_pending = nil
    end
    fn(w)
    return w
end

t.test("a night switch that sent no event is rebuilt in this very paint", function()
    local w = follow(false, true, nil)
    eq(rebuilds, 1, "the shelf ignored a screen that went to night")
    eq(w._built_night, true)
    eq(flips[1], true, "no event flipped the wallpaper, so this must")
end)

t.test("...and back to day the same way", function()
    follow(true, false, nil)
    eq(rebuilds, 1); eq(flips[1], false)
end)

t.test("no change, no rebuild", function()
    follow(true, true, nil); eq(rebuilds, 0)
    follow(false, false, nil); eq(rebuilds, 0)
end)

t.test("an event already on its way: rebuild now, and leave the wallpaper to it", function()
    -- The event handler flipped the wallpaper and deferred a rebuild; the
    -- toggle's full refresh paints before that tick. Rebuilding here makes the
    -- frame right, and settles the flag so the tick stands down.
    local w = follow(false, true, true)
    eq(rebuilds, 1, "the refresh painted the old theme first: the flash")
    eq(#flips, 0, "the wallpaper was flipped twice, back to the wrong way")
    eq(w._night_rebuild_pending, nil)
end)

t.test("before the first rebuild there is nothing to compare", function()
    follow(nil, true, nil)
    eq(rebuilds, 0)
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
