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
local eq = helpers.eq
local src = io.open("lib/bookshelf_chip_editor.lua"):read("*a")

-- The reader, and the decision it drives, lifted out by name.
local read = src:match("(local function authorOn%(%).-\n            end)")
assert(read, "authorOn moved or was renamed")
local decide = src:match("(if authorOn%(%) then\n.-\n                      end)")
assert(decide, "the Author on spine callback moved or was renamed")

local function tapper()
    local draft = {}
    local env = { draft = draft }
    local body = read .. "\n" .. decide
    local tap = assert(load("return function()\n" .. body .. "\nend",
                            "toggle", "t", env))()
    local on = assert(load("return function()\n" .. read
                           .. "\nreturn authorOn()\nend", "read", "t", env))()
    return draft, tap, on
end

t.test("a tap turns it off, and the next turns it back on", function()
    local draft, tap, on = tapper()
    eq(on(), true, "unset should read as on, which is the default")
    tap()
    eq(draft.spine_show_author, false, "the tap has to PIN it off")
    eq(on(), false, "the tick should have cleared")
    tap()
    eq(on(), true, "and come back")
end)

t.test("it keeps alternating, which is all the reader asked for", function()
    local draft, tap, on = tapper()
    local seen = {}
    for i = 1, 6 do tap(); seen[#seen + 1] = on() and "on" or "off" end
    eq(table.concat(seen, ","), "off,on,off,on,off,on",
       "the row stopped responding after " .. tostring(#seen) .. " taps")
end)

t.test("off is stored as false, not as absence", function()
    -- nil means "follow the default" everywhere else in this editor, and the
    -- default is on, so absence cannot express off.
    local draft, tap = tapper()
    tap()
    assert(draft.spine_show_author == false,
        "stored " .. tostring(draft.spine_show_author) .. "; nil would follow "
        .. "the default straight back to on")
end)

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
