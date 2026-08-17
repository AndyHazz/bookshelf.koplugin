-- bookshelf_list_presets.lua
-- Named, switchable list-view layouts, one settings file each.
--
-- ── WHY ────────────────────────────────────────────────────────────────────
--
-- A list layout is now a real piece of work to build: up to six lines, each
-- with a token template, a face, a size, a weight, a slant, a case and an
-- alignment, over a column count and a density. Having built one, there is no
-- way to keep it while trying another -- the maintainer's words: "the
-- complexity and possibilities of the listing layouts warrant being able to
-- save presets ... at least stored as separate settings files with a way to
-- switch between them".
--
-- Deliberately NOT bookends's preset system, which also does sharing, import,
-- a gallery and a cycle list. This is the half that was asked for: save, apply,
-- rename, delete.
--
-- ── STORAGE ────────────────────────────────────────────────────────────────
--
-- One KOReader LuaSettings file per preset, in its own directory. LuaSettings
-- is the reason this module is short: it already serialises a nested Lua table
-- to a file that parses back, writes atomically, and survives a half-written
-- file. Bookends hand-rolled a serialiser because it needed sparse-array
-- round-tripping and a validation sandbox; nothing here does.
--
-- The FILENAME is sanitised from the name, and the NAME is stored inside the
-- file. So a preset called "Two-column, rich" lives in two_column_rich.lua and
-- still displays with its punctuation, and renaming does not have to move the
-- file (though it does, so the directory stays readable from a shell).
--
-- ── WHAT A PRESET HOLDS ────────────────────────────────────────────────────
--
-- The four keys that decide what a list LOOKS like. Not the three view-mode
-- toggles (list_when_expanded / _collapsed / _in_folder) and not a chip's
-- view_mode pin: those decide WHERE a list appears, which is a different
-- question, and folding them in would mean applying a layout could switch the
-- shelf out from under you.
--
-- Values are captured RESOLVED, through the same readers the renderer uses, so
-- a preset never contains "unset". Applying one therefore always writes all
-- four keys and can never leave a field of the previous layout behind -- which
-- is the failure that makes preset systems feel haunted.
--
-- NO VERSIONING AND NO MIGRATION, deliberately. Presets have exactly one shape
-- and have never had another; there is no released build that wrote a
-- different one, so there is nothing to convert from. If the shape ever does
-- change, the answer is the same one the column keys got: leave the old files
-- alone and let them fall back, rather than carrying a converter forever.

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local lfs         = require("libs/libkoreader-lfs")
local logger      = require("logger")

local BookshelfSettings = require("lib/bookshelf_settings_store")
local Lines             = require("lib/bookshelf_list_lines")

local Presets = {}

Presets.KEY_LINES      = Lines.KEYS.lines
Presets.KEY_SHOW_COVER = Lines.KEYS.show_cover
Presets.KEY_COLUMNS    = "list_columns"
Presets.KEY_FONT_SCALE = "list_font_scale"

-- dir() -> the preset directory, created on demand.
--
-- Resolved through getFullDataDir, which expands "." to the real cwd: a Kobo
-- launcher runs without KO_HOME and DataStorage falls back to a relative path,
-- so caching a relative one would break every lookup after any cwd change.
-- (Bookends hit exactly that.)
local _dir
function Presets.dir()
    if not _dir then
        local base = DataStorage.getFullDataDir and DataStorage:getFullDataDir()
                     or DataStorage:getDataDir()
        _dir = base .. "/settings/bookshelf_list_presets"
    end
    if lfs.attributes(_dir, "mode") ~= "directory" then
        lfs.mkdir(_dir)
    end
    return _dir
end

-- A filename that cannot escape the directory or collide with the filesystem's
-- opinions about punctuation. Never empty: a name of nothing but punctuation
-- would otherwise produce ".lua".
function Presets.filenameFor(name)
    local s = tostring(name or ""):lower()
        :gsub("[^%w_]", "_"):gsub("_+", "_"):gsub("^_", ""):gsub("_$", "")
    if s == "" then s = "preset" end
    return s .. ".lua"
end

-- ── Capture and apply ──────────────────────────────────────────────────────

-- current() -> the layout as it stands, fully resolved.
function Presets.current()
    local layout = Lines.layout()
    local cols = BookshelfSettings.read(Presets.KEY_COLUMNS)
    local scale = BookshelfSettings.read(Presets.KEY_FONT_SCALE)
    return {
        lines      = layout.lines,
        show_cover = layout.show_cover,
        columns    = type(cols)  == "number" and cols  or 1,
        font_scale = type(scale) == "number" and scale or 100,
    }
end

-- save(name) -> filename, or nil, err.
--
-- Overwrites a preset of the same name rather than making "name (2)": the user
-- typed a name they had used before, and silently keeping both is how a preset
-- list becomes unusable.
function Presets.save(name, layout)
    name = tostring(name or ""):match("^%s*(.-)%s*$")
    if name == "" then return nil, "empty name" end
    local file = Presets.filenameFor(name)
    local path = Presets.dir() .. "/" .. file
    local ok, err = pcall(function()
        local s = LuaSettings:open(path)
        s:saveSetting("name", name)
        s:saveSetting("layout", layout or Presets.current())
        s:flush()
    end)
    if not ok then
        logger.warn("[bookshelf] preset save failed: " .. tostring(err))
        return nil, tostring(err)
    end
    return file
end

-- read(file) -> { file, name, layout } or nil.
--
-- A file that does not parse, or parses to something without a layout, is
-- skipped rather than fatal: these are plain text files in a directory a user
-- can reach, and one bad edit must not take the menu down with it.
function Presets.read(file)
    local path = Presets.dir() .. "/" .. file
    local ok, s = pcall(LuaSettings.open, LuaSettings, path)
    if not ok or not s then return nil end
    local layout = s:readSetting("layout")
    if type(layout) ~= "table" then return nil end
    return {
        file   = file,
        name   = s:readSetting("name") or file:gsub("%.lua$", ""),
        layout = layout,
    }
end

-- list() -> array of { file, name, layout }, sorted by name.
function Presets.list()
    local out = {}
    local dir = Presets.dir()
    local ok = pcall(function()
        for f in lfs.dir(dir) do
            if f:match("%.lua$") then
                local entry = Presets.read(f)
                if entry then out[#out + 1] = entry end
            end
        end
    end)
    if not ok then return {} end
    table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
    return out
end

-- apply(layout) -> true.
--
-- Writes ALL four keys, always. A preset holds resolved values precisely so
-- this cannot half-apply and leave a line count from the previous layout
-- sitting under a font scale from this one.
function Presets.apply(layout)
    if type(layout) ~= "table" then return false end
    if type(layout.lines) == "table" then
        Lines.save{ lines = layout.lines }
    end
    if type(layout.show_cover) == "boolean" then
        Lines.save{ show_cover = layout.show_cover }
    end
    BookshelfSettings.save(Presets.KEY_COLUMNS,
        type(layout.columns) == "number" and layout.columns or 1)
    BookshelfSettings.save(Presets.KEY_FONT_SCALE,
        type(layout.font_scale) == "number" and layout.font_scale or 100)
    -- The action boundary: a user tapped a preset, and the next thing that
    -- happens may be the device suspending.
    BookshelfSettings.flush()
    return true
end

function Presets.delete(file)
    local path = Presets.dir() .. "/" .. file
    return os.remove(path) ~= nil
end

-- rename(file, name) -> new filename, or nil.
--
-- Writes the new file first and only then removes the old one: the reverse
-- loses the preset outright if the write fails.
function Presets.rename(file, name)
    local entry = Presets.read(file)
    if not entry then return nil end
    local new_file = Presets.save(name, entry.layout)
    if not new_file then return nil end
    if new_file ~= file then Presets.delete(file) end
    return new_file
end

return Presets
