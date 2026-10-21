--[[
Add flow for micro-modules on the top panel and the full-screen view. Moving,
sizing, settings and removing live in the layout editor
(bookshelf_module_grid_editor), opened by long-pressing a module. A plain add
follows Model.load -> insert -> Model.save -> rebuild the surface.
]]
local Notification = require("ui/widget/notification")
local UIManager    = require("ui/uimanager")
local HeroModel    = require("lib/bookshelf_hero_modules_model")
local HeroModules  = require("lib/bookshelf_hero_modules")
local Modules      = require("lib/bookshelf_start_menu_modules")
local _            = require("lib/bookshelf_i18n").gettext

local Edit = {}

-- Which list this edit targets. The full-screen overlay edits the full-screen
-- list; the hero edits the hero list. bw._micro_fullscreen is set for the whole
-- time the overlay is open (edit dialogs / pickers open on top of it), so it's
-- the reliable signal. The pure list helpers (findById / moveBy / ...) are the
-- SAME shared functions on both models, so only load / save / nextId differ.
local function modelFor(bw)
    if bw and bw._micro_fullscreen then
        return require("lib/bookshelf_fullscreen_modules_model")
    end
    return HeroModel
end

-- Load fresh items, apply fn, save + rebuild the active surface (the overlay
-- when open, else the hero — HeroModules._rebuild routes it). fn returning
-- false (e.g. a clamped moveBy, or a target id that no longer exists) skips both.
local function mutate(bw, fn)
    local Model = modelFor(bw)
    local items = Model.load()
    local changed = fn(items)
    if changed ~= false then
        Model.save(items)
        HeroModules._rebuild(bw)
    end
end

-- Add a micro-module to the hero grid (after anchor_id, or appended when nil).
-- on_added(entry), when given, receives the new entry instead of it being
-- saved: the layout editor places it in its working copy.
function Edit.showAdd(bw, anchor_id, on_added)
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
            local e = { id = modelFor(bw).nextId(), type = "module", module = key }
            if type(extra) == "table" then
                for k, v in pairs(extra) do e[k] = v end
            end
            if on_added then return on_added(e) end
            mutate(bw, function(items)
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
    end, { for_hero = true })
end

return Edit
