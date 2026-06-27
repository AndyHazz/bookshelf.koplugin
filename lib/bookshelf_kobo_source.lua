--[[
bookshelf_kobo_source.lua — defensive, read-only bridge to OGKevin's
kobo.koplugin "virtual library", so the native Kobo kepub collection can surface
as a Bookshelf shelf (issue: sort the Kobo virtual library).

This is the ONLY point of contact with the kobo plugin. The plugin's
virtual_library is an INTERNAL API (not published/stable), and the plugin only
exists on Kobo (supported_platforms = {"kobo"}), so EVERYTHING here is
feature-detected and pcall-guarded: on a non-Kobo, or if the plugin is absent /
inactive / its API has shifted, isAvailable() returns false and Bookshelf simply
shows no Kobo shelf. No DRM code lives here -- opening a virtual path is handled
by the plugin's own ReaderUI:showReader patch.

Reached via the active UI: (FileManager.instance or ReaderUI.instance).kobo_plugin
(the plugin is a WidgetContainer named "kobo_plugin", is_doc_only=false), which
holds .virtual_library.

NOTE: build-blind. No Kobo hardware available to the maintainer; verified by unit
tests here + a Kobo-owning reporter on a dev branch.
]]

local M = {}

-- Debug-level tracing of the detection / cover chain. Kobo is build-blind for
-- the maintainer (no device), so these are kept at logger.dbg: silent in normal
-- use, available when a tester runs with debug logging on. logger is lazy +
-- pcall-guarded so the headless unit test (no KOReader logger) is unaffected.
local function diag(...)
    local ok, logger = pcall(require, "logger")
    if ok and logger and logger.dbg then logger.dbg("[bookshelf][kobo]", ...) end
end

-- Locate the kobo plugin's virtual_library instance, or nil. Logs each step so a
-- reporter's crash.log shows exactly where the chain breaks (no UI / no
-- kobo_plugin / no virtual_library).
local function virtualLibrary()
    local ui, src
    local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
    if ok_fm and FileManager and FileManager.instance then ui = FileManager.instance; src = "FileManager" end
    if not ui then
        local ok_r, ReaderUI = pcall(require, "apps/reader/readerui")
        if ok_r and ReaderUI and ReaderUI.instance then ui = ReaderUI.instance; src = "ReaderUI" end
    end
    if not ui then
        diag("no active UI: FileManager.instance and ReaderUI.instance both nil")
        return nil
    end
    diag("active UI =", src)
    -- The kobo plugin's module name and its _meta name differ ("kobo_plugin"
    -- vs "kobo"); KOReader merges _meta over the module, so _meta.name wins as
    -- the registerModule key -- the plugin lives at ui.kobo, not ui.kobo_plugin
    -- (the original assumption, which #203 disproved). Don't hardcode either:
    -- a registered plugin is also stored in the ui's array part, so scan every
    -- value for one that exposes a virtual_library with the API we use. Robust
    -- to the plugin being renamed and to the _meta/module name split.
    local function exposesVL(m)
        return type(m) == "table"
            and type(m.virtual_library) == "table"
            and type(m.virtual_library.getBookEntries) == "function"
    end
    -- Fast paths first (known keys), then a full scan.
    local kp = exposesVL(ui.kobo_plugin) and ui.kobo_plugin
        or (exposesVL(ui.kobo) and ui.kobo) or nil
    if not kp then
        for k, mod in pairs(ui) do
            if exposesVL(mod) then
                kp = mod
                diag("kobo plugin found by scan under ui key:", tostring(k))
                break
            end
        end
    end
    if not kp then
        diag("no ui module exposes a virtual_library (checked ui.kobo_plugin/ui.kobo + full scan)"
            .. " -> kobo.koplugin not loaded/active in this context")
        return nil
    end
    diag("virtual_library located OK")
    return kp.virtual_library
end
-- Exposed for tests to inject a fake.
M._virtualLibrary = virtualLibrary

-- True only when the plugin is present, reports active, and exposes the methods
-- we use. Any miss -> false -> no Kobo shelf, zero impact elsewhere.
function M.isAvailable()
    local vl = M._virtualLibrary()
    if type(vl) ~= "table" then return false end
    -- Only getBookEntries is required: it's what lists the shelf. Covers are
    -- OPTIONAL and feature-detected per build in coverBB (getMetadataForPath on
    -- newer kobo.koplugin builds, getThumbnailPath on older ones), so the chip
    -- must NOT be gated on the cover method -- older installs have getBookEntries
    -- but not getMetadataForPath, and would otherwise lose the shelf entirely.
    if type(vl.getBookEntries) ~= "function" then
        diag("virtual_library has no getBookEntries -> cannot list the Kobo shelf")
        return false
    end
    local ok, active = pcall(function()
        return type(vl.isActive) ~= "function" or vl:isActive()
    end)
    if not (ok and active == true) then
        diag("virtual_library present but not active: pcall_ok=", tostring(ok),
             "isActive=", tostring(active))
        return false
    end
    diag("AVAILABLE -> Kobo chip should appear in the chip strip")
    return true
end

-- Kobo metadata carries no KOReader read-status, only ___PercentRead; derive a
-- Bookshelf status from it. (Kobo's own ReadStatus could refine this later via
-- the plugin's reading_state_sync; percent is enough for the PoC.)
local function statusFromPercent(pct)
    if not pct or pct <= 0 then return "unread" end
    if pct >= 100 then return "finished" end
    return "reading"
end

-- Map one kobo plugin entry -> a Bookshelf-shaped Book record. NO cover here
-- (covers are fetched lazily for the visible slice via M.coverBB). kobo_metadata
-- = { book_id, title, author, publisher, series, series_number, percent_read };
-- entry = { path (virtual), attr{size,modification}, kobo_book_id, kobo_metadata }.
local function toRecord(entry)
    local md = entry.kobo_metadata or {}
    local pct = tonumber(md.percent_read) or 0
    local author = (type(md.author) == "string" and md.author ~= "") and md.author or nil
    local series_name = (type(md.series) == "string" and md.series ~= "") and md.series or nil
    local mtime = (entry.attr and entry.attr.modification) or 0
    local title = (type(md.title) == "string" and md.title ~= "") and md.title
        or (entry.text or "Unknown")
    local status = statusFromPercent(pct)
    return {
        filepath       = entry.path,                 -- virtual path: open key + id
        filename       = entry.path and entry.path:match("([^/]+)$") or entry.text,
        title          = title,
        display_title  = title,
        author         = author,                     -- primary, for author sort
        authors        = author and { author } or nil,
        series_name    = series_name,
        series_num     = (series_name and md.series_number ~= nil)
                            and tostring(md.series_number) or nil,
        book_pct       = pct / 100,
        status         = status,
        read_status    = status,
        rating         = nil,                         -- Kobo DB has no KOReader rating
        added_time     = mtime,
        last_read_time = mtime,
        attr           = { mode = "file", size = (entry.attr and entry.attr.size) or 0,
                           modification = mtime },
        format         = "kepub",
        kobo_book_id   = entry.kobo_book_id,
        is_kobo        = true,    -- marker: virtual record (guard file-ops in the book menu)
    }
end
M._toRecord = toRecord

-- The Kobo library as Bookshelf Book records (no covers). {} on any failure.
function M.listBooks()
    local vl = M._virtualLibrary()
    if type(vl) ~= "table" or type(vl.getBookEntries) ~= "function" then return {} end
    local ok, entries = pcall(function() return vl:getBookEntries() end)
    if not ok or type(entries) ~= "table" then return {} end
    local out = {}
    for _i, e in ipairs(entries) do
        if type(e) == "table" and e.path then
            local ok_rec, rec = pcall(toRecord, e)
            if ok_rec and rec then out[#out + 1] = rec end
        end
    end
    return out
end

-- Lazy cover for ONE book: a fresh blitbuffer the caller OWNS (it's freed after
-- paint), nil when unavailable.
function M.coverBB(virtual_path)
    if not virtual_path then return nil end
    local vl = M._virtualLibrary()
    if type(vl) ~= "table" then return nil end
    -- Newer builds: getMetadataForPath(path, true) returns cover_bb. The plugin
    -- caches and returns the SAME bb each call, so hand back a :copy() -- the
    -- shelf's ImageWidget frees the bb after paint, which would otherwise blank
    -- the plugin's cached cover until a re-fetch (covers only showing once a book
    -- is selected, blank again after a chip switch -- #203).
    if type(vl.getMetadataForPath) == "function" then
        local ok, meta = pcall(function() return vl:getMetadataForPath(virtual_path, true) end)
        if ok and type(meta) == "table" and meta.cover_bb then
            local bb = meta.cover_bb
            if type(bb.copy) == "function" then
                local ok_c, copy = pcall(function() return bb:copy() end)
                if ok_c and copy then return copy, meta.cover_w, meta.cover_h end
            end
            return bb, meta.cover_w, meta.cover_h
        end
        -- DIAGNOSTIC (#203 covers): getMetadataForPath returned no cover_bb. For
        -- an undecrypted Kobo-store book the cover may not be extractable until
        -- the book has been opened once.
        diag("coverBB: getMetadataForPath gave no cover_bb (ok=", tostring(ok), ") for", tostring(virtual_path))
    end
    -- Older builds: getThumbnailPath(path) returns a PNG path; render it here into
    -- a fresh blitbuffer the caller owns (freed after paint, re-rendered each
    -- rebuild -- no shared/cached bb, so the BIM one-shot-free trap doesn't apply).
    if type(vl.getThumbnailPath) == "function" then
        local ok, path = pcall(function() return vl:getThumbnailPath(virtual_path) end)
        if ok and type(path) == "string" and path ~= "" then
            local ok_r, RenderImage = pcall(require, "ui/renderimage")
            if ok_r and RenderImage and RenderImage.renderImageFile then
                local ok_bb, bb = pcall(function() return RenderImage:renderImageFile(path, false) end)
                if ok_bb and type(bb) == "table" then
                    local w = bb.getWidth and bb:getWidth() or nil
                    local h = bb.getHeight and bb:getHeight() or nil
                    return bb, w, h
                end
            end
            diag("coverBB: getThumbnailPath render failed for", tostring(path))
        end
    end
    diag("coverBB: NIL (getMetadataForPath=", tostring(type(vl.getMetadataForPath) == "function"),
         " getThumbnailPath=", tostring(type(vl.getThumbnailPath) == "function"), ")")
    return nil
end

-- Resolve a virtual path to a REAL, openable file via the plugin's own API,
-- decrypting on demand. We can't just hand the KOBO_VIRTUAL:// path to
-- ReaderUI:showReader: the plugin's showReader patch matches a different path
-- scheme, so the virtual path falls through and silently fails to open (#203).
-- decryptIfNeeded returns an openable path (the real file for unencrypted books,
-- a cached decrypted copy for encrypted ones) or nil (DRM off / decrypt failed --
-- in which case the plugin has already shown the user why). Returns nil when the
-- resolve API isn't present, so the caller can fall back.
function M.realPathForOpen(virtual_path)
    if not virtual_path then return nil end
    local vl = M._virtualLibrary()
    if type(vl) ~= "table" then return nil end
    if type(vl.getBookId) == "function" and type(vl.decryptIfNeeded) == "function" then
        local ok_id, book_id = pcall(function() return vl:getBookId(virtual_path) end)
        if ok_id and book_id then
            local ok_d, real = pcall(function() return vl:decryptIfNeeded(book_id) end)
            if ok_d and type(real) == "string" and real ~= "" then return real end
            return nil  -- decrypt declined/failed; plugin surfaced the reason
        end
    end
    -- Fallback for builds without decryptIfNeeded: a plain (non-decrypting)
    -- resolve. Works for unencrypted books; encrypted ones just won't open.
    if type(vl.getRealPath) == "function" then
        local ok_r, real = pcall(function() return vl:getRealPath(virtual_path) end)
        if ok_r and type(real) == "string" and real ~= "" then return real end
    end
    return nil
end

-- True if this filepath is one of the plugin's virtual paths (used to guard the
-- book menu / file-ops, and to route opening). Falls back to the is_kobo marker.
function M.isKoboPath(filepath)
    if not filepath then return false end
    local vl = M._virtualLibrary()
    if type(vl) == "table" and type(vl.isVirtualPath) == "function" then
        local ok, res = pcall(function() return vl:isVirtualPath(filepath) end)
        if ok then return res == true end
    end
    return false
end

return M
