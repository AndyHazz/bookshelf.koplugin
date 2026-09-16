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
local eq = helpers.eq
local src = io.open("lib/bookshelf_chip_editor.lua"):read("*a")

-- The picker lives inside the "Face out" row's callback in _pickGroupDisplay.
local a = src:find("text_func = faceOutShown,", 1, true)
assert(a, "face-out row not found")
local b = src:find("Author on the spine, below the title", a, true)
assert(b, "end of the face-out block not found")
local raw   = src:sub(a, b)
local block = raw:gsub("%-%-[^\n]*", "")

t.test("toggles rewrite labels in place instead of closing and reopening the picker", function()
    assert(block:find("getButtonById(", 1, true), "labels must be reached through getButtonById")
    assert(block:find(":setText(", 1, true), "labels must be rewritten with setText")
    local closes = select(2, block:gsub("UIManager:close%(sub%)", ""))
    eq(closes, 2, "only the count picker and Done may close the picker; found " .. closes .. " closes")
    assert(not block:find("UIManager:close(sub); show()", 1, true) or closes == 2)
end)

t.test("the repaint after a toggle is a plain ui refresh of the dialog's own rectangle", function()
    assert(block:find('return "ui", sub.movable.dimen', 1, true), "expected a region-scoped ui refresh of the picker")
    assert(not block:find("flashui", 1, true))
end)

t.test("fixed shape: two toggles per row, a count button that is disabled rather than absent, All/None as a pair, Done", function()
    assert(block:find('toggle("favorites"', 1, true) and block:find('toggle("reading"', 1, true), "reason toggles")
    assert(block:find('id = "face_count"', 1, true), "the count button must always exist")
    assert(block:find("enabled = ", 1, true), "the count button is disabled, not hidden, when Recent is off")
    assert(block:find('_("Done")', 1, true), "the closing button is Done; nothing here is cancelled")
    assert(not block:find('_("Cancel")', 1, true), "Cancel misdescribed a picker whose changes are already in the draft")
    assert(not block:find("if spec.recent then\n", 1, true), "no structural change on toggle")
end)

t.test("source strings use American spelling", function()
    -- raw, not block: a "--" inside the old string made the stripper eat the rest of its line.
    assert(not raw:find("favourite that", 1, true), "the help text said 'favourite'; British belongs only in en_GB.po")
end)

t.test("the parent editor's rebuild does not mark a hidden dialog dirty", function()
    local body = src:match("\n    local function rebuild%(%)\n(.-)\n    end\n")
    assert(body, "rebuild() not found")
    assert(body:find("UIManager:isWidgetShown(dialog)", 1, true), "rebuild must check the dialog is shown before setDirty")
    assert(not body:find('if dialog then\n            UIManager:setDirty(dialog, "ui")', 1, true))
end)

t.done()
