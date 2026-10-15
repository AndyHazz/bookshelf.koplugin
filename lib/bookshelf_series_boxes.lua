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

-- A member's spine width in px at full height, the way plan sizes a spine.
local function spinePx(member, auto_thick)
    local SpineLayout = require("lib/bookshelf_spine_layout")
    local pages
    local ok, SpineShelf = pcall(require, "lib/bookshelf_spine_shelf")
    if ok and SpineShelf and member.filepath then
        local pp, _ps, _known, psrc = SpineShelf.cachedProgress(member.filepath)
        if pp and psrc ~= "render" then pages = pp end
    end
    pages = pages or member.page_count or member.pages
    local Screen = require("device").screen
    return Screen:scaleBySize(SpineLayout.spineWidthDp(pages) * auto_thick)
end

-- The most books a slipcase shows; its count label says how many it holds.
M.SLIPCASE_SPINES = 8
-- The narrowest a slipcase goes, as a share of a face-out cover's width, and
-- whether it also widens to fit its series name.
M.SLIPCASE_MIN_SHARE = 0.5
M.SLIPCASE_NAME_FIT = true

-- slipcaseGeometry(book, base, opts) -> the face-out box set's shape.
--
-- A face-out cover's height (base.h), and as wide as its books, up to a
-- face-out cover's width (base.w): an open-topped slipcase with the books
-- standing in it spine-out, their heads above its rim, so each one's top and
-- status mark show. The front, printed with the first cover, is shorter than
-- the books by `rise`; the name strip runs along its foot as on the
-- spine-out box. Up to SLIPCASE_SPINES books, at their own spine widths, or
-- sharing the cover's width in proportion to them when they would not fit.
function M.slipcaseGeometry(book, base, opts)
    local Screen = require("device").screen
    local SpineLayout = require("lib/bookshelf_spine_layout")
    local SpineShelf = require("lib/bookshelf_spine_shelf")
    local px_per_dp = Screen:scaleBySize(100) / 100
    local auto_thick = SpineLayout.autoThickness(
        opts.row_h and px_per_dp > 0 and (opts.row_h / px_per_dp) or nil)
    local count = #book.books
    local border = math.max(2, Screen:scaleBySize(2))
    local max_w = math.max(2, math.min(base.w,
        (opts.content_w or base.w) - 2 * (opts.end_margin or 0)))
    local h = base.h
    local label_size = SpineShelf.titleSize(base.ref_w_dp)
    local strip_h = SpineShelf.textHeight(label_size) + 2 * math.max(1, Screen:scaleBySize(2))
    local rise = math.max(Screen:scaleBySize(48), math.floor(h * 0.27))
    local n = math.min(count, M.SLIPCASE_SPINES)
    -- The side boards stand the full height either side of the books, a
    -- little thicker than the front's frame so they read as walls.
    local wall = 2 * border
    -- The books at their own widths, and the box as wide as they are: a
    -- two-book series is a narrow slipcase, not two doorstops filling a
    -- cover's width. Only past a face-out cover's width are they squeezed
    -- to share it.
    local nat, sum = {}, 0
    for i = 1, n do
        nat[i] = math.max(1, spinePx(book.books[i], auto_thick))
        sum = sum + nat[i]
    end
    -- Never so thin the series cannot be told: at least SLIPCASE_MIN_SHARE of
    -- a cover's width, and (SLIPCASE_NAME_FIT) wide enough for the name at
    -- the spine-title size, within the cover's width. A name that will not
    -- go on one line at that width wraps to two, broken where the longer
    -- line is shortest, so a long name asks for half its width, not all.
    local pad = math.max(1, Screen:scaleBySize(3))
    local base_w = math.max(sum + 2 * wall, math.floor(max_w * M.SLIPCASE_MIN_SHARE))
    local want = base_w
    local name_lines
    if M.SLIPCASE_NAME_FIT then
        pcall(function()
            local BFont = require("lib/bookshelf_fonts")
            local TW = require("lib/bookshelf_colour_text")
            local face = BFont:getFace(BFont.getUIFontFace() or "cfont", label_size)
            local function width(t)
                local tw = TW:new{ text = t, face = face, padding = 0 }
                local wd = tw:getSize().w
                if tw.free then tw:free() end
                return wd
            end
            local name = book.series_name or ""
            local frame = 2 * border + 2 * pad
            local one = width(name) + frame
            if one <= base_w then return end
            -- The best break into two lines, by word.
            local words = {}
            for word in name:gmatch("%S+") do words[#words + 1] = word end
            local best, best_w
            for k = 1, #words - 1 do
                local a = table.concat(words, " ", 1, k)
                local b = table.concat(words, " ", k + 1)
                local lw = math.max(width(a), width(b)) + frame
                if not best_w or lw < best_w then best, best_w = { a, b }, lw end
            end
            if best and best_w < one then
                want = math.max(base_w, best_w)
                name_lines = best
            else
                want = math.max(base_w, one)
            end
        end)
    end
    local w = math.min(max_w, want)
    if name_lines then
        strip_h = 2 * SpineShelf.textHeight(label_size) + 2 * math.max(1, Screen:scaleBySize(2))
    end
    local inner_w = w - 2 * wall
    local spines, x = {}, 0
    for i = 1, n do
        local sw = (i == n) and (inner_w - x)
                   or math.max(1, math.floor(inner_w * nat[i] / sum + 0.5))
        spines[i] = { member = i, x = x, w = sw }
        x = x + sw
    end
    -- The box is as deep as its books, so its side walls show above the rim
    -- by the band a book's page top takes (its depth, foreshortened), and
    -- then run back behind the books.
    local wall_top = math.min(rise, SpineLayout.topEdgeHeight(h, base.aspect,
        Screen:scaleBySize(5)))
    return { style = "slipcase", w = w, h = h, face_h = base.face_h or h, wall_top = wall_top,
             depth = base.depth, lid = 0, border = border, wall = wall, strip_h = strip_h,
             label_size = label_size, rise = rise, front_h = h - rise,
             pad = pad, spines = spines, name_lines = name_lines,
             count = count }
end

-- geometry(book, base, opts) -> the box's shape, or nil for anything else.
function M.geometry(book, base, opts)
    if not M.isBox(book) then return nil end
    return M.slipcaseGeometry(book, base, opts or {})
end

-- shadowColumns(p, x, inset) -> the columns the row's recess shadow follows:
-- one, the box's own footprint, measured from the row's baseline.
function M.shadowColumns(p, x, _inset)
    -- Stands at the front edge like a spine, so no face-out inset. The
    -- slipcase's outline: its books the full height in the middle, its side
    -- walls only as high as their tops. One rectangle cast the books' shadow
    -- from the box's outer edge, a wall's width off them.
    local wall_h = p.front_h + p.wall_top
    return { { x = x, w = p.wall, h = wall_h, foot = 0 },
             { x = x + p.wall, w = p.w - 2 * p.wall, h = p.h, foot = 0 },
             { x = x + p.w - p.wall, w = p.wall, h = wall_h, foot = 0 } }
end

return M
