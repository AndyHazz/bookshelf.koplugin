-- tests/_test_page_dialog_pass_swipes.lua
-- A side swipe off one of our windows turns the shelf's page behind it
-- (GestureZones.passSideSwipe, tested in _test_gesture_zones). The slider
-- pages get it from the shared handler, and the page turn under a window
-- must not draw over it.
-- Usage (from plugin root): lua tests/_test_page_dialog_pass_swipes.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t = H.runner()

t.test("the page dialog passes swipes through the shared handler, not its own", function()
    local src = io.open("lib/bookshelf_page_dialog.lua"):read("*a")
    local body = src:match("\n(function PageDialog:handleEvent%(.-\nend)\n")
    assert(body and body:find("return GZ.overlayEvent(", 1, true), "PageDialog bypasses overlayEvent")
    assert(not src:find("pass_swipes", 1, true), "a second, slider-only pass")
end)

-- The page-turn wipe draws the new page straight to the screen: under a
-- window it would draw over it. Covered, the turn repaints instead
-- (setDirty on the shelf repaints the windows above it too).
t.test("a page turn under another window skips the wipe", function()
    local w = io.open("lib/bookshelf_widget.lua"):read("*a")
    local a = w:find("local anim_steps = _wipe_dir and shelf_top and _pageAnimSteps()", 1, true)
    local run = w:find("PageWipe.run(Screen, new_bb, region", 1, true)
    assert(a and run, "the wipe moved")
    local between = w:sub(a, run)
    assert(between:find("UIManager:getTopmostVisibleWidget()", 1, true)
        and between:find("anim_steps = nil", 1, true), "the wipe draws over a window above the shelf")
end)

t.done()
