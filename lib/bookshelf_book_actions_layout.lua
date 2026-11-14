-- bookshelf_book_actions_layout.lua
-- The book popup's Actions cards in the reader's own order, with the ones they
-- hid left out. A long-press on a card rearranges them (the Edit tab); the
-- result is one setting: { order = { id, ... }, hidden = { [id] = true } }.
-- Ids are stable names ("favorite", "delete", "plugin:<label>"), so an action
-- that comes or goes (a plugin installed or removed) leaves the rest in place.

local M = {}

M.KEY = "book_popup_actions"

-- arrange(specs, layout) -> a new list: the specs in layout.order, then any it
-- doesn't name in their default order. Each carries .hidden from layout.hidden.
function M.arrange(specs, layout)
    layout = layout or {}
    local rank = {}
    for i, id in ipairs(layout.order or {}) do rank[id] = i end
    local out = {}
    for i, a in ipairs(specs) do out[i] = a; a._default_rank = i end
    table.sort(out, function(a, b)
        local ra, rb = rank[a.id], rank[b.id]
        if ra and rb then return ra < rb end
        if ra or rb then return ra ~= nil end
        return a._default_rank < b._default_rank
    end)
    -- An action the saved order does not know sorted last. One that names a
    -- neighbor (a.after = that card's id) goes straight after it instead,
    -- so a card added by a later version shows up where it belongs, not
    -- under the fold of a reader who arranged their cards before it existed.
    if next(rank) then
        local moved = {}
        for _i, a in ipairs(out) do
            if a.after and not rank[a.id] then moved[#moved + 1] = a end
        end
        for _i, a in ipairs(moved) do
            local from, to
            for k, x in ipairs(out) do
                if x == a then from = k end
            end
            table.remove(out, from)
            for k, x in ipairs(out) do
                if x.id == a.after then to = k end
            end
            if to then table.insert(out, to + 1, a) else table.insert(out, from, a) end
        end
    end
    local hidden = layout.hidden or {}
    for _i, a in ipairs(out) do
        a._default_rank = nil
        a.hidden = hidden[a.id] == true or nil
    end
    return out
end

-- visible(list) -> the arranged list without the hidden ones.
function M.visible(list)
    local out = {}
    for _i, a in ipairs(list) do
        if not a.hidden then out[#out + 1] = a end
    end
    return out
end

-- move(order, id, d) -> a copy of order with id moved d places (stops at the
-- ends).
function M.move(order, id, d)
    local out, at = {}, nil
    for i, v in ipairs(order) do
        out[i] = v
        if v == id then at = i end
    end
    if not at then return out end
    local to = math.max(1, math.min(#out, at + d))
    table.remove(out, at)
    table.insert(out, to, id)
    return out
end

-- canHide(list, hidden, id) -> false when hiding id would leave no card to
-- long-press (the only way back in).
function M.canHide(list, hidden, id)
    for _i, a in ipairs(list) do
        if a.id ~= id and not hidden[a.id] then return true end
    end
    return false
end

return M
