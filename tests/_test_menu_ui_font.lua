-- tests/_test_menu_ui_font.lua
-- Bookshelf's menus are in the Bookshelf UI font, all of them (maintainer,
-- 2026-10-31): the kit's headings and buttons were, but the editor pages'
-- cards, several pickers and every title bar took KOReader's font, so a
-- menu mixed two typefaces. KOReader's faces stay only for icon glyphs
-- (symbols) and the font picker's previews of each font.
--
-- Usage (from plugin root): lua tests/_test_menu_ui_font.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()

local MENUS = {
    "lib/bookshelf_editor_page.lua", "lib/bookshelf_chip_editor.lua",
    "lib/bookshelf_ornament_menu.lua", "lib/bookshelf_ornament_browser.lua",
    "lib/bookshelf_reviews_modal.lua", "lib/bookshelf_icons_library.lua",
    "lib/bookshelf_wallpaper_browser.lua", "lib/bookshelf_plank_browser.lua",
    "lib/bookshelf_module_grid_editor.lua", "lib/bookshelf_theme_library.lua",
    "lib/bookshelf_popup_kit.lua", "lib/bookshelf_library_modal.lua",
    "lib/bookshelf_page_dialog.lua", "lib/bookshelf_color_palette.lua",
    "lib/bookshelf_pack_editor.lua", "lib/bookshelf_page_count_dialog.lua",
}

t.test("no menu takes KOReader's text font", function()
    for _i, f in ipairs(MENUS) do
        local s = io.open(f):read("*a")
        for line in s:gmatch("[^\n]+") do
            if line:find("[^B]Font:getFace%(\"cfont\"") or line:find("^Font:getFace%(\"cfont\"")
                    or line:find("getFace%(\"cfont\"") and line:find("ui/font", 1, true) then
                error(f .. ": " .. line)
            end
        end
    end
end)

t.test("every title bar is in the UI font's bold", function()
    for _i, f in ipairs(MENUS) do
        local s = io.open(f):read("*a")
        local pos = 1
        while true do
            local i = s:find("TitleBar:new{", pos, true) or s:find('require("ui/widget/titlebar"):new{', pos, true)
            if not i then break end
            local block = s:sub(i, (s:find("\n%s*}", i)) or #s)
            assert(block:find("title_face", 1, true) and block:find("titleFace()", 1, true),
                f .. ": a title bar in KOReader's font")
            -- And its text in the middle of the bar (centreTitle), not low.
            assert(s:sub(i, i + 1600):find("centreTitle(", 1, true), f .. ": a title sits low in its bar")
            pos = i + 1
        end
    end
end)

t.test("Kit.titleFace is the UI font at KOReader's title size", function()
    local kit = io.open("lib/bookshelf_popup_kit.lua"):read("*a")
    local b = assert(kit:match("\nfunction Kit.titleFace%(%)\n(.-)\nend\n"))
    assert(b:find('getFace("x_smalltfont", 22)', 1, true))
end)

-- KOReader's Button takes its font by name (text_font_face), not a face:
-- the footer's face = ... was never used, so Cancel | Apply stayed in
-- KOReader's font.
t.test("the footer's buttons are in the UI font", function()
    local kit = io.open("lib/bookshelf_popup_kit.lua"):read("*a")
    local f = assert(kit:match("\nfunction Kit.footerRow%(actions, w, o%)\n(.-)\nend\n"))
    assert(f:find("text_font_face = ff.face", 1, true), "the footer's buttons keep KOReader's font")
    assert(not f:find("face = face, bold = bold", 1, true), "Button ignores face and bold")
end)

-- A stock ButtonTable (the shelf editor's Delete | New shelf | Close, the
-- font picker's, the reviews', the page count dialog's) takes its font per
-- button: each table's rows go through Kit.uiFontButtons.
t.test("every button table's buttons are in the UI font", function()
    local files = { "lib/bookshelf_chip_editor.lua", "lib/bookshelf_font_picker.lua",
                    "lib/bookshelf_reviews_modal.lua", "lib/bookshelf_page_count_dialog.lua" }
    for _i, f in ipairs(files) do
        local s = io.open(f):read("*a")
        local pos = 1
        while true do
            local i = s:find("ButtonTable:new{", pos, true) or s:find('require("ui/widget/buttontable"):new{', pos, true)
            if not i then break end
            local block = s:sub(i, i + 400)
            assert(block:find("uiFontButtons", 1, true), f .. ": a button table in KOReader's font")
            pos = i + 1
        end
    end
end)

t.done()
