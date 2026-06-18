--[[
Builds the "pick an action" button rows shared by the start menu's Add-to-menu
dialog and the hero Action module's add flow. `close(fn)` is the host's dialog
closer (returns a wrapped callback that closes the host dialog first). `on_pick`
receives the chosen action's FIELDS — { label, icon?, action|plugin|internal } —
without id/type, which the caller stamps on. Plugin glyph default matches the
start menu (issue #140).
]]
local ButtonDialog = require("ui/widget/buttondialog")
local Notification = require("ui/widget/notification")
local UIManager    = require("ui/uimanager")
local _            = require("lib/bookshelf_i18n").gettext

local PLUGIN_DEFAULT_ICON = "\xEE\xAC\xB0" -- U+EB30 mdi-puzzle (start-menu default)

local Chooser = {}

function Chooser.actionRows(close, on_pick)
    return {
        { { text = _("Plugin\xE2\x80\xA6"), callback = close(function()
            local PluginScan = require("lib/bookshelf_plugin_scan")
            local found = PluginScan.scan()
            if #found == 0 then
                UIManager:show(Notification:new{
                    text = _("No launchable plugins found") })
                return
            end
            local MenuHost = require("lib/bookshelf_menu_host")
            local host
            local picker_items = {}
            for _i, p in ipairs(found) do
                local entry_icon = p.icon or PLUGIN_DEFAULT_ICON
                picker_items[#picker_items + 1] = {
                    text = (p.icon and (p.icon .. "  ") or "") .. p.title,
                    callback = function()
                        MenuHost.close(host)
                        on_pick{ label = p.title, icon = entry_icon,
                                 plugin = { key = p.key, method = p.method } }
                    end,
                }
            end
            host = MenuHost.show{ title = _("Choose a plugin"),
                item_table = picker_items }
        end) } },
        { { text = _("System action\xE2\x80\xA6"), callback = close(function()
            local ActionPicker = require("lib/bookshelf_action_picker")
            ActionPicker.show{
                on_pick = function(action, name)
                    on_pick{ label = name, action = action }
                end,
            }
        end) } },
        { { text = _("Bookshelf action\xE2\x80\xA6"), callback = close(function()
            local sub
            local function subClose(fn)
                return function() UIManager:close(sub); fn() end
            end
            sub = ButtonDialog:new{
                title = _("Bookshelf actions"), title_align = "center",
                width_factor = 0.65,
                buttons = {
                    { { text = _("Close bookshelf"), callback = subClose(function()
                        on_pick{ label = _("Close bookshelf"),
                                 icon = "\xEE\xA1\x95", internal = "close" }
                    end) } },
                    { { text = _("Bookshelf menu"), callback = subClose(function()
                        on_pick{ label = _("Bookshelf menu"),
                                 icon = "\xE2\x9A\x99", internal = "settings" }
                    end) } },
                },
            }
            UIManager:show(sub)
        end) } },
    }
end

return Chooser
