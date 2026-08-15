-- lib/bookshelf_opds_db.lua
-- SQLite storage for cached OPDS feed windows: the feeds we have fetched and
-- the entries in each.
--
-- WHY A DATABASE, having been a Lua file. The window store began life on
-- bookshelf_settings_store because that is what existed, and it grew into a
-- 4.7MB file holding 167 feeds and 2147 records. Measured on a PW5:
--
--   parse at launch                 306 ms
--   serialise + write, PER SAVE     399 ms
--
-- and a save happens on every fetched page, because LuaSettings can only
-- rewrite the whole file. So appending 25 records to one feed re-serialised
-- all 167 of them, and the cost grew with everything the reader had ever
-- browsed. The same operations here, measured with real SQLite:
--
--   append one 25-record page       0.8 ms
--   slice 25 rows at offset 1000    2.1 ms
--
-- The point is not the constant, it is the exponent: appending is O(page)
-- rather than O(store), and reading a page is a LIMIT/OFFSET rather than
-- holding every feed in RAM. That is also what makes deep paging possible at
-- all - the old MAX_ENTRIES cap existed to bound a file that had to be
-- rewritten in full, not because anyone wanted feeds truncated at 1000.
--
-- WHY OUR OWN FILE, not CoverBrowser's bookinfo_cache. That database belongs
-- to another plugin; bookshelf_bim_db borrows it read-write for metadata and
-- accepts the coupling because the data IS CoverBrowser's. Feed windows are
-- ours, and writing our tables into someone else's schema would break both on
-- their next migration.
--
-- WAL, matching bookshelf_hardcover's cache - which is OUR database too, has
-- run in WAL on a PW5 since it shipped, and is the reason to trust it here. I
-- first reasoned that /mnt/us is vfat and WAL needs shared memory vfat cannot
-- provide; that is wrong on this hardware. /mnt/us is fuse.fsp, not vfat, and
-- the -wal and -shm sidecars are present and journal_mode reports "wal" on the
-- live device. Checking beat reasoning.
--
-- busy_timeout still matters: cover workers are forked children and the parent
-- writes while a render may read.
local M = {}

local logger = (function()
    local ok, l = pcall(require, "logger")
    if ok and l then return l end
    return { dbg = function() end, warn = function() end }
end)()

M.DB_NAME = "bookshelf_opds.sqlite3"

-- Payload codec. rapidjson is bundled with KOReader and measured 3.5x faster
-- to encode and 2.6x faster to decode than the Lua dump/loadstring pair, at
-- 30% fewer bytes (560 vs 728 for a typical record). dump is the fallback for
-- a build without it; both round-trip the same nested record shape.
local _encode, _decode
local function codec()
    if _encode then return _encode, _decode end
    local ok, rj = pcall(require, "rapidjson")
    if ok and rj and rj.encode then
        _encode = function(t)
            local ok_e, s = pcall(rj.encode, t)
            return ok_e and s or nil
        end
        _decode = function(s)
            local ok_d, t = pcall(rj.decode, s)
            return ok_d and type(t) == "table" and t or nil
        end
    else
        local dump = require("dump")
        _encode = function(t)
            local ok_e, s = pcall(dump, t)
            return ok_e and s or nil
        end
        _decode = function(s)
            local f = loadstring or load
            local ok_l, chunk = pcall(f, "return " .. s)
            if not (ok_l and chunk) then return nil end
            local ok_r, t = pcall(chunk)
            return ok_r and type(t) == "table" and t or nil
        end
    end
    return _encode, _decode
end

local SCHEMA = [[
CREATE TABLE IF NOT EXISTS feeds (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    server_key  TEXT    NOT NULL,
    feed_url    TEXT    NOT NULL,
    fetched_at  INTEGER NOT NULL DEFAULT 0,
    next_url    TEXT,
    total       INTEGER,
    complete    INTEGER NOT NULL DEFAULT 0,
    trimmed     INTEGER NOT NULL DEFAULT 0,
    search      TEXT,
    items_per_page INTEGER,
    UNIQUE (server_key, feed_url)
);
CREATE TABLE IF NOT EXISTS entries (
    feed_id     INTEGER NOT NULL,
    seq         INTEGER NOT NULL,
    filepath    TEXT    NOT NULL,
    payload     TEXT    NOT NULL,
    PRIMARY KEY (feed_id, seq)
);
-- The dedupe appendPage used to do by hand, walking every existing entry to
-- build a `seen` set on each page. Now the database's problem.
CREATE UNIQUE INDEX IF NOT EXISTS entries_by_path ON entries (feed_id, filepath);
CREATE INDEX IF NOT EXISTS feeds_by_age ON feeds (fetched_at);
]]

local _db          -- one connection for the session
local _open_failed -- remember a hard failure so we stop retrying per call

-- open() -> db | nil, reason
-- reason is a short loggable token, as bookshelf_bim_db uses.
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
    -- WAL: see the header. NORMAL sync is the right trade for a cache - a torn
    -- write costs a refetch, not data.
    local ok_p = pcall(function()
        db:exec("PRAGMA journal_mode=WAL;")
        db:exec("PRAGMA synchronous=NORMAL;")
        db:exec("PRAGMA busy_timeout=5000;")
        -- CAP THE WAL. Checkpointing moves pages into the database but does
        -- not shrink the -wal file; without a limit it keeps whatever high
        -- water mark a big walk left it at. Measured on device: a 9MB database
        -- carrying a 12MB -wal, on an e-reader that has run out of space
        -- before. With a limit, each checkpoint truncates back to it.
        --
        -- 2MB is comfortably more than a page of feed entries needs between
        -- checkpoints, so this costs no extra fsyncs in normal browsing - it
        -- only stops the file staying huge after an unusually long walk.
        db:exec("PRAGMA journal_size_limit=2097152;")
        db:exec(SCHEMA)
        -- A database created before this column exists has to grow one. SQLite
        -- has no IF NOT EXISTS for ADD COLUMN, so the duplicate case is an
        -- error to swallow rather than a condition to test.
        pcall(function() db:exec("ALTER TABLE feeds ADD COLUMN items_per_page INTEGER;") end)
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
end

-- Every public call goes through this: a cache that cannot be opened must
-- degrade to "no cached feeds", never to an error reaching the shelf.
local function with(fn, default)
    local db = M.open()
    if not db then return default end
    local ok, res = pcall(fn, db)
    if not ok then
        logger.warn("[bookshelf] opds db:", tostring(res))
        return default
    end
    return res
end

-- feedId(db, server_key, feed_url, create) -> id | nil
local function feedId(db, server_key, feed_url, create)
    -- A window without its identity cannot address a row. Refusing here turns
    -- a caller's mistake into "no cached feed" instead of an ljsqlite3 bind
    -- error per record, which is how the bare-table refresh window presented:
    -- hundreds of constraint warnings and a silently empty shelf.
    if type(server_key) ~= "string" or type(feed_url) ~= "string"
            or server_key == "" or feed_url == "" then
        return nil
    end
    local st = db:prepare("SELECT id FROM feeds WHERE server_key=? AND feed_url=?")
    st:reset():bind(server_key, feed_url)
    local row = st:step()
    if row then return tonumber(row[1]) end
    if not create then return nil end
    local ins = db:prepare("INSERT INTO feeds (server_key, feed_url) VALUES (?,?)")
    ins:reset():bind(server_key, feed_url):step()
    st:reset():bind(server_key, feed_url)
    row = st:step()
    return row and tonumber(row[1]) or nil
end

-- meta(server_key, feed_url) -> table (never nil; an unknown feed reads as a
-- blank window, which is what "we have not fetched this" means everywhere).
function M.meta(server_key, feed_url)
    local blank = { fetched_at = 0, next_url = nil, total = nil,
                    complete = false, trimmed = false, search = nil, count = 0,
                    items_per_page = nil }
    return with(function(db)
        local st = db:prepare([[
            SELECT f.fetched_at, f.next_url, f.total, f.complete, f.trimmed,
                   f.search, (SELECT COUNT(*) FROM entries e WHERE e.feed_id = f.id),
                   f.items_per_page
            FROM feeds f WHERE f.server_key=? AND f.feed_url=?]])
        st:reset():bind(server_key, feed_url)
        local r = st:step()
        if not r then return blank end
        return {
            fetched_at = tonumber(r[1]) or 0,
            next_url   = r[2],
            total      = tonumber(r[3]),
            complete   = tonumber(r[4]) == 1,
            trimmed    = tonumber(r[5]) == 1,
            -- A table went in encoded (see setMeta), so try to decode; a value
            -- that is not encoded is handed back as the string it is. Falling
            -- back rather than failing keeps the column readable across a
            -- codec change and lets a caller store a bare href if it wants to.
            search     = r[6] and (select(2, codec())(r[6]) or r[6]) or nil,
            count      = tonumber(r[7]) or 0,
            items_per_page = tonumber(r[8]),
        }
    end, blank)
end

-- setMeta(server_key, feed_url, meta) - upsert the feed row's own fields.
-- Only the keys present are written, so a caller updating fetched_at does not
-- have to know about search links.
function M.setMeta(server_key, feed_url, meta)
    if type(meta) ~= "table" then return end
    with(function(db)
        local id = feedId(db, server_key, feed_url, true)
        if not id then return end
        local sets, vals = {}, {}
        -- A value sqlite cannot bind must cost its own column and nothing
        -- more. It used to cost the whole statement: bind() raises on the
        -- first unbindable argument, with() catches it, and every OTHER column
        -- in the same UPDATE was lost with it. That is how a table in `search`
        -- (below) stopped next_url, items_per_page, total and complete from
        -- EVER persisting on any catalog advertising search - the feed paged
        -- fine in memory and came back from the database with no chain, so
        -- categories froze at whatever the first visit had cached. Skipping
        -- the column keeps the rest of the write intact and says so out loud.
        local function put(col, v)
            if v == nil then return end
            local t = type(v)
            if t ~= "string" and t ~= "number" and t ~= "boolean" then
                logger.warn("[bookshelf] opds db: refusing to bind", t,
                            "for column", col)
                return
            end
            sets[#sets + 1] = col .. "=?"
            vals[#vals + 1] = v
        end
        put("fetched_at", meta.fetched_at)
        put("next_url",   meta.next_url)
        put("total",      meta.total)
        if meta.complete ~= nil then put("complete", meta.complete and 1 or 0) end
        if meta.trimmed  ~= nil then put("trimmed",  meta.trimmed  and 1 or 0) end
        -- `search` is a {href, type} pair, not a scalar - mapEntries captures
        -- the feed's search link, and _opdsSearch reads .href and .type off
        -- it. The column is TEXT, so it is stored the way entry payloads are.
        put("search",     type(meta.search) == "table"
                          and select(1, codec())(meta.search) or meta.search)
        put("items_per_page", meta.items_per_page)
        if #sets == 0 then return end
        local st = db:prepare("UPDATE feeds SET " .. table.concat(sets, ",")
                              .. " WHERE id=?")
        vals[#vals + 1] = id
        -- `unpack and unpack(vals) or table.unpack(vals)` looks like a version
        -- shim and is a bug: an and/or expression truncates multiple returns
        -- to ONE, so only the first value was ever bound and every update
        -- silently did nothing. Resolve the function first, then call it in a
        -- position that keeps the whole list.
        local unp = unpack or table.unpack
        st:reset():bind(unp(vals)):step()
    end)
end

-- clearNextUrl: setMeta cannot express "set this to NULL" (a nil value means
-- "leave alone"), and a feed whose chain has ended must be able to say so.
function M.clearNextUrl(server_key, feed_url)
    with(function(db)
        local id = feedId(db, server_key, feed_url, false)
        if not id then return end
        db:prepare("UPDATE feeds SET next_url=NULL WHERE id=?"):reset():bind(id):step()
    end)
end

-- Render decoration the repo adds to the COPIES it hands out, which must never
-- be written back: cover_bb is a BlitBuffer, cover_image_path and downloaded
-- are re-derived from disk on every render, and description is mirrored from
-- opds.summary which is already stored once.
--
-- This was belt-and-braces in the Lua store. It is load-bearing here: cover_bb
-- is cdata, the JSON encoder fails on it, and a record that fails to encode is
-- a record silently not stored. The nested opds table is deliberately NOT
-- touched - opds.icon carries a nav tile's data-uri icon, which is persisted
-- state rather than decoration.
local DECORATION = { "cover_bb", "cover_w", "cover_h", "has_cover",
                     "cover_image_path", "cover_borrowed", "downloaded",
                     "description" }
local function scrubbed(rec)
    local out = {}
    for k, v in pairs(rec) do out[k] = v end
    for _i = 1, #DECORATION do out[DECORATION[_i]] = nil end
    return out
end

-- append(server_key, feed_url, records) -> how many were new
--
-- One transaction for the page. Duplicates are dropped by the unique index on
-- (feed_id, filepath) rather than by walking the existing entries, which is
-- what the Lua version had to do on every page.
function M.append(server_key, feed_url, records)
    if type(records) ~= "table" or #records == 0 then return 0 end
    local encode = select(1, codec())
    return with(function(db)
        local id = feedId(db, server_key, feed_url, true)
        if not id then return 0 end
        local seq_st = db:prepare("SELECT COALESCE(MAX(seq), 0) FROM entries WHERE feed_id=?")
        seq_st:reset():bind(id)
        local row = seq_st:step()
        local seq = row and tonumber(row[1]) or 0
        local before = M.rawCount(db, id)
        db:exec("BEGIN;")
        local ok = pcall(function()
            local ins = db:prepare(
                "INSERT OR IGNORE INTO entries (feed_id, seq, filepath, payload) VALUES (?,?,?,?)")
            for _i = 1, #records do
                local rec = records[_i]
                local fp  = rec and rec.filepath
                if type(fp) == "string" and fp ~= "" then
                    local blob = encode(scrubbed(rec))
                    if blob then
                        seq = seq + 1
                        ins:reset():bind(id, seq, fp, blob):step()
                    end
                end
            end
        end)
        if ok then db:exec("COMMIT;") else db:exec("ROLLBACK;") end
        local added = M.rawCount(db, id) - before
        -- INVARIANT: a feed holding entries has a fetch timestamp. The two are
        -- written by separate steps in the walk, and a window with records but
        -- no stamp reads as "never fetched" to every caller that asks the cache
        -- question that way - which on device was a nav tile that did nothing
        -- at all when tapped. Stamping here means no caller can leave that
        -- state behind, whatever order it writes in.
        if added > 0 then
            local st = db:prepare("UPDATE feeds SET fetched_at=? WHERE id=? AND fetched_at<=0")
            st:reset():bind(os.time(), id):step()
        end
        return added
    end, 0)
end

-- rawCount(db, feed_id) - internal, assumes an open db and a known id.
function M.rawCount(db, feed_id)
    local st = db:prepare("SELECT COUNT(*) FROM entries WHERE feed_id=?")
    st:reset():bind(feed_id)
    local r = st:step()
    return r and tonumber(r[1]) or 0
end

function M.count(server_key, feed_url)
    return with(function(db)
        local id = feedId(db, server_key, feed_url, false)
        if not id then return 0 end
        return M.rawCount(db, id)
    end, 0)
end

-- slice(server_key, feed_url, offset, limit) -> { records }
-- The whole point of the exercise: a page of any depth for the cost of an
-- indexed range scan, with nothing else resident.
function M.slice(server_key, feed_url, offset, limit)
    local decode = select(2, codec())
    return with(function(db)
        local id = feedId(db, server_key, feed_url, false)
        if not id then return {} end
        local st = db:prepare(
            "SELECT payload FROM entries WHERE feed_id=? ORDER BY seq LIMIT ? OFFSET ?")
        st:reset():bind(id, limit or 0, offset or 0)
        local out = {}
        while true do
            local r = st:step()
            if not r then break end
            local rec = decode(r[1])
            if rec then out[#out + 1] = rec end
        end
        return out
    end, {})
end

-- reset(server_key, feed_url) - drop a feed's entries, keeping the row so its
-- search link and identity survive a refresh that replaces the window.
function M.reset(server_key, feed_url)
    with(function(db)
        local id = feedId(db, server_key, feed_url, false)
        if not id then return end
        db:prepare("DELETE FROM entries WHERE feed_id=?"):reset():bind(id):step()
        -- fetched_at goes with the entries. A reset feed has not been fetched
        -- - leaving the stamp behind would read as "cached", and the shelf
        -- would show an empty category and never ask again.
        db:prepare([[UPDATE feeds SET next_url=NULL, total=NULL, complete=0,
                     trimmed=0, fetched_at=0 WHERE id=?]])
          :reset():bind(id):step()
    end)
end

-- forget(server_key, feed_url) - remove the feed entirely.
function M.forget(server_key, feed_url)
    with(function(db)
        local id = feedId(db, server_key, feed_url, false)
        if not id then return end
        db:prepare("DELETE FROM entries WHERE feed_id=?"):reset():bind(id):step()
        db:prepare("DELETE FROM feeds WHERE id=?"):reset():bind(id):step()
    end)
end

-- evict(max_feeds, max_entries) - LRU by fetched_at, oldest first, until both
-- bounds hold. Now a DELETE with an ORDER BY rather than a walk over every
-- window weighing it, which is what the Lua store had to do inside each save.
function M.evict(max_feeds, max_entries)
    with(function(db)
        local function scalar(sql)
            local st = db:prepare(sql); st:reset()
            local r = st:step()
            return r and tonumber(r[1]) or 0
        end
        local feeds   = scalar("SELECT COUNT(*) FROM feeds")
        local entries = scalar("SELECT COUNT(*) FROM entries")
        if feeds <= (max_feeds or math.huge)
           and entries <= (max_entries or math.huge) then return end
        local st = db:prepare("SELECT id, (SELECT COUNT(*) FROM entries e WHERE e.feed_id=f.id)"
                              .. " FROM feeds f ORDER BY fetched_at ASC")
        st:reset()
        local victims = {}
        while true do
            local r = st:step()
            if not r then break end
            victims[#victims + 1] = { id = tonumber(r[1]), n = tonumber(r[2]) or 0 }
        end
        for _i = 1, #victims do
            if feeds <= (max_feeds or math.huge)
               and entries <= (max_entries or math.huge) then break end
            local v = victims[_i]
            db:prepare("DELETE FROM entries WHERE feed_id=?"):reset():bind(v.id):step()
            db:prepare("DELETE FROM feeds WHERE id=?"):reset():bind(v.id):step()
            feeds   = feeds - 1
            entries = entries - v.n
        end
    end)
end

-- stats() -> feeds, entries. For the settings screen and for tests.
function M.stats()
    return with(function(db)
        local function scalar(sql)
            local st = db:prepare(sql); st:reset()
            local r = st:step()
            return r and tonumber(r[1]) or 0
        end
        return { feeds = scalar("SELECT COUNT(*) FROM feeds"),
                 entries = scalar("SELECT COUNT(*) FROM entries") }
    end, { feeds = 0, entries = 0 })
end

return M
