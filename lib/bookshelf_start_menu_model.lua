--[[
Start menu data model. One list under settings key "start_menu_items".
Entry shapes (discriminated by `type`):
  { id, type = "action", label, icon?, action = <verbatim dispatcher settings table> }
  { id, type = "action", label, icon?, internal = "close" | "settings" }
  { id, type = "action", label, icon?, plugin = { key, method } }  -- FM plugin launcher
  { id, type = "folder", label, icon?, children = { <action/module entries> } }
  { id, type = "module", module = "stats" }
  { id, type = "divider" }  -- bare separator line, root-level only
Folders only at top level (one-level rule), enforced by sanitize().
]]
local BookshelfSettings = require("lib/bookshelf_settings_store")
local logger = require("logger")
local _ = require("lib/bookshelf_i18n").gettext

local M = {}

local STORAGE_KEY = "start_menu_items"
local SEEDED_KEY  = "start_menu_seeded"
local NEXT_ID_KEY = "start_menu_next_id"

function M.nextId()
    local n = BookshelfSettings.read(NEXT_ID_KEY, 1)
    BookshelfSettings.save(NEXT_ID_KEY, n + 1)
    return "sm" .. n
end

-- Default icons are user-editable. Glyphs are symbols.ttf-covered (cfont
-- falls back to it); emoji codepoints are not and render as tofu.
-- The set mirrors the maintainer's own day-to-day menu (2026-06-12),
-- minus anything that depends on other plugins being installed.
function M.DEFAULTS()
    return {
        { id = "sm_quote",    type = "module", module = "quote_of_day" },
        { id = "sm_cal",      type = "action", label = _("Reading calendar"),
          icon = "\xEF\x81\xB3", action = { stats_calendar_view = true } }, -- U+F073 fa-calendar
        { id = "sm_wifi",     type = "action", label = _("Toggle Wi-Fi"),
          icon = "\xEE\xB2\xA8", action = { toggle_wifi = true } },      -- U+ECA8 wifi
        { id = "sm_night",    type = "action", label = _("Toggle night mode"),
          icon = "\xEE\xB2\x93", action = { night_mode = true } },       -- U+EC93 weather-night
        { id = "sm_settings", type = "action", label = _("Bookshelf menu"),
          icon = "\xE2\x9A\x99", internal = "settings" },                -- U+2699 ⚙
        { id = "sm_close",    type = "action", label = _("Exit bookshelf"),
          icon = "\xEE\xA4\x85", internal = "close", scope = "library" }, -- U+E905 exit-to-app
        { id = "sm_reader_home", type = "action", label = _("Close book"),
          icon = "\xEE\xA4\x85", menu_path = { { id = "filemanager" } },  -- U+E905 exit-to-app
          scope = "reader" },
        { id = "sm_sleep",    type = "action", label = _("Sleep"),
          icon = "\xEE\xAC\xA4", action = { suspend = true } },          -- U+EB24 power-sleep
    }
end

local function validAction(it)
    return type(it.action) == "table"
        or it.internal == "close" or it.internal == "settings"
        or (type(it.plugin) == "table"
            and type(it.plugin.key) == "string"
            and type(it.plugin.method) == "string")
        or (type(it.menu_path) == "table" and #it.menu_path > 0)
end

-- Returns (out, changed). Does NOT mutate any input table.
function M.sanitize(items)
    if type(items) ~= "table" then return {}, true end
    local out = {}
    local changed = false
    for _i, it in ipairs(items) do
        local keep = false
        local entry = it
        if type(it) == "table" and type(it.id) == "string" then
            if it.type == "action" and type(it.label) == "string" and validAction(it) then
                keep = true
            elseif it.type == "folder" and type(it.label) == "string" then
                -- Sanitize children, stripping nested folders.
                local raw_children = type(it.children) == "table" and it.children or {}
                local kids = {}
                local kids_changed = type(it.children) ~= "table"
                local inner, inner_changed = M.sanitize(raw_children)
                if inner_changed then kids_changed = true end
                for _j, c in ipairs(inner) do
                    if c.type == "folder" then
                        kids_changed = true
                    else
                        kids[#kids + 1] = c
                    end
                end
                -- Build a shallow copy of the folder with the new children list.
                if kids_changed or #kids ~= #raw_children then
                    local copy = {}
                    for k, v in pairs(it) do copy[k] = v end
                    copy.children = kids
                    entry = copy
                    changed = true
                end
                keep = true
            elseif it.type == "module" and type(it.module) == "string" then
                keep = true
            elseif it.type == "divider" then
                keep = true
            end
        end
        if keep then
            -- Self-heal: older builds wrote a transient _unresolved flag onto
            -- live entries, which got flushed into settings. Strip it from
            -- anything we keep (copy-on-strip; never mutate the input).
            if entry._unresolved ~= nil then
                if entry == it then
                    local copy = {}
                    for k, v in pairs(entry) do copy[k] = v end
                    entry = copy
                end
                entry._unresolved = nil
                changed = true
            end
            out[#out + 1] = entry
        else
            changed = true
            logger.warn("[bookshelf] start menu: dropping malformed entry",
                type(it) == "table" and tostring(it.id) or tostring(it))
        end
    end
    return out, changed
end

-- One-time migration: set scope="library" on any sm_close entry that has no
-- scope set, and inject sm_reader_home after it if absent. Self-heals saved
-- configs that pre-date the context-scoping defaults (issue #216).
local function _migrate(items)
    local changed = false
    local has_reader_home = false
    local close_idx = nil
    local close_was_unscoped = false

    for i, it in ipairs(items) do
        if it.id == "sm_close" and it.scope == nil then
            it.scope = "library"
            changed = true
            close_idx = i
            close_was_unscoped = true
        end
        if it.id == "sm_reader_home" then
            has_reader_home = true
        end
    end

    -- Only inject sm_reader_home if we just fixed an unscoped sm_close (and it's
    -- not already present). This avoids re-populating configs the user has
    -- deliberately cleared.
    if close_was_unscoped and not has_reader_home then
        local reader_home
        for _, d in ipairs(M.DEFAULTS()) do
            if d.id == "sm_reader_home" then reader_home = d; break end
        end
        if reader_home then
            local pos = close_idx + 1
            table.insert(items, pos, reader_home)
            changed = true
        end
    end

    return items, changed
end

function M.load()
    local saved = BookshelfSettings.read(STORAGE_KEY)
    if type(saved) == "table" then
        local out, changed = M.sanitize(saved)
        local mig_changed
        out, mig_changed = _migrate(out)
        if changed or mig_changed then M.save(out) end
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

-- Returns: containing_list, index, entry, parent_folder_or_nil. Nil if absent.
function M.findById(items, id)
    for i, it in ipairs(items) do
        if it.id == id then return items, i, it, nil end
        if it.type == "folder" then
            for j, c in ipairs(it.children or {}) do
                if c.id == id then return it.children, j, c, it end
            end
        end
    end
    return nil
end

-- Filter to entries visible in `context` ("library" | "reader"). An entry's
-- scope restricts it: "library"/"reader" to that context; nil (the default) and
-- "both" show everywhere. ("both" is the explicit "show in both views" a
-- menu-action shortcut can be set to, vs nil which for menu actions means "Auto"
-- -- shown wherever its menu item exists, gated separately by the availability
-- filter.) A folder's OWN scope still gates it, same as any other entry, but
-- an empty folder is never dropped for being empty -- whether it started that
-- way (e.g. one the user just created) or ended up that way because all its
-- children are scoped elsewhere (#221: a folder can always be populated via
-- its flyout, or deleted manually if it's not wanted -- it doesn't need to be
-- hidden either way). Returns a fresh filtered list -- never mutates.
function M.filterByScope(items, context)
    local function visible(e)
        return e.scope == nil or e.scope == "both" or e.scope == context
    end
    local out = {}
    for _i, it in ipairs(items or {}) do
        if visible(it) then
            if it.type == "folder" then
                local kids = {}
                for _j, c in ipairs(it.children or {}) do
                    if visible(c) then kids[#kids + 1] = c end
                end
                local copy = {}
                for k, v in pairs(it) do copy[k] = v end
                copy.children = kids
                out[#out + 1] = copy
            else
                out[#out + 1] = it
            end
        end
    end
    return out
end

-- dir = -1 (up) / 1 (down). Returns true if moved.
-- is_visible (optional) is a predicate run on neighbouring entries: when given,
-- the move skips over entries it rejects and swaps the target directly with its
-- nearest VISIBLE neighbour, leaving the skipped ones parked at their slots.
-- This keeps a single tap producing a single visible step when the live view
-- hides some entries (e.g. Auto menu shortcuts not available here) -- without it
-- the user taps once per hidden item to walk past them. nil predicate == the
-- old plain-adjacent swap (every entry visible), so existing callers/tests are
-- unaffected.
function M.moveBy(items, id, dir, is_visible)
    local list, i = M.findById(items, id)
    if not list then return false end
    local function visible(e) return is_visible == nil or is_visible(e) end
    local j = i + dir
    while j >= 1 and j <= #list and not visible(list[j]) do
        j = j + dir
    end
    if j < 1 or j > #list then return false end
    list[i], list[j] = list[j], list[i]
    return true
end

function M.removeById(items, id)
    local list, i = M.findById(items, id)
    if not list then return false end
    table.remove(list, i)
    return true
end

-- anchor_id nil = append to top level. Inserts into the anchor's own list.
function M.insertAfter(items, anchor_id, entry)
    if anchor_id then
        local list, i = M.findById(items, anchor_id)
        if list then table.insert(list, i + 1, entry); return end
    end
    items[#items + 1] = entry
end

function M.moveToFolder(items, id, folder_id)
    local _list, _i, entry = M.findById(items, id)
    local _fl, _fi, folder = M.findById(items, folder_id)
    if not entry or not folder then return false end
    if entry.type == "folder" or folder.type ~= "folder" then return false end
    M.removeById(items, id)
    folder.children = folder.children or {}
    folder.children[#folder.children + 1] = entry
    return true
end

function M.moveToTopLevel(items, id)
    local _list, _i, entry, parent = M.findById(items, id)
    if not entry or not parent then return false end
    M.removeById(items, id)
    items[#items + 1] = entry
    return true
end

-- If `value` is a whole-value image-icon token "[icon=NAME]" (as inserted by
-- the SVG icon-folder chip in the icon picker), return the trimmed NAME;
-- otherwise nil. The start-menu renderer uses this to swap the row's glyph
-- TextWidget for an IconWidget. NAME is read up to the first ']' (matches the
-- picker's exclusion of ']' in filenames); a plain glyph or %token returns nil.
function M.imageIconName(value)
    if type(value) ~= "string" then return nil end
    local name = value:match("^%[icon=([^%]]*)%]$")
    if not name then return nil end
    name = name:gsub("^%s*(.-)%s*$", "%1")
    if name == "" then return nil end
    return name
end

return M
