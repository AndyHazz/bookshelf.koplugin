-- tests/_test_shelf_module_step.lua
-- A shelf module's < and > (and a swipe on it) move it one thing along the
-- shelf: past the next book, or past a module standing beside it. Modules
-- share an `after` (the books before them) and keep their list order there,
-- so a step that only changed `after` jumped: a pinned skull just after a box
-- set went, on one <, to the start of the row of modules above (maintainer,
-- PW5).
--
-- Usage (from plugin root): lua tests/_test_shelf_module_step.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local t  = dofile("tests/_helpers.lua").runner()
local eq = dofile("tests/_helpers.lua").eq
local SM = dofile("lib/bookshelf_shelf_modules.lua")

-- The shelf as it reads, books "b<n>" among the modules.
local function shelf(mods, n_books)
    local out = {}
    for _i, x in ipairs(SM.insertItems((function()
        local items = {}
        for i = 1, n_books do items[i] = { title = "b" .. i } end
        return items
    end)(), mods)) do
        out[#out + 1] = x.shelf_module and x.shelf_module.id or x.title
    end
    return table.concat(out, " ")
end

t.test("one step left past a book lands just before it, not before the modules", function()
    -- The PW5: a chart and a random book module before the first item, the
    -- skull pinned after it. The skull was first in the list.
    local mods = { { id = "skull", after = 1 }, { id = "chart", after = 0 }, { id = "random", after = 0 } }
    eq(shelf(mods, 3), "chart random b1 skull b2 b3")
    mods = SM.step(mods, "skull", -1)
    eq(shelf(mods, 3), "chart random skull b1 b2 b3")
end)

t.test("a step past a module beside it swaps the two", function()
    local mods = { { id = "chart", after = 0 }, { id = "random", after = 0 }, { id = "skull", after = 0 } }
    mods = SM.step(mods, "skull", -1)
    eq(shelf(mods, 2), "chart skull random b1 b2")
    mods = SM.step(mods, "skull", -1)
    eq(shelf(mods, 2), "skull chart random b1 b2")
    eq(SM.step(mods, "skull", -1), nil, "nothing further left")
    assert(not SM.canStep(mods, "skull", -1))
end)

t.test("right steps mirror left, one thing at a time", function()
    local mods = { { id = "a", after = 0 }, { id = "skull", after = 0 }, { id = "c", after = 1 } }
    mods = SM.step(mods, "skull", 1)
    eq(shelf(mods, 2), "a b1 skull c b2")
    mods = SM.step(mods, "skull", 1)
    eq(shelf(mods, 2), "a b1 c skull b2")
    mods = SM.step(mods, "skull", 1)
    eq(shelf(mods, 2), "a b1 c b2 skull")
    assert(SM.canStep(mods, "skull", -1))
end)

t.test("the menu's nudge and swipe use the step", function()
    local w = io.open("lib/bookshelf_widget.lua"):read("*a")
    assert(w:find("local moved = SM.step(l, id, dir)", 1, true), "the nudge only changes after")
    assert(w:find("left     = SM.canStep(SM.list(TabModel.getById(bw.chip)) or {}, id, -1)", 1, true),
        "< is offered only by after")
end)

t.done()
