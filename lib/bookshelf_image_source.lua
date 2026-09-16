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
-- Bounded by a BYTE budget, with MAX_ENTRIES kept as a count backstop. A
-- shelf typically shows 8-16 slots, so 64 entries covers full pagination --
-- but loadImageNative (custom covers, external covers, cover-apply, cover-
-- grid cells) loads at native size, and a native-size photo can run several
-- MB. 64 of those could hold well over 100 MB resident, which is why entry
-- count alone isn't a real bound; see BB_BYTE_BUDGET below.
local _bb_cache  = {}
local _bb_order  = {}    -- queue of cache keys, oldest first
local _bb_sizes  = {}    -- key -> bytes, so evict/overwrite adjust _bb_bytes O(1)
local _bb_bytes  = 0     -- running sum of resident entry bytes
local MAX_ENTRIES = 64

-- 8 MiB. Exported so callers/tests can read (and, in principle, tune) the
-- bound; see bookshelf_scaled_cover_cache's own _byte_budget for the sibling
-- cache this mirrors.
ImageSource.BB_BYTE_BUDGET = 8 * 1024 * 1024

-- Resident byte size of a decoded bb -- the same measure
-- bookshelf_scaled_cover_cache's _bbBytes uses, copied locally rather than
-- required so the two caches stay decoupled: `stride * height` is the true
-- C allocation size (bytes-per-row including row padding) when the bb
-- declares a stride, else width * height * ceil(bpp / 8). All under pcall;
-- 0 on failure so a malformed bb never breaks accounting.
local function _bbBytes(bb)
    if not bb then return 0 end
    local ok, n = pcall(function()
        local h = (bb.getHeight and bb:getHeight()) or tonumber(bb.h) or 0
        local stride = tonumber(bb.stride)
        if stride and h > 0 then return stride * h end
        local w   = (bb.getWidth and bb:getWidth()) or 0
        local bpp = (bb.getBpp and bb:getBpp()) or 8
        return w * h * math.ceil(bpp / 8)
    end)
    return (ok and n) or 0
end

-- Eviction DROPS THE REFERENCE AND DOES NOT FREE. Callers pass the bb to
-- ImageWidget with image_disposable=false, on the understanding that the cache
-- owns its lifetime -- but this cache has no idea how many live widgets are
-- still pointing at an entry when it falls off the end of the LRU. Freeing it
-- yanked the C memory out from under them, and the next partial repaint drew
-- whatever had since been allocated in its place: a hero cover painted from
-- fragments of half a dozen OPDS thumbnails, seen while paging an Internet
-- Archive catalog.
--
-- Latent until covers started loading automatically. A 64-entry cache holding
-- only tap-fetched covers rarely evicted anything; a catalog page fetching ten
-- covers at a time, with the next page prefetched behind it, turns it over
-- constantly - and a local book's own external cover (a Hardcover or custom
-- image) sits in the same cache, which is how a LOCAL hero ended up painted
-- with REMOTE pixels.
--
-- Blitbuffer installs an ffi.gc finalizer at allocate time (setAllocated(1) in
-- ffi/blitbuffer.lua), so dropping the last reference reclaims the C memory on
-- its own. Slight reclaim latency, no use-after-free. This is the policy
-- bookshelf_scaled_cover_cache already documents and follows; the two caches
-- hand bbs to the same widgets and must agree about who may free them.
--
-- The bound checked below is bytes first, count second: MAX_ENTRIES only
-- still matters once the byte budget already binds, as a backstop against a
-- pathological many-tiny-images case.
local function _evictIfNeeded()
    while #_bb_order > 1
          and (#_bb_order > MAX_ENTRIES or _bb_bytes > ImageSource.BB_BYTE_BUDGET) do
        local oldest = table.remove(_bb_order, 1)
        _bb_cache[oldest] = nil
        _bb_bytes = _bb_bytes - (_bb_sizes[oldest] or 0)
        if _bb_bytes < 0 then _bb_bytes = 0 end
        _bb_sizes[oldest] = nil
    end
end

-- Shared insert path for loadImage/loadImageNative: keeps _bb_cache,
-- _bb_order, _bb_sizes and _bb_bytes consistent in one place, including the
-- overwrite case (the same key inserted twice) -- subtract the old size
-- before adding the new one, and don't duplicate the key in _bb_order.
-- Neither loader's cache-hit check can actually reach the overwrite branch
-- in practice (a hit on the same key returns early before ever re-
-- rendering), so this is exposed as ImageSource._bbCachePut for tests to
-- exercise it directly; see the test-seam block near invalidateCache.
local function _bbPut(key, bb)
    if _bb_cache[key] then
        _bb_bytes = _bb_bytes - (_bb_sizes[key] or 0)
        if _bb_bytes < 0 then _bb_bytes = 0 end
    else
        _bb_order[#_bb_order + 1] = key
    end
    _bb_cache[key] = { bb = bb }
    local size = _bbBytes(bb)
    _bb_sizes[key] = size
    _bb_bytes = _bb_bytes + size
    _evictIfNeeded()
end

-- ── how big is this file, without decoding it ───────────────────────────────
--
-- Both container formats we meet declare their pixel dimensions in a header
-- near the front of the file, so the size can be read from the first few
-- hundred bytes instead of from a decoded bitmap. Worth having because the
-- alternatives are both expensive in the wrong way: decoding to find out
-- costs the decode we were trying to decide about, and guessing costs an
-- upscale through MuPDF, which is the direction that corrupts on Kindle.
--
--   PNG  -- an 8-byte signature, then the IHDR chunk: 4-byte length, the tag,
--           then width and height as big-endian 32-bit integers.
--   JPEG -- SOI, then a chain of segments, each a 0xFF marker byte and a
--           2-byte length. The frame header (SOF) carries height then width
--           as big-endian 16-bit integers after a one-byte sample precision.
--           Every SOF marker in C0..CF is a frame header EXCEPT C4, C8 and CC,
--           which are the Huffman table, an extension and the arithmetic
--           coding table -- they are ordinary segments and must be skipped, or
--           the first quantisation table in the file reads as a picture size.
--
-- Returns nil for anything else, for a truncated header, and for a JPEG whose
-- frame header sits past the window we read (a huge EXIF thumbnail can do
-- that). nil means "ask the decoder", which is what the callers did before.
local PROBE_BYTES   = 64 * 1024
local PNG_SIGNATURE = "\137PNG\r\n\26\n"

local function _u16(s, at)
    local hi, lo = s:byte(at, at + 1)
    if not (hi and lo) then return nil end
    return hi * 256 + lo
end

local function _u32(s, at)
    local a, b, c, d = s:byte(at, at + 3)
    if not (a and b and c and d) then return nil end
    return ((a * 256 + b) * 256 + c) * 256 + d
end

local function _pngSize(head)
    if head:sub(1, 8) ~= PNG_SIGNATURE then return nil end
    if head:sub(13, 16) ~= "IHDR" then return nil end
    return _u32(head, 17), _u32(head, 21)
end

local function _jpegSize(head)
    if head:sub(1, 2) ~= "\255\216" then return nil end   -- SOI
    local at = 3
    while at + 3 <= #head do
        -- Markers may be preceded by any number of fill bytes.
        if head:byte(at) ~= 0xFF then return nil end
        while head:byte(at) == 0xFF do at = at + 1 end
        local marker = head:byte(at)
        at = at + 1
        if not marker then return nil end
        -- Standalone markers carry no length: the restart set, SOI/EOI, TEM.
        if (marker >= 0xD0 and marker <= 0xD9) or marker == 0x01 then
            -- nothing to skip
        else
            local seg_len = _u16(head, at)
            if not seg_len or seg_len < 2 then return nil end
            if marker >= 0xC0 and marker <= 0xCF
                    and marker ~= 0xC4 and marker ~= 0xC8 and marker ~= 0xCC then
                -- length(2) + precision(1), then height then width.
                local h = _u16(head, at + 3)
                local w = _u16(head, at + 5)
                if w and h and w > 0 and h > 0 then return w, h end
                return nil
            end
            at = at + seg_len
        end
    end
    return nil
end

-- Memoised on (path, mtime): the shelf asks about the same cover on every
-- render, and the answer only changes when the file does.
local _size_memo = {}
local _size_memo_n = 0
local SIZE_MEMO_MAX = 256

-- probeSize(image_path) -> w, h  (nil when it cannot be read from the header)
function ImageSource.probeSize(image_path)
    if type(image_path) ~= "string" or image_path == "" then return nil end
    local attr = lfs.attributes(image_path)
    if not attr or attr.mode ~= "file" then return nil end
    local key = image_path .. "|" .. tostring(attr.modification or 0)
    local hit = _size_memo[key]
    if hit then return hit[1], hit[2] end
    local f = io.open(image_path, "rb")
    if not f then return nil end
    local head = f:read(PROBE_BYTES)
    f:close()
    if type(head) ~= "string" or #head < 24 then return nil end
    local w, h = _pngSize(head)
    if not w then w, h = _jpegSize(head) end
    if not (w and h and w > 0 and h > 0) then return nil end
    if _size_memo_n >= SIZE_MEMO_MAX then _size_memo, _size_memo_n = {}, 0 end
    _size_memo[key] = { w, h }
    _size_memo_n = _size_memo_n + 1
    return w, h
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
    _bbPut(key, bb)
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
    _bbPut(key, bb)
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
-- Drops references only, for the reason _evictIfNeeded does: this runs while
-- the shelf is on screen (setting a folder image repaints it), so the widgets
-- currently painting are exactly the ones holding these bbs.
function ImageSource.invalidateCache()
    for k in pairs(_bb_cache) do
        _bb_cache[k] = nil
    end
    _bb_order = {}
    _bb_sizes = {}
    _bb_bytes = 0
    _resolve_memo = {}
    _resolve_gen  = -1
end

-- Test seams (not used by production code, bar _bbCachePut -- see the note
-- above _bbPut): _bbCacheStats() reports current occupancy for tests and
-- diagnostics; _bbCacheReset() empties the bb cache between test cases.
function ImageSource._bbCacheStats()
    return { n = #_bb_order, bytes = _bb_bytes, budget = ImageSource.BB_BYTE_BUDGET,
             max_entries = MAX_ENTRIES }
end

function ImageSource._bbCacheReset()
    _bb_cache = {}
    _bb_order = {}
    _bb_sizes = {}
    _bb_bytes = 0
end

ImageSource._bbCachePut = _bbPut

return ImageSource
