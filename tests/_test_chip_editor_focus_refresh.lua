-- tests/_test_chip_editor_focus_refresh.lua
-- D-pad focus moves in the shelf editor repaint the editor.
--
-- FocusManager refreshes `self.show_parent or self` when focus moves. The
-- editor's ButtonTable had no show_parent, so it marked ITSELF dirty, and a
-- widget that is not on the window stack is never repainted: on a keys-only
-- device the first button ("<") stayed highlighted while focus moved on
-- underneath (GitHub issue 361, reproduced on the rig). The table is rebuilt
-- on every edit, and the first build runs before the dialog exists, so both
-- the rebuild and the dialog's creation have to hand the table its parent.
package.path = "./?.lua;./?/init.lua;" .. package.path
local t  = dofile("tests/_helpers.lua").runner()

local src = io.open("lib/bookshelf_chip_editor.lua"):read("*a")

t.test("each rebuilt focus manager is pointed at the dialog", function()
    -- The editor's body is one FocusManager over the strip and the cards
    -- (STYLE.md layout), in place of the stock ButtonTable.
    local bt = src:find("local button_table = FocusManager:new{", 1, true)
    assert(bt, "editor focus manager not found")
    local after = src:sub(bt, bt + 1200)
    assert(after:find("button_table.show_parent = dialog", 1, true),
        "a rebuilt ButtonTable is not given the dialog as show_parent")
end)

t.test("the first ButtonTable gets the dialog once it exists", function()
    local mk = src:find("dialog = InputContainer:new{}", 1, true)
    assert(mk, "dialog creation not found")
    local after = src:sub(mk, mk + 400)
    assert(after:find("current_bt.show_parent = dialog", 1, true),
        "the first build's ButtonTable never learns its show_parent")
end)

t.done()
