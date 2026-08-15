-- bookshelf_list_columns.lua
-- The catalogue of list-view columns, and how each reads a value out of an
-- item.
--
-- Column ids match lib/bookshelf_sort_engine.lua's SortEngine.KEYS wherever
-- the concept exists there, so the column vocabulary and the sort vocabulary
-- are the same words for the same things. SortEngine's comments document
-- where each value lives for each of the three item shapes (book record, lfs
-- entry, group record); those comments are the source of truth for the
-- accessors below.
--
-- Accessors return a raw value or nil. Formatting to a display string happens
-- in resolve(), so the "missing value" placeholder is decided in exactly one
-- place rather than smeared across sixteen accessors.

local BookshelfSettings = require("lib/bookshelf_settings_store")

local i18n = require("lib/bookshelf_i18n")
local function tr(s) if i18n and i18n.gettext then return i18n.gettext(s) end return s end

local Columns = {}

-- Group kinds ShelfRow dispatches on (bookshelf_shelf_row.lua:448-627).
-- Series groups are absent: they predate the `kind` field and are detected by
-- their `books` array instead (bookshelf_shelf_row.lua:648).
local GROUP_KINDS = {
    folder   = true,
    opds_nav = true,
    author   = true,
    genre    = true,
    tag      = true,
    language = true,
    series   = true,
}

function Columns.isGroup(item)
    if type(item) ~= "table" then return false end
    if item.kind and GROUP_KINDS[item.kind] then return true end
    return type(item.books) == "table"
end

-- ── Formatting helpers ─────────────────────────────────────────────────────

local function fmtInt(n)
    if type(n) ~= "number" then return nil end
    return string.format("%d", math.floor(n + 0.5))
end

local function fmtPercent(frac)
    if type(frac) ~= "number" then return nil end
    return string.format("%d%%", math.floor(frac * 100 + 0.5))
end

-- Binary-prefix sizes, matching how KOReader reports file sizes elsewhere.
local function fmtSize(bytes)
    if type(bytes) ~= "number" or bytes < 0 then return nil end
    if bytes < 1024 then return string.format("%d B", bytes) end
    local kb = bytes / 1024
    if kb < 1024 then return string.format("%d KB", math.floor(kb + 0.5)) end
    return string.format("%.1f MB", kb / 1024)
end

local function fmtDate(epoch)
    if type(epoch) ~= "number" or epoch <= 0 then return nil end
    return os.date("%Y-%m-%d", epoch)
end

-- Rating renders as filled/empty stars rather than a bare number: at a glance
-- in a column of text, "4" reads as a count of something, not a score.
local function fmtRating(n)
    if type(n) ~= "number" or n <= 0 then return nil end
    local whole = math.floor(n + 0.5)
    if whole < 1 then return nil end
    if whole > 5 then whole = 5 end
    return string.rep("\xE2\x98\x85", whole)   -- ★
end

local STATUS_LABEL = {
    reading  = tr("Reading"),
    finished = tr("Finished"),
    on_hold  = tr("On hold"),
    unread   = tr("Unread"),
}
local function fmtStatus(s)
    if type(s) ~= "string" then return nil end
    return STATUS_LABEL[s]
end

local function fmtFormat(item)
    local name = item.filename or item.file or item.filepath
    if type(name) ~= "string" then return nil end
    local ext = name:match("%.(%w+)$")
    if not ext then return nil end
    return ext:upper()
end

-- Group display name. Group shapes disagree about which field holds it, so
-- this is the one place that knows the whole list.
local function groupName(g)
    return g.name or g.label or g.series_name or g.title
end

-- ── Catalogue ──────────────────────────────────────────────────────────────
-- Order here is the order the "Add column" picker offers, sorted by likely
-- usefulness rather than alphabetically (same convention as SortEngine.ORDER).
--
-- weight  = flex column; shares whatever width is left, in proportion.
-- sample  = fixed column; sized once from this worst-case string.
-- Exactly one of the two, enforced by the test suite.

Columns.CATALOGUE = {
    { id = "cover", label = tr("Cover"), kind = "cover",
      book  = function(b) return b.filepath end,
      group = function(g) return groupName(g) end },

    { id = "title", label = tr("Title"), kind = "text",
      align = "left", weight = 3,
      book  = function(b) return b.title end,
      group = function(g) return groupName(g) end },

    { id = "author_name", label = tr("Author"), kind = "text",
      align = "left", weight = 2,
      -- `authors` has two shapes in the repo: a TABLE of names on the
      -- buildBookMeta path (bookshelf_book_repository.lua:826, from
      -- splitAuthors) and a "; "-joined string on the SQL prefetch path
      -- (:2535). Returning the table unchanged made resolve() drop it -- it
      -- only accepts strings -- so the column rendered its empty placeholder
      -- for every book on the shelf's own path. Join instead.
      book  = function(b)
          if type(b.authors) == "table" then
              if #b.authors == 0 then return nil end
              return table.concat(b.authors, ", ")
          end
          return b.authors or b.author
      end,
      -- On an Authors chip the group IS the author, so its name is the
      -- honest value here; on any other group kind there is no single author.
      group = function(g)
          if g.kind == "author" then return groupName(g) end
          return nil
      end },

    { id = "series_name", label = tr("Series"), kind = "text",
      align = "left", weight = 2,
      book  = function(b) return b.series or b.series_name end,
      group = function(g)
          if g.kind == "series" or g.books then return groupName(g) end
          return nil
      end },

    { id = "series_index", label = tr("Series #"), kind = "text",
      align = "right", sample = "999",
      book  = function(b) return fmtInt(tonumber(b.series_index or b.series_num)) end,
      group = function() return nil end },

    { id = "percent_read", label = tr("Progress"), kind = "text",
      align = "right", sample = "100%",
      book  = function(b) return fmtPercent(b.book_pct or b.percent_finished) end,
      group = function() return nil end },

    { id = "page_count", label = tr("Pages"), kind = "text",
      align = "right", sample = "99999",
      book  = function(b) return fmtInt(b.page_count) end,
      -- Sum across members, per SortEngine's page_count comparator. NOT the
      -- member count -- that is the book_count column.
      group = function(g) return fmtInt(g.total_pages) end },

    { id = "book_count", label = tr("Books"), kind = "text",
      align = "right", sample = "9999",
      book  = function() return nil end,
      group = function(g)
          local n = g.book_count or (g.filepaths and #g.filepaths)
                    or (g.books and #g.books)
          return fmtInt(n)
      end },

    { id = "read_status", label = tr("Status"), kind = "text",
      align = "left", sample = "Finished",
      book  = function(b) return fmtStatus(b.status or b.read_status or b._status) end,
      group = function() return nil end },

    { id = "rating", label = tr("Rating"), kind = "text",
      align = "left", sample = "\xE2\x98\x85\xE2\x98\x85\xE2\x98\x85\xE2\x98\x85\xE2\x98\x85",
      book  = function(b) return fmtRating(b.rating) end,
      group = function(g) return fmtRating(g.avg_rating) end },

    { id = "last_opened", label = tr("Opened"), kind = "text",
      align = "right", sample = "9999-99-99",
      book  = function(b) return fmtDate(b.last_opened or b._last_read) end,
      group = function(g) return fmtDate(g.latest) end },

    { id = "date_added", label = tr("Added"), kind = "text",
      align = "right", sample = "9999-99-99",
      book  = function(b)
          return fmtDate(b.date_added or (b.attr and b.attr.modification))
      end,
      group = function(g) return fmtDate(g.latest_added) end },

    { id = "size", label = tr("File size"), kind = "text",
      align = "right", sample = "999.9 MB",
      book  = function(b) return fmtSize(b.size or (b.attr and b.attr.size)) end,
      group = function() return nil end },

    { id = "language", label = tr("Language"), kind = "text",
      align = "left", sample = "zh-CN",
      book  = function(b) return b.lang end,
      group = function(g)
          if g.kind == "language" then return groupName(g) end
          return nil
      end },

    { id = "format", label = tr("Format"), kind = "text",
      align = "left", sample = "EPUB",
      book  = function(b) return fmtFormat(b) end,
      group = function() return nil end },

    { id = "filename", label = tr("Filename"), kind = "text",
      align = "left", weight = 2,
      book  = function(b) return b.filename or b.file or b.name end,
      group = function() return nil end },
}

Columns.DEFAULT_IDS = { "cover", "title", "author_name", "percent_read" }

local _by_id
function Columns.byId(id)
    if not _by_id then
        _by_id = {}
        for _i, c in ipairs(Columns.CATALOGUE) do _by_id[c.id] = c end
    end
    return _by_id[id]
end

-- resolve(item, column) -> display string, or nil when this column has no
-- value for this item. nil (rather than a literal dash) keeps the placeholder
-- a rendering decision, so it lives in one place in the row widget.
function Columns.resolve(item, column)
    if type(item) ~= "table" or type(column) ~= "table" then return nil end
    local accessor = Columns.isGroup(item) and column.group or column.book
    if type(accessor) ~= "function" then return nil end
    local ok, value = pcall(accessor, item)
    if not ok or value == nil then return nil end
    if type(value) == "number" then value = tostring(value) end
    if type(value) ~= "string" or value == "" then return nil end
    return value
end

-- active() -> ordered array of column tables.
-- Unknown ids are dropped rather than fatal: a saved set can name a column a
-- later version removed, and that must not take the shelf down. An empty
-- result falls back to the defaults, since blank rows would leave the user no
-- way back through the UI.
function Columns.active()
    local saved = BookshelfSettings.read("list_columns")
    local out = {}
    if type(saved) == "table" then
        for _i, id in ipairs(saved) do
            local c = Columns.byId(id)
            if c then out[#out + 1] = c end
        end
    end
    if #out == 0 then
        for _i, id in ipairs(Columns.DEFAULT_IDS) do
            local c = Columns.byId(id)
            if c then out[#out + 1] = c end
        end
    end
    return out
end

-- solveWidths(active, available_w, gap, measure, cover_w) -> array of widths
--
-- Deterministic and single-pass. Content is deliberately NOT measured:
-- auto-fitting every cell would make column positions depend on which page
-- you are looking at, so the table would shift under the user as they page.
-- Fixed positions are worth more than tight packing here.
--
-- Invariants, in priority order:
--   1. Widths plus gaps sum EXACTLY to available_w (always).
--   2. Every column gets at least 1 pixel, WHEN the available width can afford it
--      (i.e., content_w >= column_count). When the available width is smaller
--      than the column count, exact-sum wins and some columns may be zero.
--
-- The algorithm:
--   1. The cover column takes cover_w, decided by row geometry.
--   2. Columns declaring a `sample` take that sample's rendered width plus one
--      gap of breathing room. These are the numeric and short columns.
--   3. Whatever is left splits among `weight` columns in proportion.
--   4. If the floor is affordable, every column is raised to >= 1 and deficit
--      is reclaimed from the widest columns.
--   5. The rounding remainder is reconciled with the widest column, taking 1px
--      at a time if needed (for negative slack), to ensure exact-sum always holds.
--
-- `measure` is injected rather than required, so the solver stays pure and
-- testable without a font stack.
function Columns.solveWidths(active, available_w, gap, measure, cover_w)
    local n = #active
    local widths = {}
    if n == 0 then return widths end

    local content_w = available_w - gap * (n - 1)
    if content_w < 0 then content_w = 0 end

    -- Pass 1: everything that is not flex.
    local fixed_total  = 0
    local weight_total = 0
    for i, c in ipairs(active) do
        if c.kind == "cover" then
            widths[i] = cover_w or 0
            fixed_total = fixed_total + widths[i]
        elseif type(c.sample) == "string" then
            widths[i] = measure(c.sample) + gap
            fixed_total = fixed_total + widths[i]
        else
            widths[i] = 0                       -- filled in by pass 2
            weight_total = weight_total + (c.weight or 1)
        end
    end

    -- Cramped: fixed columns alone overflow. Scale them down proportionally
    -- rather than emitting negative flex widths, which would crash
    -- TextWidget's max_width (it requires a positive budget).
    if fixed_total > content_w then
        local scale = (fixed_total > 0) and (content_w / fixed_total) or 0
        fixed_total = 0
        for i, c in ipairs(active) do
            if c.kind == "cover" or type(c.sample) == "string" then
                widths[i] = math.floor(widths[i] * scale)
                fixed_total = fixed_total + widths[i]
            end
        end
    end

    -- Pass 2: flex columns split the remainder by weight.
    local remainder = content_w - fixed_total
    if remainder < 0 then remainder = 0 end
    if weight_total > 0 then
        for i, c in ipairs(active) do
            if c.kind ~= "cover" and type(c.sample) ~= "string" then
                widths[i] = math.floor(remainder * (c.weight or 1) / weight_total)
            end
        end
    end

    -- Pass 2.5: enforce minimum width (>= 1) for all columns, if affordable.
    -- Integer division can leave columns at zero. If the available width can
    -- support giving every column at least 1 pixel (content_w >= n), raise them
    -- to 1 and reclaim deficit from the widest columns. If not affordable,
    -- skip the floor to preserve exact-sum.
    local MIN_COL_W = 1
    local affordable = content_w >= n
    if affordable then
        local deficit = 0
        for i = 1, n do
            if widths[i] < MIN_COL_W then
                deficit = deficit + (MIN_COL_W - widths[i])
                widths[i] = MIN_COL_W
            end
        end

        -- Reclaim pixels from the widest columns to pay back the deficit
        if deficit > 0 then
            -- Build list of (index, width) and sort descending by width
            local sorted = {}
            for i = 1, n do
                sorted[#sorted + 1] = { i, widths[i] }
            end
            table.sort(sorted, function(a, b) return a[2] > b[2] end)

            -- Take from widest, never dropping below MIN_COL_W
            for _, pair in ipairs(sorted) do
                if deficit <= 0 then break end
                local i, w = pair[1], pair[2]
                local can_take = w - MIN_COL_W
                if can_take > 0 then
                    local take = math.min(deficit, can_take)
                    widths[i] = widths[i] - take
                    deficit = deficit - take
                end
            end
        end
    end

    -- Pass 3: reconcile the sum with content_w exactly by adjusting the widest
    -- column. Positive slack adds to the widest; negative slack takes from the
    -- widest 1px at a time, never forcing any column negative. This ensures
    -- exact-sum always holds.
    local sum = 0
    for _i, w in ipairs(widths) do sum = sum + w end
    local slack = content_w - sum
    if slack > 0 then
        -- Add positive slack to the widest column
        local widest_i, widest_w = 1, -1
        for i, w in ipairs(widths) do
            if w > widest_w then widest_i, widest_w = i, w end
        end
        widths[widest_i] = widths[widest_i] + slack
    elseif slack < 0 then
        -- Take negative slack from the widest column, 1px at a time
        local remaining = -slack
        while remaining > 0 do
            local widest_i, widest_w = 1, -1
            for i, w in ipairs(widths) do
                if w > widest_w then widest_i, widest_w = i, w end
            end
            if widest_w <= 0 then break end  -- No column has width to give
            widths[widest_i] = widths[widest_i] - 1
            remaining = remaining - 1
        end
    end

    return widths
end

return Columns
