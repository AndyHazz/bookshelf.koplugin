-- tests/_test_spine_last_page.lua
-- Issue 463 (second half): in spine view the ">>" button stopped short of the
-- end on the first tap ("215-258 of 355"). It asked _spineTotalPages(), which
-- only READS the page map; before anything had built it, the tap fell back to
-- the view-size estimate and jumped there. A spine shelf's last page now comes
-- from the map, built on the tap: _spineCursorForPage builds it and clamps a
-- page past the end to the last one.
-- Run from the plugin root: lua tests/_test_spine_last_page.lua
package.path = "./?.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()
local src = io.open("lib/bookshelf_widget.lua"):read("*a")

t.test("the last-page button builds the spine page map on the tap", function()
    local cb = src:match('icon = "chevron.last".-callback%s*=%s*(.-)margin%s*=%s*bm%("last"%)')
    assert(cb, "the last-page button moved")
    assert(cb:find("_isSpineMode()", 1, true) and cb:find("math.huge", 1, true),
        "spine mode still jumps to the estimated last page")
end)

t.test("_spineCursorForPage builds the map and clamps past the end", function()
    local f = src:match("function BookshelfWidget:_spineCursorForPage%(p%).-\nend")
    assert(f and f:find("_spinePageFirsts(true)", 1, true) and f:find("if p > #firsts then p = #firsts end", 1, true))
end)

t.done()
