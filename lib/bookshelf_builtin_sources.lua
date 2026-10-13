--[[
bookshelf_builtin_sources.lua -- the sources Bookshelf ships, registered with
lib/bookshelf_sources the same way another plugin's would be (issue 452).

Each spec is a thin layer over its own module (lib/bookshelf_kindle_source,
lib/bookshelf_kobo_source), which keep doing the real work. What moved here is
the per-source knowledge that used to be spread across the repository, the
widget and the shelf editor as `kind == "kindle"` tests.

Called once, by lib/bookshelf_sources, with the registry: a require the other
way round would be a loop.
]]

-- Lazy: the specs are registered at load, and the headless tests load this
-- without KOReader's gettext behind the i18n module.
local function _(s) return require("lib/bookshelf_i18n").gettext(s) end

return function(Sources)
    -- The Kindle's own library (issue 355). Its books count as part of the
    -- library for search and the tallies once a shelf uses it.
    local function kindle() return require("lib/bookshelf_kindle_source") end
    -- package.loaded rather than require for the per-book questions: they are
    -- asked on every shelf, Kindle or not, and a module never loaded has no
    -- records to answer about (see the repository's getKindleSource note).
    local function kindleIfLoaded()
        local mod = package.loaded["lib/bookshelf_kindle_source"]
        return type(mod) == "table" and mod or nil
    end
    Sources.register("kindle", {
        api       = 1,
        label     = function() return _("Kindle Virtual Library") end,
        available = function() return kindle().isAvailable() end,
        list      = function() return kindle().listBooks() end,
        library   = true,
        sort_default = { { key = "title", reverse = false } },
        -- A new Kindle shelf starts with the formats KOReader cannot open
        -- filtered out, so it is not padded with books that can only refuse.
        -- Only a shelf with no filter of its own: re-picking the source must
        -- never discard one the reader set.
        --
        -- Openability is a per-BOOK question (DRM and the file's magic bytes as
        -- well as the extension), so a format earns its place if any book in
        -- it can be opened, which keeps KFX and EPUB and drops AZW3. A format
        -- with both kinds keeps both: the Format filter is a list of formats
        -- and cannot say "the unlocked ones".
        new_shelf = function(draft)
            local Filter = require("lib/bookshelf_filter")
            if Filter.isActive(draft.filter) then return end
            local allowed, openable, blocked = {}, false, false
            for _i, b in ipairs(kindle().listBooks() or {}) do
                local fmt = b.format
                if fmt and fmt ~= "" then
                    if b.kindle_blocked then blocked = true
                    else allowed[fmt] = true; openable = true end
                end
            end
            -- Nothing blocked: leave the shelf unfiltered rather than pinning
            -- it to today's formats, which would hide one bought later.
            if not (openable and blocked) then return end
            draft.filter = draft.filter or {}
            draft.filter.formats = allowed
        end,
        owns = function(book) return book.is_kindle and true or false end,
        open = function(book, ctx) return ctx.widget:_openKindleBook(book, ctx.after_open) end,
        -- A book of ours changed (or everything did): drop the catalogue cache
        -- so the next listing re-reads status and progress. Answered from the
        -- existing cache only, so an invalidation never turns into a scan.
        invalidate = function(filepath)
            local mod = kindleIfLoaded()
            if not (mod and mod.invalidate) then return end
            if filepath == nil or (mod.isKindlePath and mod.isKindlePath(filepath)) then
                mod.invalidate()
            end
        end,
    })

    -- The Kobo store's library, through kobo.koplugin. An ordinary source: a
    -- reader who wants it adds a shelf of it, and can hide, move or delete it
    -- like any other. (It used to be a fixed "Kobo" button switched on under
    -- Advanced, which the shelf editor could not touch. Many install the Kobo
    -- plugin for its other features and never wanted the shelf.)
    local function kobo() return require("lib/bookshelf_kobo_source") end
    Sources.register("kobo", {
        api       = 1,
        label     = function() return _("Kobo library") end,
        available = function() return kobo().isAvailable() end,
        list      = function() return kobo().listBooks() end,
        sort_default = { { key = "title", reverse = false } },
        -- BIM cannot read a DRM'd kepub, so the plugin hands back a copied
        -- cover per record, attached for the visible page only.
        cover     = function(rec) return kobo().coverBB(rec.filepath) end,
        owns      = function(book) return book.is_kobo and true or false end,
        open      = function(book, ctx) return ctx.widget:_openKoboBook(book, ctx.after_open) end,
    })
end
