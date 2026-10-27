-- tests/_test_face_out_picker.lua
-- The face-out picker updates itself in place: no close-and-reopen per tap.
--
-- WHAT NEEDS PINNING. Each toggle used to close the ButtonDialog and show a
-- fresh one. KOReader's ButtonDialog asks for a flashui refresh of its own
-- rectangle when it closes; the editor's hidden parent dialog marked itself
-- dirty full-screen at the same moment, and the two merged into a
-- full-screen flash on every tap ("the whole screen flashes when I tap the
-- face out options"). With the shelf rebuild now deferred, that flash was
-- followed by a second full-screen redraw, two visible changes per tap.
--
-- Now the picker has a fixed shape - two toggles per row, the recent-count
-- button always present and merely disabled when Recent is off, All/None as
-- a pair, Done - and a tap rewrites the button labels through
-- getButtonById/setText and repaints the dialog's own rectangle with a
-- plain ui refresh. Only the count picker and Done close it. The parent's
-- rebuild() no longer marks a hidden dialog dirty.
--
-- Usage (from plugin root): lua tests/_test_face_out_picker.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local src = io.open("lib/bookshelf_chip_editor.lua"):read("*a")

-- The picker is a page of its own now (Editor:_openFaceOut), laid out again
-- in place after each tap; its behaviour is tested in _test_chip_editor.
local raw = src:match("\nfunction Editor:_openFaceOut%b()(.-)\nend\n")
assert(raw, "Editor:_openFaceOut not found")

t.test("source strings use American spelling", function()
    for str in raw:gmatch('_%("(.-)"%)') do
        assert(not str:find("favourite", 1, true), "British spelling belongs only in en_GB.po: " .. str)
    end
end)

t.test("the parent editor's rebuild does not mark a hidden dialog dirty", function()
    local body = src:match("\n    rebuild = function%(%)\n(.-)\n    end\n")
    assert(body, "rebuild() not found")
    assert(body:find("markDirty()", 1, true), "rebuild must repaint through markDirty")
    local mark = src:match("\n    local function markDirty%(%)\n(.-)\n    end\n")
    assert(mark and mark:find("UIManager:isWidgetShown(dialog)", 1, true), "markDirty must check the dialog is shown before setDirty")
    assert(not body:find('if dialog then\n            UIManager:setDirty(dialog, "ui")', 1, true))
end)

t.done()
