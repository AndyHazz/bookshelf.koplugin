-- tests/_test_list_panel_ink.lua
-- A list on the panel takes the panel's ink, as the hero and the tag pills
-- do. Search results shown as a list on a coloured panel (a theme with
-- Panel text white) had black titles and authors: the rows took the
-- shelf's ink, which is for the page, not the panel (maintainer, PW5).
--
-- Usage (from plugin root): lua tests/_test_list_panel_ink.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()

local src = io.open("lib/bookshelf_widget.lua"):read("*a")

t.test("the rows' ink is the panel's when they sit on one", function()
    local i = src:find("LR.setTheme(", 1, true)
    assert(i, "the rows are not themed")
    local block = src:sub(i - 900, i + 80)
    assert(block:find("CP.panelInk", 1, true), "the rows ignore the panel's ink")
    assert(block:find("LR.setTheme(colors.panel_bg, row_ink)", 1, true), "the rows still take the page's ink")
end)

t.done()
