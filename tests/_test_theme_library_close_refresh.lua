-- tests/_test_theme_library_close_refresh.lua
-- The Theme library flashed the whole screen as it closed after a theme was
-- chosen. Pointless (maintainer): the shelf behind is redrawn as each theme
-- is tapped, and the modal's own close refreshes where it was (ui).
-- Usage (from plugin root): lua tests/_test_theme_library_close_refresh.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t = H.runner()

t.test("closing the Theme library does not flash the screen", function()
    local s = io.open("lib/bookshelf_theme_library.lua"):read("*a")
    assert(not s:find('setDirty("all", "full")', 1, true), "the close still asks for a full refresh")
    local m = io.open("lib/bookshelf_library_modal.lua"):read("*a")
    local close = m:match("\nfunction LibraryModal:onCloseWidget%(%)(.-)\nend\n")
    assert(close and close:find('UIManager:setDirty("all", "ui")', 1, true), "the modal's own close refresh is gone")
end)

t.done()
