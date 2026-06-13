--[[
Long-press context dialog and Add flows for the start menu.
All mutations follow one shape: Model.load -> mutate -> Model.save ->
menu:_reload(). The settings store flushes on save, so each completed
user action is durable immediately (user-action boundary rule).

Stale-reference rule: dialog closures capture entry *ids*, never the
entry tables - Model.load() returns fresh tables on every call (and
sanitize may have swapped folder tables), so every mutate callback
re-finds its target by id against the list it is about to save.
]]
local ButtonDialog   = require("ui/widget/buttondialog")
local ConfirmBox     = require("ui/widget/confirmbox")
local InputDialog    = require("ui/widget/inputdialog")
local Notification   = require("ui/widget/notification")
local UIManager      = require("ui/uimanager")
local Model          = require("lib/bookshelf_start_menu_model")
local Modules        = require("lib/bookshelf_start_menu_modules")
local _              = require("lib/bookshelf_i18n").gettext
local T              = require("ffi/util").template

local Edit = {}

-- Default icon for plugin launcher entries: mdi-puzzle (U+EB30), rendered
-- via the bundled Symbols Nerd Font fallback like every other start-menu
-- icon. KOReader has NO convention for plugins to declare their own icon -
-- per-item menu registrations carry no icon field (TouchMenuItem renders
-- checkmark + text only; icons exist only on the five first-level tabs)
-- and _meta.lua is name/fullname/description only - so plugin entries get
-- this glyph at insert time; "Change icon" still lets the user swap it.
local PLUGIN_DEFAULT_ICON = "\xEE\xAC\xB0" -- U+EB30 mdi-puzzle

-- Load fresh items, apply fn, save + rebuild the menu. fn returning
-- false (e.g. a clamped moveBy, or the target id no longer existing)
-- skips both the save and the reload.
local function mutate(menu, fn)
    local items = Model.load()
    local changed = fn(items)
    if changed ~= false then
        Model.save(items)
        menu:_reload()
    end
end

local function trim(s)
    return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function displayLabel(entry)
    if entry.type == "module" then
        return Modules.title(entry.module) or entry.module
    end
    return entry.label or "?"
end

-- One-field text prompt. on_confirm(text) runs only for non-empty input.
local function promptText(title, initial, confirm_label, on_confirm)
    local input
    input = InputDialog:new{
        title = title,
        input = initial or "",
        buttons = {{
            { text = _("Cancel"), id = "close",
              callback = function() UIManager:close(input) end },
            { text = confirm_label, is_enter_default = true,
              callback = function()
                  local text = trim(input:getInputText())
                  UIManager:close(input)
                  if text ~= "" then on_confirm(text) end
              end },
        }},
    }
    UIManager:show(input)
    input:onShowKeyboard()
end

-- Long-press context dialog for one entry. `menu` is the live StartMenu
-- widget, `entry` the held entry (the synthetic "__add" row never lands
-- here - the widget routes its hold to _addEntry directly).
function Edit.show(menu, entry)
    local dialog
    local function close(fn)
        return function()
            UIManager:close(dialog)
            if fn then fn() end
        end
    end

    local id        = entry.id
    local is_module = entry.type == "module"
    local is_folder = entry.type == "folder"
    -- Fresh lookup for structure facts (parent, sibling folders): the
    -- captured entry may predate earlier edits.
    local items_now = Model.load()
    local _list, _idx, _e, parent = Model.findById(items_now, id)
    local in_folder = parent ~= nil

    local rows = {}

    if not is_module then
        local icon_row = {
            { text = _("Rename"), callback = close(function()
                local _l, _i, fresh = Model.findById(Model.load(), id)
                promptText(_("Rename"), fresh and fresh.label or entry.label,
                    _("Rename"), function(new_label)
                        mutate(menu, function(items)
                            local _l2, _i2, e = Model.findById(items, id)
                            if not e or e.label == new_label then return false end
                            e.label = new_label
                        end)
                    end)
            end) },
            { text = _("Change icon"), callback = close(function()
                local Editor = require("lib/bookshelf_chip_editor")
                local _l, _i, fresh = Model.findById(Model.load(), id)
                -- Fresh draft seeded with the current icon; the picker
                -- writes the chosen glyph into draft.icon ("Remove icon"
                -- below is the path that clears it).
                local draft = { icon = fresh and fresh.icon or nil }
                Editor:_pickIcon(draft, function()
                    -- Belt-and-braces: the picker already excludes the
                    -- Dynamic category, but reject %tokens (e.g.
                    -- "%batt_icon") anyway -- they're meaningless in the
                    -- start menu and would overflow the icon column.
                    if type(draft.icon) == "string" and draft.icon:sub(1,1) == "%" then
                        UIManager:show(Notification:new{
                            text = _("Dynamic icons aren't supported here"),
                        })
                        return
                    end
                    mutate(menu, function(items)
                        local _l2, _i2, e = Model.findById(items, id)
                        if not e or e.icon == draft.icon then return false end
                        e.icon = draft.icon -- nil clears
                    end)
                end)
            end) },
        }
        -- Only show "Remove icon" when the entry already has one; this gives a
        -- picker-independent way to clear it.
        local has_icon = entry.icon ~= nil
        if has_icon then
            icon_row[#icon_row + 1] = {
                text = _("Remove icon"), callback = close(function()
                    mutate(menu, function(items)
                        local _l2, _i2, e = Model.findById(items, id)
                        if not e or e.icon == nil then return false end
                        e.icon = nil
                    end)
                end)
            }
        end
        rows[#rows + 1] = icon_row
    else
        -- Modules with a show_settings hook get a settings row where the
        -- Rename / Change icon row sits for other entries. The module owns
        -- the settings UI + persistence (micromodule_<key>_* store keys)
        -- and calls menu:_reload() itself after changes; same ctx shape as
        -- on_tap. pcall: a broken module must not break the edit dialog.
        local def = Modules.get(entry.module)
        if def and type(def.show_settings) == "function" then
            rows[#rows + 1] = {
                { text = _("Module settings\xE2\x80\xA6"), callback = close(function()
                    local ok, err = pcall(def.show_settings,
                        { bw = menu.bw, menu = menu })
                    if not ok then
                        require("logger").warn(
                            "[bookshelf] module settings failed:",
                            entry.module, err)
                    end
                end) },
            }
        end
    end

    rows[#rows + 1] = {
        -- Deliberately NOT close()-wrapped: the user taps repeatedly to
        -- walk an entry through the list, so the dialog stays open while
        -- mutate() reloads the menu beneath it (the dialog remains
        -- topmost). moveBy's result still flows back through mutate: a
        -- clamped no-op (already at the edge) skips the save + reload.
        { text = _("Move up"), callback = function()
            mutate(menu, function(items) return Model.moveBy(items, id, -1) end)
        end },
        { text = _("Move down"), callback = function()
            mutate(menu, function(items) return Model.moveBy(items, id, 1) end)
        end },
    }

    if not is_folder then
        if in_folder then
            rows[#rows + 1] = {
                { text = _("Move out of folder"), callback = close(function()
                    mutate(menu, function(items)
                        return Model.moveToTopLevel(items, id)
                    end)
                end) },
            }
        else
            for _i, it in ipairs(items_now) do
                if it.type == "folder" then
                    local folder_id = it.id
                    rows[#rows + 1] = {
                        { text = T(_("Move to: %1"), it.label),
                          callback = close(function()
                              mutate(menu, function(items)
                                  return Model.moveToFolder(items, id, folder_id)
                              end)
                          end) },
                    }
                end
            end
        end
    end

    local function doDelete()
        mutate(menu, function(items)
            return Model.removeById(items, id)
        end)
    end
    local delete_btn = { text = _("Delete"), callback = close(function()
        local _l, _i, fresh = Model.findById(Model.load(), id)
        if not fresh then return end
        if fresh.type == "folder" and fresh.children and #fresh.children > 0 then
            -- ConfirmBox outlives this dialog; doDelete captures
            -- only menu + id, both still valid when it fires.
            UIManager:show(ConfirmBox:new{
                text = _("Delete this folder and everything in it?"),
                ok_text = _("Delete"),
                ok_callback = doDelete,
            })
        else
            doDelete()
        end
    end) }

    -- NB: literal UTF-8 ellipsis bytes, not \u{2026} - xgettext's Lua parser
    -- doesn't decode \u escapes, so the msgid would never match a translation.
    local add_btn = { text = _("Add new menu item\xE2\x80\xA6"), callback = close(function()
        -- When the held entry is a folder, add into it rather than
        -- inserting a sibling after it.
        local folder_id = is_folder and id or nil
        Edit.showAdd(menu, id, folder_id)
    end) }

    rows[#rows + 1] = { delete_btn, add_btn }

    -- An [icon=NAME] image value would render as raw token text in the dialog
    -- title; show the label alone for image icons (glyph icons still prefix).
    local title_icon = entry.icon
    if title_icon and Model.imageIconName(title_icon) then title_icon = nil end
    local entry_title = (title_icon and (title_icon .. "  ") or "") .. displayLabel(entry)

    dialog = ButtonDialog:new{
        title        = entry_title,
        title_align  = "center",
        width_factor = 0.65,
        buttons      = rows,
    }
    UIManager:show(dialog)
end

-- "Add to menu" dialog.
-- anchor_id: the entry the new item lands after in the normal (sibling) path.
-- folder_id: when set, insertion targets that folder's children regardless of
--   anchor - the new entry is appended to folder.children (and at_top = false,
--   suppressing "New folder…" since nesting isn't allowed).
function Edit.showAdd(menu, anchor_id, folder_id)
    local dialog
    local function close(fn)
        return function()
            UIManager:close(dialog)
            if fn then fn() end
        end
    end

    local function insertEntry(make)
        if folder_id then
            -- Insert into the target folder's children list.
            mutate(menu, function(items)
                local _l, _i, folder = Model.findById(items, folder_id)
                if not folder or folder.type ~= "folder" then return false end
                folder.children = folder.children or {}
                folder.children[#folder.children + 1] = make()
            end)
        else
            mutate(menu, function(items)
                Model.insertAfter(items, anchor_id, make())
            end)
        end
    end

    -- Folders can't nest (one-level rule): offer "New folder…" only
    -- when the insertion point is at the top level.
    local at_top
    if folder_id then
        -- We are inserting into a folder; top-level options don't apply.
        at_top = false
    elseif anchor_id then
        local _l, _i, _e, parent = Model.findById(Model.load(), anchor_id)
        at_top = parent == nil
    else
        at_top = true
    end

    local rows = {
        { { text = _("Plugin…"), callback = close(function()
            -- Installed FM plugins (games etc.) found on the live
            -- FileManager instance; picking one stores a {key, method}
            -- launcher resolved live at activation time.
            local PluginScan = require("lib/bookshelf_plugin_scan")
            local found = PluginScan.scan()
            if #found == 0 then
                UIManager:show(Notification:new{
                    text = _("No launchable plugins found"),
                })
                return
            end
            local MenuHost = require("lib/bookshelf_menu_host")
            local host
            local picker_items = {}
            for _i, p in ipairs(found) do
                picker_items[#picker_items + 1] = {
                    text = p.title,
                    callback = function()
                        MenuHost.close(host)
                        insertEntry(function()
                            return { id = Model.nextId(), type = "action",
                                     label = p.title,
                                     icon = PLUGIN_DEFAULT_ICON,
                                     plugin = { key = p.key, method = p.method } }
                        end)
                    end,
                }
            end
            host = MenuHost.show{
                title = _("Choose a plugin"),
                item_table = picker_items,
            }
        end) } },
        { { text = _("System action…"), callback = close(function()
            local ActionPicker = require("lib/bookshelf_action_picker")
            ActionPicker.show{
                on_pick = function(action, name)
                    insertEntry(function()
                        return { id = Model.nextId(), type = "action",
                                 label = name, action = action }
                    end)
                end,
            }
        end) } },
        { { text = _("Bookshelf action…"), callback = close(function()
            -- Category sub-dialog; same close-then-act pattern as the
            -- parent (close the sub-dialog, then insert).
            local sub
            local function subClose(fn)
                return function()
                    UIManager:close(sub)
                    fn()
                end
            end
            sub = ButtonDialog:new{
                title        = _("Bookshelf actions"),
                title_align  = "center",
                width_factor = 0.65,
                buttons      = {
                    { { text = _("Close bookshelf"), callback = subClose(function()
                        insertEntry(function()
                            return { id = Model.nextId(), type = "action",
                                     label = _("Close bookshelf"),
                                     icon = "\xEE\xA1\x95", internal = "close" }
                        end)
                    end) } },
                    { { text = _("Bookshelf menu"), callback = subClose(function()
                        insertEntry(function()
                            return { id = Model.nextId(), type = "action",
                                     label = _("Bookshelf menu"),
                                     icon = "\xE2\x9A\x99", internal = "settings" }
                        end)
                    end) } },
                },
            }
            UIManager:show(sub)
        end) } },
        { { text = _("Bookshelf micro-module…"), callback = close(function()
            local keys = Modules.keys()
            if #keys == 0 then
                UIManager:show(Notification:new{
                    text = _("No micro-modules available"),
                })
                return
            end
            -- Card-grid picker showing each module's live preview (same
            -- modal chrome as the icons library).
            local ModulePicker = require("lib/bookshelf_module_picker")
            ModulePicker:show(function(key)
                insertEntry(function()
                    return { id = Model.nextId(),
                             type = "module", module = key }
                end)
            end)
        end) } },
    }

    if at_top then
        rows[#rows + 1] = {
            { text = _("New folder…"), callback = close(function()
                promptText(_("New folder"), "", _("Add"), function(name)
                    insertEntry(function()
                        return { id = Model.nextId(), type = "folder",
                                 label = name, children = {} }
                    end)
                end)
            end) },
        }
    end

    dialog = ButtonDialog:new{
        title        = _("Add to menu"),
        title_align  = "center",
        width_factor = 0.65,
        buttons      = rows,
    }
    UIManager:show(dialog)
end

return Edit
