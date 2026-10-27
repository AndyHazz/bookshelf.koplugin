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
    return require("lib/bookshelf_paths").cacheFile("covers")
end

-- Shared recursive, pcall-hardened helper (lib/bookshelf_fs); the flat copy
-- this replaces failed on any target whose parent didn't exist yet.
local function _ensureDir(dir)
    return require("lib/bookshelf_fs").ensureDir(dir)
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

-- The book's TRUE embedded cover, decoded and scaled down to thumbnail size,
-- for the grid to show: bb, original width, original height (or nil). Kept in
-- memory, not written out: it lives as long as the modal (whose close empties
-- the cache folder anyway), and writing it as a full-size PNG cost 2 s on a
-- desktop for a 1400 x 2100 cover against 0.2 s to read it.
CoverApply.EMBEDDED_THUMB_H = 824
local function _extractEmbedded(book)
    if not book.has_cover then return nil end
    local fp = book.filepath
    local ok_bi, BookInfo = pcall(require, "apps/filemanager/filemanagerbookinfo")
    if not ok_bi or not BookInfo then return nil end
    -- force_orig=true bypasses any active custom cover -> the native cover.
    local ok, bb = pcall(function() return BookInfo:getCoverImage(nil, fp, true) end)
    if not ok or not bb then return nil end
    local w, h = bb:getWidth(), bb:getHeight()
    local s = math.min(1, CoverApply.EMBEDDED_THUMB_H / math.max(1, h))
    if s < 1 then
        local ok_s, small = pcall(function()
            return require("ui/renderimage"):scaleBlitBuffer(bb,
                math.max(1, math.floor(w * s + 0.5)), math.max(1, math.floor(h * s + 0.5)), true)
        end)
        if not ok_s or not small then
            logger.warn("[bookshelf cover] embedded cover scale failed for", fp)
            return nil
        end
        bb = small
    end
    return bb, w, h
end

-- The cover the shelf already holds for the book (the cover browser's stored
-- thumbnail), owned by the caller: a few ms against opening the document to
-- read its cover, which took 1-3 s on a PW5. Only right when that thumbnail
-- IS the embedded cover -- no custom cover, no external cover image -- and
-- only used when the full cover's size is known (cover_sizetag) for the
-- caption.
local function _shelfThumb(book)
    if book.cover_image_path then return nil end
    local ok, Repo = pcall(require, "lib/bookshelf_book_repository")
    if not (ok and Repo and Repo.getCoverBB) then return nil end
    local ok_b, bb = pcall(Repo.getCoverBB, book.filepath)
    return ok_b and bb or nil
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
    -- cover); the decoded image is only for display.
    local _gettime = require("lib/bookshelf_gettime")
    local t0 = _gettime()
    local sw, sh = _parseSizetag(book.cover_sizetag)
    local emb, ew, eh
    if book.has_cover and not active and sw and sh then emb = _shelfThumb(book) end
    local from_shelf = emb ~= nil
    if not emb then emb, ew, eh = _extractEmbedded(book) end
    logger.dbg(string.format("[bookshelf perf] Cover tab: embedded cover %.0fms (%s)",
        (_gettime() - t0) * 1000, from_shelf and "shelf thumbnail" or "from the book"))
    if emb then
        out[#out + 1] = {
            kind = "embedded", source_label = _("Embedded"),
            image = emb, width = sw or ew, height = sh or eh,
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

-- Recursively empty the cover working dir (settings/bookshelf_covers), with
-- one exemption (KEEP_SUBDIRS below).
--
-- The Cover tab's own material under here is transient: the online/ search
-- downloads and, from older builds, emb_*.png embedded-cover extractions and
-- per-book download subdirs. An APPLIED cover is copied into the
-- book's .sdr and Hardcover enrichment covers live in a separate
-- bookshelf_hardcover dir, so none of that is worth keeping. Never cleaned up
-- before, so it grew unbounded (issue 267). Called on book-detail modal close.
--
-- It is NOT all transient any more, though: the OPDS feed cover cache lives at
-- bookshelf_covers/opds (lib/bookshelf_opds_covers.lua's cacheDir), and it is
-- a real cache with a real refill cost -- full-size catalog images, re-fetched
-- over the network the next time the user opens that catalog. Closing a local
-- book's detail modal has no business emptying it, so opds/ is skipped here
-- and bounded by its own byte cap instead (OpdsCovers.sweepCache).
local KEEP_SUBDIRS = { opds = true }

function CoverApply.resetWorkingCache()
    local dir = _cacheDir()
    if lfs.attributes(dir, "mode") ~= "directory" then return end
    local function _rmrf(path)
        -- symlinkattributes: a link is removed, never followed into what it
        -- points at.
        local mode = (lfs.symlinkattributes or lfs.attributes)(path, "mode")
        if mode == "directory" then
            local ok_iter, iter, dobj = pcall(lfs.dir, path)
            if ok_iter then
                for f in iter, dobj do
                    if f ~= "." and f ~= ".." then _rmrf(path .. "/" .. f) end
                end
            end
            pcall(lfs.rmdir, path)
        else
            pcall(os.remove, path)
        end
    end
    local ok_iter, iter, dobj = pcall(lfs.dir, dir)
    if not ok_iter then return end
    for f in iter, dobj do
        if f ~= "." and f ~= ".." and not KEEP_SUBDIRS[f] then
            _rmrf(dir .. "/" .. f)
        end
    end
end

CoverApply.cacheDir = _cacheDir
CoverApply.ensureDir = _ensureDir
CoverApply.safeKey = _safeKey

return CoverApply
