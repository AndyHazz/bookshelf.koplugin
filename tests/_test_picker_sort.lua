-- tests/_test_picker_sort.lua
-- A grouped-source picker (Home > Source > Author, Series, Genre...) lists its
-- choices A-Z or by how many books each has (maintainer: "an option to sort
-- a-z or by number of books" on the strip beside the search box).
--
-- Usage (from plugin root): lua tests/_test_picker_sort.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq
local Sort = require("lib/bookshelf_picker_sort")

local function labels(list)
    local out = {}
    for i, c in ipairs(list) do out[i] = c.label end
    return table.concat(out, ",")
end
local choices = {
    { value = "b", label = "beckett", count = 2 },
    { value = "a", label = "Austen", count = 6 },
    { value = "c", label = "Christie", count = 6 },
    { value = "d", label = "Dickens", count = 9 },
}

t.test("A-Z ignores case", function()
    eq(labels(Sort.sort(choices, "az")), "Austen,beckett,Christie,Dickens")
end)

t.test("most books first, ties A-Z", function()
    eq(labels(Sort.sort(choices, "count")), "Dickens,Austen,Christie,beckett")
end)

t.test("sorting leaves the caller's list alone", function()
    Sort.sort(choices, "count")
    eq(choices[1].label, "beckett")
end)

t.test("an unknown order falls back to A-Z", function()
    eq(labels(Sort.sort(choices, nil)), "Austen,beckett,Christie,Dickens")
end)

t.test("only lists with book counts offer the switch", function()
    eq(Sort.hasCounts(choices), true)
    eq(Sort.hasCounts({ { label = "5 stars", value = "5" }, { label = "Unrated", value = "unrated" } }), false)
    eq(Sort.hasCounts({}), false)
end)

t.test("the switch names both orders", function()
    local items = Sort.items()
    eq(#items, 2)
    eq(items[1].key, "az"); eq(items[2].key, "count")
end)

t.done()
