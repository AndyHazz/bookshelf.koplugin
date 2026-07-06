-- bookshelf_cover_apply.lua
-- The Cover picker's LOCAL half: enumerate the covers already stored for a
-- book, and commit a chosen image as the book's cover throughout KOReader.
-- No UI, no network -- callable from tests with the usual DocSettings stubs.
--
-- Commit model mirrors Hardcover.enableSidecarCover (bookshelf_hardcover.lua):
-- a chosen image is written into the book's .sdr sidecar as cover.<ext> via
-- DocSettings:flushCustomCover, so KOReader's file browser / history / Book
-- info all pick it up. Any pre-existing user cover is preserved once to
-- cover.orig.<ext> (basename "cover.orig", which findCustomCoverFile ignores)
-- and surfaced back as the "Previous cover" candidate. After a write we
-- broadcast InvalidateMetadataCache + BookMetadataChanged (same pair
-- Repo.setEmbeddedGenres uses) so KOReader's own caches refresh.
--
-- Render-cost gate: the shelf render already prefers book.cover_image_path
-- over the embedded cover, but resolving it needs a findCustomCoverFile disk
-- probe. To avoid paying that on every book on every shelf render for users
-- who never touch this feature, we persist a small filepath-keyed map
-- ("cover_choices") of only the books this feature has customised; the
-- repository consults the map first and only probes disk for entries in it.

local DataStorage = require("datastorage")
local lfs         = require("libs/libkoreader-lfs")
local logger      = require("logger")
local Store       = require("lib/bookshelf_settings_store")
local ImageSource = require("lib/bookshelf_image_source")
local T           = require("ffi/util").template
local _           = require("lib/bookshelf_i18n").gettext

local CoverApply = {}

local CHOICES_KEY = "cover_choices"

-- Downloaded / extracted cover working files live here (shared with
-- bookshelf_cover_fetch). Kept out of any .sdr so they're disposable cache.
local function _cacheDir()
    return DataStorage:getSettingsDir() .. "/bookshelf_covers"
end

local function _ensureDir(dir)
    if lfs.attributes(dir, "mode") == "directory" then return true end
    lfs.mkdir(dir)
    return lfs.attributes(dir, "mode") == "directory"
end

local function _safeKey(s)
    return tostring(s):gsub("[^%w_.-]", "_")
end

local function _choices()
    local t = Store.read(CHOICES_KEY)
    return type(t) == "table" and t or {}
end

-- Parse BIM's cover_sizetag ("1072x1448") into width, height -- the TRUE,
-- pre-thumbnail embedded resolution, so the Embedded candidate's caption
-- reflects the original cover, not a decoded proxy. (Same parser as
-- bookshelf_hardcover._parseSizetag.)
local function _parseSizetag(tag)
    if type(tag) ~= "string" then return nil end
    local w, h = tag:match("^(%d+)x(%d+)$")
    return tonumber(w), tonumber(h)
end

-- A pre-existing user cover is preserved as "<sdr>/cover.orig.<ext>" -- basename
-- "cover.orig" so KOReader's findCustomCoverFile skips it. (Same probe as
-- bookshelf_hardcover._findUserCoverBackup; duplicated deliberately so this
-- module has no hard dependency on the optional Hardcover integration.)
local function _findUserCoverBackup(dir)
    if not (dir and lfs.dir) then return nil end
    local ok_iter, iter, dir_obj = pcall(lfs.dir, dir)
    if not ok_iter then return nil end
    for f in iter, dir_obj do
        if f:match("^cover%.orig%.[^.]+$") then return dir .. "/" .. f end
    end
    return nil
end

local function _broadcast(filepath)
    local ok_ev, Event = pcall(require, "ui/event")
    local ok_um, UIManager = pcall(require, "ui/uimanager")
    if ok_ev and ok_um and Event and UIManager then
        UIManager:broadcastEvent(Event:new("InvalidateMetadataCache", filepath))
        UIManager:broadcastEvent(Event:new("BookMetadataChanged", { filepath = filepath }))
    end
end

-- Decode an image file just far enough to read its pixel dimensions. Reuses
-- ImageSource's mtime-keyed decode cache, so the grid's later render of the
-- same file is a cache hit (no double decode). Returns w, h or nil.
function CoverApply.imageDims(path)
    local bb = ImageSource.loadImageNative(path)
    if not bb then return nil end
    local w = bb.w or (bb.getWidth and bb:getWidth())
    local h = bb.h or (bb.getHeight and bb:getHeight())
    return w, h
end

function CoverApply.fileSize(path)
    return lfs.attributes(path, "size")
end

-- Extract the book's TRUE embedded cover to a disposable PNG so the grid can
-- render it like any other file candidate. The embedded cover has no file of
-- its own (it lives inside the document container), so we materialise one.
-- Cached by the book's mtime -- re-extracted only when the book file changes.
local function _extractEmbedded(book)
    if not book.has_cover then return nil end
    local fp = book.filepath
    local dir = _cacheDir()
    if not _ensureDir(dir) then return nil end
    local dest = dir .. "/emb_" .. _safeKey(fp) .. ".png"
    local dmod = lfs.attributes(dest, "modification")
    local bmod = lfs.attributes(fp, "modification")
    if dmod and bmod and dmod >= bmod then return dest end
    local ok_bi, BookInfo = pcall(require, "apps/filemanager/filemanagerbookinfo")
    if not ok_bi or not BookInfo then return nil end
    -- force_orig=true bypasses any active custom cover -> the native cover.
    local ok, bb = pcall(function() return BookInfo:getCoverImage(nil, fp, true) end)
    if not ok or not bb then return nil end
    local ok_w = pcall(function() bb:writePNG(dest) end)
    pcall(function() if bb.free then bb:free() end end)
    if not ok_w then
        logger.warn("[bookshelf cover] embedded cover extract failed for", fp)
        return nil
    end
    return dest
end

-- Drop candidates whose (width,height,filesize) triple already appeared, so the
-- same underlying image (e.g. an active sidecar cover that originally came from
-- Hardcover, still also present in the Hardcover cache) shows once. Earliest
-- occurrence wins -- ordering below puts the more meaningful label first. The
-- Embedded candidate carries filesize=nil so it never collides.
local function _dedup(list)
    local seen, out = {}, {}
    for _i, c in ipairs(list) do
        local key = (c.filesize == nil) and ("emb\1" .. tostring(c.kind))
            or table.concat({ c.width or "?", c.height or "?", c.filesize }, "\1")
        if not seen[key] then
            seen[key] = true
            out[#out + 1] = c
        end
    end
    return out
end

-- localCandidates(book) -> array<Candidate>
-- Order: Embedded, active custom cover, Previous-cover backup, Hardcover cache.
function CoverApply.localCandidates(book)
    local out = {}
    if type(book) ~= "table" or not book.filepath then return out end
    local fp = book.filepath
    local DocSettings = require("docsettings")
    local dir = DocSettings:getSidecarDir(fp)
    local active = DocSettings:findCustomCoverFile(fp)
    local choice = _choices()[fp]

    -- Embedded (native) cover. Tapping this reverts to it (removes the custom
    -- cover); the extracted PNG is only for display.
    local emb = _extractEmbedded(book)
    if emb then
        local sw, sh = _parseSizetag(book.cover_sizetag)
        local w, h = CoverApply.imageDims(emb)
        out[#out + 1] = {
            kind = "embedded", source_label = _("Embedded"),
            local_path = emb, width = sw or w, height = sh or h,
            filesize = nil, is_active = (active == nil),
        }
    end

    -- Active custom cover (what's showing now, if any).
    if active then
        local w, h = CoverApply.imageDims(active)
        local label = (type(choice) == "table" and choice.label)
            and T(_("Current cover — %1"), choice.label) or _("Custom cover")
        out[#out + 1] = {
            kind = "sidecar", source_label = label, local_path = active,
            width = w, height = h, filesize = CoverApply.fileSize(active),
            is_active = true,
        }
    end

    -- Previous cover the user had before this feature displaced it.
    local bak = _findUserCoverBackup(dir)
    if bak then
        local w, h = CoverApply.imageDims(bak)
        out[#out + 1] = {
            kind = "backup", source_label = _("Previous cover"), local_path = bak,
            width = w, height = h, filesize = CoverApply.fileSize(bak),
            is_active = false,
        }
    end

    -- Hardcover's downloaded cover, if the optional plugin is present and holds
    -- one for this book. Fully guarded so a missing Hardcover integration is a
    -- silent no-op.
    local ok_hc, Hardcover = pcall(require, "lib/bookshelf_hardcover")
    if ok_hc and Hardcover and Hardcover.isAvailable and Hardcover.isAvailable() then
        local link = Hardcover.getLink and Hardcover.getLink(fp)
        if link and link.book_id and Hardcover.getCachedEnrichment then
            local enr = Hardcover.getCachedEnrichment(link.book_id, link.edition_id)
            local src = type(enr) == "table" and enr.cover_path or nil
            if type(src) == "string" and src ~= ""
                    and lfs.attributes(src, "mode") == "file" then
                local w, h = CoverApply.imageDims(src)
                out[#out + 1] = {
                    kind = "hardcover_cache", source_label = _("Hardcover"),
                    local_path = src,
                    width = w or tonumber(enr.cover_width),
                    height = h or tonumber(enr.cover_height),
                    filesize = CoverApply.fileSize(src), is_active = false,
                }
            end
        end
    end

    return _dedup(out)
end

-- apply(filepath, image_path, opts) -> ok, err
-- Write image_path into the book's sidecar as its cover, preserving any prior
-- user cover once. opts.label is a short source name recorded for the caption
-- and as the render-cost gate entry.
function CoverApply.apply(filepath, image_path, opts)
    opts = opts or {}
    if not filepath then return false, "no filepath" end
    if type(image_path) ~= "string" or lfs.attributes(image_path, "mode") ~= "file" then
        return false, "cover image not found"
    end
    local DocSettings = require("docsettings")
    local dir = DocSettings:getSidecarDir(filepath)
    local active = DocSettings:findCustomCoverFile(filepath)
    if active and dir and not _findUserCoverBackup(dir) then
        local ext = active:match("%.([^.]+)$") or "jpg"
        pcall(os.rename, active, dir .. "/cover.orig." .. ext)
    elseif active then
        -- Backup slot already taken, so the active cover wasn't renamed away.
        -- Remove it before flushing: flushCustomCover writes cover.<new-ext>
        -- WITHOUT clearing an existing cover.<old-ext>, and with two cover.*
        -- files findCustomCoverFile returns whichever the dir iterator hits
        -- first -- applying a .png over a .jpg would be nondeterministic.
        pcall(os.remove, active)
    end
    local ok_flush = pcall(function() DocSettings:flushCustomCover(filepath, image_path) end)
    if not ok_flush then return false, "could not write cover" end
    pcall(function() DocSettings:getCustomCoverFile(true) end)

    local choices = _choices()
    choices[filepath] = { label = opts.label }
    Store.save(CHOICES_KEY, choices)
    _broadcast(filepath)
    return true
end

-- revertToEmbedded(filepath) -> ok, err
-- Remove the active custom cover so the book shows its native embedded cover.
-- The Previous-cover backup (if any) is left in place -- restoring THAT is a
-- separate action (tap the "Previous cover" candidate).
function CoverApply.revertToEmbedded(filepath)
    if not filepath then return false, "no filepath" end
    local DocSettings = require("docsettings")
    -- Sweep until none left: a sidecar can hold more than one cover.* (e.g.
    -- cover.jpg + cover.png from a historic cross-extension apply), and
    -- findCustomCoverFile returns only one per call.
    local active = DocSettings:findCustomCoverFile(filepath)
    while active do
        pcall(os.remove, active)
        local nxt = DocSettings:findCustomCoverFile(filepath)
        if nxt == active then break end  -- unremovable; don't spin
        active = nxt
    end
    pcall(function() DocSettings:getCustomCoverFile(true) end)

    local choices = _choices()
    if choices[filepath] then
        choices[filepath] = nil
        Store.save(CHOICES_KEY, choices)
    end
    _broadcast(filepath)
    return true
end

-- For the repository's render-cost gate: is this book customised by us?
function CoverApply.isCustomized(filepath)
    return _choices()[filepath] ~= nil
end

CoverApply.cacheDir = _cacheDir
CoverApply.ensureDir = _ensureDir
CoverApply.safeKey = _safeKey

return CoverApply
