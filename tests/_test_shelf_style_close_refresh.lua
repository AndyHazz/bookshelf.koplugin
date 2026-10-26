-- tests/_test_shelf_style_close_refresh.lua
-- Closing Shelf style flashed the whole screen (maintainer, PW5). The editor
-- it was opened from came back with a bare "ui" refresh, which with no region
-- covers the whole screen, and UIManager merges it with Shelf style's own
-- flashui on close, keeping the stronger mode: one whole-screen flash. The
-- editor comes back over its own frame, as it was first shown.
-- Run from the plugin root: lua tests/_test_shelf_style_close_refresh.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()

local src = io.open("lib/bookshelf_chip_editor.lua"):read("*a")

t.test("the editor comes back over its own frame, not the whole screen", function()
    assert(not src:find('show = function() UIManager:show(dialog, "ui") end', 1, true),
        "the editor's re-show still refreshes the whole screen")
    assert(src:find('show = function()\n                        UIManager:show(dialog, function() return "ui", frame.dimen end)', 1, true),
        "the editor's re-show doesn't name its frame")
end)

t.done()
