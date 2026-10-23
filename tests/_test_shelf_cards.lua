-- tests/_test_shelf_cards.lua (SPIKE) -- cards in a cover shelf's slots.
package.path = "./?.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()
local SC = dofile("lib/bookshelf_shelf_cards.lua")
local function books(n) local o = {} for i = 1, n do o[i] = { filepath = "/b" .. i } end return o end
local function show(list)
    local s = {}
    for i = 1, #list do
        local it = list[i]
        s[i] = it.shelf_card and ("C" .. it.part) or it.shelf_blank and "_" or it.filepath:sub(3)
    end
    return table.concat(s, " ")
end

t.test("a card two slots wide on row 1 pushes the books along", function()
    local out = SC.inject(books(6), { { at = { page = 1, col = 2, row = 1, w = 2 } } }, 4, 8)
    assert(show(out) == "1 C1 C2 2 3 4 5 6", show(out))
end)

t.test("cards on a later page sit at that page's slots", function()
    local out = SC.inject(books(12), { { at = { page = 2, col = 1, row = 1, w = 1 } } }, 4, 8)
    assert(out[9].shelf_card and out[8].filepath == "/b8" and out[10].filepath == "/b9")
end)

t.test("a card past the last book still stands in its slot", function()
    local out = SC.inject(books(2), { { at = { page = 1, col = 1, row = 2, w = 2 } } }, 4, 8)
    assert(show(out) == "1 2 _ _ C1 C2", show(out))
end)

t.test("a card is kept inside its row, and the cached list is untouched", function()
    local src = books(3)
    local out = SC.inject(src, { { at = { page = 1, col = 4, row = 1, w = 3 } } }, 4, 8)
    assert(show(out) == "1 2 3 C1", show(out))
    assert(#src == 3 and src[1].filepath == "/b1")
end)

t.test("no cards: the same list back", function()
    local src = books(3)
    assert(SC.inject(src, {}, 4, 8) == src)
end)

-- A windowed source (one page fetched at a time) asks for the books from the
-- page's first BOOK, which the cards before it have moved along.
t.test("windowed: page 2 fetches from the book the cards pushed along", function()
    local taken, order = SC.slots({ { at = { page = 1, col = 2, row = 1, w = 2 } } }, 4, 8)
    assert(SC.slotsBefore(order, 9) == 2, "page 2 starts 2 books earlier")
    assert(SC.slotsBefore(order, 1) == 0)
end)

t.test("windowed: a page lays its cards and books out slot by slot", function()
    local taken = SC.slots({ { at = { page = 1, col = 2, row = 1, w = 2 } } }, 4, 8)
    local page = SC.page(books(8), taken, 1, 8)
    assert(show(page) == "1 C1 C2 2 3 4 5 6", show(page))
    local short = SC.page(books(1), taken, 1, 8)
    assert(show(short) == "1 C1 C2", show(short))
end)

t.test("windowed: the shelf's total counts the cards among the books", function()
    local _t, order = SC.slots({ { at = { page = 1, col = 2, row = 1, w = 2 } } }, 4, 8)
    assert(SC.total(10, order) == 12)
    local _t2, far = SC.slots({ { at = { page = 9, col = 1, row = 1, w = 1 } } }, 4, 8)
    assert(SC.total(10, far) == 10, "a card far past the books adds no page")
end)

t.done()
