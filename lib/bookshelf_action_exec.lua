--[[
Executes one "action" entry (the shape the start menu and the hero Action
module share): { internal = "close"|"settings" } | { plugin = {key,method} } |
{ action = <dispatcher table> }. The CALLER closes its own menu/widget first and
wraps this in UIManager:nextTick; dispatch only runs the action. Extracted from
bookshelf_start_menu.lua so the start menu and the Action micro-module share one
execution path.
]]
local _ = require("lib/bookshelf_i18n").gettext

local Exec = {}

-- entry: the action entry. bw: the bookshelf widget (needed for internal=close
-- and the settings menu host). Defensive against a non-table / empty entry.
function Exec.dispatch(entry, bw)
    if type(entry) ~= "table" then return end
    local UIManager = require("ui/uimanager")
    local logger    = require("logger")

    if entry.internal == "close" then
        if bw and bw.onClose then
            bw:onClose()
            -- bw:onClose() enqueues no screen refresh on its own; re-flag the
            -- whole remaining window stack so the reveal actually flushes.
            UIManager:setDirty("all", "full")
        end
    elseif entry.internal == "settings" then
        -- Host the plugin's FULL top-level menu (probe the live plugin's
        -- addToMainMenu, assemble in MENU_ORDER), falling back to the settings
        -- subtree.
        local MenuHost = require("lib/bookshelf_menu_host")
        local S = require("lib/bookshelf_settings")
        S._bw = bw
        local items
        local ok_probe = pcall(function()
            local fm_mod = package.loaded["apps/filemanager/filemanager"]
            local fm  = fm_mod and fm_mod.instance
            local mod = fm and fm.bookshelf
            if not mod then
                -- Hot parking: no FileManager exists while a reader is
                -- parked under the shelf - the reader-context plugin
                -- instance carries the same menu via buildMenuItems
                -- (addToMainMenu itself bails in reader context so the
                -- actual reading menu stays uncluttered).
                local rui_mod = package.loaded["apps/reader/readerui"]
                local rui = rui_mod and rui_mod.instance
                mod = rui and rui.bookshelf
            end
            if not (mod and (type(mod.buildMenuItems) == "function"
                             or type(mod.addToMainMenu) == "function")) then
                return
            end
            local probe = {}
            if type(mod.buildMenuItems) == "function" then
                mod:buildMenuItems(probe)
            else
                mod:addToMainMenu(probe)
            end
            local order = mod.MENU_ORDER
            if type(order) ~= "table" then
                order = {}
                for k in pairs(probe) do order[#order + 1] = k end
                table.sort(order)
            end
            local out = {}
            for _i, key in ipairs(order) do
                local it = probe[key]
                if type(it) == "table" and key ~= "bookshelf_tab" then
                    out[#out + 1] = it
                end
            end
            if #out > 0 then items = out end
        end)
        if not (ok_probe and items) then
            items = S:_settingsSubItems()
        end
        MenuHost.show{ title = _("Bookshelf"), item_table = items }
    elseif type(entry.plugin) == "table" then
        local PluginScan = require("lib/bookshelf_plugin_scan")
        local launch = PluginScan.resolve(entry.plugin.key, entry.plugin.method)
        if launch then
            local ok_l, err = pcall(launch)
            if not ok_l then
                logger.warn("[bookshelf] action plugin launch failed:",
                    entry.plugin.key, err)
            end
        end
    elseif type(entry.menu_path) == "table" then
        local MenuShortcut = require("lib/bookshelf_menu_shortcut")
        if entry.menu_page then
            MenuShortcut.replayPage(entry.menu_path, entry.label)
        else
            MenuShortcut.replay(entry.menu_path)
        end
    elseif type(entry.action) == "table" then
        local ok, Dispatcher = pcall(require, "dispatcher")
        if ok then Dispatcher:execute(entry.action) end
    end
end

return Exec
