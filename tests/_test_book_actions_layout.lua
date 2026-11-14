-- tests/_test_book_actions_layout.lua
-- The book popup's Actions cards in the reader's own order, with the ones
-- they hid left out (lib/bookshelf_book_actions_layout).
-- Run from the plugin root: lua tests/_test_book_actions_layout.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t = H.runner()
t.eq = H.eq
local Arr = require("lib/bookshelf_book_actions_layout")

local function specs(...)
    local out = {}
    for i, id in ipairs({ ... }) do out[i] = { id = id } end
    return out
end
local function ids(list)
    local out = {}
    for i, a in ipairs(list) do out[i] = a.id end
    return table.concat(out, ",")
end

t.test("no saved layout keeps the default order", function()
    t.eq(ids(Arr.arrange(specs("fav", "info", "delete"), {})), "fav,info,delete")
end)

t.test("a saved order wins; actions it doesn't know go last, in default order", function()
    local got = Arr.arrange(specs("fav", "info", "delete", "plugin:A"),
        { order = { "delete", "fav" } })
    t.eq(ids(got), "delete,fav,info,plugin:A")
end)

t.test("a saved id with no action (a plugin since removed) is skipped", function()
    t.eq(ids(Arr.arrange(specs("fav", "info"), { order = { "plugin:Gone", "info" } })), "info,fav")
end)

t.test("a new action that names its neighbor lands beside it in a saved order", function()
    -- A reader with a saved order found the new cards (issue 390) at the very
    -- end, under the fold: a new action says which card it belongs after.
    local list = specs("fav", "shelf", "shelf_move", "info", "delete")
    list[2].after = "fav"; list[3].after = "shelf"
    local got = Arr.arrange(list, { order = { "fav", "delete", "info" } })
    t.eq(ids(got), "fav,shelf,shelf_move,delete,info")
    -- Once the reader has placed it, their place wins.
    list = specs("fav", "shelf", "info")
    list[2].after = "fav"
    t.eq(ids(Arr.arrange(list, { order = { "shelf", "info", "fav" } })), "shelf,info,fav")
    -- No saved order: the default order, untouched.
    list = specs("fav", "shelf", "info")
    list[2].after = "fav"
    t.eq(ids(Arr.arrange(list, nil)), "fav,shelf,info")
    -- A neighbor that is not there: it goes last, as any unknown action.
    list = specs("info", "shelf")
    list[2].after = "fav"
    t.eq(ids(Arr.arrange(list, { order = { "info" } })), "info,shelf")
    -- The hint is not left on the action.
    t.eq(got[2].after, "fav")
end)

t.test("hidden actions are marked, and visible() leaves them out", function()
    local got = Arr.arrange(specs("fav", "info", "delete"), { hidden = { info = true } })
    t.eq(got[2].hidden, true)
    t.eq(ids(Arr.visible(got)), "fav,delete")
end)

t.test("move shifts one place and stops at the ends", function()
    local order = { "a", "b", "c" }
    t.eq(table.concat(Arr.move(order, "b", -1), ","), "b,a,c")
    t.eq(table.concat(Arr.move(order, "b", 1), ","), "a,c,b")
    t.eq(table.concat(Arr.move(order, "a", -1), ","), "a,b,c")
    t.eq(table.concat(Arr.move(order, "c", 1), ","), "a,b,c")
    -- The input is left alone.
    t.eq(table.concat(order, ","), "a,b,c")
end)

t.test("the last visible action can't be hidden", function()
    local list = Arr.arrange(specs("a", "b"), { hidden = { a = true } })
    t.eq(Arr.canHide(list, { a = true }, "b"), false)
    t.eq(Arr.canHide(list, {}, "a"), true)
end)

t.test("the cards try five columns first, and fewer when a label would take three lines", function()
    -- Maintainer: nine cards in four columns left one alone on a third row,
    -- below the fold on a PW5.
    local src = io.open("lib/bookshelf_widget_book_popup.lua"):read("*a")
    local grid = src:match("%-%- 3%. Actions:(.-)local tile_w = ")
    assert(grid, "the Actions grid moved")
    assert(grid:find("local cols = 5\n", 1, true), "the grid starts from some other column count")
    assert(grid:find("while cols > 2 do", 1, true), "no fallback for long labels or a big zoom")
end)

t.done()
