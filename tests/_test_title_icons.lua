-- tests/_test_title_icons.lua
-- A shelf named with an [icon=NAME] picture showed the markup itself in
-- the shelf editor's title ("Editing shelf: [icon=app_launcher] Home") and
-- its breadcrumbs, where the shelf menu draws the picture (maintainer,
-- PW5, 2026-10-31).
--
-- Usage (from plugin root): lua tests/_test_title_icons.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()
local ed  = io.open("lib/bookshelf_chip_editor.lua"):read("*a")
local lm  = io.open("lib/bookshelf_library_modal.lua"):read("*a")
local kit = io.open("lib/bookshelf_popup_kit.lua"):read("*a")
local cb  = io.open("lib/bookshelf_chip_bar.lua"):read("*a")

t.test("a label builds in a face of the caller's", function()
    assert(cb:find("function ChipBar.buildLabel(label, size, max_w, ink, face)", 1, true),
        "buildLabel draws text in the chips' font only")
    assert(cb:find("_buildLabelContent(label, size, max_w, ink, false, true, face)", 1, true))
end)

t.test("Kit.iconTitle draws a title's pictures, and leaves plain text alone", function()
    local body = assert(kit:match("\nfunction Kit.iconTitle%(title_bar, title%)\n(.-)\nend\n"))
    assert(body:find('title:find("[icon=", 1, true)', 1, true), "every title is rebuilt")
    assert(body:find("buildLabel(title,", 1, true), "the pictures are not drawn")
end)

t.test("the editor's title, its breadcrumbs and a picker's over it use it", function()
    local n = select(2, ed:gsub("Kit.iconTitle%(title_bar, ", ""))
    assert(n >= 2, "the editor's title or breadcrumbs show the markup (" .. n .. ")")
    assert(lm:find("PopupKit.iconTitle(bar, over.crumbs", 1, true), "a picker over the editor shows the markup")
end)

t.done()
