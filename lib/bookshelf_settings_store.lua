-- bookshelf_settings_store.lua
--
-- All bookshelf preferences live in a dedicated settings file at
-- <datadir>/settings/bookshelf.lua (LuaSettings format) rather than mixed
-- into the global settings.reader.lua. This keeps the user's
-- settings.reader.lua tidy and means an eventual KOReader "delete plugin
-- settings on uninstall" feature has a clear target file to remove.
--
-- The first call to any Store method runs a one-shot migration that
-- copies legacy "bookshelf_<key>" entries from G_reader_settings into
-- this file (with the prefix stripped) and then deletes them from the
-- global store. The `migrated` flag in the new file prevents repeats.
--
-- Call sites use short keys -- the prefix is implicit. Examples:
--
--   Store.read("active_chip", "recent")
--   Store.save("chip_font_scale", 120)
--   Store.delete("dev_branch")
--   Store.isTrue("chip_flex_widths")
--   Store.nilOrTrue("show_close_msg")

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local logger      = require("logger")
local lfs         = require("libs/libkoreader-lfs")

local SETTINGS_PATH = DataStorage:getSettingsDir() .. "/bookshelf.lua"

local _file_present_at_load = lfs.attributes(SETTINGS_PATH, "mode") ~= nil

-- Explicit list of legacy keys to migrate. Editor / UI keys, tab schema,
-- progress indicators, advanced toggles, updater state. Enumerated rather
-- than glob-scanned because there's no public API for "list all keys in
-- G_reader_settings starting with X".
local LEGACY_KEYS = {
    -- Navigation state (chip / page / drill path)
    "active_chip", "active_page", "drill_path",
    -- Tab schema + legacy disabled-set
    "tabs", "chips_disabled",
    -- Font + chip-strip sizing
    "font_scale", "chip_font_scale", "chip_flex_widths",
    -- Library scan behaviour
    "calibre_metadata", "latest_walk_depth",
    -- UX toggles
    "show_close_msg", "show_series_num",
    -- Cover-progress indicator colors / toggles
    "progress_fill", "progress_track", "bookmark_color",
    "badge_fg", "badge_bg",
    "folder_overlay_bg", "folder_overlay_fg",
    "progress_badge_enabled", "progress_bar_enabled",
    "progress_bookmark_enabled", "progress_enabled",
    -- Legacy v1.1 single-key sort flags (kept for back-compat read path)
    "sort_all_mixed", "sort_all_reverse",
    -- Updater state
    "check_updates", "dev_branch", "last_install_source",
}

-- Legacy per-chip sort keys looked like "bookshelf_sort_<chip>" -- there's
-- no enumeration API so iterate the known built-in chip ids that any
-- v1.1 user might have customised. Newer (v1.2) tabs persist sort via
-- the tabs schema, not per-chip keys, so this list doesn't need to grow.
local LEGACY_SORT_CHIPS = {
    "all", "recent", "latest", "series", "authors",
    "genres", "tags", "favorites",
}

local Store = {}
local _settings = nil

function Store.wasPresent() return _file_present_at_load end

local function _migrate(s)
    if s:readSetting("migrated") then return end
    local prefix = "bookshelf_"
    local count = 0
    for _i, k in ipairs(LEGACY_KEYS) do
        local glob_key = prefix .. k
        local val = G_reader_settings:readSetting(glob_key)
        if val ~= nil then
            s:saveSetting(k, val)
            G_reader_settings:delSetting(glob_key)
            count = count + 1
        end
    end
    for _i, chip in ipairs(LEGACY_SORT_CHIPS) do
        local glob_key = prefix .. "sort_" .. chip
        local val = G_reader_settings:readSetting(glob_key)
        if val ~= nil then
            s:saveSetting("sort_" .. chip, val)
            G_reader_settings:delSetting(glob_key)
            count = count + 1
        end
    end
    s:saveSetting("migrated", true)
    s:flush()
    logger.dbg(string.format(
        "[bookshelf] settings migrated to %s (%d keys)",
        SETTINGS_PATH, count))
end

local function _open()
    if _settings then return _settings end
    _settings = LuaSettings:open(SETTINGS_PATH)
    _migrate(_settings)
    return _settings
end

-- Monotonic counter bumped on every save / delete. Lets downstream
-- modules memoise expensive derived state (e.g. CoverProgress color
-- resolution) and invalidate cheaply by comparing the cached counter
-- against the current one. Cheap to read (single field access) and
-- cheap to bump (one add per user-action settings write — same cadence
-- as the existing flush()).
local _generation = 0

function Store.generation() return _generation end

function Store.read(key, default)
    local v = _open():readSetting(key)
    if v == nil then return default end
    return v
end

function Store.save(key, value)
    local s = _open()
    s:saveSetting(key, value)
    -- LuaSettings:saveSetting only updates the in-memory table; the
    -- file isn't touched until flush() runs. Relying on KOReader's
    -- shutdown hook is fragile: KOReader can be SIGTERM-killed
    -- (Kindle frame switching), OOM'd, or simply closed via a path
    -- that doesn't broadcast onFlushSettings. Every user-action
    -- save call sits at a boundary where durability matters more
    -- than the cost of one file write, so flush here.
    s:flush()
    _generation = _generation + 1
end

-- saveDeferred(key, value): in-memory write only -- no flush. For hot-path
-- state that's written very frequently (nav cursor / page / chip / drill on
-- every rebuild and every pagination) where a per-call file write is the
-- dominant cost and durability can wait for a debounced / lifecycle flush.
-- The caller OWNS flushing: schedule a coalesced Store.flush() and/or flush
-- at a close / suspend / onFlushSettings boundary, since bookshelf.lua is a
-- standalone LuaSettings file NOT covered by G_reader_settings autosave.
-- Bumps the generation counter like save() so change-detection consumers
-- still observe the write immediately.
function Store.saveDeferred(key, value)
    local s = _open()
    s:saveSetting(key, value)
    _generation = _generation + 1
end

function Store.delete(key)
    local s = _open()
    s:delSetting(key)
    s:flush()
    _generation = _generation + 1
end

function Store.flush()
    if _settings then _settings:flush() end
end

function Store.isTrue(key)
    return _open():isTrue(key)
end

function Store.nilOrTrue(key)
    return _open():nilOrTrue(key)
end

-- Path the settings live at. Exposed so a future "uninstall plugin"
-- feature can find and remove it without re-deriving the convention.
function Store.path() return SETTINGS_PATH end

return Store
