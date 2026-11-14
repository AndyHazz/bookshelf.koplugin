-- tests/_test_library_modal_over_place.lua
-- Where a page of a menu is drawn (config.over). A page dialog is short and
-- opens mid-screen; a list opened from it as a page (Hardcover > Manual
-- link) is taller, and ran from the menu's top edge down to the foot of the
-- screen (maintainer, PW5: "the modal I think should be positioned higher
-- up"). With over.centre such a page sits centred on the screen, still
-- covering the menu. The shelf editor's pages fit inside the editor and
-- keep its top edge.
--
-- Usage (from plugin root): lua tests/_test_library_modal_over_place.lua
package.path = "./?.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq

local src = io.open("lib/bookshelf_library_modal.lua"):read("*a")
local body = src:match("(function LibraryModal%.overY%(.-\nend)\n")
assert(body, "LibraryModal.overY not found")
local LibraryModal = {}
assert(load("local LibraryModal = ...\n" .. body))(LibraryModal)

local SCREEN = 1648

t.test("a page no taller than its menu keeps the menu's top", function()
    local menu = { y = 530, h = 600, centre = true }
    eq(LibraryModal.overY(menu, 600, SCREEN), 530)
    eq(LibraryModal.overY(menu, 400, SCREEN), 530)
end)

t.test("taller than its menu, with centre: centred on the screen", function()
    local menu = { y = 530, h = 500, centre = true }
    eq(LibraryModal.overY(menu, 1100, SCREEN), math.floor((SCREEN - 1100) / 2))
end)

t.test("centred, it still covers the whole menu", function()
    -- A menu low on the screen: centring would leave its foot showing.
    local menu = { y = 1000, h = 500, centre = true }
    local y = LibraryModal.overY(menu, 700, SCREEN)
    assert(y <= 1000, "the menu's top shows above the page")
    assert(y + 700 >= 1500, "the menu's foot shows below the page")
end)

t.test("never above the top of the screen", function()
    local menu = { y = 100, h = 300, centre = true }
    eq(LibraryModal.overY(menu, 1800, SCREEN), 0)
end)

t.test("without centre (the shelf editor): the menu's top, as before", function()
    local menu = { y = 530, h = 500 }
    eq(LibraryModal.overY(menu, 1100, SCREEN), 530)
end)

t.test("the frame is drawn, and its refresh box kept, where overY puts it", function()
    assert(src:find("frame:paintTo(bb, over.x, LibraryModal.overY(over, frame:getSize().h, Screen:getHeight()))", 1, true),
        "the page is not drawn where overY says")
    assert(src:find("y = at and LibraryModal.overY(at, size.h, Screen:getHeight())", 1, true),
        "the refresh box is not where the page is")
end)

t.test("a page dialog's pages are centred; the shelf editor's are not", function()
    local pd = io.open("lib/bookshelf_page_dialog.lua"):read("*a")
    assert(pd:find("centre = true,", 1, true), "PageDialog:over does not ask for centring")
    local ed = io.open("lib/bookshelf_chip_editor.lua"):read("*a")
    assert(not ed:find("centre = true", 1, true), "the shelf editor's pages would move")
end)

t.done()
