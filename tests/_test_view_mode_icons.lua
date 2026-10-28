-- tests/_test_view_mode_icons.lua
-- The View mode card on the editor's front page and the style cards on its
-- page show the same icon for each look (maintainer: the Spines card kept
-- the old library icon).
package.path = "./?.lua;./?/init.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()

local src = io.open("lib/bookshelf_chip_editor.lua"):read("*a")

t.test("each style card's icon is the one the View mode card shows", function()
    local mode = src:match("\nfunction Editor%._modeIcon%(.-\nend\n")
    assert(mode, "no _modeIcon")
    for _i, pair in ipairs({ { "Spines", "SPINES" }, { "List", "LIST" } }) do
        local want = mode:match("ViewMode%." .. pair[2] .. " then return \"(.-)\"")
        local got = src:match('styleCard%(_%("' .. pair[1] .. '"%), "(.-)"')
        assert(want and got == want, pair[1] .. ": " .. tostring(got) .. " vs " .. tostring(want))
    end
    local covers = src:match('styleCard%(_%("Covers"%), "(.-)"')
    assert(covers and mode:find('return "' .. covers .. '"', 1, true), "Covers")
end)

t.done()
