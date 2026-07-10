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

local Edit = {}

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
    if entry.type == "divider" then
        return _("Divider")
    end
    return entry.label or "?"
end

-- One-field text prompt. on_confirm(text) runs only for non-empty input,
-- unless allow_empty is set (icon-only entries keep a deliberate "" label).
local function promptText(title, initial, confirm_label, on_confirm, allow_empty)
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
                  if text ~= "" or allow_empty then on_confirm(text) end
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
    local is_module  = entry.type == "module"
    local is_folder  = entry.type == "folder"
    local is_divider = entry.type == "divider"
    -- Fresh lookup for structure facts (parent, sibling folders): the
    -- captured entry may predate earlier edits.
    local items_now = Model.load()
    local _list, _idx, _e, parent = Model.findById(items_now, id)
    local in_folder = parent ~= nil

    local rows = {}

    if not is_module and not is_divider then
        -- Rename edits the label text only. Unlike a chip (whose glyph is
        -- folded into the label string), a start-menu entry's icon is a
        -- SEPARATE field rendered in its own column -- and folders drive a
        -- default + open/close glyph off it -- so it keeps its own picker
        -- (the "Icon…" entry below) rather than living inline in the label.
        local rename_btn = { text = _("Rename"), callback = close(function()
            local _l, _i, fresh = Model.findById(Model.load(), id)
            -- A blanked label makes the row icon-only (#207) -- allowed as
            -- long as something still renders: an icon, or a folder (which
            -- always falls back to the folder glyph).
            local can_blank = (fresh and fresh.icon ~= nil) or is_folder
            promptText(_("Rename"), fresh and fresh.label or entry.label,
                _("Rename"), function(new_label)
                    if new_label == "" and not can_blank then
                        UIManager:show(Notification:new{
                            text = _("Choose an icon first to make this entry icon-only"),
                        })
                        return
                    end
                    mutate(menu, function(items)
                        local _l2, _i2, e = Model.findById(items, id)
                        if not e or e.label == new_label then return false end
                        e.label = new_label
                    end)
                end, true)
        end) }

        local function pickIcon()
            local Editor = require("lib/bookshelf_chip_editor")
            local _l, _i, fresh = Model.findById(Model.load(), id)
            -- Fresh draft seeded with the current icon; the picker writes the
            -- chosen glyph into draft.icon.
            local draft = { icon = fresh and fresh.icon or nil }
            Editor:_pickIcon(draft, function()
                -- Belt-and-braces: the picker already excludes the Dynamic
                -- category, but reject %tokens (e.g. "%batt_icon") anyway --
                -- they're meaningless in the start menu and would overflow
                -- the icon column.
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
        end
        local function clearIcon()
            -- Icon-only entries (#207) have a deliberately blank label; taking
            -- the icon away too would leave an invisible-but-holdable row.
            local _l, _i, fresh = Model.findById(Model.load(), id)
            if fresh and fresh.label == "" and fresh.type ~= "folder" then
                UIManager:show(Notification:new{
                    text = _("This entry is icon-only - add a label before removing the icon"),
                })
                return
            end
            mutate(menu, function(items)
                local _l2, _i2, e = Model.findById(items, id)
                if not e or e.icon == nil then return false end
                e.icon = nil
            end)
        end
        -- One "Icon…" entry (replacing the old Change icon / Remove icon pair):
        -- opens a small chooser to pick from the icon library or, when an icon
        -- is set, clear it -- so "remove" stays reachable without a second
        -- top-level row.
        local function openIconChooser()
            local _l, _i, fresh = Model.findById(Model.load(), id)
            local has = fresh and fresh.icon ~= nil
            local chooser
            local crows = {
                { { text = _("Choose icon\xE2\x80\xA6"), callback = function()
                    UIManager:close(chooser); pickIcon()
                end } },
            }
            if has then
                crows[#crows + 1] = { { text = _("Remove icon"), callback = function()
                    UIManager:close(chooser); clearIcon()
                end } }
            end
            crows[#crows + 1] = { { text = _("Cancel"), id = "close",
                callback = function() UIManager:close(chooser) end } }
            chooser = ButtonDialog:new{
                title = _("Icon"), title_align = "center",
                width_factor = 0.65, buttons = crows,
            }
            UIManager:show(chooser)
        end

        rows[#rows + 1] = {
            rename_btn,
            { text = _("Icon\xE2\x80\xA6"), callback = close(openIconChooser) },
        }
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
                    local ctx = { bw = menu.bw, menu = menu, entry = entry,
                                  surface = "start_menu" }
                    function ctx.save()
                        mutate(menu, function(items)
                            local list, i = Model.findById(items, entry.id)
                            if list and i then list[i] = entry end
                        end)
                    end
                    -- Per-instance config handle, like the hero / tap ctx. Without
                    -- it a per-instance module (Countdown: its date + label live on
                    -- the entry via ctx.config) bails and its settings won't open
                    -- from the start-menu edit dialog.
                    ctx.config = require("lib/bookshelf_module_kit").entryConfig(entry, ctx.save)
                    local ok, err = pcall(def.show_settings, ctx)
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
        -- Move up / down as chevron glyphs (mdi-chevron-up / -down, the same
        -- family as the chip editor's move chevrons).
        -- The predicate is computed per tap (menu._items refreshes on each
        -- _reload), so the move skips entries hidden from the current view and
        -- steps past the nearest VISIBLE neighbour -- no dead taps on hidden
        -- rows. nil-safe: an older widget without _visibleIds falls back to the
        -- plain adjacent swap.
        { text = "\xEE\xA1\x82", font_face = "symbols", font_size = 28,
          font_bold = false, callback = function()
            local vis = menu._visibleIds and menu:_visibleIds()
            mutate(menu, function(items)
                return Model.moveBy(items, id, -1,
                    vis and function(e) return vis[e.id] end or nil)
            end)
        end },
        { text = "\xEE\xA0\xBF", font_face = "symbols", font_size = 28,
          font_bold = false, callback = function()
            local vis = menu._visibleIds and menu:_visibleIds()
            mutate(menu, function(items)
                return Model.moveBy(items, id, 1,
                    vis and function(e) return vis[e.id] end or nil)
            end)
        end },
    }

    if not is_folder and not is_divider then
        if in_folder then
            rows[#rows + 1] = {
                { text = _("Move out of folder"), callback = close(function()
                    mutate(menu, function(items)
                        return Model.moveToTopLevel(items, id)
                    end)
                end) },
            }
        else
            -- Collect the folders once; offer a single "Move to folder…" row
            -- that opens a submenu listing them, rather than one top-level row
            -- per folder. Only shown when there's at least one folder to
            -- target. Mirrors the single "Move out of folder" row above.
            local folders = {}
            for _i, it in ipairs(items_now) do
                if it.type == "folder" then folders[#folders + 1] = it end
            end
            if #folders > 0 then
                rows[#rows + 1] = {
                    { text = _("Move to folder\xE2\x80\xA6"), callback = close(function()
                        local sub
                        local srows = {}
                        for _j, f in ipairs(folders) do
                            local folder_id = f.id
                            srows[#srows + 1] = {
                                { text = f.label, callback = function()
                                    UIManager:close(sub)
                                    mutate(menu, function(items)
                                        return Model.moveToFolder(items, id, folder_id)
                                    end)
                                end },
                            }
                        end
                        srows[#srows + 1] = { { text = _("Cancel"), id = "close",
                            callback = function() UIManager:close(sub) end } }
                        sub = ButtonDialog:new{
                            title = _("Move to folder"), title_align = "center",
                            width_factor = 0.65, buttons = srows,
                        }
                        UIManager:show(sub)
                    end) },
                }
            end
        end
    end

    -- Show-in scope: which context the entry appears in -- the library home
    -- screen, the in-reader launcher, or both. Stored as entry.scope
    -- ("library" | "reader"); nil means "both" (the default, so existing menus
    -- are unaffected). Folders carry it too, gating the whole group. Dividers
    -- carry it like any other entry (#256) -- a separator that only makes
    -- sense in one view shouldn't leave a stray line in the other.
    do
        -- Menu-action shortcuts get an "Auto" scope (nil): shown wherever the
        -- menu item exists, governed by the availability filter. They also get
        -- an explicit "both" to force showing in both views regardless. Other
        -- item types keep the plain Library/Reader/both(nil) choices.
        local _l0, _i0, e0 = Model.findById(Model.load(), id)
        local is_menu_action = type(e0) == "table" and type(e0.menu_path) == "table"
        local SCOPES = is_menu_action and {
            { nil,       _("Auto") },
            { "library", _("Library only") },
            { "reader",  _("Reader only") },
            { "both",    _("Library and reader") },
        } or {
            { nil,       _("Library and reader") },
            { "library", _("Library only") },
            { "reader",  _("Reader only") },
        }
        local valid = { library = true, reader = true, both = is_menu_action or nil }
        local function curScope()
            local _l, _i, fresh = Model.findById(Model.load(), id)
            local s = fresh and fresh.scope
            return valid[s] and s or nil
        end
        local function scopeLabel(val)
            for _j, s in ipairs(SCOPES) do if s[1] == val then return s[2] end end
            return SCOPES[1][2]
        end
        rows[#rows + 1] = {
            { text = _("Show in") .. ": " .. scopeLabel(curScope()),
              callback = close(function()
                local sub
                local srows = {}
                for _j, s in ipairs(SCOPES) do
                    local val = s[1]
                    srows[#srows + 1] = {
                        { text = (curScope() == val and "\xE2\x9C\x93 " or "  ") .. s[2],
                          callback = function()
                            UIManager:close(sub)
                            mutate(menu, function(items)
                                local _l2, _i2, e = Model.findById(items, id)
                                if not e or e.scope == val then return false end
                                e.scope = val
                            end)
                          end },
                    }
                end
                srows[#srows + 1] = { { text = _("Cancel"), id = "close",
                    callback = function() UIManager:close(sub) end } }
                sub = ButtonDialog:new{ title = _("Show in"), title_align = "center",
                    width_factor = 0.65, buttons = srows }
                UIManager:show(sub)
            end) },
        }
    end

    local function doDelete()
        mutate(menu, function(items)
            return Model.removeById(items, id)
        end)
    end
    local delete_btn = { text = "\xEE\xA2\xBF", -- U+E8BF mdi-delete (matches chip editor)
        font_face = "symbols", font_size = 28, font_bold = false,
        callback = close(function()
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
    local add_btn = { text = "\xEF\x81\x95", -- U+F055 fa-plus-circle (matches chip editor)
        font_face = "symbols", font_size = 28, font_bold = false,
        callback = close(function()
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

    -- Plugin / System action / Bookshelf action rows come from the shared
    -- chooser (reused by the hero Action module); each yields the entry FIELDS,
    -- to which we stamp a fresh id + type="action" before inserting.
    local Chooser = require("lib/bookshelf_action_chooser")
    local rows = {}
    for _i, r in ipairs(Chooser.actionRows(close, function(fields)
        insertEntry(function()
            local e = { id = Model.nextId(), type = "action" }
            for k, v in pairs(fields) do e[k] = v end
            return e
        end)
    end)) do
        rows[#rows + 1] = r
    end

    -- "Bookshelf micro-module…" is hidden when the start-menu micro-module
    -- surface is off: no way to add one when module cards aren't shown there.
    if require("lib/bookshelf_settings_store").microInStartMenu() then
        rows[#rows + 1] = { { text = _("Bookshelf micro-module…"), callback = close(function()
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
                local def = Modules.get(key)
                local function insert(extra)
                    insertEntry(function()
                        local e = { id = Model.nextId(), type = "module", module = key }
                        if type(extra) == "table" then
                            for k, v in pairs(extra) do e[k] = v end
                        end
                        return e
                    end)
                end
                -- Interactive add step (e.g. Action picks its action + icon);
                -- done(nil) cancels the add.
                if def and type(def.on_add) == "function" then
                    local ok = pcall(def.on_add, { bw = menu.bw }, function(fields)
                        if fields then insert(fields) end
                    end)
                    if not ok then insert() end
                else
                    insert()
                end
            end)
        end) } }
    end

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
        rows[#rows + 1] = {
            -- No name prompt -- a divider is a bare line, nothing to label.
            { text = _("Divider"), callback = close(function()
                insertEntry(function()
                    return { id = Model.nextId(), type = "divider" }
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
