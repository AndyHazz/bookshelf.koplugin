-- tests/_test_hide_menu_stale.lua
-- Bookshelf:hideMenu steps KOReader's menu aside for a picker (the Theme
-- library) and shows it again after. KOReader keeps one menu_container per
-- menu and REPLACES it when the menu is opened again (a tap in its top zone
-- outside the picker did that): showing the old one again left a menu that
-- nothing could close, tapping outside it did nothing (maintainer, PW5).
-- Usage (from plugin root): lua tests/_test_hide_menu_stale.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq

local src = io.open("main.lua"):read("*a")
local body = src:match("\n(function Bookshelf:hideMenu%(.-\nend)\n")
assert(body, "no Bookshelf:hideMenu")

local shown
local UIManager = {
    close = function(_s, w) shown[w] = nil end,
    show = function(_s, w) shown[w] = true end,
}
local FM = { instance = { menu = {} } }
local RUI = { instance = nil }
local env = setmetatable({
    Bookshelf = {},
    UIManager = UIManager,
    require = function(n)
        if n == "apps/filemanager/filemanager" then return FM end
        if n == "apps/reader/readerui" then return RUI end
        return require(n)
    end,
}, { __index = _G })
assert(load(body, "hideMenu", "t", env))()
local B = env.Bookshelf

local function menu()
    local c = { name = "container" }
    local tm = { show_parent = c, updated = 0 }
    function tm:updateItems() self.updated = self.updated + 1 end
    return c, tm
end

t.test("the menu comes back after the picker", function()
    shown = {}
    local c, tm = menu()
    FM.instance.menu.menu_container = c; shown[c] = true
    local restore = B.hideMenu(B, tm)
    eq(shown[c], nil, "not stepped aside")
    restore()
    eq(shown[c], true); eq(tm.updated, 1)
end)

t.test("a menu opened again meanwhile is left as the one on screen", function()
    shown = {}
    local c, tm = menu()
    FM.instance.menu.menu_container = c; shown[c] = true
    local restore = B.hideMenu(B, tm)
    local c2 = { name = "new container" }
    FM.instance.menu.menu_container = c2; shown[c2] = true   -- KOReader's onShowMenu
    restore()
    eq(shown[c], nil, "the replaced menu came back, and nothing can close it")
    eq(shown[c2], true)
end)

t.test("a menu closed meanwhile stays closed", function()
    shown = {}
    local c, tm = menu()
    FM.instance.menu.menu_container = c; shown[c] = true
    local restore = B.hideMenu(B, tm)
    FM.instance.menu.menu_container = nil                     -- onCloseFileManagerMenu
    restore()
    eq(shown[c], nil)
end)

t.test("a menu no KOReader menu owns comes back as before", function()
    shown = {}
    FM.instance.menu.menu_container = nil
    local c, tm = menu()
    shown[c] = true
    local restore = B.hideMenu(B, tm)
    restore()
    eq(shown[c], true)
end)

t.done()
