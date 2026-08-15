-- tests/_test_list_columns.lua
-- Pure-Lua tests for the list-view column registry and value resolution.
-- Usage (from plugin root): lua tests/_test_list_columns.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

-- Settings stub must be in place before the module is required: Columns.active
-- reads list_columns through it.
local _settings = {}
package.loaded["lib/bookshelf_settings_store"] = {
    read   = function(key, default)
        if _settings[key] ~= nil then return _settings[key] end
        return default
    end,
    save   = function(key, value) _settings[key] = value end,
    isTrue = function(key) return _settings[key] == true end,
    flush  = function() end,
}
package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }

local helpers = dofile("tests/_helpers.lua")
local t       = helpers.runner()

local Columns = require("lib/bookshelf_list_columns")

-- ── Fixtures ───────────────────────────────────────────────────────────────
local BOOK = {
    filepath   = "/books/wolf.epub",
    filename   = "wolf.epub",
    title      = "Wolf Hall",
    authors    = "Hilary Mantel",
    series     = "Thomas Cromwell",
    series_index = 1,
    book_pct   = 0.62,
    page_count = 604,
    size       = 1536000,
    date_added = 1700000000,
    last_opened= 1755000000,
    rating     = 4,
    status     = "reading",
    lang       = "en",
}
-- Series group: no `kind` field, detected by the `books` array. This is the
-- legacy shape ShelfRow still dispatches on (bookshelf_shelf_row.lua:648).
local SERIES = {
    series_name  = "Thomas Cromwell",
    books        = { { filepath = "/books/wolf.epub" }, { filepath = "/books/bring.epub" } },
    total_pages  = 1400,
    latest_added = 1710000000,
    latest       = 1750000000,
    avg_rating   = 4.5,
}
local FOLDER = { kind = "folder", label = "Sci-Fi", filepaths = { "a", "b", "c" } }
local OPDS   = { kind = "opds_nav", name = "New releases" }

-- ── Registry integrity ─────────────────────────────────────────────────────
t.test("every catalogue entry is well formed", function()
    assert(#Columns.CATALOGUE > 0, "catalogue is empty")
    local seen = {}
    for _i, c in ipairs(Columns.CATALOGUE) do
        assert(type(c.id) == "string" and c.id ~= "", "column with no id")
        assert(not seen[c.id], "duplicate column id: " .. tostring(c.id))
        seen[c.id] = true
        assert(type(c.label) == "string" and c.label ~= "",
            c.id .. " has no label")
        assert(c.kind == "text" or c.kind == "cover",
            c.id .. " has bad kind: " .. tostring(c.kind))
        if c.kind == "text" then
            assert(c.align == "left" or c.align == "right",
                c.id .. " has bad align")
            local has_weight = type(c.weight) == "number"
            local has_sample = type(c.sample) == "string"
            assert(has_weight ~= has_sample,
                c.id .. " must declare exactly one of weight or sample")
        end
    end
end)

t.test("every column declares both accessors and neither crashes", function()
    -- A column whose group accessor is missing would throw the moment a
    -- series or folder appears on the page, which is the common case on a
    -- Series or Authors chip.
    for _i, c in ipairs(Columns.CATALOGUE) do
        assert(type(c.book) == "function",  c.id .. " has no book accessor")
        assert(type(c.group) == "function", c.id .. " has no group accessor")
        -- Called on a bare table: must return nil, not error.
        local ok_b = pcall(c.book, {})
        local ok_g = pcall(c.group, {})
        assert(ok_b, c.id .. " book accessor errored on an empty record")
        assert(ok_g, c.id .. " group accessor errored on an empty record")
    end
end)

t.test("defaults all exist in the catalogue", function()
    for _i, id in ipairs(Columns.DEFAULT_IDS) do
        assert(Columns.byId(id), "default column not in catalogue: " .. id)
    end
end)

-- ── Group detection ────────────────────────────────────────────────────────
t.test("isGroup recognises every group shape", function()
    assert(Columns.isGroup(SERIES) == true, "series group not detected")
    assert(Columns.isGroup(FOLDER) == true, "folder not detected")
    assert(Columns.isGroup(OPDS)   == true, "opds_nav not detected")
    assert(Columns.isGroup({ kind = "author",   name = "Mantel" }) == true)
    assert(Columns.isGroup({ kind = "genre",    name = "History" }) == true)
    assert(Columns.isGroup({ kind = "tag",      name = "TBR" })     == true)
    assert(Columns.isGroup({ kind = "language", name = "English" }) == true)
    assert(Columns.isGroup(BOOK) == false, "book misdetected as group")
    assert(Columns.isGroup(nil)  == false)
end)

-- ── Resolution: books ──────────────────────────────────────────────────────
t.test("book values resolve", function()
    local function got(id) return Columns.resolve(BOOK, Columns.byId(id)) end
    assert(got("title")        == "Wolf Hall",       tostring(got("title")))
    assert(got("author_name")  == "Hilary Mantel",   tostring(got("author_name")))
    assert(got("series_name")  == "Thomas Cromwell", tostring(got("series_name")))
    assert(got("series_index") == "1",               tostring(got("series_index")))
    assert(got("percent_read") == "62%",             tostring(got("percent_read")))
    assert(got("page_count")   == "604",             tostring(got("page_count")))
    assert(got("filename")     == "wolf.epub",       tostring(got("filename")))
    assert(got("language")     == "en",              tostring(got("language")))
    assert(got("format")       == "EPUB",            tostring(got("format")))
end)

t.test("book_count is blank on a book", function()
    -- page_count and book_count are separate columns on purpose: showing a
    -- member count under a page-count heading would be wrong exactly where
    -- the table is meant to be exact.
    assert(Columns.resolve(BOOK, Columns.byId("book_count")) == nil)
end)

-- ── Resolution: groups ─────────────────────────────────────────────────────
t.test("series group values resolve to group fallbacks", function()
    local function got(id) return Columns.resolve(SERIES, Columns.byId(id)) end
    assert(got("title")      == "Thomas Cromwell", tostring(got("title")))
    assert(got("page_count") == "1400",            tostring(got("page_count")))
    assert(got("book_count") == "2",               tostring(got("book_count")))
end)

t.test("folder book_count counts filepaths", function()
    assert(Columns.resolve(FOLDER, Columns.byId("book_count")) == "3")
    assert(Columns.resolve(FOLDER, Columns.byId("title")) == "Sci-Fi")
end)

t.test("columns with no group meaning yield nil", function()
    -- These render as a dash. Returning nil (rather than "-") keeps the
    -- placeholder a rendering decision, so it can change in one place.
    assert(Columns.resolve(SERIES, Columns.byId("series_index")) == nil)
    assert(Columns.resolve(SERIES, Columns.byId("percent_read")) == nil)
    assert(Columns.resolve(OPDS,   Columns.byId("page_count"))   == nil)
end)

t.test("a sparse OPDS record never errors", function()
    -- Catalog records carry almost no metadata; every column must degrade to
    -- nil rather than throwing mid-render.
    for _i, c in ipairs(Columns.CATALOGUE) do
        local ok = pcall(Columns.resolve, OPDS, c)
        assert(ok, "resolve errored on opds_nav for column " .. c.id)
    end
end)

-- ── Active set ─────────────────────────────────────────────────────────────
t.test("active falls back to the defaults when unset", function()
    _settings.list_columns = nil
    local active = Columns.active()
    assert(#active == #Columns.DEFAULT_IDS, "wrong default count")
    for i, c in ipairs(active) do
        assert(c.id == Columns.DEFAULT_IDS[i], "default order not preserved")
    end
end)

t.test("active honours saved order and drops unknown ids", function()
    -- An id can go stale if a column is removed in a later version; a saved
    -- set naming it must not crash the shelf.
    _settings.list_columns = { "page_count", "nonexistent_column", "title" }
    local active = Columns.active()
    assert(#active == 2, "unknown id not dropped, got " .. #active)
    assert(active[1].id == "page_count")
    assert(active[2].id == "title")
end)

t.test("active falls back to defaults when the saved set is empty", function()
    -- An empty table would render blank rows with no way back through the UI.
    _settings.list_columns = {}
    assert(#Columns.active() == #Columns.DEFAULT_IDS)
end)

-- ── Width solver ───────────────────────────────────────────────────────────
-- A fake measurer: 10px per character. Deterministic, so the arithmetic is
-- checkable by hand.
local function measure(s) return #tostring(s) * 10 end

local function idsToColumns(ids)
    local out = {}
    for _i, id in ipairs(ids) do out[#out + 1] = Columns.byId(id) end
    return out
end

t.test("widths sum exactly to the available width", function()
    -- Exactness matters: a one-pixel shortfall repeated down every row is a
    -- visible ragged right edge, and an overshoot pushes the last column off
    -- screen.
    local sets = {
        { "title" },
        { "title", "author_name" },
        { "cover", "title", "author_name", "percent_read" },
        { "title", "author_name", "page_count", "percent_read", "size" },
        { "cover", "title", "page_count", "book_count", "rating", "format" },
    }
    for _i, ids in ipairs(sets) do
        local active = idsToColumns(ids)
        for _j, avail in ipairs({ 300, 601, 758, 1236, 1448 }) do
            local gap = 8
            local widths = Columns.solveWidths(active, avail, gap, measure, 40)
            assert(#widths == #active,
                "width count mismatch for set " .. _i)
            local sum = 0
            for _k, w in ipairs(widths) do
                assert(w >= 0, "negative width in set " .. _i)
                sum = sum + w
            end
            local total = sum + gap * (#active - 1)
            assert(total == avail, string.format(
                "set %d at avail=%d: widths+gaps summed to %d", _i, avail, total))
        end
    end
end)

t.test("the cover column takes exactly the width it is given", function()
    local active = idsToColumns({ "cover", "title" })
    local widths = Columns.solveWidths(active, 600, 8, measure, 40)
    assert(widths[1] == 40, "cover width was " .. widths[1])
end)

t.test("fixed columns get their sample width", function()
    -- "100%" through the 10px-per-char fake is 40px, plus the solver's
    -- breathing-room padding of one gap.
    local active = idsToColumns({ "title", "percent_read" })
    local widths = Columns.solveWidths(active, 600, 8, measure, 0)
    assert(widths[2] == measure("100%") + 8, "fixed width was " .. widths[2])
end)

t.test("flex columns split the remainder by weight", function()
    -- title weight 3, author_name weight 2. Remainder after the gap splits 3:2.
    local active = idsToColumns({ "title", "author_name" })
    local widths = Columns.solveWidths(active, 508, 8, measure, 0)
    -- 508 - 8 (one gap) = 500 to split 3:2 => 300 / 200.
    assert(widths[1] == 300, "title width was " .. widths[1])
    assert(widths[2] == 200, "author width was " .. widths[2])
end)

t.test("an all-fixed column set still fills the width", function()
    -- With no flex column to absorb it, the leftover must go somewhere
    -- deterministic rather than leaving a ragged edge.
    local active = idsToColumns({ "percent_read", "page_count" })
    local widths = Columns.solveWidths(active, 600, 8, measure, 0)
    local sum = widths[1] + widths[2] + 8
    assert(sum == 600, "all-fixed set summed to " .. sum)
end)

t.test("a cramped width degrades without going negative", function()
    -- Narrow screens and long column sets must not produce negative widths,
    -- which would crash TextWidget's max_width.
    local active = idsToColumns({ "cover", "title", "author_name", "page_count",
                                 "percent_read", "size", "rating" })
    local widths = Columns.solveWidths(active, 200, 8, measure, 40)
    local sum = 0
    for _i, w in ipairs(widths) do
        assert(w > 0, "zero or negative width at column index " .. _i)
        sum = sum + w
    end
    assert(sum + 8 * (#active - 1) == 200, "cramped set summed to " .. sum)
end)

t.done()
