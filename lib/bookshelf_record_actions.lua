-- lib/bookshelf_record_actions.lua
-- Buttons other plugins add to an OPDS book's details window (PR 496): a
-- reader plugin such as Meguru can offer "Open in ..." for a catalog entry
-- without bookshelf knowing anything about it.
--
-- A provider is function(book, ctx) -> list of buttons, or nil:
--   book  the catalog record: title, author, opds = { acquisitions = { { type,
--         href, title } ... }, stream = { href, count, last_read } or nil,
--         summary, feed_url, thumbnail_url }
--   ctx   { server = { title, url, username, password } for the catalog the
--           record came from (the login only when the record's links are on
--           that catalog's own origin), close = function() closes the window }
-- A button is { text = "...", callback = function() ... end }; each goes on a
-- row of its own, below bookshelf's download and stream buttons. A provider
-- that errors is logged and skipped. Providers are asked in order of their ids.
--
-- From a plugin: ui.bookshelf:registerRecordActions(id, fn), checking
-- ui.bookshelf.RECORD_ACTIONS_API first. From a user patch:
--
--     local userpatch = require("userpatch")
--     userpatch.registerPatchPluginFunc("bookshelf", function(Bookshelf)
--         if not Bookshelf.registerRecordActions then return end
--         Bookshelf:registerRecordActions("my-patch", function(book, ctx) ... end)
--     end)
--
-- Registering an id again replaces it; nil removes it.
local M = {}

M.API = 1
M.KEY = "bookshelf.record_actions"

local function registry()
    local reg = package.loaded[M.KEY]
    if type(reg) ~= "table" then
        reg = {}
        package.loaded[M.KEY] = reg
    end
    return reg
end
registry()

function M.register(id, fn)
    if type(id) ~= "string" or id == "" then return false, "id must be a string" end
    if fn ~= nil and type(fn) ~= "function" then return false, "provider must be a function" end
    registry()[id] = fn
    return true
end

-- buttonsFor(book, ctx) -> every provider's buttons, in id order. A button
-- without text or a callback is dropped, and each callback is wrapped so an
-- error in it is logged rather than taking the window down.
function M.buttonsFor(book, ctx)
    local reg, out = registry(), {}
    if next(reg) == nil then return out end
    local ids = {}
    for id, fn in pairs(reg) do
        if type(id) == "string" and type(fn) == "function" then ids[#ids + 1] = id end
    end
    table.sort(ids)
    local function warn(...)
        local ok_l, logger = pcall(require, "logger")
        if ok_l and logger then logger.warn("[bookshelf] record actions", ...) end
    end
    for _i, id in ipairs(ids) do
        local ok, list = pcall(reg[id], book, ctx or {})
        if not ok then
            warn(id, "failed:", list)
        elseif type(list) == "table" then
            for _j, b in ipairs(list) do
                if type(b) == "table" and type(b.text) == "string" and b.text ~= ""
                        and type(b.callback) == "function" then
                    local cb = b.callback
                    out[#out + 1] = { text = b.text, callback = function()
                        local ok_c, err = pcall(cb)
                        if not ok_c then warn(id, "button failed:", err) end
                    end }
                end
            end
        end
    end
    return out
end

return M
