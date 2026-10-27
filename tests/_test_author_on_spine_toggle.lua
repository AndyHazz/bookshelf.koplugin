-- tests/_test_author_on_spine_toggle.lua
-- "Author on spine" turns back off.
--
-- THE REPORT (#439). "Previously had it unselected for Spines view, but
-- wanted to test having it turned on. After turning it on, clicking the same
-- button again doesn't toggle it off, and the checkmark next to it in the
-- chip settings persists."
--
-- THE BUG, one line:
--
--     draft.spine_show_author = authorOn() and false or nil
--
-- In Lua that can never produce false. `true and false` is false, and
-- `false or nil` is nil, so BOTH branches wrote nil. nil means "follow the
-- default", the default is on, so the row ticked itself straight back and
-- there was no way to switch it off from the editor at all.
--
-- The and/or idiom is only a conditional expression while the middle value
-- is truthy. This is the case it cannot express.
--
-- Usage (from plugin root): lua tests/_test_author_on_spine_toggle.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local src = io.open("lib/bookshelf_chip_editor.lua"):read("*a")

-- The toggle itself is driven in _test_chip_editor (shelf style: Author on
-- spine can be turned off and back on).

t.test("the idiom that could not express it is gone", function()
    -- Code only: the fix quotes the old line in a comment, on purpose, so
    -- the next reader knows why it is written the long way.
    for line in src:gmatch("[^\n]+") do
        if not line:match("^%s*%-%-") then
            assert(not line:find("and false or nil", 1, true),
                "`x and false or nil` is nil either way round: " .. line)
        end
    end
end)

t.done()
