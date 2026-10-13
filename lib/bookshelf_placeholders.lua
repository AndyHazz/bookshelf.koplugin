-- lib/bookshelf_placeholders.lua
-- Placeholders for books without a cover, supplied by a user patch or
-- another plugin (PR 515). Bookshelf draws its own lettered card unless a
-- provider hands back a widget for the book, which is then drawn inside the
-- card's frame in the cover grid, list rows, the top panel and face-out
-- spines. Taps, selection and layout stay bookshelf's.
--
-- A provider is function(book, w, h, ctx) -> widget [, opts] or nil:
--   book  the book's record (title, authors, genres, description, filepath, ...)
--   w, h  the space inside the card's border, in pixels; the widget must fit
--   ctx   { bare = true when the caller wants no lettering (list rows),
--           flat = true for a thumbnail without rounded corners or shadow }
--   opts  optional: { frame = false } draws the widget on its own, with no
--         card border, background or shadow behind it
-- nil (or an error, which is logged) leaves the book to the next provider,
-- then to bookshelf's own card. Providers are asked in order of their ids.
--
-- The registry lives in package.loaded under a fixed name rather than in
-- this module, so a user patch can register before bookshelf has loaded,
-- with no require:
--
--     local reg = package.loaded["bookshelf.placeholders"] or {}
--     package.loaded["bookshelf.placeholders"] = reg
--     reg["my-patch"] = function(book, w, h, ctx) ... end
--
-- A plugin with the bookshelf instance can call ui.bookshelf:registerPlaceholder
-- (id, fn) instead. Setting an id again replaces it; nil removes it.
local M = {}

M.API = 1
M.KEY = "bookshelf.placeholders"

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

function M.any()
    return next(registry()) ~= nil
end

-- widgetFor(book, w, h, ctx) -> the first provider's widget and its opts
-- (always a table), or nil.
function M.widgetFor(book, w, h, ctx)
    local reg = registry()
    if next(reg) == nil then return nil end
    local ids = {}
    for id, fn in pairs(reg) do
        if type(id) == "string" and type(fn) == "function" then ids[#ids + 1] = id end
    end
    table.sort(ids)
    for _i, id in ipairs(ids) do
        local ok, widget, opts = pcall(reg[id], book, w, h, ctx or {})
        if not ok then
            local ok_l, logger = pcall(require, "logger")
            if ok_l and logger then
                logger.warn("[bookshelf] placeholder provider", id, "failed:", widget)
            end
        elseif type(widget) == "table" then
            return widget, type(opts) == "table" and opts or {}
        end
    end
    return nil
end

return M
