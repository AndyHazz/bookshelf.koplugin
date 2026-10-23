--[[
Shelf cards (SPIKE): micro-module cards standing on a cover shelf, taking the
slots of books.

A card is stored on its shelf's record (tab.shelf_cards), positioned in book
slots: at = { page, col, row, w } (one row tall in this spike). The shelf's
whole book list is fetched and then cut into pages of rows * columns slots;
inject() turns that list into a list of SLOTS, with a placeholder wherever a
card stands, so the existing page arithmetic (totals, page count, slicing,
cursor) is untouched and the books simply flow after the cards. The cover
rows turn placeholders back into empty slots and draw the card over them.
]]
local M = {}

-- cardsFor(tab) -> the shelf's cards, or nil.
function M.cardsFor(tab)
    if type(tab) ~= "table" or type(tab.shelf_cards) ~= "table" or #tab.shelf_cards == 0 then
        return nil
    end
    return tab.shelf_cards
end

-- span(at, n_cols) -> how many slots a card takes, kept inside its row.
function M.span(at, n_cols)
    local col = math.max(1, math.min(n_cols, math.floor(tonumber(at.col) or 1)))
    return math.max(1, math.min(math.floor(tonumber(at.w) or 1), n_cols - col + 1)), col
end

-- slotIndex(at, n_cols, view) -> the card's first slot in the slot list.
function M.slotIndex(at, n_cols, view)
    local _w, col = M.span(at, n_cols)
    local page = math.max(1, math.floor(tonumber(at.page) or 1))
    local row = math.max(1, math.floor(tonumber(at.row) or 1))
    return (page - 1) * view + (row - 1) * n_cols + col
end

-- isPlaceholder(item) -> true for a slot a card takes or a blank before one.
function M.isPlaceholder(item)
    return type(item) == "table" and (item.shelf_card ~= nil or item.shelf_blank == true)
end

-- slots(cards, n_cols, view) -> { [slot index] = placeholder }, and the
-- indices sorted. Overlapping cards: the first wins.
function M.slots(cards, n_cols, view)
    local taken, order = {}, {}
    for _i, c in ipairs(cards or {}) do
        local at = type(c.at) == "table" and c.at or {}
        local w = M.span(at, n_cols)
        local base = M.slotIndex(at, n_cols, view)
        for k = 0, w - 1 do
            if not taken[base + k] then
                taken[base + k] = { shelf_card = c, part = k + 1, span = w }
                order[#order + 1] = base + k
            end
        end
    end
    table.sort(order)
    return taken, order
end

-- booksBefore(order, first) -> how many card slots come before slot `first`:
-- a page starting at slot `first` starts at book first - booksBefore.
function M.slotsBefore(order, first)
    local n = 0
    for _i, idx in ipairs(order) do
        if idx < first then n = n + 1 else break end
    end
    return n
end

-- page(books, taken, first, view) -> one page of slots from slot `first`:
-- placeholders where cards stand, `books` (fetched from the matching book)
-- in order in the rest, blanks where the books ran out before a card.
function M.page(books, taken, first, view)
    local out, bi, last_card = {}, 1, 0
    for v = first, first + view - 1 do
        if taken[v] then last_card = v - first + 1 end
    end
    for i = 1, view do
        local v = first + i - 1
        if taken[v] then
            out[i] = taken[v]
        elseif bi <= #books then
            out[i] = books[bi]; bi = bi + 1
        elseif i < last_card then
            out[i] = { shelf_blank = true }
        else
            break
        end
    end
    return out
end

-- total(book_total, order) -> how many slots the shelf has: every book, and
-- every card that stands at or before the end of them.
function M.total(book_total, order)
    local t = book_total
    for _i, idx in ipairs(order) do
        if idx <= t + 1 then t = t + 1 end
    end
    return t
end

-- inject(items, cards, n_cols, view) -> the slot list: books in order, with
-- { shelf_card = card, part = k, span = w } in each slot a card takes, and
-- { shelf_blank = true } where the books ran out before a card. A new table;
-- `items` (a cached list) is left alone. Overlapping cards: the first wins.
function M.inject(items, cards, n_cols, view)
    if type(cards) ~= "table" or #cards == 0 then return items end
    local taken, last = {}, 0
    for _i, c in ipairs(cards) do
        local at = type(c.at) == "table" and c.at or {}
        local w = M.span(at, n_cols)
        local base = M.slotIndex(at, n_cols, view)
        for k = 0, w - 1 do
            if not taken[base + k] then
                taken[base + k] = { shelf_card = c, part = k + 1, span = w }
                if base + k > last then last = base + k end
            end
        end
    end
    local out, bi, v = {}, 1, 1
    while bi <= #items or v <= last do
        if taken[v] then
            out[v] = taken[v]
        elseif bi <= #items then
            out[v] = items[bi]; bi = bi + 1
        else
            out[v] = { shelf_blank = true }
        end
        v = v + 1
    end
    return out
end

return M
