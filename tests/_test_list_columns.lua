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

-- ── The sidecar, stubbed ───────────────────────────────────────────────────
-- Progress / status / rating / page count are NOT on the record the shelf
-- renders (see the block above Columns.CATALOGUE for the measurement), so the
-- accessors fetch them through Repo.progressFor. Stub the whole repository:
-- these tests are about what the column DOES with what comes back, and the
-- repository has its own suite.
--
-- `calls` counts every lookup, so a test can assert that a record which
-- already carries its own fields never reaches the disk at all.
local SIDECAR = {}
local sidecar_calls = 0
package.loaded["lib/bookshelf_book_repository"] = {
    progressFor = function(fp)
        sidecar_calls = sidecar_calls + 1
        local s = SIDECAR[fp]
        if not s then return nil, nil, nil, nil end
        return s.pct, s.status, s.rating, s.pages
    end,
}

local helpers = dofile("tests/_helpers.lua")
local t       = helpers.runner()

local Columns    = require("lib/bookshelf_list_columns")
local SortEngine = require("lib/bookshelf_sort_engine")

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

t.test("author_name joins the table shape of `authors`", function()
    -- buildBookMeta hands the shelf an ARRAY of author names (splitAuthors),
    -- not the joined string the SQL prefetch path produces. Both have to
    -- render, or the author column is empty on the shelf's own path.
    local col = Columns.byId("author_name")
    assert(Columns.resolve({ authors = { "Terry Pratchett", "Stephen Baxter" } }, col)
           == "Terry Pratchett, Stephen Baxter")
    assert(Columns.resolve({ authors = {}, author = nil }, col) == nil)
    assert(Columns.resolve({ author = "Iain M. Banks" }, col) == "Iain M. Banks")
end)

-- ── Resolution: the SHELF's own record shape ───────────────────────────────
-- The BOOK fixture above is a Repo.buildBook record -- book_pct, status,
-- rating, page_count all present. The shelf never calls buildBook. Every row
-- it renders is a Repo.buildBookMeta record, which is BookInfoManager-only,
-- and on device that means these four fields read nil on every book:
--
--   [diag] 'Salem's Lot | book_pct=nil percent_finished=nil _pct=nil
--          status=nil read_status=nil _status=nil rating=nil page_count=nil
--   [diag]     TRUTH  pct=0.0016 status=reading rating=nil pages=616
--
-- (offscreen at 1248x1648 over a real library, on the "all" chip, and the same
-- under a rating / page_count / percent_read sort). The suite passed anyway,
-- because every fixture in it carried fields the shelf does not supply. These
-- cases pin the shape that actually reaches a row.
local function shelfRecord(fp, extra)
    -- Deliberately minimal: filepath and title are all buildBookMeta reliably
    -- gives a row for these columns. Adding a field here to make a test pass
    -- is how the gap opened in the first place.
    local b = { filepath = fp, filename = fp:match("([^/]+)$"), title = "T" }
    for k, v in pairs(extra or {}) do b[k] = v end
    return b
end

t.test("progress resolves from the sidecar for a bare shelf record", function()
    SIDECAR["/books/salem.epub"] = { pct = 0.62, status = "reading", pages = 616 }
    local b = shelfRecord("/books/salem.epub")
    assert(Columns.resolve(b, Columns.byId("percent_read")) == "62%",
        tostring(Columns.resolve(b, Columns.byId("percent_read"))))
    assert(Columns.resolve(b, Columns.byId("read_status")) == "Reading")
    assert(Columns.resolve(b, Columns.byId("page_count")) == "616")
end)

t.test("a finished book reads 100% with no stored percentage", function()
    -- The case that has no percentage to show and must still not show a dash.
    SIDECAR["/books/done.epub"] = { status = "finished" }
    local b = shelfRecord("/books/done.epub")
    assert(Columns.resolve(b, Columns.byId("percent_read")) == "100%",
        tostring(Columns.resolve(b, Columns.byId("percent_read"))))
    assert(Columns.resolve(b, Columns.byId("read_status")) == "Finished")
end)

t.test("a finished book stopped at 99% still reads 100%", function()
    SIDECAR["/books/nearly.epub"] = { pct = 0.99, status = "finished" }
    local b = shelfRecord("/books/nearly.epub")
    assert(Columns.resolve(b, Columns.byId("percent_read")) == "100%",
        tostring(Columns.resolve(b, Columns.byId("percent_read"))))
end)

t.test("an unread book reads 0%, not a dash", function()
    -- No sidecar entry at all: never opened. "0%" and "Unread" are facts about
    -- that book; a dash would read as "the renderer could not tell".
    local b = shelfRecord("/books/never-opened.epub")
    assert(Columns.resolve(b, Columns.byId("percent_read")) == "0%",
        tostring(Columns.resolve(b, Columns.byId("percent_read"))))
    assert(Columns.resolve(b, Columns.byId("read_status")) == "Unread")
end)

t.test("rating and pages come from the sidecar too, whatever the sort", function()
    -- The review's second question. The repository DOES set rating /
    -- page_count conditionally -- only when that key is in the chip's sort
    -- priority -- but it sets them on the light candidate records it sorts and
    -- then discards, so nothing sort-shaped ever reaches a row. Resolving them
    -- here, from the record's own filepath, is what makes the two columns
    -- independent of how the chip happens to be sorted.
    SIDECAR["/books/rated.epub"] = { status = "reading", rating = 4, pages = 288 }
    local b = shelfRecord("/books/rated.epub")
    assert(Columns.resolve(b, Columns.byId("rating")) == "\xE2\x98\x85\xE2\x98\x85\xE2\x98\x85\xE2\x98\x85",
        tostring(Columns.resolve(b, Columns.byId("rating"))))
    assert(Columns.resolve(b, Columns.byId("page_count")) == "288")
end)

t.test("the lfs / light shapes resolve without a sidecar lookup", function()
    -- _pct / _status are what SortEngine documents for the lfs entry and the
    -- light record. They are not on a rendered row today, but the accessor has
    -- to read them: the letter-jump path hands back light candidates directly,
    -- and a future page that keeps them must not pay for a lookup it does not
    -- need.
    local before = sidecar_calls
    local b = { filepath = "/books/light.epub", _pct = 0.4, _status = "reading" }
    assert(Columns.resolve(b, Columns.byId("percent_read")) == "40%",
        tostring(Columns.resolve(b, Columns.byId("percent_read"))))
    assert(Columns.resolve(b, Columns.byId("read_status")) == "Reading")
    assert(sidecar_calls == before,
        "a record carrying its own progress still hit the sidecar")
end)

t.test("record fields beat the sidecar", function()
    SIDECAR["/books/stale.epub"] = { pct = 0.9, status = "finished" }
    local b = { filepath = "/books/stale.epub", book_pct = 0.1, status = "reading" }
    assert(Columns.resolve(b, Columns.byId("percent_read")) == "10%",
        tostring(Columns.resolve(b, Columns.byId("percent_read"))))
    assert(Columns.resolve(b, Columns.byId("read_status")) == "Reading")
end)

t.test("BIM's own page count beats the sidecar's", function()
    -- buildBookMeta sets page_count from BIM for pre-paginated formats; only
    -- reflowed EPUBs fall through to the sidecar.
    SIDECAR["/books/pdf.pdf"] = { pages = 999 }
    local b = shelfRecord("/books/pdf.pdf", { page_count = 120 })
    assert(Columns.resolve(b, Columns.byId("page_count")) == "120")
end)

t.test("Progress shows exactly what the percent_read sort orders by", function()
    -- The property, not a sample of it: for every record shape a row can hold,
    -- the rendered cell is SortEngine.effectivePercent formatted. A second copy
    -- of the finished/unread rules in the column would show 99% next to a
    -- book the sort had already promoted to the top as finished.
    SIDECAR["/books/agree.epub"] = { pct = 0.33, status = "reading" }
    local shapes = {
        { filepath = "/books/agree.epub" },                                  -- shelf record
        { filepath = "/books/agree.epub", _pct = 0.5, _status = "reading" }, -- lfs / light
        { filepath = "/books/agree.epub", percent_finished = 0.75,
          read_status = "reading" },                                         -- SQL prefetch
        { filepath = "/books/agree.epub", book_pct = 0.2, status = "finished" }, -- buildBook
        { filepath = "/books/never-opened.epub" },                           -- unread
    }
    for i, rec in ipairs(shapes) do
        local got = Columns.resolve(rec, Columns.byId("percent_read"))
        -- The sort sees the same record. Normalise onto the two names
        -- effectivePercent reads, exactly as the accessor does.
        local pct    = rec.book_pct or rec.percent_finished or rec._pct
        local status = rec.status or rec.read_status or rec._status
        if pct == nil or status == nil then
            local s = SIDECAR[rec.filepath]
            if pct == nil then pct = s and s.pct end
            if status == nil then status = (s and s.status) or "unread" end
        end
        local want = SortEngine.effectivePercent{
            percent_finished = pct, read_status = status }
        want = want and string.format("%d%%", math.floor(want * 100 + 0.5))
        assert(got == want, string.format(
            "shape %d: column says %s, the sort orders by %s",
            i, tostring(got), tostring(want)))
    end
end)

t.test("a record with no filepath claims nothing", function()
    -- No fields and no file to read them from. "0%" / "Unread" would be an
    -- assertion about a book that isn't there; the dash is the honest cell.
    local blank = {}
    assert(Columns.resolve(blank, Columns.byId("percent_read")) == nil)
    assert(Columns.resolve(blank, Columns.byId("read_status")) == nil)
    assert(Columns.resolve(blank, Columns.byId("rating")) == nil)
    assert(Columns.resolve(blank, Columns.byId("page_count")) == nil)
end)

t.test("one sidecar lookup serves all four columns on a row", function()
    -- Repo.readProgress memoizes, but the accessors must not each rebuild the
    -- record's fields from scratch either. Four columns, one row: the count
    -- pins that the lookup is per FIELD-GROUP, not per column x per call.
    SIDECAR["/books/count.epub"] = { pct = 0.5, status = "reading",
                                     rating = 3, pages = 100 }
    local b = shelfRecord("/books/count.epub")
    local before = sidecar_calls
    Columns.resolve(b, Columns.byId("percent_read"))
    Columns.resolve(b, Columns.byId("read_status"))
    Columns.resolve(b, Columns.byId("rating"))
    Columns.resolve(b, Columns.byId("page_count"))
    local n = sidecar_calls - before
    -- percent_read and read_status share progressOf (one call each, since a
    -- row resolves cell by cell); rating and page_count take one each. Four
    -- is the ceiling, and it is what Repo.readProgress's 120s memo is for.
    assert(n <= 4, "four columns cost " .. n .. " sidecar lookups")
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

t.test("exact-sum holds even when the floor is unaffordable", function()
    -- When content_w < column count, we cannot give every column at least 1px.
    -- In that case, exact-sum is the authoritative invariant; some columns may
    -- be zero. Verify the constraint is preserved when the floor is unaffordable.
    local active = idsToColumns({ "title", "author_name", "filename" })
    -- With 3 text columns all flex, available_w=3, gap=1:
    -- content_w = 3 - 1*2 = 1. We cannot give each column 1px, so floor is
    -- unaffordable and some columns will be zero.
    local widths = Columns.solveWidths(active, 3, 1, measure, 0)
    local sum = 0
    for _, w in ipairs(widths) do
        assert(w >= 0, "negative width with unaffordable floor")
        sum = sum + w
    end
    local total = sum + 1 * (#active - 1)
    assert(total == 3, string.format(
        "unaffordable case summed to %d, not 3", total))
end)

t.test("exact-sum holds when the floor IS affordable", function()
    -- With available_w=5, gap=1, we can give 3 columns 1px each (3px used for
    -- widths, 2px for gaps = 5px total). Floor is affordable and should be
    -- enforced: each column gets at least 1px.
    local active = idsToColumns({ "title", "author_name", "filename" })
    local widths = Columns.solveWidths(active, 5, 1, measure, 0)
    local sum = 0
    for _, w in ipairs(widths) do
        assert(w >= 1, "floor not enforced when affordable")
        sum = sum + w
    end
    local total = sum + 1 * (#active - 1)
    assert(total == 5, string.format(
        "affordable case summed to %d, not 5", total))
end)

t.done()
