-- tests/_test_close_raise_on_show.lua
-- Issue 460: with "Return to file browser" as the end-of-book action, KOReader's
-- file browser flashed before the shelf came back (a regression in v5.1.2,
-- bisected to the issue-422 change that keeps the shelf alive through a
-- close). onShow is what beats the file browser's first paint, and it returned
-- early whenever the shelf was SHOWN -- which since 422 it always is, just
-- buried under the new file browser. An announced takeover with the shelf
-- shown but not on top must raise it there and then.
-- Run from the plugin root: lua tests/_test_close_raise_on_show.lua
package.path = "./?.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()
local src = io.open("main.lua"):read("*a")
local body = src:match("function Bookshelf:onShow%(%).-\nend\n")

t.test("onShow raises a shelf buried under the file browser when a takeover is announced", function()
    assert(body, "Bookshelf:onShow moved")
    local shown = body:find("UIManager:isWidgetShown(_live_widget)", 1, true)
    assert(shown, "the shown check moved")
    local after = body:sub(shown, shown + 900)
    assert(after:find("_expect_onshow_takeover", 1, true) and after:find("_raiseInPlace()", 1, true),
        "a shown-but-buried shelf still makes onShow stand down, so the file browser paints first")
end)

t.done()
