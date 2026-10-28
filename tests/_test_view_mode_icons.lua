-- tests/_test_view_mode_icons.lua
-- The View mode card on the editor's front page and the style cards on its
-- page show the same icon for each look (maintainer: the Spines card kept
-- the old library icon).
package.path = "./?.lua;./?/init.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()

local src = io.open("lib/bookshelf_chip_editor.lua"):read("*a")

t.test("the level cards take the View mode card's icons", function()
    local page = src:match("\nfunction Editor:_pickGroupDisplay%(.-\nend\n")
    assert(page, "no _pickGroupDisplay")
    assert(page:find("icon = Editor._modeIcon(style, no_spines)", 1, true),
        "a level card picks its own icon")
end)

t.test("spines: Face out leads, with the book icon", function()
    local b = src:match("\n    local function spinesBlocks%(.-\n    end\n")
    assert(b, "no spinesBlocks")
    local face, rows = b:find('_("Face out")', 1, true), b:find('_("Rows")', 1, true)
    assert(face and rows and face < rows, "Face out is not above Rows")
    assert(b:find('icon = "\\u{E7B9}"', 1, true), "Face out lost its book icon")
end)

t.done()
