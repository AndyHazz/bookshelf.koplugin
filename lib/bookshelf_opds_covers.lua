-- lib/bookshelf_opds_covers.lua
-- Disk cache for OPDS feed thumbnails, keyed by server + thumbnail URL hash.
-- Fetching is a plain blocking loop (CoverFetch.download per URL) run by the
-- widget inside Trapper; rendering returns a FRESH bb per call (the grid cell
-- frees its cover bb after paint - never hand out a shared one, see the BIM
-- one-shot trap).
local M = {}

function M.cacheDir()
    local DataStorage = require("datastorage")
    return DataStorage:getSettingsDir() .. "/bookshelf_covers/opds"
end

function M.cachePath(rec)
    local o = rec and rec.opds
    if not (o and o.thumbnail_url) then return nil end
    local OpdsSource = require("lib/bookshelf_opds_source")
    local server = rec.filepath:match("^OPDS://([^/]+)/") or "unknown"
    return M.cacheDir() .. "/" .. server .. "/"
        .. OpdsSource.serverKey(o.thumbnail_url) .. ".img"
end

function M.cachedCoverBB(rec)
    local path = M.cachePath(rec)
    if not path then return nil end
    local lfs = require("libs/libkoreader-lfs")
    local ok_a, a = pcall(lfs.attributes, path)
    if not (ok_a and a and a.mode == "file") then return nil end
    local ok_r, RenderImage = pcall(require, "ui/renderimage")
    if not (ok_r and RenderImage) then return nil end
    local ok_bb, bb = pcall(function() return RenderImage:renderImageFile(path, false) end)
    if not (ok_bb and bb) then return nil end
    return bb, bb.getWidth and bb:getWidth() or nil, bb.getHeight and bb:getHeight() or nil
end

-- Credentials for the server a record came from, resolved from its own
-- OPDS://<server_key>/ path. A password-protected catalogue (Calibre-Web et al)
-- 401s an anonymous thumbnail GET, so without these the covers never appear at
-- all. Memoised per pass: OpdsSource.servers() re-reads and re-parses the stock
-- plugin's opds.lua on every call, and a page is typically all one server.
-- Unknown key (server deleted, filepath not ours) -> download anonymously
-- rather than error; that is exactly the pre-existing behaviour.
local NO_CREDS = {}
local function credentialsFor(rec, cache)
    local key = type(rec.filepath) == "string"
        and rec.filepath:match("^OPDS://([^/]+)/") or nil
    if not key then return nil, nil end
    local hit = cache[key]
    if not hit then
        hit = NO_CREDS
        local ok_s, OpdsSource = pcall(require, "lib/bookshelf_opds_source")
        if ok_s and type(OpdsSource) == "table" then
            local ok_g, server = pcall(OpdsSource.getServer, key)
            if ok_g and type(server) == "table" then
                hit = { user = server.username, password = server.password }
            end
        end
        cache[key] = hit
    end
    return hit.user, hit.password
end

-- How long a thumbnail pass may hold the main loop. This runs serially and
-- uncancellably off a scheduleIn, so the defaults matter: CoverFetch's
-- socketutil LARGE pair is 10s block / 30s total, which for a full page of
-- slots against a server that accepts the connection but never answers is
-- minutes of frozen shelf after an ordinary page turn. Two bounds instead:
-- a tight per-request timeout (a thumbnail is tens of KB - anything slower
-- than this is not going to arrive usefully), and a whole-batch deadline so
-- the freeze is bounded no matter how many covers are missing. Whatever the
-- budget cuts off is simply retried by the next render of the same page,
-- and the on-disk cache means each pass starts where the last one stopped.
M.THUMB_BLOCK_TIMEOUT = 5
M.THUMB_TOTAL_TIMEOUT = 10
M.BATCH_BUDGET        = 20

function M.fetchMissing(records, on_done)
    local CoverFetch = require("lib/bookshelf_cover_fetch")
    local lfs = require("libs/libkoreader-lfs")
    local fetched = 0
    local creds = {}
    local deadline = os.time() + M.BATCH_BUDGET
    local net_opts = { block_timeout = M.THUMB_BLOCK_TIMEOUT,
                       total_timeout = M.THUMB_TOTAL_TIMEOUT }
    for _i, rec in ipairs(records or {}) do
        local path = M.cachePath(rec)
        if path then
            local ok_a, a = pcall(lfs.attributes, path)
            if not (ok_a and a) then
                if os.time() >= deadline then break end
                local user, password = credentialsFor(rec, creds)
                local got = CoverFetch.download(rec.opds.thumbnail_url, path,
                                                user, password, net_opts)
                if got then fetched = fetched + 1 end
            end
        end
    end
    if on_done then on_done(fetched) end
end

return M
