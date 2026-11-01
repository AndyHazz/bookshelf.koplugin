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
    -- The whole screen, without a flash (maintainer, PW5 trial): "ui".
    assert(sync:find('UIManager:setDirty("all", "ui")', 1, true),
        "a change of look is not a whole-screen refresh without a flash")
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

-- The Theme card is on the editor's front page, beside Modules: out of View
-- mode, where it was a level down (maintainer, 2026-10-28).
t.test("the editor's front page has the shelf's Theme card, sub-shelves too, previewed live", function()
    local ed = read("lib/bookshelf_chip_editor.lua")
    local pick = ed:match("\nfunction Editor:_pickGroupDisplay%(draft, on_change, chrome%)(.-)\nfunction Editor:")
    assert(pick, "_pickGroupDisplay moved")
    assert(not pick:find('label = _("Theme")', 1, true), "View mode still has a Theme row")
    local row = ed:match("local look_row = {}\n        do\n(.-)\n        end\n")
    assert(row, "no Theme card on the front page")
    row = row:gsub("%-%-[^\n]*", "")
    assert(row:find('_("Theme: %1")', 1, true), "the card is not Theme")
    -- Every shelf, a sub-shelf included (Reddit, after 5.4): no gate on
    -- draft.parent, and a sub-shelf following its shelf of shelves says so.
    assert(not row:find("if draft.parent == nil then", 1, true), "the Theme card is top-level shelves only")
    assert(row:find("local follow = draft.parent ~= nil and TP.followOf(draft.id) or nil", 1, true)
        and row:find("follow = follow,", 1, true),
        "a sub-shelf's Theme card does not say it follows its shelf of shelves")
    -- Following the default reads "Theme: Default theme", as the Theme
    -- menu's shelf rows do (maintainer, 2026-10-09).
    assert(row:find("(v == nil and follow) and follow.title or TP.choiceLabel(v)", 1, true),
        "the card does not name following the default Default theme")
    assert(row:find('require("lib/bookshelf_theme_library").show{', 1, true),
        "the card does not open the Theme library the menus open")
    assert(row:find("current = function() return draft.theme end,", 1, true), "the picker does not mark the draft's choice")
    -- A pick reaches the draft and the shelf behind at once, not on the
    -- editor's debounce: the Theme library refreshes the whole screen as it
    -- applies, so a rebuild left for later was a flash that showed nothing,
    -- then a second with the theme (PW5, 2026-10-09).
    assert(row:find("choose = function(value) draft.theme = value end,", 1, true)
        and row:find("apply = function() commit(); settlePreview() end,", 1, true),
        "a pick does not reach the draft, or is not previewed on the shelf behind at once")
    assert(row:find("on_closed = function() rebuild() end,", 1, true), "the editor does not come back after the picker")
    local tm = read("lib/bookshelf_theme_menu.lua")
    local open = tm:match("function M%.openLibrary%(S, id, touchmenu_instance, after%)(.-)\nend\n")
    assert(open and open:find('require("lib/bookshelf_theme_library").show(opts)', 1, true),
        "the menus do not open the Theme library")
    -- The pick reaches the saved shelf: commit writes the whole working copy.
    assert(ed:find("save_tabs[i] = Editor._deepCopy(draft)", 1, true),
        "a change is not written onto the saved shelf whole, so the theme may not reach it")
end)

t.done()
