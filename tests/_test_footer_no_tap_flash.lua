-- tests/_test_footer_no_tap_flash.lua
-- The pagination row's buttons skip KOReader's flash_ui tap highlight.
--
-- Usage (from plugin root): lua tests/_test_footer_no_tap_flash.lua
--
-- An icon button is highlighted by inverting what is behind it; over a
-- wallpaper these have no fill, so the flash was a negative patch of the
-- picture, and on a Kindle its own refresh was often cut short by the page
-- turn after it. Only the two paint hooks are replaced, never
-- onTapSelectButton: the tap, the callback and KOReader's repaint afterwards
-- stay KOReader's own.

package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()

local src = io.open("lib/bookshelf_widget.lua"):read("*a")
local loop = src:match("for _i, b in ipairs%({first, prev, page_text, next_btn, last}%) do\n(.-)\n    end\n")

t.test("all five pagination buttons drop the highlight", function()
    assert(loop, "the pagination button loop moved")
    assert(loop:find("b._doFeedbackHighlight = function() end", 1, true))
    assert(loop:find("b._undoFeedbackHighlight = function() end", 1, true))
end)

t.test("the tap handler itself is left to KOReader", function()
    assert(not src:find("onTapSelectButton = function", 1, true),
        "a copy of KOReader's tap handler would drift from its own")
end)

t.done()
