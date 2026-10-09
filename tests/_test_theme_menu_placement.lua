-- tests/_test_theme_menu_placement.lua
-- The look of the shelf is one top-level menu, not three scattered rows: since
-- 2026-10-09 the Theme menu, which chooses themes and edits the one on screen.
-- Where it sits and what it is named; its rows are _test_shelf_theme_menu.lua.
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
-- Usage (from plugin root): lua tests/_test_theme_menu_placement.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq
local main     = io.open("main.lua"):read("*a")
local settings = io.open("lib/bookshelf_settings.lua"):read("*a")
local menu     = io.open("lib/bookshelf_theme_menu.lua"):read("*a")

t.test("it is a top-level row, sitting before Settings", function()
    local order = main:match("Bookshelf%.MENU_ORDER = {(.-)\n}")
    assert(order, "MENU_ORDER moved or was renamed")
    local th  = order:find('"bookshelf_theme"', 1, true)
    local set = order:find('"bookshelf_settings"', 1, true)
    assert(th, "the Theme menu is not in the canonical order, so the start "
        .. "menu's Bookshelf action would not host it either")
    assert(set and th < set, "it belongs before Settings, not after")
    -- ONE theme menu (maintainer, 2026-10-09): the My theme menu that edited
    -- the look is part of it, not a second row beside it.
    assert(not order:find('"bookshelf_background"', 1, true), "the separate editing menu is back in the order")
    assert(not main:find("menu_items.bookshelf_background", 1, true), "the separate editing menu is back")
end)

t.test("the row is named for the theme it edits, by a template, and the reader's own by the one name", function()
    local row = main:match("(menu_items%.bookshelf_theme = {.-\n    }\n)")
    assert(row, "menu_items.bookshelf_theme missing")
    assert(row:find("ThemeMenu.menuText()", 1, true), "the row does not take its label from menuText")
    -- "Theme (Macabre)", as Bookends' "Preset (Name)": a whole msgid with a
    -- slot, so a translation can move the name, not "Theme" .. " (" .. name.
    local text = menu:match("\nfunction M%.menuText%(%)\n(.-)\nend\n")
    assert(text, "menuText missing")
    assert(text:find('T(_("Theme (%1)"), require("lib/bookshelf_theme_pack").editName())', 1, true),
        "the label is not the Theme (%1) template over the theme on screen")
    assert(not text:find("..", 1, true), "the label is built by concatenation")
    -- The name of the reader's own lives in ONE place (TP.mineName), so it
    -- can be renamed with a one-line change (maintainer, 2026-10-07).
    local tp = io.open("lib/bookshelf_theme_pack.lua"):read("*a")
    assert(tp:find('function M.mineName() return _("Custom theme") end', 1, true), "the name changed")
    assert(tp:find("function M.editName() return M.themeName(M.shelfTheme()) end", 1, true),
        "editName does not name the theme on screen")
    local tn = tp:match("\nfunction M%.themeName%(choice%)\n(.-)\nend\n")
    assert(tn and tn:find("if choice == nil or choice == M.MINE then return M.mineName() end", 1, true),
        "the reader's own is not named by the one name")
    local n = 0
    for _ in (settings .. menu .. main):gmatch('_%("Custom theme"%)') do n = n + 1 end
    eq(n, 0, "the name is spelled out somewhere other than TP.mineName")
    assert(row:find("ThemeMenu.items(S)", 1, true), "it must build the merged menu")
    assert(row:find("MenuIcons.THEME", 1, true), "the row's glyph is not THEME")
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

t.test("the extra wallpaper folder is in Settings' appearance band; the panel rows are not", function()
    -- The row order of the Theme menu is pinned by its behaviour in
    -- _test_shelf_theme_menu.lua.
    local body = menu:match("function M%.items%(S%)(.-)\nend\n")
    assert(body, "items missing")
    assert(not body:find("_wallpaperMenu", 1, true), "the wallpaper rows are flat in the Theme menu again")
    -- The panel rows are part of the theme (2026-10-09), inside its
    -- Wallpaper submenu, so the Theme menu itself still fits one PW5 page.
    assert(not body:find("_panelRows", 1, true) and not body:find("_wallpaperFolderRow", 1, true),
        "the panel rows or the extra wallpaper folder are flat in the Theme menu")
    local sub = settings:match("function Settings:_settingsSubItems%(%)(.-)\nend\n")
    assert(sub, "_settingsSubItems moved")
    -- Comments out: one may tell where the rows went.
    local code = sub:gsub("%-%-[^\n]*", "")
    for _i, name in ipairs({ "_panelRows", "_panelShadingRow", "_scrimSubItems",
                             "Panel shading", "Blur wallpaper behind panels", "Panel behind Covers shelves" }) do
        assert(not code:find(name, 1, true), "Settings still lists " .. name)
    end
    local font = sub:find("Bookshelf UI font: %1", 1, true)
    local folder = sub:find("self:_wallpaperFolderRow()", 1, true)
    local band = sub:find("-- end appearance band", 1, true)
    assert(font and folder and band and font < folder and folder < band,
        "the extra wallpaper folder belongs at the end of Settings' appearance band")
end)

t.test("Wallpaper is a submenu named for the picture: the picture, full screen, invert, the colour behind", function()
    -- Maintainer, 2026-10-09: one row, "Wallpaper: Macabre pack", so the
    -- Theme menu fits one page; inside, the rows it held, as they were.
    local code = settings:match("\n(function Settings:_wallpaperRow%(%).-\nend)\n")
    assert(code, "_wallpaperRow missing")
    local MI = dofile("lib/bookshelf_menu_icons.lua")
    local env = setmetatable({ Settings = {}, MenuIcons = MI }, { __index = _G })
    local chunk = assert((loadstring or load)(code, "=w", "t", env))
    if setfenv then setfenv(chunk, env) end
    chunk()
    local built = 0
    local inner = function()
        built = built + 1
        return { { text_func = function() return "Wallpaper: Macabre pack" end, help_text_func = function() return "from" end },
                 { text = "Full" }, { text = "Invert" }, { text = "Behind" } }
    end
    local self = { _wallpaperMenu = inner }
    local row = env.Settings._wallpaperRow(self)
    -- With the icon the Theme library's cards show for a wallpaper.
    eq(row.text_func(), MI.label(MI.WALLPAPER, "Wallpaper: Macabre pack"), "the row is not named for the picture")
    eq(row.help_text_func(), "from", "the row's help is not where the pictures come from")
    eq(row.callback, nil, "the row opens a picker, not its submenu")
    local before = built
    local sub = row.sub_item_table_func()
    eq(#sub, 4); eq(built, before + 1, "the submenu is not built as it opens")
    -- The rows themselves, in order, each still wired as before.
    local menu = settings:match("function Settings:_wallpaperMenu%(%)(.-)\nend\n")
    local a = menu:find('T(_("Wallpaper: %1")', 1, true)
    local b = menu:find('T(_("Full screen wallpaper: %1")', 1, true)
    local c = menu:find('text = _("Invert wallpaper when dark")', 1, true)
    local d = menu:find('T(_("Color behind wallpaper: %1")', 1, true)
    local e = menu:find("self:_panelRows()", 1, true)
    assert(a and b and c and d and a < b and b < c and c < d,
        "the submenu is not the picture, full screen, invert, the colour behind")
    -- Then the panels over the picture, part of the theme (2026-10-09).
    assert(e and d < e, "the panel rows do not end the Wallpaper submenu")
end)

t.test("the theme label has one definition, not a copy in the colour list", function()
    assert(menu:find("function M.menuText()", 1, true), "the theme label builder is missing")
    assert(main:find("ThemeMenu.menuText()", 1, true), "the top-level row builds its own label")
    local colours = settings:match("function Settings:_colorsSubItems%(%)(.-)\nend\n")
    assert(colours, "_colorsSubItems moved or was renamed")
    assert(not colours:find("_lightDarkLabel", 1, true),
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
