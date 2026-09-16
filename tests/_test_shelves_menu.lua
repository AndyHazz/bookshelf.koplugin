-- tests/_test_shelves_menu.lua
-- The shelves menu leads with editing, and says how to hide.
--
-- WHAT NEEDS PINNING. "Bookshelf shelves" named the noun, not the job, and a
-- tap toggled a shelf on or off while EDITING one was hidden behind a
-- long-press that nothing advertised except a line above the list. Editing is
-- the thing people come here for, so the tap now opens the editor and the
-- long-press does the showing and hiding, with the hint moved to the bottom
-- where a reader lands after reading the shelves rather than before
-- (maintainer: "basically the opposite to how it is now").
--
-- The hint must still be a disabled ROW rather than help_text: help_text
-- costs a tap to read, and the whole problem is a reader who does not know
-- there is anything to look for.
--
-- Usage (from plugin root): lua tests/_test_shelves_menu.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq
local main     = io.open("main.lua"):read("*a")
local settings = io.open("lib/bookshelf_settings.lua"):read("*a")

t.test("the menu is named for the job, not the noun", function()
    assert(main:find('text                = _("Edit shelves', 1, true), "the shelves entry should read Edit shelves")
    assert(not main:find("Bookshelf shelves", 1, true), "the old label is still there")
end)

t.test("the size editor says what it adjusts, panel included", function()
    assert(main:find('_("Adjust shelf/top panel size")', 1, true), "the menu row's label")
    assert(settings:find('title = _("Adjust shelf/top panel size")', 1, true), "the dialog's own title")
    assert(not main:find('_("Edit shelf size")', 1, true), "the old menu label survives")
    assert(not settings:find('title = _("Edit shelf size")', 1, true), "the old dialog title survives")
end)

local rows = settings:match("function Settings:_tabsMenuItems%(%)(.-)\nend\n")
assert(rows, "_tabsMenuItems moved or was renamed")

t.test("a tap edits the shelf; the long-press shows or hides it", function()
    local row = rows:match("(items%[#items %+ 1%] = {\n            keep_menu_open = true,.-\n        }\n)")
    assert(row, "the per-shelf row moved")
    local tap  = row:match("callback = function%(touchmenu_instance%)(.-)\n            end")
    local hold = row:match("hold_callback = function%(touchmenu_instance%)(.-)\n            end")
    assert(tap and hold, "both handlers must still exist")
    assert(tap:find("editTab", 1, true), "a tap must open the editor")
    assert(hold:find("t.enabled", 1, true), "a long-press must toggle the shelf")
    assert(not tap:find("t.enabled", 1, true), "a tap must no longer toggle")
end)

t.test("the hint tells you about the long-press, and sits at the bottom", function()
    -- _%( and "%): the parentheses are literal here, not a capture group.
    local hint = rows:match('text = _%("([^"]*Long%-press[^"]*)"%)')
    assert(hint, "the hint row is missing")
    assert(hint:find("hide", 1, true) or hint:find("Hide", 1, true),
        "the hint must say what the long-press does now: show or hide")
    -- Everything the list is built from comes before it.
    local hint_at = rows:find("Long-press", 1, true)
    local loop_at = rows:find("for _i, tab in ipairs(tabs) do", 1, true)
    assert(hint_at and loop_at and hint_at > loop_at,
        "the hint must come after the shelves, not before them")
end)

t.test("the hint is still a row, not help text", function()
    local block = rows:match("(items%[#items %+ 1%] = {\n        text = _%(\"[^\"]*Long%-press.-\n    })")
    assert(block and block:find("enabled = false", 1, true),
        "the hint must stay a disabled row: help_text costs a tap to read")
end)

t.done()
