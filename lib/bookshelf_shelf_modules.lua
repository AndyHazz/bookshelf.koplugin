--[[
Shelf modules: micro-modules standing on a shelf among its books, one row
tall, on cover shelves and spine shelves.

A module is stored on its shelf's record (tab.shelf_modules) by ORDER, not by
place: after = how many of the shelf's items (books, groups, folders) come
before it, w = how wide it is (cover slots on a cover shelf; face-out cover
widths on a spine shelf). So it flows with the books when the columns, the
rows or the screen's orientation change, the way a book would.

Cover shelves lay out in SLOTS: a stream of item slots, module slots and, where
a module doesn't fit in what is left of a row, blank slots before it so it
starts the next row. The shelf's cursor and page arithmetic count slots, so
everything that pages a cover shelf works unchanged. Spine shelves take each
module as one more item in their list (insertItems); the plan stands it on the
plank at its width.
]]
local M = {}

M.KEY = "shelf_modules"

-- list(tab) -> the shelf's modules, or nil when it has none.
function M.list(tab)
    -- Micro modules > On the shelf off: none, so the books take the space
    -- back. The list itself stays on the shelf's record for when it is on.
    local ok, Store = pcall(require, "lib/bookshelf_settings_store")
    if ok and Store and Store.microOnShelf and not Store.microOnShelf() then return nil end
    local l = type(tab) == "table" and tab[M.KEY]
    if type(l) ~= "table" or #l == 0 then return nil end
    return l
end

local function after(m) return math.max(0, math.floor(tonumber(m.after) or 0)) end

-- ordered(mods) -> a copy in shelf order (by `after`; ties keep their order).
function M.ordered(mods)
    local out = {}
    for i, m in ipairs(mods or {}) do out[i] = { i = i, m = m } end
    table.sort(out, function(a, b)
        local x, y = after(a.m), after(b.m)
        if x ~= y then return x < y end
        return a.i < b.i
    end)
    for i, e in ipairs(out) do out[i] = e.m end
    return out
end

-- step(mods, id, dir) -> the list in shelf order with module `id` one thing
-- along (dir -1 left, 1 right), or nil when it can go no further left. A
-- module beside it at the same `after` is passed by swapping the two; else
-- it passes one item, landing at the near end of the modules there, beside
-- where it was. Changing `after` alone jumped: ties keep their list order,
-- so a module could land before others it had been after (maintainer, PW5).
-- The module's own table is changed, as the caller's list holds it.
local function stepTo(list, id, dir)
    local p
    for i, m in ipairs(list) do if m.id == id then p = i end end
    if not p then return nil end
    local a = after(list[p])
    local nb = list[p + dir]
    if nb and after(nb) == a then return p, "swap" end
    if dir < 0 and a == 0 then return nil end
    return p, "after"
end

function M.step(mods, id, dir)
    local list = M.ordered(mods)
    local p, how = stepTo(list, id, dir)
    if not p then return nil end
    if how == "swap" then
        list[p], list[p + dir] = list[p + dir], list[p]
    else
        list[p].after = after(list[p]) + dir
    end
    return list
end

-- canStep(mods, id, dir) -> whether step would move it; changes nothing.
function M.canStep(mods, id, dir)
    return stepTo(M.ordered(mods), id, dir) ~= nil
end

-- startWidth(def) -> the width in slots a module is added at: its own start_w
-- when it says (a frameless figure, one book wide), else 2; never below its
-- min_w. The grid editor's add (HeroModules._sizeFor) reads the same fields.
function M.startWidth(def)
    local w = 2
    if def and type(def.start_w) == "number" then w = math.max(1, math.floor(def.start_w)) end
    if def and type(def.min_w) == "number" then w = math.max(w, math.floor(def.min_w)) end
    return w
end

-- width(m, cols) -> a module's width in slots, 1 to the row's width.
function M.width(m, cols)
    return math.max(1, math.min(math.floor(tonumber(m.w) or 2), cols or 1))
end

-- stream(n_items, mods, cols, limit, min_for) -> the cover shelf's slots, in
-- order: { item = i }, { module = m, part = k, span = w } or { blank = true }.
-- Stops once `limit` slots are laid out (nil: all of them). A module after
-- the last item stands after it. A module wider than what is left of its row
-- is narrowed to fit when that is still at least min_for(m) (its narrowest;
-- no min_for: its own width), so a row isn't left half empty; otherwise it
-- starts the next.
function M.stream(n_items, mods, cols, limit, min_for)
    local s = {}
    local order = M.ordered(mods)
    local mi, i = 1, 1
    local function place(m)
        local w = M.width(m, cols)
        local col = #s % cols
        if col + w > cols then
            local room = cols - col
            -- Without a minimum, a module keeps its width.
            local least = math.max(1, math.floor(tonumber(min_for and min_for(m)) or w))
            if col > 0 and room >= least then
                w = room
            else
                for _k = col + 1, cols do s[#s + 1] = { blank = true } end
            end
        end
        for k = 1, w do s[#s + 1] = { module = m, part = k, span = w } end
    end
    while true do
        while mi <= #order and (after(order[mi]) <= i - 1 or i > n_items) do
            place(order[mi]); mi = mi + 1
            if limit and #s >= limit then return s end
        end
        if i > n_items then break end
        s[#s + 1] = { item = i }
        i = i + 1
        if limit and #s >= limit then return s end
    end
    return s
end

-- total(n_items, mods, cols) -> how many slots the shelf has.
function M.total(n_items, mods, cols, min_for)
    return #M.stream(n_items, mods, cols, nil, min_for)
end

-- window(n_items, mods, cols, first, view) -> the page's slots (first ..
-- first + view - 1), and the range of items it shows (i_first, count): a
-- windowed source fetches just those.
function M.window(n_items, mods, cols, first, view, min_for)
    local s = M.stream(n_items, mods, cols, first + view - 1, min_for)
    local page, i_first, count = {}, nil, 0
    for v = first, math.min(#s, first + view - 1) do
        local d = s[v]
        page[#page + 1] = d
        if d.item then
            i_first = i_first or d.item
            count = count + 1
        end
    end
    return page, i_first, count
end

-- slots(n_items, mods, cols, min_for) -> { [module id] = its first slot },
-- { [module id] = its width as laid out }.
function M.slots(n_items, mods, cols, min_for)
    local out, spans = {}, {}
    for v, d in ipairs(M.stream(n_items, mods, cols, nil, min_for)) do
        if d.module and d.part == 1 and d.module.id ~= nil then
            out[d.module.id], spans[d.module.id] = v, d.span
        end
    end
    return out, spans
end

-- afterFromSlots(placed) -> { [id] = after }: modules placed at slots (the
-- layout editor's grid: { id, slot, w } each), as order. Every other slot
-- before a module holds an item, so its `after` is its slot less one, less
-- the slots the modules before it take.
function M.afterFromSlots(placed)
    local l = {}
    for i, p in ipairs(placed or {}) do l[i] = p end
    table.sort(l, function(a, b) return a.slot < b.slot end)
    local out, taken = {}, 0
    for _i, p in ipairs(l) do
        out[p.id] = math.max(0, p.slot - 1 - taken)
        taken = taken + math.max(1, p.w or 1)
    end
    return out
end

-- insertItems(items, mods) -> a spine shelf's item list with each module as
-- { shelf_module = m } after its `after` items. A new list.
function M.insertItems(items, mods)
    if not mods or #mods == 0 then return items end
    local order = M.ordered(mods)
    local out, mi = {}, 1
    for i = 0, #items do
        while mi <= #order and (after(order[mi]) <= i or i == #items) do
            local m = order[mi]
            -- The id keys the spine plan's cache: a move or a resize is a
            -- different list.
            out[#out + 1] = { shelf_module = m,
                id = "module:" .. tostring(m.id) .. ":" .. tostring(m.w) }
            mi = mi + 1
        end
        if i < #items then out[#out + 1] = items[i + 1] end
    end
    return out
end

-- A spine shelf's list with its modules in it: module k (in shelf order) is
-- at position after + k. A windowed source returns one page from a position,
-- so the page's books start after the modules before it.
-- spineWindow(mods, first) -> books before position `first`, and the modules
-- by position.
function M.spineWindow(mods, first)
    local at, before_mods = {}, 0
    for k, m in ipairs(M.ordered(mods)) do
        local pos = after(m) + k
        at[pos] = m
        if pos < first then before_mods = before_mods + 1 end
    end
    return math.max(0, first - 1 - before_mods), at
end

-- spinePage(books, n_books, mods, first, limit) -> the page from position
-- `first`: `books` (fetched from the book spineWindow said) with the modules
-- at their positions, at most `limit` items. A module after the last book
-- still stands at the end. Each module item is { shelf_module = m, id = ... }.
function M.spinePage(books, n_books, mods, first, limit)
    local books_before, at = M.spineWindow(mods, first)
    local out, bi, v = {}, 1, first
    local placed = 0
    local n_mods = 0
    for _k in pairs(at) do n_mods = n_mods + 1 end
    while #out < limit do
        local m = at[v]
        if m then
            out[#out + 1] = { shelf_module = m, id = "module:" .. tostring(m.id) .. ":" .. tostring(m.w) }
            placed = placed + 1
        elseif bi <= #books and books_before + bi <= n_books then
            out[#out + 1] = books[bi]; bi = bi + 1
        else
            -- Out of books: the modules still to come stand at the end.
            local rest = {}
            for pos, mm in pairs(at) do if pos > v then rest[#rest + 1] = { pos = pos, m = mm } end end
            table.sort(rest, function(a, b) return a.pos < b.pos end)
            for _i, r in ipairs(rest) do
                if #out >= limit then break end
                out[#out + 1] = { shelf_module = r.m, id = "module:" .. tostring(r.m.id) .. ":" .. tostring(r.m.w) }
            end
            break
        end
        v = v + 1
    end
    return out
end

-- isModule(item) -> true for a module's slot, a blank, or a spine module item.
function M.isPlaceholder(item)
    return type(item) == "table" and (item.module ~= nil and item.part ~= nil
        or item.blank == true or item.shelf_module ~= nil)
end

-- ── The home shelf, for plugins (Kit.setOnHomeShelf) ────────────────────────
-- A plugin with a module pack can put its module on the reader's home shelf
-- when the reader asks it to (Silverfish's welcome screen, as it puts its card
-- on Simple UI's home screen). The home shelf is the first shelf on the chip
-- strip that holds books: not a hidden one, a sub-shelf, a card's own shelf or
-- a shelf of shelves (which shows shelves, not modules).

-- homeShelf(tabs) -> that shelf's record in tabs, or nil.
function M.homeShelf(tabs)
    local TabModel = require("lib/bookshelf_tab_model")
    for _i, t in ipairs(tabs or {}) do
        if t.enabled ~= false and not t.parent and not t.card_only and not TabModel.isShelves(t) then
            return t
        end
    end
    return nil
end

-- onHome(key, tabs) -> true when the home shelf holds module `key`.
function M.onHome(key, tabs)
    local home = M.homeShelf(tabs)
    for _i, m in ipairs(home and home[M.KEY] or {}) do
        if m.module == key then return true end
    end
    return false
end

-- setOnHome(key, on, tabs, w) -> changed, home, removed: puts module `key`
-- first on the home shelf at width w, once, or takes every copy of it off
-- (removed: those entries, for the module's on_remove). Changes tabs in
-- place; the caller saves them.
function M.setOnHome(key, on, tabs, w)
    local home = M.homeShelf(tabs)
    if not home or on == M.onHome(key, tabs) then return false, home end
    local mods = home[M.KEY] or {}
    if on then
        local used = {}
        for _i, m in ipairs(mods) do used[m.id] = true end
        local k = 1
        while used["sm_" .. k] do k = k + 1 end
        -- First in the list as well as after = 0: modules at the same place
        -- keep their list order (ordered), so it stands before them.
        table.insert(mods, 1, { id = "sm_" .. k, type = "module", module = key, after = 0, w = w or 2 })
        home[M.KEY] = mods
        return true, home
    end
    local keep, removed = {}, {}
    for _i, m in ipairs(mods) do
        if m.module == key then removed[#removed + 1] = m else keep[#keep + 1] = m end
    end
    home[M.KEY] = keep
    return true, home, removed
end

return M
