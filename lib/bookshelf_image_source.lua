-- bookshelf_image_source.lua
-- Resolves and loads user-provided cover images for surfaces that don't
-- naturally have one (folders today; chip backgrounds tomorrow). Two
-- responsibilities:
--
--   1. Resolution. For a folder, pick the image to show: an explicit
--      override the user set via the long-press menu wins, otherwise
--      auto-detect cover.jpg / cover.png / folder.jpg / folder.png at
--      the folder root (Plex / Jellyfin convention). Returning nil
--      means "fall back to the default rendering".
--
--   2. Loading. Wrap RenderImage:renderImageFile with a small mtime-
--      keyed cache so a 100-folder shelf rebuild doesn't re-decode the
--      same JPEG 100 times. The bb itself is shared across paints (the
--      cache owns its lifetime; callers should pass image_disposable
--      = false to ImageWidget / cover_bb_disposable = false to
--      SpineWidget so they don't free it).
--
-- Storage shape:
--   Store.read("folder_images") -> { [absolute_folder_path] = image_path, ... }
-- The whole table is one settings key so we have one read per resolve;
-- on save we read-modify-write the table. For a typical user with a
-- handful of custom folder images this is bounded and cheaper than a
-- per-folder key proliferation.

local lfs        = require("libs/libkoreader-lfs")
local logger     = require("logger")
local Store      = require("lib/bookshelf_settings_store")
local RenderImage = require("ui/renderimage")

local ImageSource = {}

local AUTO_NAMES = { "cover.jpg", "cover.png", "folder.jpg", "folder.png" }

local IMAGE_EXTS = { jpg = true, jpeg = true, png = true, gif = true,
                     bmp = true, tiff = true, tif = true, webp = true }

-- For ImageLibrary auto-discovery (resolveStackImage). Order is
-- precedence: the first existing file wins, so jpg / jpeg / png cover
-- the dominant majority of user libraries first.
local LIBRARY_EXTS = { "jpg", "jpeg", "png", "gif", "bmp", "webp", "tiff", "tif" }

-- Per-kind subfolder names under the image library root. Plural because
-- the library reads like a content directory (authors/, series/, ...).
-- "collections" rather than "tags" so the image-library subfolder name
-- matches the user-facing UI label ("Set collection image…", "Manage
-- collections", the Collections chip) -- bookshelf's internal kind name
-- "tag" comes from KOReader's ReadCollection history; users only see
-- "collection".
local STACK_SUBDIRS = {
    author = "authors",
    series = "series",
    genre  = "genres",
    tag    = "collections",
}

-- Stack identity key used in the user-override table. Concatenating
-- kind + ":" + name keeps a single flat settings key while letting the
-- same string appear under different kinds (a tag "Sci-Fi" and a genre
-- "Sci-Fi" are distinct overrides).
local function _stackKey(kind, name)
    return tostring(kind) .. ":" .. tostring(name)
end

-- ASCII-slug fallback for image-library lookups. Lowercases and
-- collapses common separators (comma, period, semicolon, colon, slash,
-- backslash, whitespace, underscore) to a single dash; trims leading /
-- trailing dashes. "Asimov, Isaac" -> "asimov-isaac";
-- "Sci-Fi/Fantasy" -> "sci-fi-fantasy". Non-ASCII letters are
-- preserved so a Polish "Stanisław Lem" stays meaningful as
-- "stanisław-lem". Used only as a secondary lookup after the exact
-- match misses, so users who name files exactly still win.
local function _slug(s)
    if type(s) ~= "string" or s == "" then return "" end
    local out = s:lower()
    out = out:gsub("[,;:./%s_\\]+", "-")
    out = out:gsub("^%-+", ""):gsub("%-+$", "")
    return out
end

-- Predicate for file pickers: pass nothing other than common raster
-- image formats. SVG intentionally excluded: SpineWidget's
-- bb pipeline doesn't currently take the renderSVGImageFile path.
function ImageSource.isImageFile(path)
    if type(path) ~= "string" then return false end
    local ext = path:match("%.([^./]+)$")
    return ext and IMAGE_EXTS[ext:lower()] or false
end

local function _folderImagesTable()
    return Store.read("folder_images") or {}
end

-- Returns user override path (or nil) for `folder_path`.
function ImageSource.getFolderImageOverride(folder_path)
    if type(folder_path) ~= "string" then return nil end
    local t = _folderImagesTable()
    return t[folder_path]
end

-- Resolve the image to show for a folder. Returns the image filepath
-- or nil. User override beats auto-detection; auto-detect walks the
-- AUTO_NAMES list in order so the first match wins.
function ImageSource.resolveFolderImage(folder_path)
    if type(folder_path) ~= "string" or folder_path == "" then return nil end
    local override = ImageSource.getFolderImageOverride(folder_path)
    if override and lfs.attributes(override, "mode") == "file" then
        return override
    end
    -- Normalise: strip trailing slash so we don't end up with "//cover.jpg".
    local base = folder_path:gsub("/+$", "")
    for _, name in ipairs(AUTO_NAMES) do
        local candidate = base .. "/" .. name
        if lfs.attributes(candidate, "mode") == "file" then
            return candidate
        end
    end
    return nil
end

function ImageSource.setFolderImage(folder_path, image_path)
    if type(folder_path) ~= "string" or folder_path == "" then return end
    local t = _folderImagesTable()
    if image_path == nil or image_path == "" then
        t[folder_path] = nil
    else
        t[folder_path] = image_path
    end
    Store.save("folder_images", t)
end

function ImageSource.clearFolderImage(folder_path)
    ImageSource.setFolderImage(folder_path, nil)
end

-- ---------------------------------------------------------------------
-- Stack images (author / series / genre / tag)
-- ---------------------------------------------------------------------

-- Resolved root for image-library auto-discovery. User setting wins;
-- the default lives inside the user's KOReader home directory so it
-- ships with the library when they move devices.
function ImageSource.getImageLibraryPath()
    local override = Store.read("image_library_path")
    if type(override) == "string" and override ~= "" then return override end
    local home = G_reader_settings and G_reader_settings:readSetting("home_dir")
    if type(home) ~= "string" or home == "" then return nil end
    return home:gsub("/+$", "") .. "/.bookshelf-images"
end

function ImageSource.setImageLibraryPath(path)
    if type(path) ~= "string" or path == "" then
        Store.delete("image_library_path")
    else
        Store.save("image_library_path", path)
    end
end

-- Returns the expected library filename (without extension) for a
-- (kind, name) pair, so the menu's "Show expected filename" helper can
-- show users exactly what to name a file for auto-discovery to pick
-- it up. Returns nil for unsupported kinds.
function ImageSource.expectedLibraryStub(kind, name)
    local subdir = STACK_SUBDIRS[kind]
    if not subdir or type(name) ~= "string" or name == "" then return nil end
    local lib = ImageSource.getImageLibraryPath()
    if not lib then return nil end
    return lib:gsub("/+$", "") .. "/" .. subdir .. "/" .. name
end

local function _stackOverridesTable()
    return Store.read("stack_images") or {}
end

function ImageSource.getStackImageOverride(kind, name)
    if not STACK_SUBDIRS[kind] or type(name) ~= "string" or name == "" then
        return nil
    end
    local t = _stackOverridesTable()
    return t[_stackKey(kind, name)]
end

function ImageSource.setStackImage(kind, name, image_path)
    if not STACK_SUBDIRS[kind] or type(name) ~= "string" or name == "" then
        return
    end
    local t = _stackOverridesTable()
    if image_path == nil or image_path == "" then
        t[_stackKey(kind, name)] = nil
    else
        t[_stackKey(kind, name)] = image_path
    end
    Store.save("stack_images", t)
end

function ImageSource.clearStackImage(kind, name)
    ImageSource.setStackImage(kind, name, nil)
end

-- Auto-discovery: look for <library>/<kind>s/<name>.<ext>, trying
-- exact name first then the sanitised slug as a fallback. Returns the
-- first existing path, or nil. The exact-first ordering means users
-- who name files exactly always win; the slug fallback exists to
-- accommodate libraries built without comma / space sensitivity.
local function _autoDiscoverStackImage(kind, name)
    local subdir = STACK_SUBDIRS[kind]
    if not subdir then return nil end
    local lib = ImageSource.getImageLibraryPath()
    if not lib then return nil end
    local base = lib:gsub("/+$", "") .. "/" .. subdir .. "/"
    local candidates = { name }
    local slug = _slug(name)
    if slug ~= "" and slug ~= name then
        candidates[#candidates + 1] = slug
    end
    for _, stem in ipairs(candidates) do
        for _, ext in ipairs(LIBRARY_EXTS) do
            local p = base .. stem .. "." .. ext
            if lfs.attributes(p, "mode") == "file" then
                return p
            end
        end
    end
    return nil
end

-- Resolve the image to show for a stack. Same precedence as folders:
-- explicit user override wins, then image-library auto-discovery.
function ImageSource.resolveStackImage(kind, name)
    if not STACK_SUBDIRS[kind] or type(name) ~= "string" or name == "" then
        return nil
    end
    local override = ImageSource.getStackImageOverride(kind, name)
    if override and lfs.attributes(override, "mode") == "file" then
        return override
    end
    return _autoDiscoverStackImage(kind, name)
end

-- bb cache. Keyed by "path|mtime|w|h" so overwriting the file (mtime
-- bump) invalidates the entry, and different render sizes don't share
-- a bb (avoids upscale-from-cache pixel artefacts).
--
-- LRU eviction at MAX_ENTRIES. A shelf typically shows 8-16 slots; a
-- bounded cache of 64 covers full pagination without unbounded growth.
local _bb_cache  = {}
local _bb_order  = {}    -- queue of cache keys, oldest first
local MAX_ENTRIES = 64

local function _evictIfNeeded()
    while #_bb_order > MAX_ENTRIES do
        local oldest = table.remove(_bb_order, 1)
        local entry  = _bb_cache[oldest]
        if entry and entry.bb and entry.bb.free then
            pcall(function() entry.bb:free() end)
        end
        _bb_cache[oldest] = nil
    end
end

-- Load `image_path` and return a BlitBuffer scaled to (w, h). Returns
-- nil if the file is missing or RenderImage fails. The returned bb is
-- owned by the cache; callers must NOT free it directly (pass
-- image_disposable=false to ImageWidget, cover_bb_disposable=false to
-- SpineWidget).
function ImageSource.loadImage(image_path, w, h)
    if type(image_path) ~= "string" or not w or not h or w <= 0 or h <= 0 then
        return nil
    end
    local attr = lfs.attributes(image_path)
    if not attr or attr.mode ~= "file" then return nil end
    local key = image_path .. "|" .. tostring(attr.modification or 0)
                .. "|" .. tostring(w) .. "|" .. tostring(h)
    local hit = _bb_cache[key]
    if hit then
        return hit.bb
    end
    local ok, bb = pcall(function()
        return RenderImage:renderImageFile(image_path, false, w, h)
    end)
    if not ok or not bb then
        logger.warn("[bookshelf image] failed to render", image_path,
                    "err=", tostring(bb))
        return nil
    end
    _bb_cache[key] = { bb = bb }
    _bb_order[#_bb_order + 1] = key
    _evictIfNeeded()
    return bb
end

-- Drop everything. Called when a folder image is set / cleared so the
-- next paint reflects the change without waiting for mtime to differ.
function ImageSource.invalidateCache()
    for k, entry in pairs(_bb_cache) do
        if entry and entry.bb and entry.bb.free then
            pcall(function() entry.bb:free() end)
        end
        _bb_cache[k] = nil
    end
    _bb_order = {}
end

return ImageSource
