-- tests/_test_soft_refresh_hero_book.lua
-- The warm return from a book must not leave the PREVIOUS book's cover
-- standing beside the new book's text.
--
-- WHAT NEEDS PINNING. softRefresh's cheap hero path swaps the right column
-- only, on the stated grounds that "the hero cover doesn't change on book
-- close (same book is still currently reading)". That holds for the book the
-- hero already stood for -- open it from the hero, read, come back -- and not
-- for the far more common gesture: tap a cover on the SHELF. That book
-- becomes the current one, so the right column comes back as the new book
-- while the cover beside it is still the old one.
--
-- It stayed invisible while the ordinary close cold-created the shelf (the
-- whole hero, cover included, was rebuilt from scratch every time). Issue 422
-- keeps the shelf alive across the close, which makes this warm path the
-- normal route home -- so the mismatch has to be caught here. The correction
-- is one hero rebuild (_swapHeroInPlace), not a page rebuild: the shelves,
-- chips and footer are untouched either way.
--
-- Usage (from plugin root): lua tests/_test_soft_refresh_hero_book.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq
local src = io.open("lib/bookshelf_widget.lua"):read("*a")

local function extract(source, name)
    local pat = "\nfunction " .. name:gsub("[%.%(%)]", "%%%0") .. "\n(.-)\nend\n"
    local body = source:match(pat)
    assert(body, name .. " not found")
    return (body:gsub("%-%-[^\n]*", ""))
end

local function newEnv(current_fp)
    local e = { calls = {} }
    e.UIManager = {
        setDirty   = function() e.calls[#e.calls + 1] = "setDirty" end,
        scheduleIn = function(_, _, fn) e.calls[#e.calls + 1] = "scheduleIn"; e.scheduled = fn end,
        unschedule = function() end,
    }
    e.Repo = { currentFilepath = function() return current_fp end }
    e.require = function(name)
        if name == "lib/bookshelf_hero_regions" then return { read = function() return {} end } end
        error("unexpected require " .. tostring(name))
    end
    e.type, e.pairs, e.ipairs, e.tostring = type, pairs, ipairs, tostring
    local fn = assert(load("return function(self)\n"
        .. extract(src, "BookshelfWidget:softRefresh()") .. "\nend",
        "softRefresh", "t", e))
    return e, fn()
end

-- A live, collapsed tree whose hero was built for `hero_fp`.
local function newWidget(hero_fp)
    local calls = {}
    local hero = { replaceRightColumn = true, book = { filepath = hero_fp } }
    local w = {
        _tree_fresh   = nil,
        _inner_vgroup = {}, _shelf_dims = { n_shelves = 2 }, _hero_dims = {},
        _hero_parent  = { hero },
        _hero_card    = hero,
        _nShelves                      = function() return 2 end,
        _refreshDitherFlag             = function() end,
        _rebuild                       = function() calls[#calls + 1] = "rebuild" end,
        _swapHeroRightColumnInPlace    = function() calls[#calls + 1] = "hero"; return true end,
        _swapHeroInPlace               = function() calls[#calls + 1] = "hero_full" end,
        _refreshSpineInPlace           = function() calls[#calls + 1] = "spine" end,
        _needsReaderReturnShelfRefresh = function() return false end,
        _startStatusTimer              = function() calls[#calls + 1] = "timer" end,
        _swapShelvesInPlace            = function() calls[#calls + 1] = "shelves" end,
    }
    return w, calls
end

t.test("same book: the cheap right-column swap still runs", function()
    local _, softRefresh = newEnv("/books/a.epub")
    local w, calls = newWidget("/books/a.epub")
    softRefresh(w)
    eq(calls[1], "hero", "an unchanged hero book must not pay for a cover rebuild")
end)

t.test("a different book: the whole hero is rebuilt, so the cover follows", function()
    local _, softRefresh = newEnv("/books/b.epub")
    local w, calls = newWidget("/books/a.epub")
    softRefresh(w)
    eq(calls[1], "hero_full",
        "the hero stands for a book that is no longer current - its cover is stale")
end)

t.test("a staged preview is what the hero is compared against", function()
    -- _previewBook stages a shelf book in the hero; the right column is
    -- rendered for THAT record, so it is the one the cover has to match.
    local _, softRefresh = newEnv("/books/a.epub")
    local w, calls = newWidget("/books/a.epub")
    w._preview_book = { filepath = "/books/c.epub" }
    softRefresh(w)
    eq(calls[1], "hero_full", "the preview moved the hero off its built book")
end)

t.test("a hero with no book recorded keeps the cheap path", function()
    -- Older trees (and the micro-module grid) carry no book on the hero;
    -- unknown must not mean "rebuild on every tick".
    local _, softRefresh = newEnv("/books/a.epub")
    local w, calls = newWidget(nil)
    softRefresh(w)
    eq(calls[1], "hero", "no recorded book is not evidence of a stale cover")
end)

t.done()
