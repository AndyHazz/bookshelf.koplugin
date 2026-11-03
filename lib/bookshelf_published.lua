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
    -- put reads a row it has not seen before writing it (so a date never
    -- blanks a page count): the batch's rows in one query, not forty. On a
    -- PW5 the forty reads held the UI for ~100 ms a batch.
    if F and F.prefetch then
        local fps = {}
        for fp in pairs(res) do fps[#fps + 1] = fp end
        pcall(F.prefetch, fps)
    end
    for fp, r in pairs(res) do
        -- A date the reader set while this batch was being read stands.
        local e = F and F.get(fp)
        if F and not (e and e.pdm == M.USER_MTIME) then F.put(fp, { pd = r.date, pdm = r.mtime }) end
        if r.date ~= "" then filled[#filled + 1] = fp end
    end
    if F and next(res) and F.flushSoon then F.flushSoon() end
    -- The Published sort remembers each record's year; new dates void that.
    if #filled > 0 then
        pcall(function() require("lib/bookshelf_sort_engine").clearPublishedMemo() end)
    end
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

-- A date the reader set (setUserDate) is stored like a read one, its file
-- mtime replaced by this marker: nothing that re-reads or replaces a date
-- (Refresh metadata, a changed file, an OPDS download, a background read)
-- touches a row carrying it.
M.USER_MTIME = -1

-- stored(fp) -> the facts row's date fields, or nil. Every stored date at
-- once (one query a session), not a query per book: a shelf sorted by year
-- asks for all of them.
local function stored(fp)
    local F = facts()
    if not F then return nil end
    local map = F.publishedMap and F.publishedMap()
    if map then return map[fp] end
    return F.get(fp)
end

-- info(book) -> date, source
-- The date %published and the Publication year sort use, as stored (a year,
-- year-month or year-month-day), and where it came from, in the order they
-- win: "user" (the reader's own), "hardcover" (Use Hardcover metadata: the
-- work's first-published year), "calibre", "catalog" (an OPDS catalogue's),
-- "file" (read from the book; read in the background the first time). With
-- no date: nil and "none" (the file was read and has none) or "pending" (not
-- read yet, and now queued; or a format with no reader).
-- opts.ignore_user: the book's own date, the reader's left aside. The
-- reader's date is stored in place of the file's, so with one set the file's
-- is not known: nil, "pending", and nothing queued (the background read
-- would not replace the reader's date anyway); the caller reads the file.
function M.info(b, opts)
    if type(b) ~= "table" then return nil, "none" end
    local P = pubdate()
    local fp = localPath(b)
    local e = fp and stored(fp)
    local user = e and e.pdm == M.USER_MTIME
    if user and not (opts and opts.ignore_user) and e.pd and e.pd ~= "" then return e.pd, "user" end
    if user then e = nil end
    if P.year(b.hardcover_published) then return P.parseDate(b.hardcover_published), "hardcover" end
    local cal = b.calibre
    if type(cal) == "table" and P.year(cal.pubdate) then return P.parseDate(cal.pubdate), "calibre" end
    if P.year(b.published) then return P.parseDate(b.published), "catalog" end
    if not fp then return nil, "none" end
    if e and e.pd ~= nil then
        if e.pd ~= "" then return e.pd, "file" end
        return nil, "none"
    end
    if user then return nil, "pending" end
    if P.handles(fp) then M.enqueue(fp) return nil, "pending" end
    return nil, "none"
end

-- forRecord(book) -> "YYYY" | ""
function M.forRecord(b)
    local date = M.info(b)
    return pubdate().year(date) or ""
end

-- userDate(fp) -> the date the reader set, or nil.
function M.userDate(fp)
    local e = type(fp) == "string" and stored(fp)
    if e and e.pdm == M.USER_MTIME and e.pd and e.pd ~= "" then return e.pd end
    return nil
end

-- setUserDate(fp, text) -> true, or false for text that is not a date.
-- nil or "" clears it: the file is read for its date again.
function M.setUserDate(fp, text)
    local F = facts()
    if not (F and type(fp) == "string") then return false end
    if text == nil or text == "" then
        local e = stored(fp)
        if e and e.pdm == M.USER_MTIME then
            F.put(fp, { pd = false, pdm = false })
            _asked[fp] = nil
            if F.flushSoon then F.flushSoon() end
        end
        return true
    end
    local date = pubdate().parseDate(text)
    if not date then return false end
    F.put(fp, { pd = date, pdm = M.USER_MTIME })
    _asked[fp] = true
    if F.flushSoon then F.flushSoon() end
    return true
end

-- remember(fp, date): a date known from elsewhere (an OPDS download), kept
-- as if the file had been read.
function M.remember(fp, date, mtime)
    local F = facts()
    date = pubdate().parseDate(date)
    if not (F and type(fp) == "string" and date) then return end
    local e = stored(fp)
    if e and e.pdm == M.USER_MTIME then return end
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
    if e.pdm == M.USER_MTIME then return end
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
