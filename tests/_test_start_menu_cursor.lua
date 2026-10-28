-- tests/_test_start_menu_cursor.lua
-- The start menu's keys cursor waits for the first key (STYLE.md): opened
-- by a tap, no row is outlined; the first key shows it where it was seeded
-- instead of moving it or pressing the row.
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t = H.runner()

local src = io.open("lib/bookshelf_start_menu.lua"):read("*a")

t.test("a row is drawn focused only once the cursor is shown", function()
    assert(src:find("local is_focused = self._focus and self._cursor_shown", 1, true),
        "the seeded row is outlined before any key")
end)

t.test("every key handler shows the cursor first", function()
    for _i, name in ipairs({ "SMFocusDown", "SMFocusUp", "SMFocusRight", "SMFocusLeft",
            "SMPress", "SMHold" }) do
        local body = src:match("\nfunction StartMenu:on" .. name .. "%(%)\n(.-)\nend\n")
        assert(body, name .. " moved")
        assert(body:find("if self:_revealCursor() then return true end", 1, true),
            name .. " acts before the cursor is shown")
    end
end)

t.done()
