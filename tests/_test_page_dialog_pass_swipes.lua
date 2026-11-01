-- tests/_test_page_dialog_pass_swipes.lua
-- A slider page (Settings > Image contrast, the size nudges) sits low on the
-- screen with the shelf live behind it. A side swipe on the shelf turns the
-- shelf's page, so a change can be seen on more books without closing the
-- page (maintainer). The page itself, its taps and KOReader's own gestures
-- behave as before.
-- Usage (from plugin root): lua tests/_test_page_dialog_pass_swipes.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq

local src = io.open("lib/bookshelf_page_dialog.lua"):read("*a")
local body = src:match("\n(function PageDialog:handleEvent%(.-\nend)\n")
assert(body, "no PageDialog:handleEvent")

local zones_took = false
local base_took = false
local function point(x, y)
    return { x = x, y = y, notIntersectWith = function(p, r)
        return p.x < r.x or p.x >= r.x + r.w or p.y < r.y or p.y >= r.y + r.h
    end }
end
local GZ = {
    onWindow = function(_event, inside) return inside end,
    overlayEvent = function(_w, event, _base, on_window)
        local ev = event.args[1]
        if not on_window(ev.pos) and zones_took then return true end
        return base_took
    end,
}
local env = setmetatable({
    PageDialog = {},
    InputContainer = {},
    require = function(n)
        if n == "lib/bookshelf_gesture_zones" then return GZ end
        return require(n)
    end,
}, { __index = _G })
assert(load(body, "handleEvent", "t", env))()

-- The frame: a slim panel at the bottom of a 600 x 800 screen.
local FRAME = { x = 50, y = 600, w = 500, h = 150 }
local function dialog(shelf)
    return setmetatable({
        frame = { dimen = FRAME },
        pass_swipes = shelf and function() return shelf end,
    }, { __index = env.PageDialog })
end
local function swipe(dir, x, y)
    return { handler = "onGesture", args = { { ges = "swipe", direction = dir, pos = point(x, y) } } }
end
local function shelf()
    local s = { got = {} }
    function s:handleEvent(e) self.got[#self.got + 1] = e.args[1].direction; return true end
    return s
end

t.test("a side swipe on the shelf behind turns the shelf's page", function()
    zones_took, base_took = false, false
    local s = shelf()
    eq(dialog(s):handleEvent(swipe("west", 300, 200)), true)
    eq(dialog(s):handleEvent(swipe("east", 300, 200)), true)
    eq(table.concat(s.got, ","), "west,east")
end)

t.test("a swipe on the page itself stays with the page", function()
    zones_took, base_took = false, false
    local s = shelf()
    dialog(s):handleEvent(swipe("west", 300, 650))
    eq(#s.got, 0)
end)

t.test("up and down swipes are not passed (the hero, the full screen view)", function()
    zones_took, base_took = false, false
    local s = shelf()
    dialog(s):handleEvent(swipe("north", 300, 200))
    dialog(s):handleEvent(swipe("south", 300, 200))
    eq(#s.got, 0)
end)

t.test("KOReader's zones still go first", function()
    zones_took, base_took = true, false
    local s = shelf()
    eq(dialog(s):handleEvent(swipe("west", 300, 200)), true)
    eq(#s.got, 0)
end)

t.test("a page without pass_swipes keeps every gesture (the other dialogs)", function()
    zones_took, base_took = false, false
    eq(dialog(nil):handleEvent(swipe("west", 300, 200)), false)
end)

t.test("a shelf that is gone takes nothing", function()
    zones_took, base_took = false, false
    local d = dialog(nil)
    d.pass_swipes = function() return nil end
    eq(d:handleEvent(swipe("west", 300, 200)), false)
end)

-- The slider pages pass them, to the shelf that is showing.
t.test("the nudge pages pass side swipes to the shelf on screen", function()
    local s = io.open("lib/bookshelf_settings.lua"):read("*a")
    local b = s:match("\nfunction Settings:_nudgePage%(.-\nend\n")
    assert(b:find("pass_swipes = function()", 1, true), "the nudge page keeps every swipe")
    assert(b:find("UIManager:isWidgetShown(bw)", 1, true), "a closed shelf could be sent swipes")
end)

-- The page-turn wipe draws the new page straight to the screen: under the
-- slider page it would draw over it. Covered, the turn repaints instead
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
