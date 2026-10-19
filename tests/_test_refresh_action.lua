-- tests/_test_refresh_action.lua
-- Issue 541: the swipe down that refreshes the library kept firing by accident
-- (KOReader's multiswipes), and with it switched off under Bookshelf gestures
-- there was no other way to refresh. It is now a system action, so it can go
-- on another gesture or a quick menu. A Dispatcher action whose event has no
-- handler does nothing, silently, so the name, the event and the handler are
-- checked together.
-- Run from the plugin root: lua tests/_test_refresh_action.lua
package.path = "./?.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()
local main = io.open("main.lua"):read("*a")
local w = io.open("lib/bookshelf_widget.lua"):read("*a")

t.test("the refresh is registered as a system action", function()
    local reg = main:match('Dispatcher:registerAction%("bookshelf_refresh_library", (%b{})%)')
    assert(reg, "no bookshelf_refresh_library action")
    assert(reg:find('event%s*=%s*"BookshelfRefreshLibrary"'), "the action sends no event")
    assert(reg:find("general%s*=%s*true"), "the action is not available everywhere")
    assert(reg:find('title%s*=%s*_%("Bookshelf: refresh the library"%)'), "the title moved")
end)

t.test("the shelf handles the event with the swipe's own refresh", function()
    local h = w:match("function BookshelfWidget:onBookshelfRefreshLibrary%(%)(.-)\nend\n")
    assert(h, "no handler for the event")
    assert(h:find("self:_refreshLibrary()", 1, true), "the handler does not refresh")
    assert(not h:find('Gestures.on("refresh")', 1, true),
        "the action must work with the swipe switched off")
end)

t.done()
