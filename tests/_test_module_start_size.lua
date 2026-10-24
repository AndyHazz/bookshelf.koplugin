-- tests/_test_module_start_size.lua
-- A module can say what size it starts at (spec start_w / start_h). The
-- Ornament module starts at one cell, so a new one drops into any free cell
-- on the page instead of needing a page of its own; ornaments are used to
-- fill small gaps (maintainer).
--
-- Usage (from plugin root): lua tests/_test_module_start_size.lua
package.path = "./?.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()
local src = assert(io.open("lib/bookshelf_hero_modules.lua")):read("*a")
local body = assert(src:match("\n(function HeroModules%._sizeFor%(entry, dims%).-\nend)\n"))
local defs = {}
local HM = {}
assert(load(body, "s", "t", { HeroModules = HM, type = type, math = math,
    Modules = { get = function(k) return defs[k] end },
    Grid = { defaultSize = function(_d, square) return square and 2 or 3, 2 end } }))()
local dims = { cols = 6, rows = 8 }

t.test("a module that says so starts at its own size", function()
    defs.orn = { start_w = 1, start_h = 1 }
    local w, h = HM._sizeFor({ module = "orn" }, dims)
    assert(w == 1 and h == 1, w .. "x" .. h)
end)

t.test("its minimum still wins, and the grid's size", function()
    defs.x = { start_w = 1, start_h = 1, min_w = 2 }
    local w, h = HM._sizeFor({ module = "x" }, dims)
    assert(w == 2 and h == 1, w .. "x" .. h)
    defs.big = { start_w = 9, start_h = 9 }
    w, h = HM._sizeFor({ module = "big" }, dims)
    assert(w == 6 and h == 8, w .. "x" .. h)
end)

t.test("one that does not, the grid's default as before", function()
    defs.plain = {}
    local w, h = HM._sizeFor({ module = "plain" }, dims)
    assert(w == 3 and h == 2, w .. "x" .. h)
end)

t.test("the Ornament module starts at one cell", function()
    local orn = assert(io.open("micromodules/ornament.lua")):read("*a")
    assert(orn:find("start_w = 1", 1, true) and orn:find("start_h = 1", 1, true))
end)

t.done()
