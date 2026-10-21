-- Headless tests for lib/bookshelf_module_grid.lua: grid dimensions and the
-- pixel <-> cell geometry the renderer and the layout editor share.
package.path = "./?.lua;./?/init.lua;" .. package.path

local Grid = dofile("lib/bookshelf_module_grid.lua")
local t = dofile("tests/_helpers.lua").runner()

t.test("fullscreen portrait is 6 columns, rows for squarest cells (PW5)", function()
    local d = Grid.dims("fullscreen", 1180, 1450, 20, {})
    assert(d.cols == 6 and d.rows == 7, d.cols .. "x" .. d.rows)
    assert(d.cell_w == math.floor((1180 - 5 * 20) / 6), "cell_w " .. d.cell_w)
    assert(d.gap == 20)
end)

t.test("tall phone-shaped panel gets more rows", function()
    local d = Grid.dims("fullscreen", 780, 1450, 16, {})
    assert(d.cols == 6 and d.rows == 11, d.cols .. "x" .. d.rows)
end)

t.test("squarer panel gets 6 rows", function()
    local d = Grid.dims("fullscreen", 720, 760, 16, {})
    assert(d.cols == 6 and d.rows == 6, d.cols .. "x" .. d.rows)
end)

t.test("landscape fullscreen keeps cells near the portrait size", function()
    local d = Grid.dims("fullscreen", 1590, 1030, 20, { landscape = true, short_side = 1236 })
    assert(d.cols == 8 and d.rows == 5, d.cols .. "x" .. d.rows)
end)

t.test("panel aims for 2 rows of square cells", function()
    local d = Grid.dims("panel", 1180, 500, 20, { min_row_h = 110 })
    assert(d.rows == 2 and d.cols == 5, d.cols .. "x" .. d.rows)
end)

t.test("short panel drops to 1 row", function()
    local d = Grid.dims("panel", 1180, 200, 20, { min_row_h = 110 })
    assert(d.rows == 1, "rows " .. d.rows)
end)

t.test("rect spans cells and the gaps between them", function()
    local d = { cols = 4, rows = 5, cell_w = 100, cell_h = 90, gap = 10 }
    local x, y, w, h = Grid.rect(d, { col = 2, row = 3, w = 2, h = 2 })
    assert(x == 110 and y == 200 and w == 210 and h == 190,
        table.concat({ x, y, w, h }, ","))
end)

t.test("cellAt maps points, gaps return nil", function()
    local d = { cols = 4, rows = 5, cell_w = 100, cell_h = 90, gap = 10 }
    local c, r = Grid.cellAt(d, 115, 205)
    assert(c == 2 and r == 3, tostring(c) .. "," .. tostring(r))
    assert(Grid.cellAt(d, 105, 5) == nil, "gap column should miss")
    assert(Grid.cellAt(d, 9999, 5) == nil, "outside should miss")
end)

t.test("toolbar floats away from the selection", function()
    assert(Grid.toolbarSide(100, 300, 1600) == "bottom")
    assert(Grid.toolbarSide(1100, 300, 1600) == "top")
end)

t.test("page dots are centred and evenly spaced", function()
    local r = Grid.dotRects(3, 300, 20, 6, 30)
    assert(#r == 3)
    assert(r[2].x + r[2].w / 2 == 150, "middle dot not centred")
    assert(r[2].x - r[1].x == 30 and r[3].x - r[2].x == 30)
    assert(r[1].y == 7 and r[1].h == 6)
end)

t.test("dotAt finds the nearest dot's page index within its slot", function()
    local r = Grid.dotRects(3, 300, 20, 6, 30)
    assert(Grid.dotAt(r, 30, 150) == 2)
    assert(Grid.dotAt(r, 30, 125) == 1)
    assert(Grid.dotAt(r, 30, 10) == nil, "far left should miss")
end)

t.test("nearestCell snaps a tap in a gap to the closest cell", function()
    local d = { cols = 4, rows = 5, cell_w = 100, cell_h = 90, gap = 10 }
    local c, r = Grid.nearestCell(d, 108, 5)       -- in the gap, nearer column 2
    assert(c == 2 and r == 1, c .. "," .. r)
    c, r = Grid.nearestCell(d, 101, 95)            -- gap corner, nearer column 1 row 1
    assert(c == 1 and r == 1, c .. "," .. r)
    assert(Grid.nearestCell(d, 9999, 5) == nil, "far outside should miss")
end)

t.test("a new module's size follows the grid", function()
    local fs  = { cols = 6, rows = 7 }
    local pan = { cols = 7, rows = 2 }
    local old = { cols = 4, rows = 2 }
    local w, h = Grid.defaultSize(fs, true);   assert(w == 2 and h == 2, "fs square " .. w .. "x" .. h)
    w, h = Grid.defaultSize(fs, false);        assert(w == 3 and h == 2, "fs card " .. w .. "x" .. h)
    w, h = Grid.defaultSize(pan, false);       assert(w == 3 and h == 2, "panel card " .. w .. "x" .. h)
    w, h = Grid.defaultSize(old, true);        assert(w == 1 and h == 1, "small grid square " .. w .. "x" .. h)
    w, h = Grid.defaultSize({ cols = 6, rows = 1 }, true)
    assert(h == 1, "never taller than the grid")
end)

t.done()
