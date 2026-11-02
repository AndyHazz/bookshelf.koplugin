-- bookshelf_published.lua
-- %published: a book's publication year, from the best source it has.
--
--   1. calibre's pubdate (metadata.calibre, when Read calibre metadata.calibre
--      is on): someone curated it
--   2. the OPDS catalog: a catalog entry's dc:issued while browsing, and the
--      same date saved at download (lib/bookshelf_widget's download flow)
--   3. the book file itself (lib/bookshelf_pubdate), read once and kept in
--      the book facts database
--
-- Nothing here runs unless a template names %published: the expander is the
-- only caller. A book whose file has not been read yet shows nothing on its
-- first paint and is queued; the queue is read in a forked child, a page at
-- a time, and the rows that gained a date are repainted in place
-- (on_filled). A render never opens a book file, and never stats one.
--
-- The date is not re-read when a file changes under the same path: Refresh
-- metadata on the book clears it (forget), and an OPDS re-download replaces it.

local M = {}

local BATCH = 40          -- books per child
local DELAY = 0.5         -- seconds: let the page finish painting first
local POLL = 0.25         -- seconds between checks on the child
local TIMEOUT = 60        -- seconds before a stuck child is killed

local _pending = {}       -- fp -> true, waiting for a child
local _order = {}         -- the same fps, first queued first
local _asked = {}         -- fp -> true: queued or read this session
local _running = false
local _armed = false
local _broken = false     -- a fork failed: stop asking for the session

-- Set by the shelf: function(fps) repaints those books where they show.
M.on_filled = nil

local function facts()
    local ok, F = pcall(require, "lib/bookshelf_book_facts_db")
    return ok and F or nil
end

local function pubdate()
    return require("lib/bookshelf_pubdate")
end

local function localPath(b)
    local fp = b and b.filepath
    if type(fp) ~= "string" or fp == "" or fp:find("^OPDS://") then return nil end
    return fp
end

local function uiManager()
    local ok, UIManager = pcall(require, "ui/uimanager")
    return ok and UIManager or nil
end

-- ── The background read ────────────────────────────────────────────────────

-- spawn(batch, done): reads every file in batch in a forked child and calls
-- done({ [fp] = { date = "YYYY..." | "", mtime = n } }) on the main process,
-- or done(nil) when the child could not be started. Replaced in tests.
function M._spawn(batch, done)
    local ok_u, util = pcall(require, "ffi/util")
    local UIManager = uiManager()
    if not (ok_u and util and util.runInSubProcess and UIManager) then
        return done(nil)
    end
    local pid, fd = util.runInSubProcess(function(_pid, write_fd)
        local lfs = require("libs/libkoreader-lfs")
        local P = require("lib/bookshelf_pubdate")
        local lines = {}
        for i, fp in ipairs(batch) do
            local date = P.read(fp) or ""
            local mtime = lfs.attributes(fp, "modification") or 0
            lines[i] = date .. "\t" .. tostring(mtime)
        end
        util.writeToFD(write_fd, table.concat(lines, "\n") .. "\n", true)
    end, true)
    if not pid or not fd then return done(nil) end
    local waited = 0
    local function check()
        if util.isSubProcessDone(pid) then
            local out = util.readAllFromFD(fd) or ""
            local res, k = {}, 0
            for line in out:gmatch("([^\n]*)\n") do
                k = k + 1
                local fp = batch[k]
                local date, mtime = line:match("^([^\t]*)\t(%d+)$")
                if fp and date then
                    res[fp] = { date = date, mtime = tonumber(mtime) }
                end
            end
            return done(res)
        end
        waited = waited + POLL
        if waited >= TIMEOUT then
            pcall(util.terminateSubProcess, pid)
            -- Reap it later; the batch counts as answered with nothing so it
            -- is not asked again this session.
            UIManager:scheduleIn(1, function() pcall(util.isSubProcessDone, pid) end)
            -- Closes our end; the killed child's end is already gone.
            pcall(util.readAllFromFD, fd)
            return done({})
        end
        UIManager:scheduleIn(POLL, check)
    end
    UIManager:scheduleIn(POLL, check)
end

local run

local function finish(res)
    _running = false
    if res == nil then
        _broken = true
        return
    end
    local F = facts()
    local filled = {}
    for fp, r in pairs(res) do
        if F then F.put(fp, { pd = r.date, pdm = r.mtime }) end
        if r.date ~= "" then filled[#filled + 1] = fp end
    end
    if F and next(res) and F.flushSoon then F.flushSoon() end
    if #filled > 0 and M.on_filled then
        pcall(M.on_filled, filled)
    end
    if #_order > 0 then run() end
end

run = function()
    if _running or _broken or #_order == 0 then return end
    local batch = {}
    while #batch < BATCH and #_order > 0 do
        local fp = table.remove(_order, 1)
        _pending[fp] = nil
        batch[#batch + 1] = fp
    end
    _running = true
    local ok = pcall(M._spawn, batch, finish)
    if not ok then finish(nil) end
end

local function arm()
    if _armed or _running then return end
    local UIManager = uiManager()
    if not UIManager then return end
    _armed = true
    UIManager:scheduleIn(DELAY, function()
        _armed = false
        run()
    end)
end

-- enqueue(fp): read this book's file in the background, once a session.
function M.enqueue(fp)
    if _broken or _asked[fp] then return end
    _asked[fp] = true
    _pending[fp] = true
    _order[#_order + 1] = fp
    arm()
end

-- ── The lookup ─────────────────────────────────────────────────────────────

-- forRecord(book) -> "YYYY" | ""
function M.forRecord(b)
    if type(b) ~= "table" then return "" end
    local P = pubdate()
    local cal = b.calibre
    if type(cal) == "table" then
        local y = P.year(cal.pubdate)
        if y then return y end
    end
    local y = P.year(b.published)
    if y then return y end
    local fp = localPath(b)
    if not fp then return "" end
    local F = facts()
    local e = F and F.get(fp)
    if e and e.pd ~= nil then return P.year(e.pd) or "" end
    if P.handles(fp) then M.enqueue(fp) end
    return ""
end

-- remember(fp, date): a date known from elsewhere (an OPDS download), kept
-- as if the file had been read.
function M.remember(fp, date, mtime)
    local F = facts()
    date = pubdate().parseDate(date)
    if not (F and type(fp) == "string" and date) then return end
    F.put(fp, { pd = date, pdm = mtime or false })
    _asked[fp] = true
end

-- forget(fp): Refresh metadata, or a file the stale sweep saw change
-- (both through Repo.forgetBook). The date is read again next time only when
-- the file is not the one it came from: an unchanged file would give the same
-- answer, and a date an OPDS download carried over is not in the file at all.
function M.forget(fp, mtime)
    local F = facts()
    if not (F and type(fp) == "string") then return end
    local e = F.get(fp)
    if not (e and e.pd ~= nil) then return end
    if mtime == nil then
        local ok, lfs = pcall(require, "libs/libkoreader-lfs")
        mtime = ok and lfs and lfs.attributes(fp, "modification") or nil
    end
    if e.pdm and mtime and e.pdm == mtime then return end
    F.put(fp, { pd = false, pdm = false })
    _asked[fp] = nil
end

-- For the tests.
function M._reset()
    _pending, _order, _asked = {}, {}, {}
    _running, _armed, _broken = false, false, false
    M.on_filled = nil
end

return M
