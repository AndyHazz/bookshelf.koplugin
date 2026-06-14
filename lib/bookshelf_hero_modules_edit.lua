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
                local ctx = HeroModules._ctx(bw)
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
    rows[#rows + 1] = {
        { text = _("Move up"), callback = function()
            mutate(bw, function(items) return HeroModel.moveBy(items, id, -1) end)
        end },
        { text = _("Move down"), callback = function()
            mutate(bw, function(items) return HeroModel.moveBy(items, id, 1) end)
        end },
    }

    rows[#rows + 1] = {
        { text = _("Remove"), callback = close(function()
            mutate(bw, function(items) return HeroModel.removeById(items, id) end)
        end) },
        -- NB: literal UTF-8 ellipsis bytes, not \u{2026} — xgettext's Lua
        -- parser doesn't decode \u escapes, so the msgid wouldn't match.
        { text = _("Add micro-module\xE2\x80\xA6"), callback = close(function()
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
        mutate(bw, function(items)
            HeroModel.insertAfter(items, anchor_id,
                { id = HeroModel.nextId(), type = "module", module = key })
        end)
    end)
end

return Edit
