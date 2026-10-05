-- tests/_test_add_tile.lua
-- The shelf of shelves' "+ Add shelf" tile: a dashed outline, not a
-- placeholder cover. The dash layout must start and end every side on a
-- dash (so corners are drawn), never overrun, and fall back to a solid
-- line on a side too short to dash. The views must use the tile.
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq

-- Only AddTile.dashes is exercised; stub what the module requires.
package.loaded["ffi/blitbuffer"] = {}
package.loaded["device"] = { screen = {} }
package.loaded["ui/font"] = {}
package.loaded["ui/geometry"] = {}
package.loaded["ui/gesturerange"] = {}
package.loaded["ui/widget/container/inputcontainer"] = { extend = function(_, o) return o end }
package.loaded["ui/widget/textboxwidget"] = {}
local AddTile = dofile("lib/bookshelf_add_tile.lua")

local function check(len, dash, gap)
    local d = AddTile.dashes(len, dash, gap)
    assert(#d >= 1, "no dashes for " .. len)
    eq(d[1][1], 0, "first dash not at the corner (len " .. len .. ")")
    eq(d[#d][1] + d[#d][2], len, "last dash does not reach the corner (len " .. len .. ")")
    for i = 1, #d do
        assert(d[i][2] > 0, "empty dash")
        if i > 1 then assert(d[i][1] > d[i - 1][1] + d[i - 1][2], "dashes touch or overlap at " .. i) end
    end
    return d
end

t.test("every side starts and ends on a dash, with gaps between", function()
    for _i, len in ipairs({ 40, 99, 100, 257, 400, 1171 }) do check(len, 9, 6) end
end)

t.test("a side too short to dash is one solid line", function()
    local d = check(20, 9, 6)
    eq(#d, 1); eq(d[1][2], 20)
end)

t.test("nothing for a zero-length side", function()
    eq(#AddTile.dashes(0, 9, 6), 0)
end)

t.test("the grid and the list draw the + tile with AddTile", function()
    local row = io.open("lib/bookshelf_shelf_row.lua"):read("*a")
    assert(row:find('require("lib/bookshelf_add_tile")', 1, true), "the cover grid does not use AddTile")
    local lg = io.open("lib/bookshelf_list_group.lua"):read("*a")
    assert(lg:find('require("lib/bookshelf_add_tile")', 1, true), "the list does not use AddTile")
end)

t.done()
