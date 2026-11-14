-- lib/bookshelf_curated.lua
-- A hand-ordered shelf's books (issue 390).
--
-- A Curated shelf is a KOReader COLLECTION shown as a shelf: source =
-- { kind = "collection", id = <collection name> }, sorted by Collection
-- order. Nothing of its own is stored: the books and their order are the
-- collection's, so they show in KOReader's own collections, other plugins
-- see them, and KOReader keeps the paths right when a file moves or goes.
-- (A first version kept lists in a file of Bookshelf's own. The maintainer
-- asked whether a collection would do; it does, and better.)
--
-- This is the one place Bookshelf adds, removes and reorders a shelf's
-- books by hand, on KOReader's ReadCollection and lib/bookshelf_collection_order
-- (which writes a whole order and drops the cached shelves).
--
-- What a collection cannot hold is anything but files in an order. A later
-- layout that needs more (a book leaning on its neighbor, a pile lying flat)
-- keeps that beside the shelf, keyed by collection and path; the pieces that
-- stand among the books already do (tab.shelf_modules).
--
--   C.create(name) -> name | nil     C.exists(name)
--   C.add(name, fp)  C.remove(name, fp)  C.has(name, fp)  C.count(name)
--   C.books(name) -> { fp, ... } in the collection's order
--   C.ordered(name) -> does every book have a place of its own?
--   C.move(name, from, to [, shown])  C.setOrder(name, { fp, ... })

local M = {}

local function RC() return require("readcollection") end

local function coll(name)
    if type(name) ~= "string" or name == "" then return nil end
    local c = RC().coll
    c = type(c) == "table" and c[name]
    return type(c) == "table" and c or nil
end

-- KOReader keys a collection's items by the file's REAL path, so a book
-- reached through a linked folder (/mnt/us on a Kindle is one) has to be
-- looked up by it: by the path the shelf holds it read as "not on it", and
-- adding it again sent it to the end.
local function real(fp)
    if type(fp) ~= "string" or fp == "" then return nil end
    local ok, util = pcall(require, "ffi/util")
    if ok and util and util.realpath then
        local ok_r, r = pcall(util.realpath, fp)
        if ok_r and type(r) == "string" and r ~= "" then return r end
    end
    return fp
end

local function changed(reason)
    pcall(function()
        local Repo = require("lib/bookshelf_book_repository")
        if Repo.invalidateBookCache then Repo.invalidateBookCache(reason) end
    end)
end

function M.exists(name) return coll(name) ~= nil end

-- create(name) -> the collection's name, made if it was not there. nil for
-- no name, or the favorites collection's (it has a shelf and a card of its
-- own).
function M.create(name)
    if type(name) ~= "string" then return nil end
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" or name == RC().default_collection_name then return nil end
    if coll(name) then return name end
    local rc = RC()
    rc:addCollection(name)
    rc:write({ [name] = true })
    return name
end

-- The collection's items as a list, in its order: by `order`, then by name
-- for the ones with none (a collection KOReader sorts itself stores no
-- order).
local function items(name)
    local c = coll(name)
    local out = {}
    if not c then return out end
    for key, it in pairs(c) do
        if type(it) == "table" then
            out[#out + 1] = { file = it.file or key, order = it.order,
                              text = tostring(it.text or it.file or key):lower() }
        end
    end
    table.sort(out, function(a, b)
        if a.order ~= nil and b.order ~= nil and a.order ~= b.order then return a.order < b.order end
        if (a.order == nil) ~= (b.order == nil) then return a.order ~= nil end
        if a.text ~= b.text then return a.text < b.text end
        return a.file < b.file
    end)
    return out
end

function M.books(name)
    local out = {}
    for i, it in ipairs(items(name)) do out[i] = it.file end
    return out
end

function M.count(name)
    local n = 0
    for _k in pairs(coll(name) or {}) do n = n + 1 end
    return n
end

function M.has(name, fp)
    local c = coll(name)
    local key = real(fp)
    return c ~= nil and key ~= nil and c[key] ~= nil
end

function M.indexOf(name, fp)
    local key = real(fp)
    for i, f in ipairs(M.books(name)) do if f == key then return i end end
    return nil
end

-- ordered(name) -> true when every book has a place of its own (and no two
-- share one): the collection is hand-ordered. False for one KOReader sorts
-- itself, which stores no order until someone arranges it.
function M.ordered(name)
    local c = coll(name)
    if not c then return false end
    local settings = RC().coll_settings and RC().coll_settings[name]
    if settings and settings.collate then return false end
    local seen = {}
    for _k, it in pairs(c) do
        if type(it) ~= "table" or it.order == nil or seen[it.order] then return false end
        seen[it.order] = true
    end
    return true
end

-- addMany(name, fps) -> how many went on, at the end, with ONE write (a
-- write a book was seconds for a big selection on a device). A book already
-- there, a file that is not on the device (KOReader raises on one) and a
-- collection that does not exist are all passed over.
function M.addMany(name, fps)
    local c = coll(name)
    if not c or type(fps) ~= "table" then return 0 end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    local rc, n = RC(), 0
    for _i, fp in ipairs(fps) do
        local key = real(fp)
        if key and not c[key] and not (ok_lfs and lfs and not lfs.attributes(key)) then
            if pcall(rc.addItem, rc, key, name) and c[key] then n = n + 1 end
        end
    end
    if n > 0 then
        rc:write({ [name] = true })
        changed("curated add: " .. name)
    end
    return n
end

function M.add(name, fp) return M.addMany(name, { fp }) == 1 end

-- removeMany(name, fps) -> how many came off, with one write.
function M.removeMany(name, fps)
    local c = coll(name)
    if not c or type(fps) ~= "table" then return 0 end
    local rc, n = RC(), 0
    for _i, fp in ipairs(fps) do
        local key = real(fp)
        if key and c[key] ~= nil then
            -- no_write: the one write is below.
            local ok, gone = pcall(rc.removeItem, rc, key, name, true)
            if ok and gone then n = n + 1 end
        end
    end
    if n > 0 then
        rc:write({ [name] = true })
        changed("curated remove: " .. name)
    end
    return n
end

function M.remove(name, fp) return M.removeMany(name, { fp }) == 1 end

-- setOrder(name, fps) -> true: the books in this order (lib/bookshelf_collection_order
-- .save, which also stops KOReader sorting the collection its own way and
-- drops the cached shelves). A path not on the shelf is ignored; a book
-- left out keeps its turn after the ones named.
function M.setOrder(name, fps)
    if not coll(name) or type(fps) ~= "table" then return false end
    local list = {}
    for _i, fp in ipairs(fps) do list[#list + 1] = { file = fp } end
    local CollectionOrder = require("lib/bookshelf_collection_order")
    -- true: drop only this collection's cached shelves.
    return CollectionOrder.save(name, list, true) == true
end

-- move(name, from, to [, shown]) -> true when the book at place `from`
-- ended up at `to`. shown: the order to start from when it is not the
-- collection's own (the shelf on screen, for a collection with no order yet,
-- or a shelf shown reversed): the places are places in THAT order, and it is
-- what gets written.
function M.move(name, from, to, shown)
    local books = shown or M.books(name)
    local n = #books
    if not (from and to) or from < 1 or from > n or to < 1 or to > n or from == to then return false end
    local out = {}
    for i, fp in ipairs(books) do out[i] = fp end
    local fp = table.remove(out, from)
    table.insert(out, to, fp)
    return M.setOrder(name, out)
end

return M
