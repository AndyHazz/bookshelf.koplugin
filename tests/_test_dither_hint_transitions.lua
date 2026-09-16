-- tests/_test_dither_hint_transitions.lua
-- The shelf drops its dither hint while a book opens over it and has it back
-- before the book's closing refresh, the way KOReader's file browser and
-- reader handle their own flag.
--
-- WHAT NEEDS PINNING. UIManager treats a widget's `dithered` flag as viral:
-- setDirty("all"), a close that leaves the widget underneath, and any repaint
-- that includes it tag the whole refresh queue. FileManager:onShowingReader
-- and ReaderUI:onShowingReader clear their own flag first ("to prevent it
-- from infecting the queue"), so a book's first page never paints through
-- the cover browser's hint. Ours stayed set for the life of the widget, so a
-- book opened over the shelf painted its first page dithered (rig log during
-- the open: "setDirty on all widgets: found a dithered widget, infecting the
-- refresh queue"). The hint must be back before the close's full refresh
-- executes, or covers return undithered on the panels it exists for (the
-- Boox Go 6 report behind b735a34): ReaderUI:onClose handles CloseDocument
-- before UIManager:close(reader, "full"), so that is where it goes back on.
--
-- Usage (from plugin root): lua tests/_test_dither_hint_transitions.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq
local src  = io.open("lib/bookshelf_widget.lua"):read("*a")
local main = io.open("main.lua"):read("*a")

local function extract(source, name)
    local pat = "\nfunction " .. name:gsub("[%.%(%)]", "%%%0") .. "\n(.-)\nend\n"
    local body = source:match(pat)
    assert(body, name .. " not found")
    return (body:gsub("%-%-[^\n]*", ""))
end

t.test("a book opening over the shelf takes the hint off the live widget", function()
    local live = { dithered = true, _tree_fresh = true }
    local env = {
        _live_widget = live,
        UIManager = { isWidgetShown = function() return true end, scheduleIn = function() end },
    }
    local fn, err = load("return function(self)\n" .. extract(main, "Bookshelf:onShowingReader()") .. "\nend",
        "onShowingReader", "t", env)
    assert(fn, err)
    fn()({})
    eq(live.dithered, nil, "dithered must be cleared while the reader opens")
    eq(live._suppress_transition_paint, true, "the transition-paint guard still arms")
end)

t.test("the close handler puts the hint back before scheduling anything", function()
    local body = extract(main, "Bookshelf:onCloseDocument()")
    local restore = body:find("_live_widget:_refreshDitherFlag()", 1, true)
    assert(restore, "onCloseDocument must call _refreshDitherFlag on the live widget")
    local first_return = body:find("\n%s*return\n")
    assert(first_return and restore < first_return, "the restore must precede the first early return")
end)

t.test("a warm show re-reads the hint even when the tree is fresh", function()
    local body = extract(src, "BookshelfWidget:softRefresh()")
    local restore = body:find("self:_refreshDitherFlag()", 1, true)
    local gate    = body:find("if self._tree_fresh then return end", 1, true)
    assert(restore, "softRefresh must call _refreshDitherFlag")
    assert(gate and restore < gate, "the hint must be re-read before the fresh-tree return")
end)

t.test("an unpark is a reader opening over the shelf with no broadcast: both marks go there too", function()
    local park = io.open("lib/bookshelf_reader_park.lua"):read("*a")
    local body = extract(park, "Park.unpark(live_widget, after_open_callback)")
    assert(body:find("live_widget._tree_fresh = nil", 1, true), "unpark must end the tree's freshness")
    assert(body:find("live_widget.dithered = nil", 1, true), "unpark must drop the dither hint")
end)

t.test("_refreshDitherFlag is still the single reader of the setting", function()
    assert(src:find("\nfunction BookshelfWidget:_refreshDitherFlag()\n", 1, true))
    local n = select(2, src:gsub('nilOrTrue%("color_panel_dithering"%)', ""))
    eq(n, 1, "expected one reader of color_panel_dithering in the widget, found " .. n)
end)

t.done()
