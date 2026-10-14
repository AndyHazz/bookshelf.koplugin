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
--           flat = true for a thumbnail without rounded corners or shadow,
--           panel = true in the top panel, the one large cover on screen }
--   opts  optional: { frame = false } draws the widget on its own, with no
--         card border, background or shadow behind it, and none of
--         bookshelf's status glyphs, badges or progress over it
-- The widget is centred in the space. Return it at its own size rather than
-- filling w x h: with { frame = false }, the top panel then shrinks the cover
-- column to the widget, top-anchored, and gives the width it leaves to the
-- text beside it.
-- nil (or an error, which is logged) leaves the book to the next provider,
-- then to bookshelf's own card. Providers are asked in order of their ids.
--
-- From a user patch (koreader/patches/2-<name>.lua), KOReader's own helper
-- hands over the plugin when it loads:
--
--     local userpatch = require("userpatch")
--     userpatch.registerPatchPluginFunc("bookshelf", function(Bookshelf)
--         if not Bookshelf.registerPlaceholder then return end  -- older bookshelf
--         Bookshelf:registerPlaceholder("my-patch", function(book, w, h, ctx)
--             ...
--         end)
--     end)
--
-- A plugin with the bookshelf instance calls ui.bookshelf:registerPlaceholder
-- the same way. Registering an id again replaces it; nil removes it. The
-- registry itself is kept in package.loaded under M.KEY, so it outlives this
-- module being reloaded and a registration made early is not lost.
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
