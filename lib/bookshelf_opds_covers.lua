-- lib/bookshelf_opds_covers.lua
-- Disk cache for OPDS feed cover images, keyed by server + selected-URL hash.
-- A feed entry may carry both a full-size image link and a thumbnail link;
-- coverUrl below prefers the full-size image (thumbnails are typically only
-- ~100px, visibly soft on a high-DPI e-reader screen) and falls back to the
-- thumbnail when no image link is present. Fetching is a plain blocking loop
-- (CoverFetch.download per URL) run by the widget inside Trapper. Rendering
-- is NOT this module's job: a cached cover is exposed only as a PATH
-- (cachedPath below), which the repo attaches as book.cover_image_path --
-- the same external-cover mechanism Hardcover uses, rendered by SpineWidget
-- via ImageSource.loadImage (a cache-owned bb, never freed). This module
-- used to also hand back a decoded BlitBuffer (cachedCoverBB); that bb was
-- one-shot per the BIM convention, but the same OPDS record is painted
-- twice (grid cell + hero preview) and repainted on later network events, so
-- whichever widget painted first freed the bb out from under the other --
-- corruption on a real device. Removed rather than fixed: a one-shot-bb
-- factory sitting here just invites the same mistake again.
local M = {}

-- coverUrl(rec) -> url | nil
-- The URL this module fetches and caches for rec: the feed's full-size image
-- link when present, else its thumbnail link. Both cachePath and
-- fetchMissing (and the credentials gate) must agree on this choice --
-- hashing or downloading a different URL than the one the gate checked would
-- reintroduce the cross-host credential leak that gate exists to prevent.
local function coverUrl(rec)
    local o = rec and rec.opds
    return o and (o.image_url or o.thumbnail_url)
end

function M.cacheDir()
    local DataStorage = require("datastorage")
    return DataStorage:getSettingsDir() .. "/bookshelf_covers/opds"
end

function M.cachePath(rec)
    local url = coverUrl(rec)
    if not url then return nil end
    if type(rec.filepath) ~= "string" then return nil end
    local OpdsSource = require("lib/bookshelf_opds_source")
    local server = rec.filepath:match("^OPDS://([^/]+)/") or "unknown"
    return M.cacheDir() .. "/" .. server .. "/"
        .. OpdsSource.serverKey(url) .. ".img"
end

-- cachedPath(rec) -> path | nil
-- The cache path for rec's cover URL, but only when a file actually exists
-- there yet -- cachePath alone is a deterministic name, not a promise the
-- fetch has landed. Callers use this to decide whether to attach
-- cover_image_path (render now) vs. leave the record for fetchMissing.
function M.cachedPath(rec)
    local path = M.cachePath(rec)
    if not path then return nil end
    local lfs = require("libs/libkoreader-lfs")
    local ok_a, a = pcall(lfs.attributes, path)
    if not (ok_a and a and a.mode == "file") then return nil end
    return path
end

-- Credentials for the server a record came from, resolved from its own
-- OPDS://<server_key>/ path. A password-protected catalogue (Calibre-Web et al)
-- 401s an anonymous cover-image GET, so without these the covers never appear
-- at all. Memoised per pass: OpdsSource.servers() re-reads and re-parses the
-- stock plugin's opds.lua on every call, and a page is typically all one
-- server. Unknown key (server deleted, filepath not ours) -> download
-- anonymously rather than error; that is exactly the pre-existing behaviour.
--
-- Credentials only travel to the server's own origin: the selected cover URL
-- came from the feed's XML, which a hostile or misconfigured server could
-- point at a foreign host, and Basic auth must not follow it there.
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
                hit = { user = server.username, password = server.password, url = server.url }
            end
        end
        cache[key] = hit
    end
    local url = coverUrl(rec)
    local ok_f, OpdsFeed = pcall(require, "lib/bookshelf_opds_feed")
    if not (ok_f and hit.url and url and OpdsFeed.sameOrigin(hit.url, url)) then
        return nil, nil
    end
    return hit.user, hit.password
end

-- How long a cover-fetch pass may hold the main loop. This runs serially and
-- uncancellably off a scheduleIn, so the defaults matter: CoverFetch's
-- socketutil LARGE pair is 10s block / 30s total, which for a full page of
-- slots against a server that accepts the connection but never answers is
-- minutes of frozen shelf after an ordinary page turn. Two bounds instead:
-- a tight per-request timeout (a cover image is at most a few hundred KB -
-- anything slower than this is not going to arrive usefully), and a
-- whole-batch deadline so the freeze is bounded no matter how many covers
-- are missing. Whatever the budget cuts off is simply retried by the next
-- render of the same page, and the on-disk cache means each pass starts
-- where the last one stopped.
M.THUMB_BLOCK_TIMEOUT = 5
M.THUMB_TOTAL_TIMEOUT = 10
-- Whole-batch deadline. Now only ever reached via the detail-modal's on-tap
-- fetch of a SINGLE cover (the shelf no longer bulk-downloads covers), so the
-- generous bound just lets one user-requested cover finish.
M.BATCH_BUDGET        = 20

-- Interim bound on the on-disk cache.
--
-- Nothing bounded this directory before: one full-size cover image per entry
-- the user ever looked at, never removed. (What used to empty it was an
-- accident -- the Cover tab's working-dir sweep, CoverApply.resetWorkingCache,
-- which owned the parent dir and recursed into this one. That now skips
-- opds/, which is why this needs a bound of its own: "cleared whenever the
-- user happens to close a book-detail modal" was never a policy.)
--
-- Deliberately dumb: total the files, and if they exceed the cap drop
-- oldest-by-mtime until they don't. mtime is "when it was downloaded", NOT
-- "when it was last looked at", so this evicts by age rather than by use --
-- a cover on a shelf the user opens daily is as evictable as one they saw
-- once. Slice 3 owns the real design (LRU on use, sharing the fetched_at
-- idiom the window store already carries); this exists so the dir cannot grow
-- without limit in the meantime.
M.CACHE_CAP_BYTES = 64 * 1024 * 1024

-- Walk the cache and enforce CACHE_CAP_BYTES. Only ever looks at
-- cacheDir()/<server>/<file> -- two levels, files only -- so nothing outside
-- the OPDS cache can be reached, let alone deleted. Every lfs call is pcall'd
-- and a missing dir is simply nothing to do.
function M.sweepCache()
    local lfs = require("libs/libkoreader-lfs")
    local root = M.cacheDir()
    local ok_root, iter, dobj = pcall(lfs.dir, root)
    if not ok_root then return end
    local files, total = {}, 0
    for server in iter, dobj do
        if server ~= "." and server ~= ".." then
            local sub = root .. "/" .. server
            local ok_sub, siter, sdobj = pcall(lfs.dir, sub)
            if ok_sub then
                for name in siter, sdobj do
                    if name ~= "." and name ~= ".." then
                        local path = sub .. "/" .. name
                        local ok_a, a = pcall(lfs.attributes, path)
                        if ok_a and type(a) == "table" and a.mode == "file" then
                            local size = a.size or 0
                            total = total + size
                            files[#files + 1] = { path = path, size = size,
                                                  mtime = a.modification or 0 }
                        end
                    end
                end
            end
        end
    end
    if total <= M.CACHE_CAP_BYTES then return end
    table.sort(files, function(a, b) return a.mtime < b.mtime end)
    local dropped, freed = 0, 0
    for _i = 1, #files do
        if total <= M.CACHE_CAP_BYTES then break end
        local f = files[_i]
        local ok_rm, done = pcall(os.remove, f.path)
        if ok_rm and done then
            total = total - f.size
            freed = freed + f.size
            dropped = dropped + 1
        end
    end
    local ok_log, logger = pcall(require, "logger")
    if ok_log and logger then
        logger.dbg("[bookshelf] opds cover cache over cap: dropped", dropped,
                   "file(s),", freed, "bytes;", total, "bytes left")
    end
end

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
                local got = CoverFetch.download(coverUrl(rec), path,
                                                user, password, net_opts)
                if got then fetched = fetched + 1 end
            end
        end
    end
    -- Only when this pass actually added bytes, and BEFORE on_done: the
    -- callback rebuilds the shelf, and it should render what is on disk after
    -- the sweep rather than briefly show a cover the sweep just dropped.
    -- Called through M so a test can observe it.
    if fetched > 0 then M.sweepCache() end
    if on_done then on_done(fetched) end
end

return M
