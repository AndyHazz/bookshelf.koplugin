-- tests/_test_toolbar_fits.lua
-- The layout editor's toolbar fits any screen (STYLE.md, Pages). On a
-- 600x800 screen the d-pad, the steppers and Settings / Style / Remove side
-- by side were wider than the screen: the toolbar ran off both edges (rig).
-- With no room for the column, the actions go on a line of their own under
-- the rest, and the keys reach them as a row below the d-pad.
--
-- Usage (from plugin root): lua tests/_test_toolbar_fits.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()

local src = io.open("lib/bookshelf_module_grid_editor.lua"):read("*a")
local body = src:match("\n(function Editor:_buildToolbar%(.-\nend)\n")
assert(body, "_buildToolbar moved")

t.test("the toolbar measures its controls against the room it has", function()
    assert(body:find("local room = ", 1, true), "no room measured")
    assert(body:find("> room", 1, true), "the side-by-side layout is used whatever the room")
end)

t.test("too narrow: the actions on a line of their own, a keys row of their own", function()
    assert(body:find("rows[#rows + 1] = actions", 1, true), "the actions are not their own keys row")
end)

t.done()
