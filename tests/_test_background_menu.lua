-- tests/_test_background_menu.lua
-- "Background and colors" is one top-level menu, not three scattered rows.
--
-- WHAT NEEDS PINNING. The theme lived under Settings > Colors, the background
-- colour and the panel shading under Settings > Wallpaper and ornaments, and
-- the wallpaper picture beside them. Three settings that are only ever chosen
-- together, in two menus two levels down, reading as unrelated (maintainer:
-- "I'm a bit concerned about how we have colour theme, background colour,
-- panel shading in separate menus").
--
-- They are now one row at the TOP level, before Settings. The name is
-- deliberately narrow: "Appearance" would have dragged the text size menu in
-- after it, and then everything else ("that feels a bit of a slippery
-- slope"), so text size stays where it is and this test says so.
--
-- The theme row has ONE definition. It was lifted out of the colour list, and
-- a copy left behind would drift.
--
-- Usage (from plugin root): lua tests/_test_background_menu.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq
local main     = io.open("main.lua"):read("*a")
local settings = io.open("lib/bookshelf_settings.lua"):read("*a")

t.test("it is a top-level row, sitting before Settings", function()
    local order = main:match("Bookshelf%.MENU_ORDER = {(.-)\n}")
    assert(order, "MENU_ORDER moved or was renamed")
    local bg  = order:find('"bookshelf_background"', 1, true)
    local set = order:find('"bookshelf_settings"', 1, true)
    assert(bg, "the new menu is not in the canonical order, so the start "
        .. "menu's Bookshelf action would not host it either")
    assert(set and bg < set, "it belongs before Settings, not after")
end)

t.test("the row is registered, with the maintainer's name", function()
    local row = main:match("(menu_items%.bookshelf_background = {.-\n    }\n)")
    assert(row, "menu_items.bookshelf_background missing")
    assert(row:find('_("Background and colors")', 1, true), "the label changed")
    assert(row:find("_backgroundSubItems", 1, true), "it must build the new menu")
    assert(row:find("S._bw = _live_widget", 1, true),
        "every menu that can repaint the shelf hands the live widget over first")
end)

t.test("Settings no longer carries Colors or Wallpaper", function()
    local sub = settings:match("function Settings:_settingsSubItems%(%)(.-)\nend\n")
    assert(sub, "_settingsSubItems moved or was renamed")
    assert(not sub:find('text                = _("Colors")', 1, true),
        "the colour list is still under Settings as well")
    assert(not sub:find('_("Wallpaper and ornaments")', 1, true),
        "the wallpaper menu is still under Settings as well")
    -- The slippery-slope ruling: text size did NOT move.
    assert(sub:find('_("Text size")', 1, true),
        "text size belongs under Settings; a menu broad enough to hold it "
        .. "would eventually hold everything")
end)

t.test("the new menu is theme, then background, then ornaments, then accents", function()
    local body = settings:match("function Settings:_backgroundSubItems%(%)(.-)\nend\n")
    assert(body, "_backgroundSubItems missing")
    local theme  = body:find("_shelfThemeRow", 1, true)
    local wall   = body:find("_wallpaperMenu", 1, true)
    local orn    = body:find("_ornamentsRow", 1, true)
    local accent = body:find('_("Accent colors")', 1, true)
    assert(theme and wall and orn and accent, "a section is missing from the menu")
    assert(theme < wall, "the theme is the first choice, above the background")
    assert(wall < orn, "ornaments close the group, after the picture")
    assert(orn < accent, "the accent list is last: it is a reference list")
end)

t.test("the theme row has one definition, not a copy in the colour list", function()
    assert(settings:find("function Settings:_shelfThemeRow()", 1, true),
        "the theme row builder is missing")
    local colours = settings:match("function Settings:_colorsSubItems%(%)(.-)\nend\n")
    assert(colours, "_colorsSubItems moved or was renamed")
    assert(not colours:find("_shelfThemeLabel", 1, true),
        "the theme row was left behind in the colour list as well; two copies drift")
end)

t.test("the ornaments row points at the folder and at the per-shelf control", function()
    local row = settings:match("function Settings:_ornamentsRow%(%)(.-)\nend\n")
    assert(row, "_ornamentsRow missing")
    assert(row:find("O.dir", 1, true), "it must name the folder, which nothing else does")
    assert(row:find("Shelf style", 1, true),
        "frequency is a per-shelf pin now, so this row has to say where it lives")
    assert(not row:find("ornament_frequency", 1, true),
        "no library-wide frequency: a default behind every shelf's pin is a trap")
end)

t.test("the accent list is banded, so it does not read as one long run", function()
    -- "Lengthy jumble" (maintainer). Eighteen colour rows with no seam in
    -- them is unscannable; the order already pairs sensibly, so what it
    -- needed was the dividers between the pairs.
    local body = settings:match("function Settings:_colorsSubItems%(%)(.-)\nend\n")
    assert(body, "_colorsSubItems moved or was renamed")
    -- Count rows and the bands they fall into, by walking the list in order.
    local rows, bands, run = 0, 1, 0
    for line in body:gmatch("[^\n]+") do
        if line:find("valueLabel(", 1, true) and line:find("return ", 1, true) then
            rows, run = rows + 1, run + 1
        elseif line:find("separator = true", 1, true) and run > 0 then
            bands, run = bands + 1, 0
        end
    end
    assert(rows > 12, "expected the full colour list, counted " .. rows)
    assert(bands >= 7,
        "the colour rows fall into " .. bands .. " bands; they were banded to "
        .. "stop the list reading as one undifferentiated run")
end)

t.test("the text ink is offered, first, and it is the palette's own key", function()
    -- The palette has carried an `ink` entry since the dark theme shipped --
    -- a dark look on a device that is not inverting needs white PAINT, and
    -- only a palette entry can be flipped -- but nothing exposed it.
    local body = settings:match("function Settings:_colorsSubItems%(%)(.-)\nend\n")
    assert(body, "_colorsSubItems moved or was renamed")
    assert(body:find('valueLabel("ink")', 1, true), "no Text ink row")
    assert(body:find('pickColor("ink_color", "ink"', 1, true),
        "the row must write the palette's own key, or it edits nothing")
    -- Its default comes from the same helper the value does. Written as a
    -- number it would need to be 100 by day and 0 at night, and one of the
    -- two would be wrong.
    assert(body:find("pickColor(\"ink_color\", \"ink\", _byteToScreenPct(0x00)", 1, true),
        "the ink default is hardcoded; it differs by mode")
    local ink  = body:find('valueLabel("ink")', 1, true)
    local fill = body:find('valueLabel("fill")', 1, true)
    assert(ink and fill and ink < fill, "ink is the colour the rest are read against; it leads")
end)

t.test("every reset row carries the icon", function()
    -- Not only the one that was asked for. The glyph itself, and the rule
    -- that keeps it inside the Private Use Area, are pinned in
    -- _test_menu_icons.lua against the shared table both files read.
    local n = select(2, settings:gsub("ICON_RESET %.%.", ""))
    assert(n >= 4, "only " .. n .. " reset rows carry the icon")
    assert(settings:find("MenuIcons.RESET", 1, true),
        "the glyph should come from the shared table, not a second copy")
end)

t.done()
