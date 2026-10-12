-- Adapted from OrbitUI's series-box implementation (AGPL-3.0).
-- View-only series grouping. Keep original members for drill, bulk actions and
-- metadata; only the physical bookshelf's display list is compacted.
local M = {}

local function copy(t)
    local out = {}
    for k, v in pairs(t or {}) do if k ~= "cover_bb" then out[k] = v end end
    return out
end
M.copy = copy

local function memberMeta(book, light_meta)
    local member = copy(book)
    for k, v in pairs(light_meta and light_meta(book.filepath) or {}) do
        if k ~= "cover_bb" and member[k] == nil then member[k] = v end
    end
    return member
end

local function name(book)
    local value = book and (book.series_name or book.series)
    return type(value) == "string" and value:match("%S") and value or nil
end

function M.isBox(item)
    return type(item) == "table" and item._series_box == true
end

function M.box(books, title, original, light_meta)
    local members, seen = {}, {}
    for _, book in ipairs(books) do
        if book.filepath and not seen[book.filepath] then
            local member = memberMeta(book, light_meta)
            members[#members+1], seen[book.filepath] = member, true
        end
    end
    if #members == 0 then return original end
    local cmp = require("lib/bookshelf_sort_engine").chainedComparator{
        {key="series_index"}, {key="filename"},
    }
    table.sort(members, cmp)
    local box = copy(original)
    box.filepath, box.path, box.shelf_section, box.shelf_section_path = nil, nil, nil, nil
    box.kind, box.series_name, box.label, box.name = "series", title, title, title
    box.title, box.display_title = title, title
    box.books, box.first_book, box.book_count = members, members[1], #members
    box.books_meta = nil
    box.author, box.authors = members[1].author, members[1].authors
    box._series_box = true
    box._series_box_key = (original and original.shelf_section_path or "") .. "\0" .. title
    box._series_display_books = nil
    box._series_sort_book = copy(original or members[1])
    -- A box has no reading status of its own, nor a borrowed cover buffer.
    box.status, box._status, box.percent_finished, box.series_num = nil, nil, nil, nil
    return box
end

-- onlyBook(books) -> the book, when the list holds one distinct file; else nil.
function M.onlyBook(books)
    local first
    for _, book in ipairs(books or {}) do
        if not book.filepath then return nil end
        if not first then first = book
        elseif book.filepath ~= first.filepath then return nil end
    end
    return first
end

function M.prepare(items, light_meta)
    local out, groups = {}, {}
    for _, item in ipairs(items or {}) do
        -- Native author/tag groups can contain only file identifiers. Resolve
        -- series membership from the light cache, never by decoding covers.
        if item.filepath and not item.books and not item.is_remote and not name(item) and light_meta then
            local meta = memberMeta(item, light_meta)
            if name(meta) then item = meta end
        end
        if M.isBox(item) then
            out[#out+1] = item
        elseif item.books then
            if name(item) and (not item.kind or item.kind == "series") then
                -- One volume on the shelf is a book, not a box set.
                local only = M.onlyBook(item.books)
                out[#out+1] = only or M.box(item.books, name(item), item, light_meta)
            else
                local group = copy(item)
                group._series_display_books = M.prepare(item.books, light_meta)
                out[#out+1] = group
            end
        elseif item.filepath and name(item) and not item.is_remote then
            -- Distinct physical sections may contain different editions of
            -- a series: do not silently merge those collections together.
            local key = (item.shelf_section_path or "") .. "\0" .. name(item)
            local g = groups[key]
            if not g then
                g = {books={}, title=name(item), original=item, at=#out+1}
                groups[key] = g
                out[g.at] = g
            end
            g.books[#g.books+1] = item
        else
            out[#out+1] = item
        end
    end
    for _, g in pairs(groups) do
        out[g.at] = M.onlyBook(g.books) or M.box(g.books, g.title, g.original, light_meta)
    end
    return out
end

function M.displayCount(item)
    if M.isBox(item) then return 1 end
    local books = item._series_display_books or item.books
    return books and #books > 0 and #books or 1
end

-- Page maps and entry caches must notice a different compacted membership,
-- even when a parent group's total number of books has not changed.
function M.signature(item)
    local parts = { item._series_box_key or "group" }
    for _, child in ipairs(item._series_display_books or item.books or {}) do
        parts[#parts+1] = M.isBox(child) and M.signature(child) or child.filepath or "?"
    end
    return table.concat(parts, "\0")
end

-- A restored box must not widen a folder/filter-local series to the whole
-- library. Persist file identifiers only, then intersect fresh membership.
function M.restore(group, files, title, light_meta)
    local allowed, books = {}, {}
    for _, fp in ipairs(files) do allowed[fp] = true end
    for _, book in ipairs(group.books or {}) do
        if allowed[book.filepath] then books[#books+1] = book end
    end
    if #books == 0 then return nil end
    return M.box(books, title, group, light_meta)
end

function M.geometry(book, base, opts)
    if not M.isBox(book) then return nil end
    local count = math.max(1, #book.books)
    local ratio = math.min(.45, .20 + .05 * (count - 1))
    local cover_w = base.w
    local side = math.max(1, math.floor(cover_w * ratio + .5))
    local max_w = math.max(2, (opts.content_w or (cover_w + side))
        - 2 * (opts.end_margin or 0))
    if cover_w + side > max_w then
        cover_w = math.max(1, math.floor(max_w / (1 + ratio)))
        side = math.max(1, math.min(max_w-cover_w, math.floor(cover_w*ratio+.5)))
    end
    local scale = cover_w / base.w
    local face_h = math.max(1, math.floor((base.face_h or base.h) * scale))
    return {w=cover_w+side, cover_w=cover_w, side=side, count=count,
        face_h=face_h, depth=base.depth, h=face_h+base.depth}
end

-- A bounded set of illustrative bindings, not miniature cover bitmaps. Reduce
-- their number on tiny faces rather than drawing subpixel stripes.
function M.spineSlots(shape, stroke)
    local slots = {}
    local gap = math.max(1, stroke)
    local room = shape.side - 2 * stroke
    local count = math.min(6, shape.count, math.floor((room + gap) / (3 + gap)))
    if count < 1 then return slots end
    local usable = room - (count - 1) * gap
    for i = 1, count do
        local start = math.floor((i - 1) * usable / count)
        local finish = math.floor(i * usable / count)
        slots[i] = { x = stroke + start + (i - 1) * gap, w = finish - start, member = i }
    end
    return slots
end

-- Recess heights are measured from the row's baseline, not the book's foot.
-- Describe the painted silhouette as joined strips so native shadows follow
-- both sloping edges instead of leaving a rectangular stamp below the side.
function M.shadowColumns(p, x, inset)
    local cols = {}
    inset = inset or 0
    local function add(first, last, h, foot)
        if last <= first then return end
        local prev = cols[#cols]
        if prev and prev.h == h and prev.foot == foot then
            prev.w = prev.w + last-first
        else
            cols[#cols+1] = {x=x+first, w=last-first, h=h, foot=foot}
        end
    end
    local dx = 0
    while dx < p.cover_w do
        local rise = math.min(p.depth, math.floor(dx*p.depth/p.side))
        local next_dx = rise < p.depth
            and math.min(p.cover_w, math.ceil((rise+1)*p.side/p.depth)) or p.cover_w
        add(dx, next_dx, p.face_h+inset+rise, inset)
        dx = next_dx
    end
    dx = 0
    while dx < p.side do
        local rise = math.floor((dx+1)*p.depth/p.side)
        local next_dx = p.depth > 0
            and math.min(p.side, math.ceil((rise+1)*p.side/p.depth)-1) or p.side
        add(p.cover_w+dx, p.cover_w+next_dx, p.h+inset, inset+rise)
        dx = next_dx
    end
    return cols
end

return M
