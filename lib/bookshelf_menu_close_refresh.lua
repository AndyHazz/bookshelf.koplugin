-- lib/bookshelf_menu_close_refresh.lua
--
-- KOReader's menu (TouchMenu) flashes the whole screen as it closes, against
-- ghosting, whenever the file browser or a book is under it. Over the shelf
-- it refreshes only where it was, with no flash (maintainer: "is that
-- necessary?"). That covers stepping the menu aside for a slider or the
-- Theme library too, which flashed as the picker opened. Over a book or the
-- file browser, KOReader's own flash as ever.
--
-- UIManager:close sends CloseWidget while the menu is still on the stack, so
-- the window under it is the one the menu sat on.

local M = {}

-- install([deps]): wraps TouchMenu:onCloseWidget once. deps (tests):
-- { TouchMenu?, UIManager, GZ, Screen }; the first argument may be the
-- TouchMenu class itself.
function M.install(TouchMenu, deps)
    deps = deps or {}
    TouchMenu = TouchMenu or require("ui/widget/touchmenu")
    if TouchMenu._bookshelf_close_refresh then return end
    TouchMenu._bookshelf_close_refresh = true
    local orig = TouchMenu.onCloseWidget
    TouchMenu.onCloseWidget = function(self, ...)
        local UIManager = deps.UIManager or require("ui/uimanager")
        local GZ = deps.GZ or require("lib/bookshelf_gesture_zones")
        local Screen = deps.Screen or require("device").screen
        local d = self.dimen
        local shelf = d and d.w and GZ.shelfBelow(self.show_parent or self)
        if not shelf then
            if orig then return orig(self, ...) end
            return
        end
        -- The menu's frame and a little round it (its border).
        local m = Screen:scaleBySize(8)
        local x0, y0 = math.max(0, d.x - m), math.max(0, d.y - m)
        local x1 = math.min(Screen:getWidth(), d.x + d.w + m)
        local y1 = math.min(Screen:getHeight(), d.y + d.h + m)
        local region = { x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
        local ok_g, Geom = pcall(require, "ui/geometry")
        if ok_g and Geom and Geom.new then region = Geom:new(region) end
        UIManager:setDirty(nil, "ui", region)
    end
end

return M
