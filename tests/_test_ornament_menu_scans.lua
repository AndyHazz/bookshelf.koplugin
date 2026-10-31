-- tests/_test_ornament_menu_scans.lua
-- The ornament menu reads the ornament folders once, not on every nudge.
-- Measured on the maintainer's PW5 (2026-10-31, 17 packs): a Height tap
-- made 11 listAll calls, each reading every pack folder again outside the
-- recent window, ~320 ms of a 0.4 s tap. Nothing in the folders changes
-- while the menu is open (the reader's file is written when it closes), so
-- its actions run inside the window (M.held), as the browser's list does.
--
-- Usage (from plugin root): lua tests/_test_ornament_menu_scans.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq

local open, fresh = false, 0
local Orn = {
    listAll = function() if not open then fresh = fresh + 1 end; return {}, {} end,
    allowRecent = function(on) local was = open; open = on and true or false; return was end,
}
package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }
package.loaded["ffi/util"] = { template = function(s) return s end }
package.loaded["lib/bookshelf_ornament_deck"] = {}
package.loaded["lib/bookshelf_ornaments"] = Orn
local M = dofile("lib/bookshelf_ornament_menu.lua")
local src = io.open("lib/bookshelf_ornament_menu.lua"):read("*a")

t.test("an action held reads the folders at most once, and leaves the window as it was", function()
    local act = M.held(function(a, b)
        for _i = 1, 11 do Orn.listAll() end
        eq(a, 1); eq(b, 2)
    end)
    act(1, 2)
    eq(fresh, 0, "the folders were read inside the window")
    eq(open, false, "the window was left open")
    -- Inside a window someone else opened: theirs to close.
    Orn.allowRecent(true)
    act(1, 2)
    eq(open, true, "the opener's window was closed under it")
    Orn.allowRecent(false)
end)

t.test("the menu's actions run inside the window", function()
    for _i, s in ipairs({
        "local rebuildShelf = M.held(function()",
        "local redraw = M.held(function(soon)",
        "local set = M.held(function(field, value, soon)",
        "local setAnchor = M.held(function(v)",
        "local step = M.held(function(delta)",
        "dialog.reinit = M.held(function(self)",
    }) do
        assert(src:find(s, 1, true), "not held: " .. s)
    end
end)

t.done()
