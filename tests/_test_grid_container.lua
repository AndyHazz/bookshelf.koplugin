-- tests/_test_grid_container.lua
-- lib/bookshelf_grid_container: paints each micro-module cell at its own
-- offset inside the grid (the cell grid has gaps, so a row/column group can't
-- express it) and records where the grid landed on screen, which is what the
-- layout editor hit-tests taps against.
package.path = "./?.lua;./?/init.lua;" .. package.path

package.loaded["ui/geometry"] = {
    new = function(_self, t) return t or {} end,
}
local WidgetContainer = {}
WidgetContainer.__index = WidgetContainer
function WidgetContainer:extend(props)
    local cls = props or {}
    cls.__index = cls
    return setmetatable(cls, { __index = self })
end
function WidgetContainer:new(o)
    o = o or {}
    return setmetatable(o, self)
end
function WidgetContainer:handleEvent(ev)
    for _i, c in ipairs(self) do
        if c.handleEvent and c:handleEvent(ev) then return true end
    end
    return false
end
package.loaded["ui/widget/container/widgetcontainer"] = WidgetContainer

local GridContainer = dofile("lib/bookshelf_grid_container.lua")
local t = dofile("tests/_helpers.lua").runner()

local function child()
    local c = { painted = {} }
    function c:paintTo(_bb, x, y) self.painted[#self.painted + 1] = { x, y } end
    return c
end

t.test("children paint at their own offsets from the grid origin", function()
    local a, b = child(), child()
    local g = GridContainer:new{
        dimen = { w = 400, h = 300 },
        pos = { { x = 0, y = 0 }, { x = 110, y = 200 } },
        a, b,
    }
    g:paintTo({}, 5, 7)
    assert(a.painted[1][1] == 5 and a.painted[1][2] == 7)
    assert(b.painted[1][1] == 115 and b.painted[1][2] == 207,
        b.painted[1][1] .. "," .. b.painted[1][2])
end)

t.test("the grid records its screen position on paint", function()
    local g = GridContainer:new{ dimen = { w = 400, h = 300 }, pos = {} }
    g:paintTo({}, 12, 34)
    assert(g.dimen.x == 12 and g.dimen.y == 34)
    assert(g:getSize().w == 400 and g:getSize().h == 300)
end)

t.test("under paints before the cells and over after them", function()
    local order = {}
    local c = { paintTo = function() order[#order + 1] = "cell" end }
    local g = GridContainer:new{
        dimen = { w = 10, h = 10 }, pos = { { x = 0, y = 0 } }, c,
        under = function() order[#order + 1] = "under" end,
        over  = function() order[#order + 1] = "over" end,
    }
    g:paintTo({}, 0, 0)
    assert(table.concat(order, ",") == "under,cell,over", table.concat(order, ","))
end)

t.test("a swapped child keeps its slot's offset", function()
    local g = GridContainer:new{
        dimen = { w = 400, h = 300 }, pos = { { x = 0, y = 0 }, { x = 110, y = 0 } },
        child(), child(),
    }
    local fresh = child()
    g[2] = fresh
    g:resetLayout()
    g:paintTo({}, 0, 0)
    assert(fresh.painted[1][1] == 110)
end)

-- A long-press between the modules (an empty cell, a gap) opens the layout
-- editor, as a long-press on a module does: the grid takes a hold no cell
-- took. Built as KOReader's Event:new builds one: handler = "on" .. name.
local function hold(x, y, kind)
    return { handler = "onGesture", args = { { ges = kind or "hold", pos = { x = x, y = y } } } }
end

t.test("a hold no cell takes reaches the grid's hold hook", function()
    local held = 0
    local g = GridContainer:new{ dimen = { w = 400, h = 300 }, pos = {},
        hold = function() held = held + 1 end }
    g:paintTo({}, 10, 20)
    assert(g:handleEvent(hold(200, 100)) == true and held == 1, "the empty space ignored the hold")
    assert(g:handleEvent(hold(5, 5)) == false and held == 1, "took a hold outside the grid")
    assert(g:handleEvent(hold(200, 100, "tap")) == false and held == 1, "took a tap")
end)

t.test("a cell's own hold wins, and no hook means no hold", function()
    local held = 0
    local cell = child()
    function cell:handleEvent() return true end
    local g = GridContainer:new{ dimen = { w = 400, h = 300 }, pos = { { x = 0, y = 0 } }, cell,
        hold = function() held = held + 1 end }
    g:paintTo({}, 0, 0)
    assert(g:handleEvent(hold(50, 50)) == true and held == 0, "the grid took the cell's hold")
    local bare = GridContainer:new{ dimen = { w = 400, h = 300 }, pos = {} }
    bare:paintTo({}, 0, 0)
    assert(bare:handleEvent(hold(50, 50)) == false, "a grid with no hook took a hold")
end)

t.test("the top panel and full screen grids open the editor from empty space", function()
    local src = io.open("lib/bookshelf_hero_modules.lua"):read("*a")
    assert(src:find("if not edit then\n        container.hold = function() HeroModules._hold(bw, nil) end", 1, true),
           "no hold hook on the module grid")
end)

t.done()
