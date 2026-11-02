-- tests/_test_menu_close_refresh.lua
-- KOReader's menu flashes the whole screen as it closes (TouchMenu:
-- onCloseWidget, against ghosting). Over the shelf it refreshes only where it
-- was, no flash (maintainer: "is that necessary?"); over a book or the file
-- browser, KOReader's own flash as ever.
-- Usage (from plugin root): lua tests/_test_menu_close_refresh.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq

local dirty = {}
local UIManager = { setDirty = function(_s, w, kind, region) dirty[#dirty + 1] = { w = w, kind = kind, region = region } end }
local shelf_below
local GZ = { shelfBelow = function(w) return shelf_below end }
local Screen = { getWidth = function() return 600 end, getHeight = function() return 800 end,
                 scaleBySize = function(_s, v) return v end }
local M = dofile("lib/bookshelf_menu_close_refresh.lua")

local function TouchMenuClass()
    local TM = { flashed = 0 }
    function TM:onCloseWidget() TM.flashed = TM.flashed + 1 end
    return TM
end

t.test("over the shelf: the menu's own area, refreshed without a flash", function()
    dirty = {}
    local TM = TouchMenuClass()
    M.install(TM, { UIManager = UIManager, GZ = GZ, Screen = Screen })
    shelf_below = { name = "bookshelf" }
    local menu = setmetatable({ show_parent = {}, dimen = { x = 10, y = 0, w = 580, h = 400 } }, { __index = TM })
    menu:onCloseWidget()
    eq(TM.flashed, 0, "KOReader's full-screen flash ran")
    eq(#dirty, 1); eq(dirty[1].kind, "ui")
    local r = dirty[1].region
    eq(r.x, 2); eq(r.y, 0); eq(r.w, 596); eq(r.h, 408)
end)

t.test("over a book or the file browser: KOReader's flash", function()
    dirty = {}
    local TM = TouchMenuClass()
    M.install(TM, { UIManager = UIManager, GZ = GZ, Screen = Screen })
    shelf_below = nil
    local menu = setmetatable({ show_parent = {}, dimen = { x = 0, y = 0, w = 600, h = 400 } }, { __index = TM })
    menu:onCloseWidget()
    eq(TM.flashed, 1); eq(#dirty, 0)
end)

t.test("a menu never painted (no place yet): KOReader's flash", function()
    dirty = {}
    local TM = TouchMenuClass()
    M.install(TM, { UIManager = UIManager, GZ = GZ, Screen = Screen })
    shelf_below = { name = "bookshelf" }
    local menu = setmetatable({ show_parent = {} }, { __index = TM })
    menu:onCloseWidget()
    eq(TM.flashed, 1)
end)

t.test("a dialog the menu item opened: refreshed where it is, not left stale (572)", function()
    -- KOReader runs the item's callback, which shows the dialog, before it
    -- closes the menu; a dialog that asks for no refresh of its own showed
    -- only where the menu had been.
    dirty = {}
    local TM = TouchMenuClass()
    local container, dialog, below = {}, { dimen = { x = 50, y = 300, w = 500, h = 400 } }, {}
    local UI = { setDirty = UIManager.setDirty,
                 _window_stack = { { widget = below }, { widget = container }, { widget = dialog } } }
    M.install(TM, { UIManager = UI, GZ = GZ, Screen = Screen })
    shelf_below = { name = "bookshelf" }
    local menu = setmetatable({ show_parent = container, dimen = { x = 10, y = 0, w = 580, h = 400 } }, { __index = TM })
    menu:onCloseWidget()
    eq(TM.flashed, 0)
    eq(#dirty, 2, "the dialog above the menu was not refreshed")
    eq(dirty[2].w, dialog)
    eq(type(dirty[2].kind), "function", "region read after the dialog paints")
    local kind, region = dirty[2].kind()
    eq(kind, "ui"); eq(region, dialog.dimen)
end)

t.test("installed once", function()
    local TM = TouchMenuClass()
    M.install(TM, { UIManager = UIManager, GZ = GZ, Screen = Screen })
    local f = TM.onCloseWidget
    M.install(TM, { UIManager = UIManager, GZ = GZ, Screen = Screen })
    eq(TM.onCloseWidget, f)
end)

t.test("main.lua installs it", function()
    local m = io.open("main.lua"):read("*a")
    assert(m:find('require("lib/bookshelf_menu_close_refresh").install()', 1, true))
end)

t.done()
