-- lib/bookshelf_add_more.lua
-- "Add more": the other books that go with a book, to put on a shelf together.
--
-- From one book in the book popup, a reader can add the whole series it is
-- in, everything by its author, or the rest of its folder, in reading order,
-- instead of finding and adding them one by one. This is the pure part: which
-- ways there are and in what order the books go. lib/bookshelf_add_more_ui
-- asks the reader and hands the books to the shelf chooser.
--
-- Nothing here reads a device or a database; the books come in as data
-- (lib/bookshelf_book_repository's group shapes), so it runs under a plain
-- interpreter like the other pure modules.
--
--   M.ways(book, data) -> { { kind, name, paths }, ... }
--       book  { filepath, series_name, author, authors }
--       data  { series = { [name] = { fp, ... } },   in series order
--               author = { [name] = { fp, ... } },
--               folder = { fp, ... } | nil, folder_name = string | nil }
--   M.readingOrder(paths, place) -> the paths in reading order
--   M.CONFIRM_ABOVE: how many books go without asking first

local M = {}

-- More than this many at once asks first, so one tap on a long list of books
-- never fills a shelf with books nobody chose.
M.CONFIRM_ABOVE = 10

local function norm(s)
    return (tostring(s or ""):lower():gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

local function basename(path)
    return (tostring(path):gsub(".*/", ""))
end

-- place(fp) -> { series = name, index = n } for a book in a series, or nil.
-- Books of one series go together, in the series' own order; series go in
-- name order; books that are in no series follow them, by file name.
function M.readingOrder(paths, place)
    local rows = {}
    for i, fp in ipairs(paths) do
        local p = place and place(fp) or nil
        rows[i] = { fp = fp, series = p and norm(p.series) or nil, index = p and p.index or nil,
                    name = norm(basename(fp)), at = i }
    end
    table.sort(rows, function(a, b)
        if (a.series ~= nil) ~= (b.series ~= nil) then return a.series ~= nil end
        if a.series ~= b.series then return a.series < b.series end
        if a.index ~= b.index then
            if a.index == nil or b.index == nil then return b.index == nil end
            return a.index < b.index
        end
        if a.name ~= b.name then return a.name < b.name end
        return a.at < b.at
    end)
    local out = {}
    for i, r in ipairs(rows) do out[i] = r.fp end
    return out
end

-- A lookup of where each book sits in its series, from the series groups
-- (each already in series order).
function M.placeFrom(series_groups)
    local at = {}
    for name, fps in pairs(series_groups or {}) do
        for i, fp in ipairs(fps) do at[fp] = { series = name, index = i } end
    end
    return function(fp) return at[fp] end
end

local function copy(list)
    local out = {}
    for i, v in ipairs(list or {}) do out[i] = v end
    return out
end

function M.ways(book, data)
    local out = {}
    if type(book) ~= "table" or not book.filepath or type(data) ~= "table" then return out end
    local place = M.placeFrom(data.series)
    local seen = {}
    -- A way that would add only the book itself is no way ("Add to a shelf"
    -- does that), and one that adds what an earlier way does (an author whose
    -- books are all one series) is not offered twice.
    local function offer(kind, name, paths)
        if not paths or #paths == 0 then return end
        if #paths == 1 and paths[1] == book.filepath then return end
        local key = table.concat(paths, "\n")
        if seen[key] then return end
        seen[key] = true
        out[#out + 1] = { kind = kind, name = name, paths = paths }
    end

    local series = book.series_name
    if type(series) == "string" and series ~= "" then
        -- Already in series order.
        offer("series", series, copy(data.series and data.series[series]))
    end

    local names = (type(book.authors) == "table" and #book.authors > 0) and book.authors
        or (book.author and book.author ~= "" and { book.author } or {})
    for i, name in ipairs(names) do
        if i > 2 then break end   -- a book with a crowd of authors does not offer a crowd of ways
        local paths = data.author and data.author[name]
        if paths then offer("author", name, M.readingOrder(paths, place)) end
    end

    if data.folder and #data.folder > 0 then
        offer("folder", data.folder_name or "", M.readingOrder(data.folder, place))
    end
    return out
end

return M
