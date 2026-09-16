-- tests/_test_night_mode_repaint.lua
-- The night-mode toggle repaints the shelf ONCE, not in three instalments.
--
-- WHAT NEEDS PINNING. KOReader's DeviceListener flips the screen, queues a
-- full refresh and saves night_mode -- AFTER our handler, because the shelf
-- sits above the file manager in the window stack and a broadcast walks it
-- top down. So the shelf has to defer. It used to defer twice: recolour the
-- glyphs and folder cards on the next tick and paint, then rebuild on the
-- tick after that and paint again, plus a debounced status-strip repaint.
-- With KOReader's own refresh that is three or four visible changes for one
-- toggle (maintainer: "looks a bit of a mess"). The recolour pass dates from
-- when a rebuild took half a second; the rebuild is what fixes everything, so
-- it runs on the first deferred tick and nothing else paints.
--
-- Usage (from plugin root): lua tests/_test_night_mode_repaint.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq
local src = io.open("lib/bookshelf_widget.lua"):read("*a")
local body = src:match("\nlocal function _scheduleNightModeRebuild%(self%)\n(.-)\nend\n")
assert(body, "_scheduleNightModeRebuild not found")
local code = body:gsub("%-%-[^\n]*", "")   -- comments out of the way

t.test("one deferred tick, and the rebuild is what runs in it", function()
    local n = select(2, code:gsub("UIManager:nextTick%(", ""))
    eq(n, 1, "expected exactly one nextTick, found " .. n)
    local tick_at    = code:find("UIManager:nextTick(", 1, true)
    local rebuild_at = code:find("self:_rebuild()", 1, true)
    assert(rebuild_at and tick_at and rebuild_at > tick_at, "the rebuild must run inside the deferred tick")
end)

t.test("nothing paints before the rebuild: no recolour pass, no gated status repaint", function()
    assert(not code:find("refreshColors", 1, true), "the glyph/folder recolour pass paints a frame of its own")
    assert(not code:find("_gatedRepaint", 1, true), "the debounced status repaint is a further change after the rebuild")
    local n = select(2, code:gsub("setDirty%(", ""))
    eq(n, 1, "expected one setDirty (after the rebuild), found " .. n)
end)

t.test("the wallpaper cache still flips on the handler's own tick, before anything is deferred", function()
    local flip_at = code:find("flipNight", 1, true)
    local tick_at = code:find("UIManager:nextTick(", 1, true)
    assert(flip_at and tick_at and flip_at < tick_at, "flipNight must precede the deferred tick")
end)

t.test("both KOReader events still reach the same scheduler", function()
    assert(src:find("function BookshelfWidget:onToggleNightMode()\n    _scheduleNightModeRebuild(self)", 1, true))
    assert(src:find("function BookshelfWidget:onSetNightMode()\n    _scheduleNightModeRebuild(self)", 1, true))
end)

t.done()
