-- tests/_test_microfs_pages.lua
-- The full-screen micro-module view's pages and its way into the layout
-- editor: a sideways swipe over the grid turns the page (an edge swipe still
-- reaches KOReader's gesture zones), a tap on a footer dot goes to that page,
-- and the pencil opens the editor with the view as its host.
--
-- Usage: cd into the plugin dir, then `lua tests/_test_microfs_pages.lua`

package.path = "./?.lua;./?/init.lua;" .. package.path

local function make_widget_base()
    local W = {}
    W.__index = W
    function W:extend(o) o = o or {}; setmetatable(o, self); self.__index = self; return o end
    function W:new(o)
        o = o or {}; setmetatable(o, self); self.__index = self
        if self.init then o:init() end
        return o
    end
    function W:init() end
    function W:getSize() return { w = 0, h = 0 } end
    function W:paintTo() end
    function W:handleEvent() return false end
    return W
end

for _, name in ipairs({
    "ui/widget/widget",
    "ui/widget/overlapgroup",
    "ui/widget/verticalgroup",
    "ui/widget/verticalspan",
    "ui/widget/container/framecontainer",
    "ui/widget/container/centercontainer",
    "ui/widget/container/widgetcontainer",
    "ui/widget/container/inputcontainer",
}) do
    package.preload[name] = function() return make_widget_base() end
end
package.preload["ui/geometry"] = function() return { new = function(_, t) return t or {} end } end
package.preload["ui/size"] = function()
    return { padding = { fullscreen = 10, default = 5 }, border = { default = 1 },
             line = { thin = 1, medium = 2, thick = 3 } }
end
package.preload["ffi/blitbuffer"] = function()
    return { COLOR_WHITE = "white", COLOR_BLACK = "black",
             Color8 = function(n) return { v = n } end,
             gray = function(f) return { gray = f } end }
end
package.preload["device"] = function()
    return {
        screen = { getWidth = function() return 1264 end,
                   getHeight = function() return 1680 end,
                   scaleBySize = function(_, n) return n end },
        input = { group = { Back = "Back" } },
        hasKeys = function() return false end,
        hasDPad = function() return false end,
        isTouchDevice = function() return true end,
    }
end
package.preload["ui/uimanager"] = function()
    return { show = function() end, close = function() end, setDirty = function() end,
             nextTick = function(_, fn) fn() end }
end
package.preload["lib/bookshelf_settings_store"] = function()
    return { read = function(_k, d) return d end,
             microFullscreenButton = function() return true end }
end
package.preload["lib/bookshelf_hero_modules"] = function()
    return { build = function() return make_widget_base():new{} end,
             navMove = function() return nil end }
end
package.preload["lib/bookshelf_fullscreen_modules_model"] = function()
    return { load = function() return {} end }
end
package.preload["lib/bookshelf_hero_card"] = function()
    return { buildStatusRow = function() return nil end }
end
package.loaded["logger"] = package.loaded["logger"] or {
    dbg = function() end, info = function() end,
    warn = function() end, err = function() end }


local zone_calls = 0
package.loaded["lib/bookshelf_gesture_zones"] = {
    tryLiveZones = function() zone_calls = zone_calls + 1; return false end,
    forwardToLive = function() return false end,
}
local opened
package.loaded["lib/bookshelf_module_grid_editor"] = {
    open = function(o) opened = o; return {} end,
}

local MicroFS = require("lib/bookshelf_micro_fullscreen")
local Grid    = dofile("lib/bookshelf_module_grid.lua")
local t = dofile("tests/_helpers.lua").runner()

local function view()
    local v = setmetatable({
        _page = 1,
        _grid_rect = { x = 50, y = 100, w = 1100, h = 1300 },
        _grid_info = { surface = "fullscreen", pages = { 1, 2, 3 }, page = 1 },
        -- The shared field can hold the TOP PANEL's grid (a background shelf
        -- rebuild while this view is open); the view must not read it.
        bw = { _module_grid = { surface = "hero", pages = { 1 }, page = 1 } },
    }, { __index = MicroFS })
    v.rebuilt, v.closed = 0, 0
    function v:rebuildGrid() self.rebuilt = self.rebuilt + 1 end
    function v:onTapClose() self.closed = self.closed + 1; return true end
    return v
end

local function gesture(ev) return { handler = "onGesture", args = { ev } } end

t.test("a west swipe over the grid turns to the next page", function()
    local v = view()
    v:handleEvent(gesture({ ges = "swipe", direction = "west", pos = { x = 600, y = 700 } }))
    assert(v._page == 2, "page " .. tostring(v._page))
    assert(v.rebuilt == 1 and v.closed == 0)
end)

t.test("an east swipe on the first page stays put", function()
    local v = view()
    v:handleEvent(gesture({ ges = "swipe", direction = "east", pos = { x = 600, y = 700 } }))
    assert(v._page == 1 and v.closed == 0)
end)

t.test("a swipe outside the grid still reaches the gesture zones", function()
    local v = view()
    zone_calls = 0
    v:handleEvent(gesture({ ges = "swipe", direction = "west", pos = { x = 5, y = 1600 } }))
    assert(v._page == 1, "an edge swipe turned the page")
    assert(zone_calls == 1, "gesture zones not consulted")
end)

t.test("tapping a footer dot goes to that page", function()
    local v = view()
    local rects = Grid.dotRects(3, 300, 40, 6, 18)
    v._dots = { dimen = { x = 400, y = 1600, w = 300, h = 40 }, rects = rects, spacing = 18 }
    v:handleEvent(gesture({ ges = "tap", pos = { x = 400 + rects[3].x + 3, y = 1620 } }))
    assert(v._page == 3, "page " .. tostring(v._page))
    assert(v.closed == 0, "a dot tap closed the view")
end)

t.test("the pencil opens the editor with the view as host", function()
    local v = view()
    opened = nil
    v._pencil_rect = { x = 1100, y = 1600, w = 80, h = 60 }
    v:handleEvent(gesture({ ges = "tap", pos = { x = 1120, y = 1620 } }))
    assert(opened and opened.host == v and opened.bw == v.bw, "editor not opened on the view")
    assert(v.closed == 0)
end)

t.test("the view is an editor host", function()
    local v = view()
    assert(type(v.model) == "function" and type(v.render) == "function"
        and type(v.footerRect) == "function" and type(v.gridInfo) == "function")
    assert(v:gridInfo() == v._grid_info, "gridInfo must be the view's own grid")
    v:render({ page = 2 })
    assert(v._edit and v._edit.page == 2 and v.rebuilt == 1)
end)

t.test("an editor that fails to open doesn't take the view down", function()
    local Editor = package.loaded["lib/bookshelf_module_grid_editor"]
    local real = Editor.open
    Editor.open = function() error("boom") end
    local v = view()
    v._pencil_rect = { x = 1100, y = 1600, w = 80, h = 60 }
    local ok = pcall(function()
        v:handleEvent(gesture({ ges = "tap", pos = { x = 1120, y = 1620 } }))
    end)
    Editor.open = real
    assert(ok, "the error escaped the view")
end)

-- Keys: the footer is a row of the pencil and the close X, in screen order.
-- Down from the grid's bottom reaches it, Left / Right move along it, Up goes
-- back to the grid, and Press on the pencil opens the editor as a tap does
-- (maintainer: keys could not reach the pencil on the desktop emulator).
local function keyed()
    local v = view()
    v._cursor_id = "m1"
    v._pencil_rect = { x = 40, y = 1600, w = 80, h = 60 }
    v._close_rect = { x = 1100, y = 1600, w = 80, h = 60 }
    v._navCell = function() return nil end      -- the cursor is on the grid's bottom row
    return v
end

t.test("keys: down to the close X, left to the pencil, press opens the editor", function()
    local v = keyed()
    v:onMFFocusDown()
    assert(v._focus_close and not v._focus_pencil, "down did not reach the footer")
    v:onMFFocusLeft()
    assert(v._focus_pencil and not v._focus_close, "left did not reach the pencil")
    opened = nil
    v:onMFPress()
    assert(opened and opened.host == v, "press on the pencil did not open the editor")
    assert(v.closed == 0, "press on the pencil closed the view")
end)

t.test("keys: right goes back to the close X, up leaves the footer", function()
    local v = keyed()
    v:onMFFocusDown(); v:onMFFocusLeft(); v:onMFFocusRight()
    assert(v._focus_close and not v._focus_pencil, "right did not go back to the X")
    v:onMFFocusRight()
    assert(v._focus_close, "right past the end left the footer")
    v:onMFFocusUp()
    assert(not v._focus_close and not v._focus_pencil, "up stayed in the footer")
end)

t.test("keys: with no pencil (editing), left stays on the X", function()
    local v = keyed()
    v._pencil_rect = nil
    v:onMFFocusDown(); v:onMFFocusLeft()
    assert(v._focus_close and not v._focus_pencil)
end)

t.done()
