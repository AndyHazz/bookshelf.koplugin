-- tests/_test_microfs_minute_tick.lua
-- Reddit report: in the full-screen micro-modules view the clock and battery
-- never update. The view's grid takes over the clock-cell list when it opens,
-- but the shelf's minute tick only advanced clocks for a micro-modules HERO,
-- and repainted the shelf under the view; the view's own status line was
-- built once and never refreshed.
-- Run from the plugin root: lua tests/_test_microfs_minute_tick.lua
package.path = "./?.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()
local w  = io.open("lib/bookshelf_widget.lua"):read("*a")
local hm = io.open("lib/bookshelf_hero_modules.lua"):read("*a")
local mf = io.open("lib/bookshelf_micro_fullscreen.lua"):read("*a")

t.test("the minute tick serves an open full-screen view first", function()
    local tick = w:match("self%._status_timer_func = function%(%).-Re%-arm at the next minute boundary")
    assert(tick, "the minute tick moved")
    local i = tick:find("_micro_fullscreen", 1, true)
    assert(i, "the tick ignores the full-screen micro-modules view")
    local after = tick:sub(i, i + 700)
    assert(after:find("tickClocks(self)", 1, true) and after:find("refreshStatus()", 1, true),
        "the view's clocks and status line are not ticked")
end)

t.test("tickClocks repaints the overlay when the cells live there", function()
    local f = hm:match("function HeroModules%.tickClocks%(bw%).-\nend")
    assert(f and f:find("bw._micro_fullscreen or bw", 1, true), "clock ticks repaint the shelf under the overlay")
end)

t.test("the full-screen view can rebuild its status line in place", function()
    assert(mf:find("function MicroFullscreen:refreshStatus()", 1, true), "no refreshStatus")
    local b = mf:match("function MicroFullscreen:_build%(%).-\nend\n")
    assert(b and b:find("self._status_rec", 1, true), "_build does not record the status row")
end)

t.done()
