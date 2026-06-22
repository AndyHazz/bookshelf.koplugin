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

-- Large values are routed to their OWN files (not bookshelf.lua), so saving an
-- ordinary preference doesn't rewrite them:
--   * "micromodule_*" keys      -> bookshelf_micromodules.lua
--   * "hardcover_links" (cache) -> bookshelf_hardcover_links.lua
-- subStoreFor(key) returns the destination store or nil (= the main file).
-- Sub-stores are lazy-required so they aren't pulled in until a routed key is
-- touched (and so the standalone test runner can stub them).
local _mm, _hc
local function mm()
    _mm = _mm or require("lib/bookshelf_micromodule_store")
    return _mm
end
local function hc()
    _hc = _hc or require("lib/bookshelf_file_store").new("bookshelf_hardcover_links.lua")
    return _hc
end
local function subStoreFor(key)
    if type(key) ~= "string" then return nil end
    if key:sub(1, 12) == "micromodule_" then return mm() end
    if key == "hardcover_links" then return hc() end
    return nil
end

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

-- One-shot: move any key that now belongs in a sub-store (micromodule_* data,
-- the hardcover_links cache) out of bookshelf.lua and into its own file. Guarded
-- by a flag so it runs once; the flag is versioned so adding a new routed key
-- (hardcover_links, after micromodules shipped) re-runs the pass on existing
-- installs. Enumerates via LuaSettings' in-memory .data (no public key-list
-- API); a stub without .data simply finds nothing and sets the flag.
--
-- Crash-safe for precious data (the link cache): each value is written to its
-- sub-store and the sub-store is FLUSHED before the main file is flushed with
-- the keys removed. A crash in between leaves the value in BOTH files (the main
-- deletes are in-memory until its flush), so the next run simply re-migrates --
-- never a loss.
local RELOCATED_FLAG = "aux_data_relocated_v2"
local function _relocateAux(s)
    if s:readSetting(RELOCATED_FLAG) then return end
    local data = s.data or {}
    local moved = {}  -- sub-store -> count, for logging
    local keys = {}
    for k in pairs(data) do
        if subStoreFor(k) then keys[#keys + 1] = k end
    end
    for _i, k in ipairs(keys) do
        local sub = subStoreFor(k)
        sub.saveDeferred(k, data[k])
        moved[sub] = (moved[sub] or 0) + 1
    end
    -- Flush every touched sub-store FIRST (durable), then drop the keys from the
    -- main file and flush it.
    for sub, n in pairs(moved) do
        sub.flush()
        logger.dbg(string.format("[bookshelf] relocated %d key(s) to %s", n, sub.path()))
    end
    for _i, k in ipairs(keys) do s:delSetting(k) end
    s:saveSetting(RELOCATED_FLAG, true)
    s:flush()
end

local function _open()
    if _settings then return _settings end
    _settings = LuaSettings:open(SETTINGS_PATH)
    _migrate(_settings)
    _relocateAux(_settings)
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
    local sub = subStoreFor(key)
    if sub then _open(); return sub.read(key, default) end
    local v = _open():readSetting(key)
    if v == nil then return default end
    return v
end

function Store.save(key, value)
    local s = _open()
    local sub = subStoreFor(key)
    if sub then sub.save(key, value); _generation = _generation + 1; return end
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

-- Per-surface micro-module placement. Three INDEPENDENT surfaces -- the start
-- menu, the hero area, and the full-screen footer button -- each on/off, so a
-- user can run modules in any combination (e.g. a clock in the hero AND a
-- different set behind the full-screen button). Toggling all three off makes
-- microAnyEnabled() false, the kill switch that lets the loader skip all
-- micro-module code (handy for ruling out performance issues).
--
-- Supersedes the old 3-way micro_modules_placement ("hero"/"fullscreen"/"off").
-- Unset per-surface keys fall back to that legacy value so existing installs
-- migrate transparently: "hero" -> hero on, "fullscreen" -> full-screen on,
-- "off" -> hero+full-screen off. The start-menu surface defaults ON regardless
-- (start menus have always shown module cards, independent of the old
-- placement, so upgraders don't lose them).
local function legacyPlacement()
    local p = Store.read("micro_modules_placement")
    if p == "hero" or p == "fullscreen" or p == "off" then return p end
    if Store.read("micro_modules_disabled") == true then return "off" end
    return "hero"
end

function Store.microInStartMenu()
    local v = Store.read("micro_in_start_menu")
    if v ~= nil then return v == true end
    return true  -- start-menu module cards predate (and never keyed off) placement
end

function Store.microInHero()
    local v = Store.read("micro_in_hero")
    if v ~= nil then return v == true end
    return legacyPlacement() == "hero"
end

function Store.microFullscreenButton()
    local v = Store.read("micro_fullscreen_button")
    if v ~= nil then return v == true end
    return legacyPlacement() == "fullscreen"
end

-- Kill switch: true while ANY surface is on. When false the micro-module
-- registry scan / loader is skipped entirely (no rendering, no async fetches).
function Store.microAnyEnabled()
    return Store.microInStartMenu() or Store.microInHero() or Store.microFullscreenButton()
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
    local sub = subStoreFor(key)
    if sub then sub.saveDeferred(key, value); _generation = _generation + 1; return end
    s:saveSetting(key, value)
    _generation = _generation + 1
end

function Store.delete(key)
    local s = _open()
    local sub = subStoreFor(key)
    if sub then sub.delete(key); _generation = _generation + 1; return end
    s:delSetting(key)
    s:flush()
    _generation = _generation + 1
end

function Store.flush()
    if _settings then _settings:flush() end
end

function Store.isTrue(key)
    local sub = subStoreFor(key)
    if sub then _open(); return sub.read(key) == true end
    return _open():isTrue(key)
end

function Store.nilOrTrue(key)
    local sub = subStoreFor(key)
    if sub then _open(); local v = sub.read(key); return v == nil or v == true end
    return _open():nilOrTrue(key)
end

-- Path the settings live at. Exposed so a future "uninstall plugin"
-- feature can find and remove it without re-deriving the convention.
function Store.path() return SETTINGS_PATH end

return Store
