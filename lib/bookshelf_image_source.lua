-- bookshelf_image_source.lua
-- Resolves and loads user-provided cover images for surfaces that don't
-- naturally have one (folders today; chip backgrounds tomorrow). Two
-- responsibilities:
--
--   1. Resolution. For a folder, pick the image to show: an explicit
--      override the user set via the long-press menu wins, otherwise
--      auto-detect cover.* / folder.* (and hidden .cover.* / .folder.*)
--      at the folder root (Plex / Jellyfin convention). Returning nil
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

-- Visible names first (Plex / Jellyfin convention), then hidden dot-file
-- variants. Some users keep the cover out of the visible file listing as
-- ".cover.jpg" / ".folder.jpg". resolveFolderImage stats each directly (not
-- via a directory walk), so dot-files resolve fine; a visible cover.* /
-- folder.* still wins when both a visible and a hidden variant exist.
local AUTO_NAMES = {
    "cover.jpg", "cover.png", "folder.jpg", "folder.png",
    ".cover.jpg", ".cover.png", ".folder.jpg", ".folder.png",
}

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

-- Resolution memo: collapses the per-render stat storm. For a single
-- card, resolveFolderImage probes up to 9 paths and resolveStackImage up
-- to 17, and every shelf rebuild re-asks for the same visible folders /
-- stacks - on a typical library with NO custom images that's dozens of
-- guaranteed-miss stats per repaint. Results (misses stored as false,
-- since nil can't live in a Lua table) are memoized, and the whole memo
-- drops whenever the settings-store generation moves: override edits,
-- library-path changes and image set / clear all write settings, so they
-- self-invalidate. An externally dropped cover.jpg shows up after the
-- next settings write (nav-state saves bump the generation on most user
-- actions) or a restart.
local _resolve_memo = {}
local _resolve_gen  = -1
local function _memo()
    local gen = Store.generation and Store.generation() or -1
    if gen ~= _resolve_gen then
        _resolve_memo = {}
        _resolve_gen  = gen
    end
    return _resolve_memo
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
    local memo = _memo()
    local mkey = "folder\1" .. folder_path
    local hit = memo[mkey]
    if hit ~= nil then return hit or nil end
    local resolved
    local override = ImageSource.getFolderImageOverride(folder_path)
    if override and lfs.attributes(override, "mode") == "file" then
        resolved = override
    else
        -- Normalise: strip trailing slash so we don't end up with "//cover.jpg".
        local base = folder_path:gsub("/+$", "")
        for _i, name in ipairs(AUTO_NAMES) do
            local candidate = base .. "/" .. name
            if lfs.attributes(candidate, "mode") == "file" then
                resolved = candidate
                break
            end
        end
    end
    memo[mkey] = resolved or false
    return resolved
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

-- Re-key folder-image overrides when a folder moves: the moved folder
-- itself plus any descendant folder keys. Override image files stored
-- under the moved folder travelled with it on disk, so their paths get
-- the same prefix swap.
function ImageSource.rekeyFolderPaths(old_dir, new_dir)
    local FileOps = require("lib/bookshelf_file_ops")
    local t = _folderImagesTable()
    local out, changed = {}, false
    for folder, image in pairs(t) do
        local nf = FileOps.prefixSwap(FileOps.normDir(folder), old_dir, new_dir)
        local ni = type(image) == "string"
            and FileOps.prefixSwap(image, old_dir, new_dir) or nil
        if nf or ni then changed = true end
        out[nf or folder] = ni or image
    end
    if changed then Store.save("folder_images", out) end
    return changed
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
    -- Skip the per-name extension sweep entirely when the per-kind
    -- library subfolder doesn't exist (the typical user has no image
    -- library at all): one memoized directory stat replaces up to 16
    -- file stats for every stack on the shelf.
    local memo = _memo()
    local dkey = "dir\1" .. base
    local dir_ok = memo[dkey]
    if dir_ok == nil then
        dir_ok = lfs.attributes(base, "mode") == "directory"
        memo[dkey] = dir_ok
    end
    if not dir_ok then return nil end
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
    local memo = _memo()
    local mkey = "stack\1" .. _stackKey(kind, name)
    local hit = memo[mkey]
    if hit ~= nil then return hit or nil end
    local resolved
    local override = ImageSource.getStackImageOverride(kind, name)
    if override and lfs.attributes(override, "mode") == "file" then
        resolved = override
    else
        resolved = _autoDiscoverStackImage(kind, name)
    end
    memo[mkey] = resolved or false
    return resolved
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

-- Load at the image's native size, without scaling -- so the bb keeps its true
-- aspect ratio. loadImage() above resizes to an exact w*h (a stretch, not a
-- fit), which is fine when the target box already matches the cover's aspect
-- (the shelf card) but distorts when it doesn't. Callers that want the real
-- shape (the book-menu header thumbnail, the full-screen viewer) use this and
-- let ImageWidget/ImageViewer do the aspect-preserving fit.
function ImageSource.loadImageNative(image_path)
    if type(image_path) ~= "string" then return nil end
    local attr = lfs.attributes(image_path)
    if not attr or attr.mode ~= "file" then return nil end
    local key = image_path .. "|" .. tostring(attr.modification or 0) .. "|native"
    local hit = _bb_cache[key]
    if hit then
        return hit.bb
    end
    local ok, bb = pcall(function()
        return RenderImage:renderImageFile(image_path, false)
    end)
    if not ok or not bb then
        logger.warn("[bookshelf image] failed to render (native)", image_path,
                    "err=", tostring(bb))
        return nil
    end
    _bb_cache[key] = { bb = bb }
    _bb_order[#_bb_order + 1] = key
    _evictIfNeeded()
    return bb
end

-- imageSizeTag(path) -> "WxH" | nil. Intrinsic pixel dimensions read straight
-- from the PNG/JPEG header (no full decode), in the "WxH" form
-- SpineWidget.bookAspect consumes as cover_sizetag. Lets the true-aspect grid
-- size a REMOTE cover's box to its own shape -- OPDS records carry no BIM
-- cover_sizetag, so without this every downloaded thumbnail sizes to the 2:3
-- default and the shelf looks uniform even with true aspect on. Memoised by
-- path (a false sentinel records a known-unreadable file so we don't reparse).
local _size_tag_memo = {}
function ImageSource.imageSizeTag(path)
    if type(path) ~= "string" or path == "" then return nil end
    local memo = _size_tag_memo[path]
    if memo ~= nil then return memo or nil end
    local w, h
    local ok = pcall(function()
        local f = io.open(path, "rb")
        if not f then return end
        local head = f:read(32) or ""
        if head:sub(1, 8) == "\137PNG\r\n\26\n" and head:sub(13, 16) == "IHDR" then
            local function be32(s)
                local a, b, c, d = s:byte(1, 4)
                return ((a * 256 + b) * 256 + c) * 256 + d
            end
            w, h = be32(head:sub(17, 20)), be32(head:sub(21, 24))
        elseif head:byte(1) == 0xFF and head:byte(2) == 0xD8 then
            -- JPEG: step over segments to the first start-of-frame marker,
            -- which carries the dimensions (skip 0xC4/C8/CC, not frame types).
            f:seek("set", 2)
            while true do
                local m = f:read(2)
                if not m or #m < 2 or m:byte(1) ~= 0xFF then break end
                local marker = m:byte(2)
                local lenb = f:read(2)
                if not lenb or #lenb < 2 then break end
                local seglen = lenb:byte(1) * 256 + lenb:byte(2)
                if marker >= 0xC0 and marker <= 0xCF
                        and marker ~= 0xC4 and marker ~= 0xC8 and marker ~= 0xCC then
                    local sof = f:read(5)
                    if sof and #sof >= 5 then
                        h = sof:byte(2) * 256 + sof:byte(3)
                        w = sof:byte(4) * 256 + sof:byte(5)
                    end
                    break
                end
                f:seek("cur", seglen - 2)
            end
        end
        f:close()
    end)
    if ok and w and h and w > 0 and h > 0 then
        local tag = w .. "x" .. h
        _size_tag_memo[path] = tag
        return tag
    end
    _size_tag_memo[path] = false
    return nil
end

-- Drop everything. Called when a folder image is set / cleared so the
-- next paint reflects the change without waiting for mtime to differ.
-- Also drops the resolution memo so set / clear takes effect even on a
-- code path that didn't write settings (belt and braces: settings writes
-- already invalidate it via the generation check).
function ImageSource.invalidateCache()
    for k, entry in pairs(_bb_cache) do
        if entry and entry.bb and entry.bb.free then
            pcall(function() entry.bb:free() end)
        end
        _bb_cache[k] = nil
    end
    _bb_order = {}
    _resolve_memo = {}
    _resolve_gen  = -1
end

return ImageSource
