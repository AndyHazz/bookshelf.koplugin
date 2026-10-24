-- lib/bookshelf_ornament_decks_db.lua
-- SQLite storage for the ornament decks (lib/bookshelf_ornament_deck): every
-- shelf's order of every piece, one row a piece.
--
-- WHY A DATABASE. The decks were one Lua table in the settings file, every
-- shelf's full list of piece names: 208 KB of a 272 KB file on the
-- maintainer's PW5 (10 shelves, ~360 pieces), so every preference saved
-- rewrote them. Moved to a file of their own (ornament_decks.lua), they were
-- still rewritten whole whenever ONE shelf's deck changed. Here a shelf's
-- deck is its own rows: changing it touches those, nothing else, and the
-- size of the collection or the number of shelves costs nothing to a save.
-- The same reasoning as lib/bookshelf_book_facts_db (maintainer: "we already
-- hold databases for other larger datasets like book facts").
--
-- READ SHAPE. The deck is read whenever a shelf deals, so the session keeps
-- every deck in memory once read (a few hundred short strings a shelf);
-- writes go to both.
--
-- MOVED IN ONCE. A database with no decks takes them from the settings store
-- (ornament_decks.lua, where 6.0 first moved them) the first time it opens,
-- and the old key goes.

local logger = require("logger")

local M = {}

M.DB_NAME = "ornament_decks.sqlite3"   -- in settings/bookshelf/ (lib/bookshelf_paths)
M.OLD_KEY = "ornament_decks"           -- the settings store's key

local SCHEMA = [[
CREATE TABLE IF NOT EXISTS decks (
    shelf TEXT NOT NULL,
    pos   INTEGER NOT NULL,
    piece TEXT NOT NULL,
    PRIMARY KEY (shelf, pos)
) WITHOUT ROWID;
]]

local _db
local _open_failed
local _memo        -- { [shelf] = { piece, ... } }, once read

local function _readAll(db)
    local out = {}
    local st = db:prepare("SELECT shelf, piece FROM decks ORDER BY shelf, pos")
    st:reset()
    local row = st:step()
    while row do
        local k = tostring(row[1])
        local list = out[k]
        if not list then list = {}; out[k] = list end
        list[#list + 1] = tostring(row[2])
        row = st:step()
    end
    return out
end

local function _writeShelf(db, shelf, list)
    db:prepare("DELETE FROM decks WHERE shelf=?"):reset():bind(shelf):step()
    if type(list) ~= "table" then return end
    local ins = db:prepare("INSERT INTO decks (shelf, pos, piece) VALUES (?,?,?)")
    for i, piece in ipairs(list) do
        ins:reset():bind(shelf, i, tostring(piece)):step()
    end
end

-- _moveIn(db): a database with no decks takes the settings store's, then the
-- store's copy goes. Written in one transaction first, so a failure leaves
-- the store's copy where it was.
local function _moveIn(db)
    local st = db:prepare("SELECT COUNT(*) FROM decks")
    st:reset()
    local row = st:step()
    if row and tonumber(row[1]) and tonumber(row[1]) > 0 then return end
    local ok_s, Store = pcall(require, "lib/bookshelf_settings_store")
    if not (ok_s and Store) then return end
    local ok_r, old = pcall(Store.read, M.OLD_KEY)
    if not (ok_r and type(old) == "table" and next(old) ~= nil) then return end
    db:exec("BEGIN;")
    local ok = pcall(function()
        for shelf, list in pairs(old) do _writeShelf(db, tostring(shelf), list) end
    end)
    if not ok then
        db:exec("ROLLBACK;")
        return
    end
    db:exec("COMMIT;")
    pcall(Store.delete, M.OLD_KEY)
    logger.dbg("[bookshelf] ornament decks moved into", M.DB_NAME)
end

-- open() -> db | nil, reason
function M.open()
    if _db then return _db end
    if _open_failed then return nil, _open_failed end
    local ok_ds = pcall(require, "datastorage")
    if not ok_ds then _open_failed = "no-datastorage"; return nil, _open_failed end
    local ok_sq, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not (ok_sq and SQ3) then _open_failed = "no-sqlite"; return nil, _open_failed end
    local path = require("lib/bookshelf_paths").settingsFile(M.DB_NAME)
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
    pcall(_moveIn, db)
    _db = db
    return _db
end

function M.close()
    if _db then pcall(function() _db:close() end) end
    _db, _open_failed, _memo = nil, nil, nil
end

-- usable() -> true when the database opened (else the deck keeps to the
-- settings store, as it did before).
function M.usable()
    return M.open() ~= nil
end

-- all() -> { [shelf] = { piece, ... } }: the session's copy.
function M.all()
    if _memo then return _memo end
    local db = M.open()
    if not db then return {} end
    local ok, res = pcall(_readAll, db)
    if not ok then
        logger.warn("[bookshelf] ornament decks db:", tostring(res))
        return {}
    end
    _memo = res
    return _memo
end

function M.get(shelf)
    return M.all()[tostring(shelf)]
end

-- put(shelf, list): replace one shelf's deck (nil: drop it).
function M.put(shelf, list)
    local k = tostring(shelf)
    local decks = M.all()
    decks[k] = list
    local db = M.open()
    if not db then return end
    local ok, err = pcall(function()
        db:exec("BEGIN;")
        local ok_w, e = pcall(_writeShelf, db, k, list)
        if ok_w then db:exec("COMMIT;") else db:exec("ROLLBACK;"); error(e) end
    end)
    if not ok then logger.warn("[bookshelf] ornament decks db:", tostring(err)) end
end

function M.drop(shelf) M.put(shelf, nil) end

return M
