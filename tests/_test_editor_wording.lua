-- tests/_test_editor_wording.lua
-- One word for one thing on a page: following the library reads "Default"
-- in the Covers card's summary for both folder tiles and captions.
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t = H.runner()

t.test("the Covers summary says Default for folder tiles that follow the library", function()
    local s = io.open("lib/bookshelf_chip_editor.lua"):read("*a")
    local body = s:match("local function coversSummary%(%)(.-)\n    end\n")
    assert(body, "coversSummary moved")
    assert(body:find('if cur == StackDisplay.FOLLOW_DEFAULT then label = _("Default") end', 1, true),
        "folder tiles read \"Default setting\" beside captions' \"Default\"")
end)

t.done()
