-- tests/_test_soft_refresh_fresh_tree.lua
-- A warm show() of a shelf whose tree was built since a book last sat over
-- it repaints nothing (issue 408).
--
-- WHAT NEEDS PINNING. Both the cold boot and the return from a book reach
-- Bookshelf:show() twice: onShow catches the file manager's Show and builds
-- the shelf, and the next-tick fallbacks (_takeOver, onCloseDocument's
-- re-show) find it live and take the warm branch. Their comments call that
-- "a no-op via show()'s idempotency check". It was not: the warm branch ran
-- softRefresh unconditionally - a hero-column swap, a spine repaint and a
-- deferred shelf swap, three partial refreshes of a tree built milliseconds
-- earlier. Painting identical pixels drives nothing on most panels, so
-- nobody saw them; once v5.0.8 tagged every shelf refresh dithered a Kobo
-- Libra 2 showed them as an extra refresh after a restart and after a book.
--
-- Usage (from plugin root): lua tests/_test_soft_refresh_fresh_tree.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq
local src  = io.open("lib/bookshelf_widget.lua"):read("*a")
local main = io.open("main.lua"):read("*a")

-- Pull one method out by name: the body runs to the first `end` at column 0.
local function extract(source, name)
    local pat = "\nfunction " .. name:gsub("[%.%(%)]", "%%%0") .. "\n(.-)\nend\n"
    local body = source:match(pat)
    assert(body, name .. " not found")
    return (body:gsub("%-%-[^\n]*", ""))
end

local function loadSoftRefresh(env)
    env.require = function(name)
        if name == "lib/bookshelf_hero_regions" then return { read = function() return {} end } end
        error("unexpected require " .. tostring(name))
    end
    local fn, err = load("return function(self)\n" .. extract(src, "BookshelfWidget:softRefresh()") .. "\nend",
        "softRefresh", "t", env)
    assert(fn, err)
    return fn()
end

local function newEnv()
    local e = { calls = {} }
    e.UIManager = {
        setDirty   = function() e.calls[#e.calls + 1] = "setDirty" end,
        scheduleIn = function(_, _, fn) e.calls[#e.calls + 1] = "scheduleIn"; e.scheduled = fn end,
        unschedule = function() end,
    }
    e.Repo = { currentFilepath = function() return "/books/a.epub" end }
    e.type, e.pairs, e.ipairs, e.tostring = type, pairs, ipairs, tostring
    return e
end

-- A live, collapsed, two-row tree with a hero card that can swap its column.
local function newWidget(fresh)
    local calls = {}
    local w = {
        _tree_fresh   = fresh,
        _inner_vgroup = {}, _shelf_dims = { n_shelves = 2 }, _hero_dims = {},
        _hero_parent  = { { replaceRightColumn = true } },
        _hero_card    = { replaceRightColumn = true },
        _nShelves                      = function() return 2 end,
        _rebuild                       = function() calls[#calls + 1] = "rebuild" end,
        _swapHeroRightColumnInPlace    = function() calls[#calls + 1] = "hero"; return true end,
        _swapHeroInPlace               = function() calls[#calls + 1] = "hero_full" end,
        _refreshSpineInPlace           = function() calls[#calls + 1] = "spine" end,
        _needsReaderReturnShelfRefresh = function() return true end,
        _startStatusTimer              = function() calls[#calls + 1] = "timer" end,
        _swapShelvesInPlace            = function() calls[#calls + 1] = "shelves" end,
    }
    return w, calls
end

t.test("a fresh tree: the warm show paints nothing and schedules nothing", function()
    local e = newEnv()
    local softRefresh = loadSoftRefresh(e)
    local w, calls = newWidget(true)
    softRefresh(w)
    eq(table.concat(e.calls, ","), "", "no refresh expected")
    eq(table.concat(calls, ","), "", "no swaps expected")
end)

t.test("a tree a book sat over still gets the hero swap, spine repaint and deferred shelf swap", function()
    local e = newEnv()
    local softRefresh = loadSoftRefresh(e)
    local w, calls = newWidget(nil)
    softRefresh(w)
    eq(table.concat(calls, ","), "hero,timer,spine")
    eq(table.concat(e.calls, ","), "scheduleIn")
    e.scheduled()
    eq(calls[#calls], "shelves")
end)

t.test("metadata edited while hidden still forces the rebuild, fresh or not", function()
    local e = newEnv()
    local softRefresh = loadSoftRefresh(e)
    local w, calls = newWidget(true)
    w._metadata_dirty_force_full_refresh = true
    softRefresh(w)
    eq(calls[1], "rebuild")
    eq(e.calls[1], "setDirty")
end)

t.test("_rebuild marks the tree it builds as fresh", function()
    local body = extract(src, "BookshelfWidget:_rebuild()")
    assert(body:find("self._tree_fresh = true", 1, true), "_rebuild must set _tree_fresh")
end)

t.test("a reader opening over the shelf, or a book closing under it, ends the freshness", function()
    assert(extract(main, "Bookshelf:onShowingReader()"):find("_tree_fresh = nil", 1, true),
        "onShowingReader must clear _tree_fresh")
    assert(extract(main, "Bookshelf:onCloseDocument()"):find("_tree_fresh = nil", 1, true),
        "onCloseDocument must clear _tree_fresh")
end)

t.done()
