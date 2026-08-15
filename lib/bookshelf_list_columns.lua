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
      book  = function(b) return b.authors or b.author end,
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

return Columns
