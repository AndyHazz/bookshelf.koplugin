-- tests/_test_cover_tab_focus_rows.lua
-- The Cover tab's D-pad layout: rows of cells, and the buttons above the grid.
--
-- focusRow(layout) takes a list of ROWS. The Cover tab passed each grid row's
-- cells as a flat list, so mergeLayoutInVertical made every cover cell a row of
-- its own and the focus landed on the cell's unpainted child: no highlight, and
-- Press crashed KOReader in FocusManager (dimen nil) on a keys-only device. The
-- "Choose from device" and "Search online..." buttons were never in the layout
-- at all. (GitHub issue 361, reproduced on the rig with isTouchDevice faked off.)
package.path = "./?.lua;./?/init.lua;" .. package.path
local t  = dofile("tests/_helpers.lua").runner()

local src  = dofile("tests/_widget_source.lua")
local body = src:match("\nfunction BookshelfWidget:_buildBookCoverTab%(.-%)\n(.-)\nend\n")
assert(body, "could not find BookshelfWidget:_buildBookCoverTab() - renamed?")

t.test("every focusRow call gets a list of rows", function()
    local n = 0
    for arg in body:gmatch("focusRow%(%s*([^%)]-)%s*%)") do
        n = n + 1
        assert(arg:sub(1, 1) == "{", "focusRow(" .. arg .. ") is a flat list, not a list of rows")
    end
    assert(n >= 2, "expected the toolbar row and the grid rows, found " .. n)
end)

t.test("the toolbar buttons are reachable", function()
    assert(body:find("focusRow%(%s*{%s*{%s*device_btn%s*,%s*online_btn%s*}%s*}%s*%)"),
        "Choose from device / Search online are not in the focus layout")
end)

t.done()
