-- tests/_test_shelf_modules.lua
-- Modules standing on a shelf among its books, stored by ORDER (after N
-- items) so they flow with the books when the layout changes.
package.path = "./?.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()
local SM = dofile("lib/bookshelf_shelf_modules.lua")
local function show(s)
    local o = {}
    for i, d in ipairs(s) do
        o[i] = d.item and tostring(d.item) or d.module and (d.module.id .. d.part) or "_"
    end
    return table.concat(o, " ")
end

t.test("a module after the first item, two slots wide", function()
    local s = SM.stream(6, { { id = "a", after = 1, w = 2 } }, 4)
    assert(show(s) == "1 a1 a2 2 3 4 5 6", show(s))
end)

t.test("a module that doesn't fit the rest of a row starts the next one", function()
    local s = SM.stream(6, { { id = "a", after = 3, w = 2 } }, 4)
    assert(show(s) == "1 2 3 _ a1 a2 4 5 6", show(s))
end)

t.test("fewer columns: the same order, a new layout", function()
    local mods = { { id = "a", after = 1, w = 2 } }
    assert(show(SM.stream(4, mods, 3)) == "1 a1 a2 2 3 4", show(SM.stream(4, mods, 3)))
    local wide = { { id = "b", after = 0, w = 4 } }
    assert(show(SM.stream(2, wide, 3)) == "b1 b2 b3 1 2", "narrowed to the row")
end)

t.test("several modules, in order, ties keep theirs", function()
    local s = SM.stream(3, { { id = "b", after = 2, w = 1 }, { id = "a", after = 0, w = 1 }, { id = "c", after = 2, w = 1 } }, 4)
    assert(show(s) == "a1 1 2 b1 c1 3", show(s))
end)

t.test("a module after the last item stands after it", function()
    local s = SM.stream(2, { { id = "a", after = 9, w = 1 } }, 4)
    assert(show(s) == "1 2 a1", show(s))
end)

t.test("a page window: its slots and the items a windowed fetch needs", function()
    local mods = { { id = "a", after = 1, w = 2 } }
    local page, first, count = SM.window(20, mods, 4, 9, 8)
    assert(first == 7 and count == 8, first .. " " .. count)
    local p1, f1, c1 = SM.window(20, mods, 4, 1, 8)
    assert(f1 == 1 and c1 == 6 and show(p1) == "1 a1 a2 2 3 4 5 6", show(p1))
end)

t.test("total counts the modules and any blanks", function()
    assert(SM.total(6, { { id = "a", after = 3, w = 2 } }, 4) == 9)
end)

t.test("the editor's grid places convert back to order", function()
    -- a at slot 2 (w 2), b at slot 7 (w 1): b has 6 slots before it, two are a's.
    local after = SM.afterFromSlots({ { id = "b", slot = 7, w = 1 }, { id = "a", slot = 2, w = 2 } })
    assert(after.a == 1 and after.b == 4, after.a .. " " .. after.b)
    -- and the round trip lays them out where they were put.
    local s = SM.stream(10, { { id = "a", after = after.a, w = 2 }, { id = "b", after = after.b, w = 1 } }, 4)
    local at = SM.slots(10, { { id = "a", after = after.a, w = 2 }, { id = "b", after = after.b, w = 1 } }, 4)
    assert(at.a == 2 and at.b == 7, show(s))
end)

t.test("spines: modules join the item list in order", function()
    local items = { { id = 1 }, { id = 2 }, { id = 3 } }
    local out = SM.insertItems(items, { { id = "a", after = 1 }, { id = "z", after = 99 } })
    assert(#out == 5 and out[2].shelf_module.id == "a" and out[5].shelf_module.id == "z")
    assert(#items == 3, "the cached list is untouched")
end)

-- A row with room for the module's narrowest width takes it there,
-- narrowed, rather than leaving the row half empty (3 columns: one book, then
-- a 3-wide streak, left two blank slots and a page of one book).
t.test("the rest of a row takes a module narrowed to its minimum", function()
    local minw = function() return 2 end
    local s = SM.stream(4, { { id = "a", after = 1, w = 3 } }, 3, nil, minw)
    assert(show(s) == "1 a1 a2 2 3 4", show(s))
    local tight = SM.stream(4, { { id = "a", after = 2, w = 3 } }, 3, nil, minw)
    assert(show(tight) == "1 2 _ a1 a2 a3 3 4", "one slot left is under its minimum: " .. show(tight))
end)

-- A windowed spine shelf: a page is fetched from a position in the list WITH
-- its modules, so its books start after the modules before it.
t.test("spines, windowed: the page's books and modules", function()
    local mods = { { id = "a", after = 1 }, { id = "b", after = 3 } }   -- at 2 and 5
    local before = SM.spineWindow(mods, 4)
    assert(before == 2, "position 4: books 1-2 and module a come before it, got " .. before)
    local books = { { id = 3 }, { id = 4 }, { id = 5 }, { id = 6 } }
    local page = SM.spinePage(books, 6, mods, 4, 5)
    local ids = {}
    for i, it in ipairs(page) do ids[i] = it.shelf_module and it.shelf_module.id or tostring(it.id) end
    assert(table.concat(ids, " ") == "3 b 4 5 6", table.concat(ids, " "))
end)

t.test("spines, windowed: modules after the last book end the shelf", function()
    local page = SM.spinePage({ { id = 1 } }, 1, { { id = "z", after = 9 } }, 1, 10)
    assert(#page == 2 and page[2].shelf_module.id == "z")
end)

t.done()
