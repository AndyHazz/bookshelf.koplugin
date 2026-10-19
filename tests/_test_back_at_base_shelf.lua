-- tests/_test_back_at_base_shelf.lua
-- Issue 542: with KOReader's "Back in file browser: parent folder", Back on
-- the base shelf fell through to the file browser, which walked to the
-- folder above the library (unbounded), and the shelf followed it there.
-- The base shelf is now as far back as Back goes; with the default setting
-- the press still falls through to KOReader's "Exit KOReader?" prompt.
-- Run from the plugin root: lua tests/_test_back_at_base_shelf.lua
package.path = "./?.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()
local src = io.open("lib/bookshelf_widget.lua"):read("*a")
local body = src:match("\n(function BookshelfWidget:onBSDrillBack%(%).-\nend)\n")
assert(body, "onBSDrillBack moved")

local function run(depth, back_setting)
    local popped
    local env = setmetatable({
        BookshelfWidget = {},
        G_reader_settings = { readSetting = function(_, k)
            if k == "back_in_filemanager" then return back_setting end
        end },
    }, { __index = _G })
    local chunk = assert((loadstring or load)(body, "back", "t", env))
    if setfenv then setfenv(chunk, env) end
    chunk()
    local w = { _navDepth = function() return depth end,
                _navBackTo = function(_, d) popped = d end }
    local handled = env.BookshelfWidget.onBSDrillBack(w)
    return handled, popped
end

t.test("inside a drilldown Back pops one level", function()
    local handled, popped = run(2, "parent_folder")
    assert(handled == true and popped == 1)
end)

t.test("on the base shelf with parent folder, Back goes no further", function()
    local handled, popped = run(0, "parent_folder")
    assert(handled == true, "Back fell through to the file browser, which climbs above the library")
    assert(popped == nil)
end)

t.test("on the base shelf with the default setting, KOReader's exit prompt still gets it", function()
    assert(run(0, nil) == false)
    assert(run(0, "default") == false)
end)

t.done()
