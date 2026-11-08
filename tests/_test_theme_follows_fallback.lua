-- tests/_test_theme_follows_fallback.lua
-- When a rebuild lands on another shelf than the one it set out to build,
-- the shelf's theme follows it.
--
-- _rebuild syncs the theme (bookshelf_theme_pack, per shelf) first, from
-- self.chip; two later steps can change self.chip: the shelf on screen
-- disabled or deleted falls back to the first one left, and going home
-- leaves a shelf of shelves for its top-level shelf. Without a sync after
-- them the shelf shown wore the old one's theme -- a deleted shelf's
-- "plain": Home without its wallpaper on a PW5 -- until the next switch.
package.path = "./?.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t = H.runner()
local W = io.open("lib/bookshelf_widget.lua"):read("*a")
local rb = assert(W:match("\nfunction BookshelfWidget:_rebuild%(%)\n(.-)\nend\n"), "_rebuild moved")

t.test("the fallback to the first shelf left syncs the theme again", function()
    local i = assert(rb:find("self.chip = active_chips[1].key", 1, true))
    local j = assert(rb:find('BookshelfSettings.saveDeferred("active_chip", self.chip)', i, true))
    local block = rb:sub(i, j + 200)
    assert(block:find("self:_syncShelfTheme()", 1, true), "the shelf fallen back to wears the gone shelf's theme")
end)

t.test("going home out of a shelf of shelves syncs it too", function()
    local i = assert(rb:find('self.chip = require("lib/bookshelf_tab_model").rootOf(self.chip)', 1, true))
    assert(rb:sub(i, i + 200):find("self:_syncShelfTheme()", 1, true), "home wears the sub-shelf's theme")
end)

t.done()
