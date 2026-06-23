--[[
Full-screen micro-module data model. One list under settings key
"fullscreen_module_items", entries module-only (same shape as the hero list):
  { id, type = "module", module = "<key>" }

This is a SEPARATE store from the hero list ("hero_module_items"): the two
surfaces hold independent module sets, so a user can run one set in the hero and
a different set behind the full-screen button. Mirrors bookshelf_hero_modules_model
(same pure list helpers borrowed from the start-menu model), with one
difference: the full-screen view reflows ALL its modules (no per-page paging),
so there is no `page` field and no Pg. assignment.

First load seeds from a COPY of the hero list (minus any page field) so turning
the full-screen surface on starts with the user's existing modules; the two
lists then diverge independently.
]]
local BookshelfSettings = require("lib/bookshelf_settings_store")
local SMModel           = require("lib/bookshelf_start_menu_model")
local logger            = require("logger")

local M = {}

local STORAGE_KEY = "fullscreen_module_items"
local SEEDED_KEY  = "fullscreen_modules_seeded"
local NEXT_ID_KEY = "fullscreen_module_next_id"

function M.nextId()
    local n = BookshelfSettings.read(NEXT_ID_KEY, 1)
    BookshelfSettings.save(NEXT_ID_KEY, n + 1)
    return "fsm" .. n
end

-- Fallback default if the hero list is itself empty at seed time: the analogue
-- clock (works everywhere, no network / statistics dependency).
function M.DEFAULTS()
    return {
        { id = "fsm_clock", type = "module", module = "analogue_clock" },
    }
end

-- Drop the page field from an entry (full-screen has no pagination), KEEPING
-- every other field -- per-instance module config (an Action card's
-- action/label/icon, etc.) lives on the entry and must survive. Returns the
-- entry unchanged when there's no page to strip, else a stripped copy + true.
local function stripPage(it)
    if it.page == nil then return it, false end
    local e = {}
    for k, v in pairs(it) do if k ~= "page" then e[k] = v end end
    return e, true
end

-- Same module-only sanitiser as the hero model (keeps the whole entry, so
-- per-instance config is preserved), but with no pagination so a stray page
-- field is dropped.
function M.sanitize(items)
    if type(items) ~= "table" then return {}, true end
    local out = {}
    local changed = false
    for _i, it in ipairs(items) do
        if type(it) == "table" and type(it.id) == "string"
                and it.type == "module" and type(it.module) == "string" then
            local e, stripped = stripPage(it)
            if stripped then changed = true end
            out[#out + 1] = e
        else
            changed = true
            logger.warn("[bookshelf] fullscreen modules: dropping malformed entry",
                type(it) == "table" and tostring(it.id) or tostring(it))
        end
    end
    return out, changed
end

-- Seed = copy of the hero list with the page field stripped (all other
-- per-instance fields preserved). Empty hero -> the clock default. Each entry
-- is DEEP-copied (one level): the two lists must not share entry tables, or an
-- in-session edit to one would leak into the other before the next reload.
local function seedFromHero()
    local ok, HeroModel = pcall(require, "lib/bookshelf_hero_modules_model")
    local out = {}
    if ok and HeroModel then
        for _i, it in ipairs(HeroModel.load() or {}) do
            if type(it) == "table" and it.type == "module" and type(it.module) == "string" then
                local e = {}
                for k, v in pairs(it) do if k ~= "page" then e[k] = v end end
                out[#out + 1] = e
            end
        end
    end
    if #out == 0 then out = M.DEFAULTS() end
    return out
end

function M.load()
    local saved = BookshelfSettings.read(STORAGE_KEY)
    if type(saved) == "table" then
        local out, changed = M.sanitize(saved)
        if changed then M.save(out) end
        return out
    end
    if BookshelfSettings.isTrue(SEEDED_KEY) then return {} end
    local seed = seedFromHero()
    BookshelfSettings.save(STORAGE_KEY, seed)
    BookshelfSettings.save(SEEDED_KEY, true)
    return seed
end

function M.save(items)
    BookshelfSettings.save(STORAGE_KEY, items)
end

-- Pure list helpers reused from the start-menu model (list-arg, no state).
M.findById    = SMModel.findById
M.moveBy      = SMModel.moveBy
M.removeById  = SMModel.removeById
M.insertAfter = SMModel.insertAfter

return M
