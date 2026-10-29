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

t.test("the editor's pickers, the Theme library and Modules open as its pages", function()
    eq(select(2, ed:gsub("over%s*= Editor%._over%(", "")), 4)
end)

-- Modules was a window of its own over the editor ("Bookshelf
-- micro-modules"), with no way back to it (user test).
t.test("Modules is a page of the editor, and its pick is not asked twice", function()
    assert(ed:find('over = Editor._over({ _("Modules") })', 1, true), "Modules is not a page")
    assert(ed:find('_editShelfModules(nil, { add = true, key = key })', 1, true),
        "the pick is not handed on, so the picker would open again")
    local mp = io.open("lib/bookshelf_module_picker.lua"):read("*a")
    assert(mp:find("over = opts.over,", 1, true), "the picker ignores over")
    assert(mp:find("if opts.key then\n        if on_select then on_select(opts.key) end\n        return", 1, true),
        "a module already picked still opens the picker")
    local w = io.open("lib/bookshelf_widget.lua"):read("*a")
    assert(w:find("ed.session:add(nil, nil, pick)", 1, true), "covers: the pick does not reach the layout editor")
    assert(w:find("return self:_addSpineModule(pick)", 1, true), "spines: the pick does not reach the add")
end)

t.done()
