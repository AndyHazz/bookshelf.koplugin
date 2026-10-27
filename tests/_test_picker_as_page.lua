-- tests/_test_picker_as_page.lua
-- A picker the shelf editor opens is a page of it (LibraryModal config.over):
-- in the editor's frame with its breadcrumb and a back chevron, refreshing
-- only that box, rather than a window over the editor that lined up with it
-- and read as one badly drawn menu.
--
-- Usage (from plugin root): lua tests/_test_picker_as_page.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local lm = io.open("lib/bookshelf_library_modal.lua"):read("*a")
local ed = io.open("lib/bookshelf_chip_editor.lua"):read("*a")

t.test("the lone Back or Close is the page's back chevron", function()
    local body = assert(lm:match("\nfunction LibraryModal:_closeOnlyAction%(%)\n(.-)\nend\n"))
    local f = assert(load("local self, _ = ...\n" .. body))
    local function only(label, over)
        return f({ config = { over = over, footer_actions = { { label = label, on_tap = function() end } } } },
                 function(s) return s end)
    end
    assert(only("Back", {}), "Back is not the chevron on a page")
    assert(not only("Back", nil), "Back became the X on a plain picker")
    assert(only("Close", nil) and only("Close", {}))
end)

t.test("a page refreshes its own box opening and closing, not the whole screen", function()
    local show = assert(lm:match("\nfunction LibraryModal:onShow%(%)\n(.-)\nend\n"))
    assert(show:find('UIManager:setDirty(self, "ui", Geom:new(self._shown_rect))', 1, true))
    local close = assert(lm:match("\nfunction LibraryModal:onCloseWidget%(%)\n(.-)\nend\n"))
    assert(close:find('UIManager:setDirty("all", "ui", Geom:new(self._shown_rect))', 1, true))
    assert(not lm:find("scrimUnder", 1, true), "the fade is back")
end)

t.test("the editor's pickers and the Theme library open as its pages", function()
    eq(select(2, ed:gsub("over%s*= Editor%._over%(", "")), 3)
end)

t.done()
