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
local Grid              = require("lib/bookshelf_module_grid")
local logger            = require("logger")

local M = {}

local STORAGE_KEY = "hero_module_items"
local SEEDED_KEY  = "hero_modules_seeded"
local NEXT_ID_KEY = "hero_module_next_id"
-- Set once this surface's layout is on the grid (by the one-time upgrade from
-- the old row packer, or by a fresh install seeding positioned DEFAULTS).
M.MIGRATED_KEY = "module_grid_migrated_hero"

function M.nextId()
    local n = BookshelfSettings.read(NEXT_ID_KEY, 1)
    BookshelfSettings.save(NEXT_ID_KEY, n + 1)
    return "hm" .. n
end

-- Default hero dashboard for a new install: the analogue clock and the quote
-- of the day. Both work everywhere -- no network, no statistics dependency --
-- and both adapt to any cell size, which is what qualifies a module to be
-- seeded rather than chosen.
--
-- Two rather than one because one leaves the dashboard looking like a
-- placeholder. The pair fills the row, shows that the area holds more than a
-- clock, and gives a new install something to read on first launch
-- (maintainer, aiming at the first impression). Users add more from the
-- chooser (long-press > add); all shipped micro-modules are built-in.
--
-- Positions: the clock as a 2x2 square at the left, the quote taking the rest
-- of the panel. The panel's column count depends on its width, so the quote
-- asks for more than any panel has and shrinks to the edge (Grid.resolve).
function M.DEFAULTS()
    return {
        { id = "hm_clock", type = "module", module = "analogue_clock",
          at = { page = 1, col = 1, row = 1, w = 2, h = 2 } },
        { id = "hm_quote", type = "module", module = "quote_of_day",
          at = { page = 1, col = 3, row = 1, w = 8, h = 2 } },
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
            local e, cleaned = Grid.cleanPositions(it)
            if cleaned then changed = true end
            out[#out + 1] = e
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
    BookshelfSettings.save(M.MIGRATED_KEY, true)
    -- A new install's clock starts without the date (maintainer, v5.3). Set
    -- here rather than by changing the module's default, which would also
    -- take the date away from every reader who never touched the toggle.
    -- Key: micromodules/analogue_clock.lua DATE_KEY.
    if BookshelfSettings.read("micromodule_analogue_clock_date") == nil then
        BookshelfSettings.save("micromodule_analogue_clock_date", false)
    end
    return defaults
end

function M.save(items)
    BookshelfSettings.save(STORAGE_KEY, items)
end

-- In memory only; the caller flushes (HeroModules._ctx's saveDeferred).
function M.saveDeferred(items)
    BookshelfSettings.saveDeferred(STORAGE_KEY, items)
end

-- Pure list helpers reused from the start-menu model (list-arg, no state).
M.findById    = SMModel.findById
M.moveBy      = SMModel.moveBy
M.removeById  = SMModel.removeById
M.insertAfter = SMModel.insertAfter

return M
