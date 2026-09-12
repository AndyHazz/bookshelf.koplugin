-- bookshelf_wallpaper.lua
-- A background image behind the whole screen, chosen PER SHELF.
--
-- ── WHY PER SHELF ───────────────────────────────────────────────────────────
--
-- Every UI plugin that has wallpaper has one wallpaper. Bookshelf's unit is
-- the shelf, not the screen: a chip already carries its own view mode, folder
-- tile style, densities and spine settings, so a chip carrying its own
-- backdrop is the same idea one step further, and it is the reason to do this
-- at all rather than copy what already exists elsewhere (maintainer's call).
-- Genres can be a library, Recent can be a desk, and neither has to agree.
--
-- Three states, using the convention already established by the per-book
-- facts store and the chip pins, so there is one rule and not three:
--
--     a string   this shelf shows that file
--     false      this shelf shows NOTHING, even if the library has a default
--     absent     this shelf follows the library default
--
-- ── WHERE THE FILES LIVE ────────────────────────────────────────────────────
--
-- <KOReader settings dir>/bookshelf/wallpapers/. Not icons/, where the
-- ornaments live: that folder was chosen because ornaments genuinely are the
-- small vector assets KOReader keeps there, and a full-screen photograph is
-- not. This mirrors where SimpleUI keeps its own
-- (settings/simpleui/sui_wallpapers), which is the convention a reader who
-- has used one is most likely to expect from the other.
--
-- ── WHAT THIS MODULE DOES NOT DO ────────────────────────────────────────────
--
-- It does not decide whether a wallpaper is legible, or paint a scrim, or
-- know anything about the widgets it sits behind. It answers "which file,
-- and give me a widget for it at this size", and the shelf does the rest.

local logger = require("logger")
local AssetFolder = require("lib/bookshelf_asset_folder")

local M = {}

-- Everything RenderImage can decode and a reader is likely to have. No SVG:
-- a wallpaper is a photograph or a texture, and nanosvg at full-screen size
-- is a very different cost from an ornament at 100px.
M.EXT_LIST = { "png", "jpg", "jpeg", "bmp", "gif", "webp" }
local EXTS = AssetFolder.extsFromList(M.EXT_LIST)

-- How much aspect-ratio distortion to accept before giving up on filling the
-- screen and best-fitting instead. KOReader's screensaver -- the same problem,
-- a full-screen image on the same panel -- defaults to 8, so this does too
-- rather than inventing a number. Below it, a nearly-right image is stretched
-- imperceptibly and fills; above it, a landscape photo on a portrait screen is
-- letterboxed rather than mangled.
M.STRETCH_LIMIT_PCT = 8

M.SUBDIR    = "bookshelf/wallpapers"
-- The per-chip key, stored on the tab beside view_mode and the densities.
M.CHIP_KEY  = "wallpaper"
-- The library default, in Bookshelf's own settings.
M.SETTING   = "wallpaper_default"

M._data_dir = nil          -- override for the data dir (tests)
M._lfs      = nil          -- lazily required
M._render   = nil          -- function(path, w, h) -> bb (tests)

local function lfs()
    if M._lfs then return M._lfs end
    local ok, l = pcall(require, "libs/libkoreader-lfs")
    if ok then M._lfs = l end
    return M._lfs
end

function M.dataDir()
    if M._data_dir then return M._data_dir end
    local ok, DataStorage = pcall(require, "datastorage")
    if ok and DataStorage then return DataStorage:getSettingsDir() end
    return nil
end

function M.dir()
    local base = M.dataDir()
    if not base then return nil end
    return base .. "/" .. M.SUBDIR
end

-- ensureDir() -- create the folder (and its parent) so a reader has somewhere
-- to put files. Cheap and idempotent; called before any scan.
M._ensured = false
function M.ensureDir()
    if M._ensured then return end
    local d, fs = M.dir(), lfs()
    if not (d and fs) then return end
    M._ensured = true
    local parent = d:match("^(.*)/[^/]+$")
    if parent and fs.attributes(parent, "mode") ~= "directory" then
        pcall(fs.mkdir, parent)
    end
    if fs.attributes(d, "mode") ~= "directory" then
        pcall(fs.mkdir, d)
    end
end

-- ── which file ─────────────────────────────────────────────────────────────

-- resolve(chip_value, default_value) -> name or nil
--
-- Pure: names only, no filesystem. pathFor turns a name into something to
-- open, and is where a file that has since been deleted drops out.
function M.resolve(chip_value, default_value)
    if chip_value == false then return nil end
    if type(chip_value) == "string" and chip_value ~= "" then
        return chip_value
    end
    if type(default_value) == "string" and default_value ~= "" then
        return default_value
    end
    return nil
end

-- pathFor(name) -> absolute path, or nil if there is no such wallpaper.
--
-- The folder is the whole namespace. A name carrying a separator is refused
-- rather than resolved, because these names come out of settings and a
-- settings file is something a reader can hand-edit -- the same reasoning
-- that produced the updater's traversal fix.
function M.pathFor(name)
    if type(name) ~= "string" or name == "" then return nil end
    if name:find("/", 1, true) or name:find("\\", 1, true) then return nil end
    if name == "." or name == ".." then return nil end
    local d, fs = M.dir(), lfs()
    if not (d and fs) then return nil end
    local path = d .. "/" .. name
    if fs.attributes(path, "mode") ~= "file" then return nil end
    return path
end

-- ── what is on offer ───────────────────────────────────────────────────────

-- list() -> { { name, label, path }, ... } sorted by name.
--
-- label is the filename without its extension: the picker shows a name, not
-- a filename. Cached on the folder's contents, not on its mtime alone -- see
-- lib/bookshelf_asset_folder.lua for the two ways that goes wrong.
M._list_cache = nil
M._list_key   = nil
function M.list()
    M.ensureDir()
    local d, fs = M.dir(), lfs()
    if not (d and fs) then return {} end
    local names, key = AssetFolder.scan(fs, d, EXTS)
    if not names then return {} end
    if M._list_cache and M._list_key == key then return M._list_cache end
    local out = {}
    for _i = 1, #names do
        local name = names[_i]
        out[#out + 1] = {
            name  = name,
            label = name:match("^(.+)%.[^%.]+$") or name,
            path  = d .. "/" .. name,
        }
    end
    M._list_cache, M._list_key = out, key
    return out
end

-- ── the widget ─────────────────────────────────────────────────────────────

-- ONE cached entry, deliberately. A full-screen bitmap is ~2MB as greyscale
-- and ~8MB as RGB32; holding a handful so that flipping between shelves never
-- re-decodes would cost more memory than this plugin has any business taking,
-- on devices where running out of it is a live bug (issue 388). One entry
-- means a shelf switch re-decodes, which is the trade to measure before
-- widening.
M._bg        = nil
M._bg_key    = nil

function M.free()
    if M._bg then
        pcall(function() if M._bg.free then M._bg:free() end end)
        M._bg = nil
    end
    M._bg_key = nil
end

-- bg(name, w, h, night) -> ImageWidget or nil
--
-- Scaled to fill w x h. night is part of the key because KOReader's
-- ImageWidget pre-inverts at paint time from Screen.night_mode, and a cache
-- built under one value must not be reused under the other.
function M.bg(name, w, h, night)
    local path = M.pathFor(name)
    if not path or not w or not h or w <= 0 or h <= 0 then return nil end
    local key = path .. "|" .. w .. "x" .. h .. (night and "|n" or "")
    if M._bg and M._bg_key == key then return M._bg end
    M.free()
    local ok, widget = pcall(function()
        if M._render then return M._render(path, w, h) end
        local ImageWidget = require("ui/widget/imagewidget")
        return ImageWidget:new{
            file          = path,
            width         = w,
            height        = h,
            -- scale_factor nil + a stretch limit is KOReader's own screensaver
            -- contract: stretch to fill when the aspect mismatch is small,
            -- best-fit when it is not. Neither mangles a photograph, and the
            -- common case -- an image cropped for this screen -- fills it.
            scale_factor  = nil,
            stretch_limit_percentage = M.STRETCH_LIMIT_PCT,
        }
    end)
    if not ok or not widget then
        logger.dbg("[bookshelf] wallpaper failed to load:", path)
        return nil
    end
    M._bg, M._bg_key = widget, key
    return widget
end

return M
