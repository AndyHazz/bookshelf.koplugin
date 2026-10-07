-- tests/_test_source_folder_tiles.lua
-- Issue 452 (kokomga port): a registered source's folders drew as OPDS
-- catalogue tiles, which are forced to the text style and carry no badge, so
-- a Komga series showed neither its cover nor its counts. The guide promised
-- both. A source folder now takes the shelf's folder style when it has a
-- cover, and its badge numbers from the record; OPDS tiles are unchanged.
-- Run from the plugin root: lua tests/_test_source_folder_tiles.lua
package.path = "./?.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()
local src = io.open("lib/bookshelf_shelf_row.lua"):read("*a")
local nav = src:match('elseif item and item.kind == "opds_nav" then(.-)elseif item and item.kind == "author"')

t.test("a source folder with a cover uses the shelf's folder style", function()
    assert(nav, "the nav tile branch moved")
    assert(nav:find("item.source_nav", 1, true), "source folders are not told apart from OPDS links")
    assert(nav:find("nav_mode", 1, true) and not nav:find("display_mode = StackDisplay.TEXT,", 1, true),
        "the display mode is still hard-coded to text for every nav tile")
end)

t.test("a source folder's badge comes from its record", function()
    for _i, f in ipairs({ "book_count", "finished_count", "finished_total" }) do
        assert(nav:find("item." .. f, 1, true), "the record's " .. f .. " is not passed to the tile")
    end
end)

t.done()
