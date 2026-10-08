-- tests/_test_shelf_themes_wiring.lua
-- The shelf wears its theme: the widget names the shelf before each build,
-- and the readers of light/dark, the plank and the ornament pool follow it.
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t = H.runner()

local function read(p) return io.open(p):read("*a") end

t.test("_rebuild names the shelf first and refreshes the whole screen when the look changes", function()
    local w = read("lib/bookshelf_widget.lua")
    local body = w:match("\nfunction BookshelfWidget:_rebuild%(%)\n(.-)\nend\n")
    assert(body, "_rebuild moved")
    local at = body:find("self:_syncShelfTheme()", 1, true)
    assert(at, "_rebuild does not name the shelf")
    assert(at < body:find("dropPlanCache", 1, true), "the shelf is named after the plan cache work began")
    local sync = w:match("\nfunction BookshelfWidget:_syncShelfTheme%(%)\n(.-)\nend\n")
    assert(sync and sync:find("TP.setShelf(self.chip)", 1, true), "_syncShelfTheme does not set the shelf")
    assert(sync:find('UIManager:setDirty("all", "full")', 1, true), "a change of look is not a full refresh")
end)

t.test("light/dark is read through the shelf", function()
    local cp = read("lib/bookshelf_cover_progress.lua")
    assert(cp:find("TP.shelfLook()", 1, true), "CoverProgress.theme ignores the shelf")
    local wp = read("lib/bookshelf_wallpaper.lua")
    assert(wp:find("TP.shelfLook()", 1, true), "Wallpaper.showsNegative ignores the shelf")
end)

t.test("the plank memo is keyed on the shelf's look too", function()
    local sp = read("lib/bookshelf_spine_shelf.lua")
    local body = sp:match("function SpineShelf%.activePlankDesign%(%)\n(.-)\nend\n")
    assert(body and body:find("TP.shelfKey()", 1, true), "the plank memo ignores the shelf")
end)

t.test("the plan deals from the shelf's pool", function()
    local sp = read("lib/bookshelf_spine_shelf.lua")
    assert(sp:find("orn.mod.listFor(TP.ornamentsFor(opts.orn_shelf))", 1, true),
        "plan deals from the library pool")
end)

t.test("page deal states are forgotten when the shelf's look changes", function()
    local w = read("lib/bookshelf_widget.lua")
    local body = w:match("\nfunction BookshelfWidget:_ornSig%(%)\n(.-)\nend\n")
    assert(body and body:find("TP.shelfKey()", 1, true), "_ornSig ignores the shelf's theme, so its pool")
end)

t.test("Shelf style has the shelf's Theme row, top-level shelves only, previewed live", function()
    local ed = read("lib/bookshelf_chip_editor.lua")
    local pick = ed:match("\nfunction Editor:_pickGroupDisplay%(draft, on_change, chrome%)(.-)\nfunction Editor:")
    assert(pick, "_pickGroupDisplay moved")
    pick = pick:gsub("%-%-[^\n]*", "")
    local row = pick:match("if draft%.parent == nil then(.-)\n        end\n")
    assert(row and row:find('_("Theme: %1")', 1, true), "no Theme row, or not limited to top-level shelves")
    assert(row:find('require("lib/bookshelf_theme_library").show{', 1, true),
        "the row does not open the Theme library the menus open")
    assert(row:find("current = cur,", 1, true), "the picker does not mark the draft's choice")
    assert(row:find("draft.theme = value", 1, true)
        and row:find("apply = on_change,", 1, true),
        "a pick does not reach the draft, or is not previewed on the shelf behind")
    -- Own theme, the first time: the draft gets a copy of what the shelf
    -- shows, before the choice is written (2026-10-08).
    local ens = row:find("if value == TP.OWN then TP.ensureOwn(draft, TP.resolveChoice(cur(), draft)) end", 1, true)
    assert(ens and ens < row:find("draft.theme = value", 1, true),
        "choosing Own theme in Shelf style does not make the shelf's own theme first")
    assert(row:find("own = function() return draft.own_theme end,", 1, true),
        "the Own theme card does not see the draft's own theme")
    assert(row:find("on_closed = show,", 1, true), "Shelf style does not come back after the picker")
    local st = read("lib/bookshelf_settings.lua")
    local open = st:match("function Settings:_openThemeLibrary%(id, touchmenu_instance, after%)(.-)\nend\n")
    assert(open and open:find('require("lib/bookshelf_theme_library").show(opts)', 1, true),
        "the menus do not open the Theme library")
    -- The pick reaches the saved shelf: commit writes the whole working copy.
    assert(ed:find("save_tabs[i] = Editor._deepCopy(draft)", 1, true),
        "a change is not written onto the saved shelf whole, so the theme may not reach it")
end)

t.done()
