-- tests/_test_back_label.lua
-- A page's back chevron alone was easy to miss; "Back" beside it where the
-- title leaves room, with padding (maintainer, 2026-10-31).
--
-- Usage (from plugin root): lua tests/_test_back_label.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()
local kit = io.open("lib/bookshelf_popup_kit.lua"):read("*a")
local ed  = io.open("lib/bookshelf_chip_editor.lua"):read("*a")
local lm  = io.open("lib/bookshelf_library_modal.lua"):read("*a")

local function body()
    return assert(kit:match("\nfunction Kit.backLabel%(title_bar%)\n(.-)\nend\n"), "no Kit.backLabel")
end

t.test("the label only where it clears the centred title with padding", function()
    local b = body()
    assert(b:find("if x + lw + gap > title_left then", 1, true), "the label can run into the title")
    assert(b:find('_("Back")', 1, true))
    assert(b:find('getFace("cfont", face.orig_size or 20)', 1, true), "the label is the title's bold")
end)

t.test("a tap on the label goes back, as the chevron does", function()
    assert(body():find("title_bar.left_icon_tap_callback()", 1, true), "the label is not a way back")
end)

t.test("the editor's pages and a picker over it carry it", function()
    assert(ed:find("Kit.backLabel(title_bar)", 1, true), "the editor's pages have no label")
    assert(lm:find("PopupKit.backLabel(bar)", 1, true), "a picker as a page has no label")
end)

t.done()
