-- lib/bookshelf_book_facts_db.lua
-- SQLite storage for the small facts the shelf works out per book: the page
-- count the scan found, the colour sampled off the cover, and the read status
-- last seen in the sidecar.
--
-- WHY A DATABASE, having been a key in the settings file. All of this lived in
-- `spine_looks`, one Lua table rewritten in full on every flush -- and a flush
-- happens as you browse, because each newly sampled cover dirties it. Measured
-- on the maintainer's PW5: 250 books cost 106KB, about 425 bytes a book. So:
--
--     1,200 books   ~0.5 MB
--     5,000 books   ~2 MB
--    30,000 books   ~12 MB     rewritten, in full, every few page turns
--
-- The sibling store already learned this. bookshelf_opds_db's header records
-- 306ms to parse a 4.7MB window file at launch and 399ms PER SAVE, against
-- 0.8ms to append a page once it was SQLite. The shape here is the same and
-- the conclusion is the same.
--
-- AND IT IS WHY THE CAP EXISTED. The old store discarded the WHOLE table past
-- 1200 entries -- not because anyone wanted a library truncated, but because
-- the file had to be rewritten in full and something had to bound it. Once
-- page counts moved in beside the colours, that cap quietly threw away an
-- hour of scanning on any library over ~1200 books, which is not an unusual
-- library (issue 388's reporter has 1228; libraries of 30,000 exist).
-- Maintainer's ruling: no cap on anything. Rows here are written one at a
-- time, so there is nothing to bound.
--
-- READ SHAPE. The shelf wants the 30-50 books on the page it is building, so
-- prefetch() takes them in one statement and fills a session memo; every
-- per-book read after that is a table lookup. Loading the whole library into
-- memory at startup would just move the problem to RAM.
--
-- OUR OWN FILE, not CoverBrowser's bookinfo_cache: that database belongs to
-- another plugin, and these facts are ours.

local logger = require("logger")

local M = {}

M.DB_NAME = "bookshelf_book_facts.sqlite3"

local SCHEMA = [[
CREATE TABLE IF NOT EXISTS book_facts (
    fp            TEXT PRIMARY KEY,
    pages         INTEGER,
    pages_src     TEXT,
    r             INTEGER,
    g             INTEGER,
    b             INTEGER,
    aspect        REAL,
    status        TEXT,
    status_known  INTEGER,
    sidecar_mtime INTEGER
);
]]

local _db
local _open_failed
-- The session's working set: prefetch fills it, reads hit it, writes land
-- here first and go to disk on flush. It is also the whole store when the
-- database cannot be opened at all.
local _memo  = {}
local _dirty = {}

-- open() -> db | nil, reason
function M.open()
    if _db then return _db end
    if _open_failed then return nil, _open_failed end
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if not ok_ds then _open_failed = "no-datastorage"; return nil, _open_failed end
    local ok_sq, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not (ok_sq and SQ3) then _open_failed = "no-sqlite"; return nil, _open_failed end
    local path = DataStorage:getSettingsDir() .. "/" .. M.DB_NAME
    local ok_open, db = pcall(SQ3.open, path)
    if not (ok_open and db) then _open_failed = "open-failed"; return nil, _open_failed end
    local ok_p = pcall(function()
        db:exec("PRAGMA journal_mode=WAL;")
        db:exec("PRAGMA synchronous=NORMAL;")
        db:exec("PRAGMA busy_timeout=5000;")
        db:exec("PRAGMA journal_size_limit=2097152;")
        db:exec(SCHEMA)
    end)
    if not ok_p then
        pcall(function() db:close() end)
        _open_failed = "schema-failed"
        return nil, _open_failed
    end
    _db = db
    return _db
end

function M.close()
    if _db then pcall(function() _db:close() end) end
    _db = nil
    _open_failed = nil
end

-- Drop the session memo. Tests use it to force a read off disk; nothing in
-- the app needs it, since the memo and the database never disagree.
function M.forgetMemo()
    _memo, _dirty = {}, {}
end

-- A store that will not open must degrade to "we know nothing", never to an
-- error reaching the shelf: this plugin has already been bitten by a poisoned
-- SQLite handle taking an unrelated feature down for a whole session.
local function with(fn, default)
    local db = M.open()
    if not db then return default end
    local ok, res = pcall(fn, db)
    if not ok then
        logger.warn("[bookshelf] book facts db:", tostring(res))
        return default
    end
    return res
end

local function _rowToFacts(row)
    if not row then return nil end
    local e = {}
    e.p    = tonumber(row[2])
    e.psrc = row[3] ~= nil and tostring(row[3]) or nil
    e.r    = tonumber(row[4])
    e.g    = tonumber(row[5])
    e.b    = tonumber(row[6])
    e.a    = tonumber(row[7])
    e.s    = row[8] ~= nil and tostring(row[8]) or nil
    local sk = tonumber(row[9])
    e.sk   = sk == 1 or nil
    e.m    = tonumber(row[10])
    return e
end

local SELECT_COLS =
    "fp, pages, pages_src, r, g, b, aspect, status, status_known, sidecar_mtime"

-- get(fp) -> facts | nil
-- Keys match the entries the settings store used, so the call sites that read
-- them did not have to change: p/psrc, r/g/b/a, s/sk/m.
function M.get(fp)
    if type(fp) ~= "string" or fp == "" then return nil end
    local hit = _memo[fp]
    if hit ~= nil then
        if hit == false then return nil end   -- known absent
        return hit
    end
    local e = with(function(db)
        local st = db:prepare("SELECT " .. SELECT_COLS .. " FROM book_facts WHERE fp=?")
        st:reset():bind(fp)
        return _rowToFacts(st:step())
    end, nil)
    _memo[fp] = e or false
    return e
end

-- prefetch(fps) -> number of rows found
-- One statement for a whole page of books. Anything not in the answer is
-- remembered as absent, so a miss costs no second query either.
function M.prefetch(fps)
    if type(fps) ~= "table" or #fps == 0 then return 0 end
    local want = {}
    for i = 1, #fps do
        local fp = fps[i]
        if type(fp) == "string" and fp ~= "" and _memo[fp] == nil then
            want[#want + 1] = fp
        end
    end
    if #want == 0 then return 0 end
    local found = with(function(db)
        local n = 0
        -- Chunked: SQLite's parameter limit is finite and a shelf can ask for
        -- a lot at once when a scan or a select-all is driving.
        local CHUNK = 200
        for from = 1, #want, CHUNK do
            local to = math.min(from + CHUNK - 1, #want)
            local marks = {}
            for _i = from, to do marks[#marks + 1] = "?" end
            local st = db:prepare("SELECT " .. SELECT_COLS
                .. " FROM book_facts WHERE fp IN (" .. table.concat(marks, ",") .. ")")
            st:reset()
            local args = {}
            for i = from, to do args[#args + 1] = want[i] end
            -- NOT `unpack and unpack(args)`: `a and f()` truncates a
            -- multi-return to one value, so only the first filepath would be
            -- bound and the page would come back with one row.
            local unpack_fn = unpack or table.unpack
            st:bind(unpack_fn(args))
            local row = st:step()
            while row do
                local fp = tostring(row[1])
                _memo[fp] = _rowToFacts(row)
                n = n + 1
                row = st:step()
            end
        end
        return n
    end, 0)
    -- Whatever the query did not answer for, we now know is not there.
    for i = 1, #want do
        if _memo[want[i]] == nil then _memo[want[i]] = false end
    end
    return found
end

-- put(fp, facts) -- merge fields onto the book's row. Only the keys present
-- are touched, so writing a look never disturbs a page count and vice versa.
function M.put(fp, facts)
    if type(fp) ~= "string" or fp == "" or type(facts) ~= "table" then return end
    local e = _memo[fp]
    if e == nil or e == false then e = {} end
    -- false means CLEAR this field, absent means leave it alone. The
    -- distinction matters: writing a look must not disturb a page count, and
    -- a sidecar that changed under us clears the cached status without
    -- touching the count, which is not the sidecar's to invalidate.
    for _, k in ipairs({ "p", "psrc", "r", "g", "b", "a", "s", "sk", "m" }) do
        local v = facts[k]
        if v ~= nil then
            if v == false then e[k] = nil else e[k] = v end
        end
    end
    _memo[fp] = e
    _dirty[fp] = true
end

function M.drop(fp)
    if type(fp) ~= "string" or fp == "" then return end
    _memo[fp] = false
    _dirty[fp] = "delete"
end

-- flush() -> number of rows written
-- One transaction for the batch: the scan persists hundreds in a pass and a
-- commit per book would be hundreds of fsyncs on a device's flash.
function M.flush()
    local pending = next(_dirty)
    if pending == nil then return 0 end
    local written = with(function(db)
        local n = 0
        db:exec("BEGIN;")
        local ok = pcall(function()
            local ins = db:prepare(
                "INSERT INTO book_facts (" .. SELECT_COLS .. ") "
                .. "VALUES (?,?,?,?,?,?,?,?,?,?) "
                .. "ON CONFLICT(fp) DO UPDATE SET "
                .. "pages=excluded.pages, pages_src=excluded.pages_src, "
                .. "r=excluded.r, g=excluded.g, b=excluded.b, "
                .. "aspect=excluded.aspect, status=excluded.status, "
                .. "status_known=excluded.status_known, "
                .. "sidecar_mtime=excluded.sidecar_mtime")
            local del = db:prepare("DELETE FROM book_facts WHERE fp=?")
            for fp, what in pairs(_dirty) do
                if what == "delete" then
                    del:reset():bind(fp):step()
                else
                    local e = _memo[fp]
                    if type(e) == "table" then
                        ins:reset():bind(fp, e.p, e.psrc, e.r, e.g, e.b, e.a,
                                         e.s, e.sk and 1 or nil, e.m):step()
                        n = n + 1
                    end
                end
            end
        end)
        if ok then db:exec("COMMIT;") else db:exec("ROLLBACK;") end
        if not ok then error("flush failed") end
        return n
    end, 0)
    -- Cleared either way: a store that cannot be written is not a reason to
    -- keep retrying the same rows on every subsequent flush. The memo still
    -- answers for the session.
    _dirty = {}
    return written
end

-- clearPageCounts() -> number of books cleared
-- The reset. Only the count and where it came from; the sampled colour and
-- the cached status are a different kind of knowledge and survive (the shelf
-- would otherwise go cold and re-decode every cover for nothing).
function M.clearPageCounts()
    M.flush()
    local n = with(function(db)
        local st = db:prepare("SELECT COUNT(*) FROM book_facts WHERE pages IS NOT NULL")
        st:reset()
        local row = st:step()
        local count = row and tonumber(row[1]) or 0
        db:exec("UPDATE book_facts SET pages=NULL, pages_src=NULL WHERE pages IS NOT NULL;")
        return count
    end, 0)
    -- The memo holds the old answers; drop just the counts from it too.
    for _fp, e in pairs(_memo) do
        if type(e) == "table" then e.p, e.psrc = nil, nil end
    end
    return n
end

function M.countRows()
    return with(function(db)
        local st = db:prepare("SELECT COUNT(*) FROM book_facts")
        st:reset()
        local row = st:step()
        return row and tonumber(row[1]) or 0
    end, 0)
end

-- countPageCounts() -> how many books carry a scanned count, for the caller
-- that wants to say "clear 431 page counts?" before doing it.
function M.countPageCounts()
    M.flush()
    return with(function(db)
        local st = db:prepare("SELECT COUNT(*) FROM book_facts WHERE pages IS NOT NULL")
        st:reset()
        local row = st:step()
        return row and tonumber(row[1]) or 0
    end, 0)
end

-- migrateFrom(legacy) -> number of books taken across
-- `legacy` is the old spine_looks table: filepath -> {r,g,b,a,p,s,sk,m}. The
-- caller writes and flushes THIS store before clearing the old key, so an
-- interrupted migration costs nothing and simply runs again.
function M.migrateFrom(legacy)
    if type(legacy) ~= "table" then return 0 end
    local n = 0
    for fp, e in pairs(legacy) do
        if type(fp) == "string" and type(e) == "table" then
            M.put(fp, { p = tonumber(e.p), psrc = e.psrc,
                        r = tonumber(e.r), g = tonumber(e.g), b = tonumber(e.b),
                        a = tonumber(e.a), s = e.s,
                        sk = e.sk == true or nil, m = tonumber(e.m) })
            n = n + 1
        end
    end
    return n
end

return M
