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

-- DIAGNOSTIC LOGGING (temporary, kobo-shelf dev branch). Greppable in
-- crash.log via "kobo-diag". logger is lazy + pcall-guarded so the headless
-- unit test (which has no KOReader logger) is unaffected. Remove before merge.
local function diag(...)
    -- warn (not info) so it lands in crash.log regardless of the device's log
    -- level - testers shouldn't have to enable verbose logging.
    local ok, logger = pcall(require, "logger")
    if ok and logger and logger.warn then logger.warn("[bookshelf][kobo-diag]", ...) end
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
    local kp = ui.kobo_plugin
    if not kp then
        diag("ui.kobo_plugin is NIL -> OGKevin kobo.koplugin not loaded/enabled in this context")
        return nil
    end
    local vl = kp.virtual_library
    if type(vl) ~= "table" then
        diag("kobo_plugin found but .virtual_library is", type(vl))
        return nil
    end
    diag("virtual_library located OK")
    return vl
end
-- Exposed for tests to inject a fake.
M._virtualLibrary = virtualLibrary

-- True only when the plugin is present, reports active, and exposes the methods
-- we use. Any miss -> false -> no Kobo shelf, zero impact elsewhere.
function M.isAvailable()
    local vl = M._virtualLibrary()
    if type(vl) ~= "table" then return false end
    local has_ge = type(vl.getBookEntries) == "function"
    local has_gm = type(vl.getMetadataForPath) == "function"
    if not (has_ge and has_gm) then
        diag("virtual_library missing methods: getBookEntries=", tostring(has_ge),
             "getMetadataForPath=", tostring(has_gm))
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

-- Lazy cover for ONE book: a fresh blitbuffer the caller owns (the plugin
-- returns a :copy(), so freeing it after paint is safe). nil when unavailable.
function M.coverBB(virtual_path)
    local vl = M._virtualLibrary()
    if type(vl) ~= "table" or type(vl.getMetadataForPath) ~= "function"
            or not virtual_path then
        return nil
    end
    local ok, meta = pcall(function() return vl:getMetadataForPath(virtual_path, true) end)
    if ok and type(meta) == "table" and meta.cover_bb then
        return meta.cover_bb, meta.cover_w, meta.cover_h
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
