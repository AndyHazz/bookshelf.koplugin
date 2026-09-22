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
-- Signature-agnostic: it gained a target_night parameter for issue 426, and
-- pinning the exact argument list here only breaks the capture silently.
local body = src:match("\nlocal function _scheduleNightModeRebuild%([^)]*%)\n(.-)\nend\n")
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
    -- Both still funnel into the one scheduler; they differ only in how they
    -- work out the target mode to hand it (issue 426).
    assert(src:find("function BookshelfWidget:onToggleNightMode()", 1, true))
    assert(src:find("function BookshelfWidget:onSetNightMode(night_mode_on)", 1, true))
    -- CALLS only: the definition line carries the same text, so anchor on the
    -- indent that only a call site has.
    --
    -- A THIRD caller is deliberate: _followScreenNight, from paintTo, for a
    -- night change that arrives with no event at all (ZenOS's Night button
    -- flips the screen and broadcasts nothing -- issue 426). It goes through
    -- the same scheduler, so there is still one night rebuild, not two ways
    -- of doing it. Each caller is named, and three is the total, so a fourth
    -- path cannot slip in unseen.
    local n = select(2, src:gsub("\n    _scheduleNightModeRebuild%(self,", ""))
    eq(n, 3, "expected the two event handlers and the paint-time follower, found " .. n)
    for _i, name in ipairs({ "onToggleNightMode%(%)", "onSetNightMode%(night_mode_on%)",
                             "_followScreenNight%(%)" }) do
        local body = src:match("\nfunction BookshelfWidget:" .. name .. "\n(.-)\nend\n")
        assert(body and body:find("_scheduleNightModeRebuild(self,", 1, true),
            name .. " no longer goes through the one scheduler")
    end
end)

t.done()
