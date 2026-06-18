--[[
Hero-area micro-module data model. One list under settings key
"hero_module_items". Entries are micro-modules only (no actions, no folders,
no nesting):
  { id, type = "module", module = "<key>" }

This is the same entry shape the start menu uses for module rows, so the
shared ModulePicker (which inserts that shape) and the micro-module registry
work here unchanged. The hero list is deliberately a SEPARATE store from the
start menu's "start_menu_items": the two surfaces hold independent sets, so a
user can keep a clock in the hero without it appearing in the launcher.

The pure list helpers (findById / moveBy / removeById / insertAfter) are
borrowed from the start-menu model — they take the list as an argument and
carry no storage state. Only the storage-bound bits (load / save / DEFAULTS /
nextId) and a module-only sanitize live here.
]]
local BookshelfSettings = require("lib/bookshelf_settings_store")
local SMModel           = require("lib/bookshelf_start_menu_model")
local logger            = require("logger")

local M = {}

local STORAGE_KEY = "hero_module_items"
local SEEDED_KEY  = "hero_modules_seeded"
local NEXT_ID_KEY = "hero_module_next_id"

function M.nextId()
    local n = BookshelfSettings.read(NEXT_ID_KEY, 1)
    BookshelfSettings.save(NEXT_ID_KEY, n + 1)
    return "hm" .. n
end

-- Default hero dashboard for a new install: just the analogue clock — it works
-- everywhere (no network, no statistics dependency) and adapts to any cell
-- size. Users add more from the chooser (long-press > add). All shipped
-- micro-modules are built-in (no dependency on other plugins).
function M.DEFAULTS()
    return {
        { id = "hm_clock",  type = "module", module = "analogue_clock" },
    }
end

-- Returns (out, changed). Keeps ONLY well-formed module entries; the hero
-- holds no actions or folders. Does NOT mutate its input.
function M.sanitize(items)
    if type(items) ~= "table" then return {}, true end
    local out = {}
    local changed = false
    for _i, it in ipairs(items) do
        if type(it) == "table" and type(it.id) == "string"
                and it.type == "module" and type(it.module) == "string" then
            out[#out + 1] = it
        else
            changed = true
            logger.warn("[bookshelf] hero modules: dropping malformed entry",
                type(it) == "table" and tostring(it.id) or tostring(it))
        end
    end
    return out, changed
end

function M.load()
    local saved = BookshelfSettings.read(STORAGE_KEY)
    if type(saved) == "table" then
        local out, changed = M.sanitize(saved)
        if changed then M.save(out) end
        return out
    end
    if BookshelfSettings.isTrue(SEEDED_KEY) then return {} end
    local defaults = M.DEFAULTS()
    BookshelfSettings.save(STORAGE_KEY, defaults)
    BookshelfSettings.save(SEEDED_KEY, true)
    return defaults
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
