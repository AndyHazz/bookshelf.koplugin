--[[
Long-press context dialog + Add flow for hero-area micro-modules.
Mirrors the start-menu edit flow but trimmed to the hero's module-only list:
no rename / icon / folders / move-to-folder — just settings, reorder, remove,
and add. Every mutation follows Model.load -> mutate -> Model.save ->
rebuild-hero, and re-finds its target by id (Model.load returns fresh tables).
]]
local ButtonDialog = require("ui/widget/buttondialog")
local Notification = require("ui/widget/notification")
local UIManager    = require("ui/uimanager")
local HeroModel    = require("lib/bookshelf_hero_modules_model")
local HeroModules  = require("lib/bookshelf_hero_modules")
local Modules      = require("lib/bookshelf_start_menu_modules")
local logger       = require("logger")
local _            = require("lib/bookshelf_i18n").gettext

local Edit = {}

-- Load fresh items, apply fn, save + rebuild the hero. fn returning false
-- (e.g. a clamped moveBy, or a target id that no longer exists) skips both.
local function mutate(bw, fn)
    local items = HeroModel.load()
    local changed = fn(items)
    if changed ~= false then
        HeroModel.save(items)
        HeroModules._rebuild(bw)
    end
end

-- Long-press context dialog for one hero module entry.
function Edit.show(bw, entry)
    local dialog
    local function close(fn)
        return function()
            UIManager:close(dialog)
            if fn then fn() end
        end
    end

    local id  = entry.id
    local def = Modules.get(entry.module)
    local rows = {}

    -- Module settings (when the module offers them). The module owns its UI
    -- + persistence and calls ctx.menu:_reload() after changes; same ctx
    -- shape as a tap. pcall: a broken module must not break the dialog.
    if def and type(def.show_settings) == "function" then
        rows[#rows + 1] = {
            { text = _("Module settings\xE2\x80\xA6"), callback = close(function()
                local ctx = HeroModules._ctx(bw, nil, entry)
                local ok, err = pcall(def.show_settings, ctx)
                if not ok then
                    logger.warn("[bookshelf] hero module settings failed:",
                        entry.module, err)
                end
            end) },
        }
    end

    -- Move up/down — deliberately NOT close()-wrapped: the user taps
    -- repeatedly to walk the module through the grid while the hero
    -- rebuilds beneath the (topmost) dialog. A clamped move is a no-op.
    -- Glyph action buttons matching the start-menu edit dialog and the chip
    -- editor: chevron up/down for move, mdi-delete for remove, fa-plus-circle
    -- for add.
    rows[#rows + 1] = {
        { text = "\xEE\xA1\x82", font_face = "symbols", font_size = 28,
          font_bold = false, callback = function()
            mutate(bw, function(items) return HeroModel.moveBy(items, id, -1) end)
        end },
        { text = "\xEE\xA0\xBF", font_face = "symbols", font_size = 28,
          font_bold = false, callback = function()
            mutate(bw, function(items) return HeroModel.moveBy(items, id, 1) end)
        end },
    }

    rows[#rows + 1] = {
        { text = "\xEE\xA2\xBF", -- U+E8BF mdi-delete (remove this module)
          font_face = "symbols", font_size = 28, font_bold = false,
          callback = close(function()
            mutate(bw, function(items) return HeroModel.removeById(items, id) end)
        end) },
        { text = "\xEF\x81\x95", -- U+F055 fa-plus-circle (add a module)
          font_face = "symbols", font_size = 28, font_bold = false,
          callback = close(function()
            Edit.showAdd(bw, id)
        end) },
    }

    dialog = ButtonDialog:new{
        title        = (def and def.title) or entry.module,
        title_align  = "center",
        width_factor = 0.65,
        buttons      = rows,
    }
    UIManager:show(dialog)
end

-- Add a micro-module to the hero grid (after anchor_id, or appended when nil).
function Edit.showAdd(bw, anchor_id)
    local keys = Modules.keys()
    if #keys == 0 then
        UIManager:show(Notification:new{ text = _("No micro-modules available") })
        return
    end
    -- Card-grid picker showing each module's live preview (shared with the
    -- start menu's add flow).
    local ModulePicker = require("lib/bookshelf_module_picker")
    ModulePicker:show(function(key)
        local def = Modules.get(key)
        local function insert(extra)
            mutate(bw, function(items)
                local e = { id = HeroModel.nextId(), type = "module", module = key }
                if type(extra) == "table" then
                    for k, v in pairs(extra) do e[k] = v end
                end
                HeroModel.insertAfter(items, anchor_id, e)
            end)
        end
        -- Modules with an interactive add step (e.g. Action picks its action +
        -- icon) configure the entry before insert; done(nil) cancels the add.
        if def and type(def.on_add) == "function" then
            local ok = pcall(def.on_add, { bw = bw }, function(fields)
                if fields then insert(fields) end
            end)
            if not ok then insert() end  -- broken on_add: fall back to bare add
        else
            insert()
        end
    end)
end

return Edit
