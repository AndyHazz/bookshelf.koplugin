-- tests/_test_micro_on_shelf.lua
-- Micro modules > On the shelf (on by default): off, a shelf shows only its
-- books (and the ornaments it deals) - its modules are not drawn and their
-- space goes back to the books, the ways of adding one ("Pin here", "Add a
-- module to this shelf") go, and the modules come back as they were when it
-- is turned on again (maintainer).
-- Run from the plugin root: lua tests/_test_micro_on_shelf.lua
package.path = "./?.lua;" .. package.path
local t  = dofile("tests/_helpers.lua").runner()
local eq = dofile("tests/_helpers.lua").eq

local on_shelf = true
package.loaded["lib/bookshelf_settings_store"] = {
    microOnShelf = function() return on_shelf end,
}
local SM = dofile("lib/bookshelf_shelf_modules.lua")

t.test("off, a shelf has no modules to lay out; on, they are back as they were", function()
    local tab = { id = "recent", shelf_modules = { { id = "sm_1", module = "shelf", after = 2, w = 4 } } }
    on_shelf = false
    eq(SM.list(tab), nil, "modules still laid out with On the shelf off")
    on_shelf = true
    local l = SM.list(tab)
    assert(l and l[1].id == "sm_1", "the modules did not come back")
    eq(#tab.shelf_modules, 1, "turning it off removed the modules themselves")
end)

local store = io.open("lib/bookshelf_settings_store.lua"):read("*a")
t.test("the setting is on by default and counts as a surface in use", function()
    local f = store:match("\nfunction Store%.microOnShelf%(%)\n(.-)\nend\n")
    assert(f and f:find('"micro_on_shelf"', 1, true), "no microOnShelf reading micro_on_shelf")
    assert(f:find("~= false", 1, true) or f:find("nilOrTrue", 1, true), "not on by default")
    local any = store:match("\nfunction Store%.microAnyEnabled%(%)\n(.-)\nend\n")
    assert(any and any:find("microOnShelf", 1, true), "Micro modules reads Off with modules on the shelf")
end)

t.test("off, nothing offers to put a module on the shelf", function()
    local orn = io.open("lib/bookshelf_ornament_menu.lua"):read("*a")
    local i = orn:find('_("Pin here")', 1, true)
    assert(i and orn:sub(i - 300, i):find("microOnShelf", 1, true), "Pin here is offered with On the shelf off")
    local ce = io.open("lib/bookshelf_chip_editor.lua"):read("*a")
    local j = ce:find("Add a module to this shelf", 1, true)
    assert(j and ce:sub(j - 400, j):find("microOnShelf", 1, true), "Add a module is offered with On the shelf off")
end)

t.test("the Micro modules menu has an On the shelf row", function()
    local s = io.open("lib/bookshelf_settings.lua"):read("*a")
    assert(s:find('_("On the shelf")', 1, true) and s:find("micro_on_shelf", 1, true), "no On the shelf row")
end)

t.test("the full-screen shelf's status strip keeps full screen when swipe back is off (issue 554)", function()
    -- With "Swipe down leaves full screen shelves" off the top panel comes
    -- back from the shelf bar's book icon or a gesture; a tap on the status
    -- strip brought it back as well.
    local w = io.open("lib/bookshelf_widget.lua"):read("*a")
    local f = w:match("\nfunction BookshelfWidget:_buildExpandedStrip%(.-\nend\n")
    assert(f, "_buildExpandedStrip moved")
    local tap = f:match("function strip:onTap%(%)(.-)\n    end")
    assert(tap and tap:find("expanded_swipe_back", 1, true), "the strip tap ignores Swipe down leaves full screen shelves")
end)

t.done()
