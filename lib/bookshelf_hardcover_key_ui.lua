-- bookshelf_hardcover_key_ui.lua
-- The settings row and dialog for the Hardcover API key
-- (lib/bookshelf_hardcover_key holds it; lib/bookshelf_hardcover_client
-- sends it).
--
-- The dialog says where the key in use comes from and offers what applies:
-- enter one, read one from a file (a key is some 500 characters), keep a
-- copy of a sync plugin's, check it, remove Bookshelf's own. Checking is the
-- only thing here that goes online, and only when tapped.

local UIManager = require("ui/uimanager")
local T = require("ffi/util").template
local _ = require("lib/bookshelf_i18n").gettext

local M = {}

local function Key() return require("lib/bookshelf_hardcover_key") end

local function sourceText(source)
    if source == "own" then return _("Bookshelf's own") end
    if source == "hardcover" then return _("from the Hardcover plugin") end
    if source == "shelfsync" then return _("from your sync plugin") end
    return _("not set")
end

local function isOn()
    local ok, Hardcover = pcall(require, "lib/bookshelf_hardcover")
    return ok and Hardcover and Hardcover.isAvailable() and true or false
end

-- The plugin a key was found in, as it reads after "from": a name.
local function pluginName(source)
    if source == "hardcover" then return _("the Hardcover plugin") end
    if source == "shelfsync" then return "ShelfSync" end
    return _("your sync plugin")
end

-- statusText() -> the settings row's text.
function M.statusText()
    local _tok, source = Key().get()
    if source and source ~= "own" and not isOn() then
        return T(_("Hardcover API key: %1"), _("in a plugin that is off"))
    end
    return T(_("Hardcover API key: %1"), sourceText(source))
end

local function info(text, timeout)
    UIManager:show(require("ui/widget/infomessage"):new{ text = text, timeout = timeout })
end

-- The key changed: Hardcover works out its client again, and the caller
-- redraws. `was_on`: whether Hardcover was available before the change (its
-- menu is built once, when KOReader starts).
local function changed(opts, was_on, text)
    local ok, Hardcover = pcall(require, "lib/bookshelf_hardcover")
    local on = false
    if ok and Hardcover then
        Hardcover.invalidateSource(true)
        on = Hardcover.isAvailable() and true or false
    end
    if on and not was_on then
        text = text .. "\n\n" .. _("Restart KOReader to see the Hardcover menu.")
    end
    info(text)
    if opts.on_change then opts.on_change() end
end

local function enterKey(opts)
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = _("Hardcover API key"),
        input = "",
        input_hint = _("Paste or type the key"),
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local was_on = isOn()
                if not Key().set(dialog:getInputText()) then
                    info(_("That does not look like a Hardcover API key."), 4)
                    return
                end
                UIManager:close(dialog)
                changed(opts, was_on, _("Key saved on this device."))
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

local function checkKey()
    require("lib/bookshelf_cover_fetch").runWhenOnline(function()
        local me, err = require("lib/bookshelf_hardcover_client"):me()
        if me then
            local name = type(me.username) == "string" and me.username ~= "" and me.username or nil
            info(name and T(_("Hardcover accepts this key (%1)."), name)
                or _("Hardcover accepts this key."))
        else
            info(T(_("The key was not accepted: %1"),
                type(err) == "table" and err.request_error or _("no reply")))
        end
    end)
end

-- open{ on_change = function() }
function M.open(opts)
    opts = opts or {}
    local K = Key()
    local _tok, source = K.get()
    local plugin = K.pluginSource()
    local title
    if source == "own" then
        title = _("Bookshelf has its own Hardcover API key, stored on this device.")
    elseif source and not isOn() then
        -- The key is in a plugin's folder, and the plugin is not running.
        title = T(_("There is a Hardcover API key %1, but that plugin is switched off, and Hardcover with it."),
            sourceText(source))
    elseif source then
        title = T(_("Bookshelf is using the Hardcover API key %1. It is read from there each time and not copied."),
            sourceText(source))
    else
        title = T(_("No Hardcover API key. Get one at hardcover.app/account/api, then enter it here, or save it in a text file at:\n%1"),
            K.importPath())
    end

    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local function close() UIManager:close(dialog) end
    local buttons = {
        { { text = _("Enter key\xE2\x80\xA6"), callback = function() close(); enterKey(opts) end } },
        { { text = _("Read key from file"), callback = function()
            local was_on = isOn()
            if K.importFile() then
                close()
                changed(opts, was_on, _("Key read and saved on this device. The file was removed."))
            else
                info(T(_("No key found. Save the key in a text file at:\n%1"), K.importPath()))
            end
        end } },
    }
    if plugin and source ~= "own" then
        -- Named for the plugin: "the plugin's key" told the maintainer
        -- nothing about whose key, or why he would want a copy.
        title = title .. "\n\n" .. _("Copying the key is only needed to use Hardcover without that plugin.")
        buttons[#buttons + 1] = { { text = T(_("Copy the key from %1"), pluginName(plugin)), callback = function()
            local was_on = isOn()
            if K.keepCopy() then
                close()
                changed(opts, was_on, _("Bookshelf now has its own copy of the key, and keeps working if the plugin is removed."))
            end
        end } }
    end
    if source then
        buttons[#buttons + 1] = { { text = _("Check key"), callback = checkKey } }
    end
    if source == "own" then
        buttons[#buttons + 1] = { { text = _("Remove Bookshelf's key"), callback = function()
            local was_on = isOn()
            K.clear()
            close()
            changed(opts, was_on, _("Bookshelf's key was removed."))
        end } }
    end
    buttons[#buttons + 1] = { { text = _("Close"), callback = close } }

    dialog = ButtonDialog:new{
        title = require("lib/bookshelf_menu_icons").HARDCOVER .. " " .. _("Hardcover API key") .. "\n\n" .. title,
        title_align = "center",
        buttons = buttons,
    }
    pcall(function() require("lib/bookshelf_gesture_zones").passSwipesOn(dialog) end)
    UIManager:show(dialog)
end

-- menuItem(on_change) -> a settings menu row.
function M.menuItem(on_change)
    return {
        text_func = M.statusText,
        keep_menu_open = true,
        help_text = _("Bookshelf can talk to Hardcover itself with an API key, with or without a sync plugin installed. A key your sync plugin already holds is used as it is. Get a key at hardcover.app/account/api."),
        callback = function(touchmenu_instance)
            M.open{ on_change = function()
                if on_change then on_change() end
                if touchmenu_instance and touchmenu_instance.updateItems then
                    touchmenu_instance:updateItems()
                end
            end }
        end,
    }
end

return M
