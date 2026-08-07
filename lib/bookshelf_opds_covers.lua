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

function M.fetchMissing(records, on_done)
    local CoverFetch = require("lib/bookshelf_cover_fetch")
    local lfs = require("libs/libkoreader-lfs")
    local fetched = 0
    for _i, rec in ipairs(records or {}) do
        local path = M.cachePath(rec)
        if path then
            local ok_a, a = pcall(lfs.attributes, path)
            if not (ok_a and a) then
                local got = CoverFetch.download(rec.opds.thumbnail_url, path)
                if got then fetched = fetched + 1 end
            end
        end
    end
    if on_done then on_done(fetched) end
end

return M
