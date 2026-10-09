-- lib/bookshelf_theme_menu.lua
-- The Theme menu: choosing themes, and the menu's assembly.
--
-- The default theme (library_theme: Custom theme, Plain, or a pack) is what
-- every shelf without one of its own wears, and each shelf may wear its own
-- (tab.theme, unset = the default). Choosing one writes that one key and
-- nothing else: a theme is a layer over the reader's own look, never written
-- into it (maintainer, 2026-10-07; bookshelf_theme_pack). Every theme is
-- chosen in the Theme library (bookshelf_theme_library).
--
-- THE BOUNDARY. This module owns the choosing rows (This shelf, Other
-- shelves and each shelf's row, Default theme), opening the Theme library
-- for them, and the order of the whole menu. The rows that EDIT the theme on
-- screen (light or dark, the wallpaper, the plank, the ornaments, the
-- colours) stay in bookshelf_settings beside the colour pickers and dialogs
-- they share with the rest of Settings; items(S) asks the Settings instance
-- S for them, and for its menu plumbing (S._bw, the shelf on screen;
-- _hidePickerMenu, _reopenSubMenu, _markDirty).
local ok_i, I18n = pcall(require, "lib/bookshelf_i18n")
local _ = (ok_i and I18n and I18n.gettext) or function(s) return s end
local ok_u, FUtil = pcall(require, "ffi/util")
local T = (ok_u and FUtil and FUtil.template) or function(f, ...)
    local args = { ... }
    return (f:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
end

local M = {}

-- The Theme menu, ONE top-level menu named for the theme of the shelf on
-- screen, "Theme (Macabre)" (maintainer, 2026-10-09, after Bookends' "Preset
-- (Name)"): it replaced a Theme menu that chose themes and a My theme menu
-- that edited them. First the choosing, as Bookends opens with "Preset
-- library...": This shelf, the Theme library for the shelf on screen, Other
-- shelves, then Default theme, the one every shelf without its own wears.
-- Then the rows that edit the theme on screen, whatever it is, all of the
-- menu on the first page of a PW5 menu: everything a theme can replace
-- (never greyed because a theme has that part, spec 2026-10-08), then the
-- collection's own New ornaments go (Reset is in the Theme library). The
-- other shelves' themes are a level down, under Other shelves below This
-- shelf, so it all fits one page (maintainer, 2026-10-09; they were flat at
-- the end, 2026-10-07). Every write goes through bookshelf_theme_pack's seam
-- (partSave, choosePlank, switches); nothing but these rows writes the
-- reader's own look (maintainer, 2026-10-07). Built each time it opens and
-- each time a Theme library opened from it closes, after a rescan, so a pack
-- copied in since start-up is listed and the rows follow the shelf.
--
-- Text size stays under Settings. A name broad enough to pull that in would
-- pull in everything eventually ("that feels a bit of a slippery slope").
function M.items(S)
    -- The colour menu opens on the slot the shelf on screen paints from.
    S:_shelfSlot()
    local TP = require("lib/bookshelf_theme_pack")
    TP.rescan()
    local rows = {}
    -- No shelf on screen (the menu opened elsewhere): no This shelf row,
    -- rather than one named for a shelf that opens the default's picker.
    if M.shelfOnScreen(S) then rows[#rows + 1] = M.thisShelfRow(S) end
    rows[#rows + 1] = M.otherShelvesRow(S)
    rows[#rows + 1] = M.defaultRow(S)
    rows[#rows].separator = true
    rows[#rows + 1] = S:_lightDarkRow()
    rows[#rows + 1] = S:_wallpaperRow()
    rows[#rows + 1] = S:_plankRow()
    rows[#rows + 1] = S:_ornamentsRow()
    rows[#rows + 1] = {
        -- The long list of colours (text, progress bar, bookmarks, badges)
        -- keeps a level of its own: a reference list people visit once.
        -- The icon a Theme library card shows for a theme's colours.
        text                = require("lib/bookshelf_menu_icons").label(
            require("lib/bookshelf_menu_icons").COLORS, _("Colors")),
        sub_item_table_func = function()
            return S:_colorsSubItems()
        end,
    }
    rows[#rows].separator = true
    -- How new ornaments join the deck: the collection's own preference.
    -- The extra wallpaper folder is a display preference no theme touches:
    -- it lives in Settings' appearance band. Panel shading and the other
    -- panel rows are part of the theme, in the Wallpaper submenu
    -- (2026-10-09). Reset to original is not a row here: it is in the Theme
    -- library's footer, with the themes (maintainer, 2026-10-09).
    rows[#rows + 1] = S:_newOrnamentsRow()
    return rows
end

-- menuText() / menuHelp(): the top-level row's label and help (main.lua
-- bookshelf_theme), named for the theme of the shelf on screen, which its
-- rows edit (TP.editName): "Theme (Custom theme)", "Theme (Plain)", "Theme
-- (Macabre)".
function M.menuText()
    return T(_("Theme (%1)"), require("lib/bookshelf_theme_pack").editName())
end

function M.menuHelp()
    local mine = require("lib/bookshelf_theme_pack").mineName()
    return T(_("A theme can bring a wallpaper, a plank, colors, light or "
            .. "dark, and ornaments. Anything it does not bring comes from "
            .. "%1. Choosing a theme never changes %1.\n\nThe rows here edit "
            .. "the theme of the shelf on screen. Your changes stay with that "
            .. "theme wherever it shows, and Reset in the Theme library brings "
            .. "back its original.\n\n"
            .. "Each shelf can have a theme of its own: choose it here, or "
            .. "long-press a shelf chip, then Shelf style."), mine)
end

-- shelfOnScreen(S): the shelf whose theme the Theme menu is about:
-- the shelf on screen, or its shelf of shelves for a sub-shelf (which wears
-- that one's theme); nil without a shelf on screen.
function M.shelfOnScreen(S)
    local chip = S._bw and S._bw.chip
    if not chip then return nil end
    local ok, TabModel = pcall(require, "lib/bookshelf_tab_model")
    return (ok and TabModel and TabModel.rootOf) and TabModel.rootOf(chip) or chip
end

-- thisShelfRow(S): the Theme menu's first row, "This shelf: Macabre": the
-- Theme library for the shelf on screen, as Bookends' Preset menu opens with
-- the preset library above the tweaks saved into the preset (maintainer,
-- 2026-10-09). Named for what it sets, as the Default theme row below it is
-- (maintainer, 2026-10-09: "Theme library..." and "Library: My theme" opened
-- the same picker and could not be told apart). It names the shelf's own
-- choice as that shelf's row under Other shelves does, "Default theme" while
-- it follows the default (maintainer, 2026-10-09: not a bare "Default"),
-- whose card is then the one marked. A sub-shelf wears its shelf of
-- shelves' theme, so the row is that shelf's. Only with a shelf on screen
-- (items).
function M.thisShelfRow(S)
    local function shelfOnScreen() return M.shelfOnScreen(S) end
    return {
        text_func = function()
            local id = shelfOnScreen()
            local TP = require("lib/bookshelf_theme_pack")
            local own = id and TP.ownChoice(id)
            return T(_("This shelf: %1"), TP.choiceLabel(own))
        end,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            M.openLibrary(S, shelfOnScreen(), touchmenu_instance, M.rebuildAfter(S, touchmenu_instance))
        end,
    }
end

-- otherShelvesRow(S): "Other shelves: 2 with own themes", right below This
-- shelf: every other shelf's theme, a level down so the Theme menu fits one
-- page now that it holds the editing rows (maintainer, 2026-10-09; it was
-- flat, 2026-10-07, when it held only shelves). Named for how many have a
-- theme of their own rather than the default, "all default" when none.
-- Greyed with no other shelf. The shelf on screen is not counted or listed:
-- This shelf is its row.
function M.otherShelvesRow(S)
    local TabModel = require("lib/bookshelf_tab_model")
    local TP = require("lib/bookshelf_theme_pack")
    local function others()
        local skip, out = M.shelfOnScreen(S), {}
        for _i, t in ipairs(TabModel.getActive() or {}) do
            if t.id ~= skip then out[#out + 1] = t end
        end
        return out
    end
    return {
        text_func = function()
            local n = 0
            for _i, t in ipairs(others()) do
                if TP.ownChoice(t.id) ~= nil then n = n + 1 end
            end
            -- Two msgids, one and many: the plugin's
            -- translations have no plural forms.
            if n == 0 then return _("Other shelves: all default") end
            if n == 1 then return _("Other shelves: 1 with own theme") end
            return T(_("Other shelves: %1 with own themes"), n)
        end,
        enabled_func = function() return #others() > 0 end,
        sub_item_table_func = function()
            return M.shelfRows(S, M.shelfOnScreen(S))
        end,
    }
end

-- shelfRows(S, skip): a row per enabled shelf but skip (the shelf
-- on screen, which This shelf sets), "Home: Default theme" or "Manga:
-- Ukiyo-e", each opening that shelf's Theme library. Other shelves' rows.
function M.shelfRows(S, skip)
    local TabModel = require("lib/bookshelf_tab_model")
    local items = {}
    for _i, t in ipairs(TabModel.getActive() or {}) do
        local id = t.id
        if id ~= skip then
            items[#items + 1] = {
                text_func = function()
                    return M.shelfLabel(TabModel.getById(id) or t)
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    -- That shelf behind the picker, so a change is seen as it
                    -- is made; it stays on screen after (maintainer,
                    -- 2026-10-04), and the Theme menu's rows then edit its
                    -- theme. This list keeps the shelves it opened with: the
                    -- one just shown stays in it, rather than the rows moving
                    -- under the finger; the menu comes back with their names
                    -- refreshed.
                    local bw = S._bw
                    if bw and bw.chip ~= id and bw._setActiveChip then bw:_setActiveChip(id) end
                    M.openLibrary(S, id, touchmenu_instance)
                end,
            }
        end
    end
    return items
end

-- shelfLabel(tab): "Home: Default theme", or "Manga: Ukiyo-e".
-- The choice is named as Shelf style names it, capital and all, like every
-- other value after a colon here ("Wallpaper: Leafy"). Following the default
-- reads "Default theme", as the picker's card does: never "library", which
-- is the Theme library's name, nor a bare "Default" (maintainer,
-- 2026-10-09).
function M.shelfLabel(tab)
    local TP = require("lib/bookshelf_theme_pack")
    local label = tab.label or tab.id
    -- What the shelf is set to as the count and This shelf read it: a
    -- stored value that is no theme (a reserved name) is Default theme.
    return T(_("%1: %2"), label, TP.choiceLabel(TP.ownChoice(tab.id)))
end

-- defaultRow(S): "Default theme: Macabre": the theme every shelf without
-- one of its own wears (library_theme), chosen in the default's Theme
-- library. "Default", not "Library": that clashed with the Theme library
-- itself (maintainer, 2026-10-09).
function M.defaultRow(S)
    local TP = require("lib/bookshelf_theme_pack")
    return {
        text_func = function() return T(_("Default theme: %1"), TP.themeName(TP.libraryChoice())) end,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            M.openLibrary(S, nil, touchmenu_instance, M.rebuildAfter(S, touchmenu_instance))
        end,
    }
end

-- openLibrary(S, id, touchmenu_instance, after): the Theme library
-- (bookshelf_theme_library), the one picker every theme is chosen in: the
-- default's when id is nil, else that shelf's. The menu steps aside while it
-- is open, so a choice is seen on the shelf behind as it is made, and comes
-- back after, at the same submenu, with its rows refreshed. Choosing writes
-- ONE key (library_theme, or the shelf's tab.theme) and rebuilds the shelf:
-- a theme is a layer over the reader's own look, never written into it
-- (maintainer, 2026-10-07).
-- after (optional): runs once the menu is back.
function M.openLibrary(S, id, touchmenu_instance, after)
    local TP = require("lib/bookshelf_theme_pack")
    local restore = S:_hidePickerMenu(touchmenu_instance)
    local opts = { on_closed = function() restore(); if after then after() end end }
    if id then
        local tab = require("lib/bookshelf_tab_model").getById(id)
        opts.shelf = (tab and tab.label) or id
        opts.current = function() return TP.ownChoice(id) end
        opts.choose = function(value) M.setShelfTheme(id, value) end
    else
        opts.current = function() return TP.libraryChoice() end
        opts.choose = function(value) TP.setLibraryTheme(value) end
    end
    -- The shelf behind rebuilt while the picker is still open (it asks once
    -- a run of taps settles, and before the menu comes back).
    opts.apply = function() S:_markDirty() end
    return require("lib/bookshelf_theme_library").show(opts)
end

-- rebuildAfter(S, touchmenu_instance): what runs as a Theme library
-- closes: the Theme menu's rows built again for what the shelf on screen
-- shows now: a shelf's row may have put another shelf on screen, whose
-- theme the rows then edit.
function M.rebuildAfter(S, touchmenu_instance)
    return function()
        S:_reopenSubMenu(touchmenu_instance, function() return M.items(S) end)
    end
end

-- setShelfTheme(id, value): that shelf's own theme (tab.theme; nil follows
-- the default).
function M.setShelfTheme(id, value)
    local TabModel = require("lib/bookshelf_tab_model")
    local tabs = TabModel.load()
    for _i, t in ipairs(tabs or {}) do
        if t.id == id then t.theme = value; break end
    end
    -- In memory only while the Theme library is open: it writes the settings
    -- once as it closes (Orn.beginDeferred), not on every tap.
    local Orn = package.loaded["lib/bookshelf_ornaments"]
    if Orn and Orn._defer then TabModel.saveDeferred(tabs) else TabModel.save(tabs) end
end

return M
