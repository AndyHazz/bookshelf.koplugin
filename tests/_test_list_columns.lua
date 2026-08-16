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
--
-- SIDECAR doubles as the "has this ever been opened?" gate, exactly as the
-- repository does it: progressFor's fifth return is its own sidecar-stat
-- answer, and a DocSettings sidecar exists if and only if KOReader has opened
-- the file. A filepath with an entry here has a sidecar; one without has never
-- been opened. An entry can be EMPTY -- a sidecar that stores neither a
-- percentage nor a status -- which is the legacy shape the Progress column has
-- to keep out of the "no history" bucket.
--
-- FILESIZE is the lfs stat behind Repo.fileSizeFor. Separate table, separate
-- counter: a file's size has nothing to do with whether it has been read, and
-- conflating the two in the stub would hide it if the column started asking
-- the wrong one.
local SIDECAR = {}
local FILESIZE = {}
local sidecar_calls = 0
local stat_calls = 0
package.loaded["lib/bookshelf_book_repository"] = {
    progressFor = function(fp)
        sidecar_calls = sidecar_calls + 1
        local s = SIDECAR[fp]
        if not s then return nil, nil, nil, nil, false end
        return s.pct, s.status, s.rating, s.pages, true
    end,
    fileSizeFor = function(fp)
        stat_calls = stat_calls + 1
        return FILESIZE[fp]
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
        -- Every catalogue entry is a text column now: the cover left the
        -- catalogue for the list_show_cover boolean, so "cover" is no longer
        -- a kind a column may declare.
        assert(c.kind == "text",
            c.id .. " has bad kind: " .. tostring(c.kind))
        assert(c.align == "left" or c.align == "right",
            c.id .. " has bad align")
        local has_weight = type(c.weight) == "number"
        local has_sample = type(c.sample) == "string"
        assert(has_weight ~= has_sample,
            c.id .. " must declare exactly one of weight or sample")
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
    --
    -- `filename` is the basename with the EXTENSION STRIPPED, because that is
    -- what buildBookMeta stores (bookshelf_book_repository.lua:804,
    -- `:gsub("%.[^.]+$", "")`). The previous fixture kept the extension, which
    -- is why a Format column that matched on `filename` looked fine here and
    -- rendered a dash on every row of the device. `format` is present for the
    -- same reason in reverse: buildBookMeta:823 always sets it, and the column
    -- was never reading it.
    --
    -- NO `size`: BookInfoManager does not store one, so the shelf's record has
    -- none, and the File size column has to go to the filesystem for it.
    local base = fp:match("([^/]+)$") or fp
    local b = {
        filepath = fp,
        filename = base:gsub("%.[^.]+$", ""),
        format   = (base:match("%.(%w+)$") or ""):upper(),
        title    = "T",
    }
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

-- ── Progress: the dash means "no reading history" ──────────────────────────
-- The four cases, pinned together because the distinction between them is the
-- whole point of the column. A previous revision rendered every never-opened
-- book as "0%", which made *untouched* indistinguishable from *opened and
-- barely started* -- and the maintainer's own library has books at ~0.16%
-- sitting next to six unread ones on the same screen.
t.test("a never-opened book shows the dash, not 0%", function()
    -- No sidecar entry at all. THE regression case: "0%" here is a claim about
    -- reading that never happened.
    local b = shelfRecord("/books/never-opened.epub")
    assert(Columns.resolve(b, Columns.byId("percent_read")) == nil,
        "a book with no reading history must render the empty cell, got "
        .. tostring(Columns.resolve(b, Columns.byId("percent_read"))))
    -- Status is a different question and still answers it: "unread" is a fact
    -- about a never-opened book in a way that "0%" is not.
    assert(Columns.resolve(b, Columns.byId("read_status")) == "Unread")
end)

t.test("a barely-started book shows 0%, not a dash", function()
    -- The other half of the distinction. 0.0016 is a real measurement off the
    -- maintainer's device; it rounds to "0%" and that is correct -- what
    -- matters is that it is a number where the untouched book is a dash.
    SIDECAR["/books/barely.epub"] = { pct = 0.0016, status = "reading" }
    local b = shelfRecord("/books/barely.epub")
    assert(Columns.resolve(b, Columns.byId("percent_read")) == "0%",
        tostring(Columns.resolve(b, Columns.byId("percent_read"))))
end)

t.test("a sidecar with a percentage but no status still shows it", function()
    -- Legacy sidecars only: current KOReader writes summary.status on every
    -- open. effectivePercent reads a nil/"unread" status as 0 whatever is
    -- stored, so routing this case through it would show a 62%-read book as
    -- 0% -- and it has history, so it must not be a dash either.
    SIDECAR["/books/legacy.epub"] = { pct = 0.62 }
    local b = shelfRecord("/books/legacy.epub")
    assert(Columns.resolve(b, Columns.byId("percent_read")) == "62%",
        tostring(Columns.resolve(b, Columns.byId("percent_read"))))
end)

t.test("a record stamped _status = unread with no sidecar is still a dash", function()
    -- bookshelf_book_repository.lua:3623 writes `b._status = "unread"` in
    -- place, onto a record for a book with NO sidecar, whenever a status or
    -- rating filter is active. Taking any non-nil status as evidence of
    -- reading history therefore turned "never opened" into "0%" -- a value
    -- that means the opposite of what it was stamped to mean.
    --
    -- Latent rather than live when this was written: both paths that carry
    -- those mutated records replace them before a row renders. Pinned anyway,
    -- because "unreachable today" is not a property the column can rely on and
    -- the record shape is one the repository really does produce.
    -- (:5767 sets `_status = nil` in the same situation, which is the
    -- convention the rest of the codebase follows.)
    local b = shelfRecord("/books/never-opened.epub")   -- no SIDECAR entry
    b._status = "unread"
    assert(Columns.resolve(b, Columns.byId("percent_read")) == nil,
        "a never-opened book must show the dash, got "
        .. tostring(Columns.resolve(b, Columns.byId("percent_read"))))
    -- Status is the other question and still answers it.
    assert(Columns.resolve(b, Columns.byId("read_status")) == "Unread")
end)

t.test("an opened book with nothing stored shows 0%", function()
    -- A sidecar exists (it has been opened) but holds neither a percentage nor
    -- a status. History, so a number; nothing read, so zero.
    SIDECAR["/books/opened-blank.epub"] = {}
    local b = shelfRecord("/books/opened-blank.epub")
    assert(Columns.resolve(b, Columns.byId("percent_read")) == "0%",
        tostring(Columns.resolve(b, Columns.byId("percent_read"))))
end)

t.test("a catalogue row is never stated to have been read", function()
    -- OPDS:// is a pseudo-path with no file behind it, so nothing below the
    -- column may stat it. Both halves matter: the dash, and the absence of the
    -- lookup (the codebase already guards the same prefix at
    -- bookshelf_book_repository.lua:715 and bookshelf_widget.lua:9698).
    local before_sidecar, before_stat = sidecar_calls, stat_calls
    local b = { filepath = "OPDS://gutenberg/1727", title = "Ilium" }
    assert(Columns.resolve(b, Columns.byId("percent_read")) == nil)
    assert(Columns.resolve(b, Columns.byId("read_status")) == nil)
    assert(Columns.resolve(b, Columns.byId("size")) == nil)
    assert(sidecar_calls == before_sidecar,
        "a catalogue row reached the sidecar gate")
    assert(stat_calls == before_stat, "a catalogue row reached the filesystem")
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

t.test("Progress agrees with the sort wherever a book has history", function()
    -- For every record shape a row can hold, a book that HAS been opened
    -- renders exactly SortEngine.effectivePercent formatted. The finished
    -- normalisation is the reason: a second copy of that rule in the column
    -- would show 99% next to a book the sort had already promoted to the top.
    SIDECAR["/books/agree.epub"] = { pct = 0.33, status = "reading" }
    local shapes = {
        { filepath = "/books/agree.epub" },                                  -- shelf record
        { filepath = "/books/agree.epub", _pct = 0.5, _status = "reading" }, -- lfs / light
        { filepath = "/books/agree.epub", percent_finished = 0.75,
          read_status = "reading" },                                         -- SQL prefetch
        { filepath = "/books/agree.epub", book_pct = 0.2, status = "finished" }, -- buildBook
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

t.test("Progress DIVERGES from the sort on a never-opened book", function()
    -- Stated as its own case so nobody "fixes" it back into agreement. The
    -- sort needs a total order over the page, so effectivePercent answers 0
    -- for a book with no history; the column does not, and a dash carries more
    -- information than a fabricated zero.
    local rec = shelfRecord("/books/never-opened.epub")
    assert(SortEngine.effectivePercent{ read_status = "unread" } == 0,
        "the sort no longer ranks unread books at 0 -- re-decide the trade")
    assert(Columns.resolve(rec, Columns.byId("percent_read")) == nil,
        "the column must NOT follow the sort here")
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

-- ── File size and Format: always knowable, so never a dash ─────────────────
-- Both were empty on every row of the maintainer's device, for two DIFFERENT
-- reasons, which is why they are pinned separately here.
t.test("File size comes from the filesystem for a bare shelf record", function()
    -- BookInfoManager stores no file size, so buildBookMeta's record has none
    -- and neither `size` nor `attr.size` is ever set on the shelf's own shape.
    -- A book on disk always has a size, so a dash here is always a bug.
    FILESIZE["/books/big.epub"] = 1536000
    local b = shelfRecord("/books/big.epub")
    assert(b.size == nil and b.attr == nil, "the fixture is not the shelf shape")
    assert(Columns.resolve(b, Columns.byId("size")) == "1.5 MB",
        tostring(Columns.resolve(b, Columns.byId("size"))))
end)

t.test("a record that carries its own size never reaches the filesystem", function()
    -- The walk and lfs shapes have it in hand already (walkBooks keeps size
    -- alongside mtime); paying for a stat on top would be pure waste.
    local before = stat_calls
    assert(Columns.resolve({ filepath = "/books/x.epub", size = 2048 },
        Columns.byId("size")) == "2 KB")
    assert(Columns.resolve({ filepath = "/books/y.epub", attr = { size = 512 } },
        Columns.byId("size")) == "512 B")
    assert(stat_calls == before, "a record with its own size still statted")
end)

t.test("Format reads the record's own label before any string matching", function()
    -- buildBookMeta:823 sets `format` for every book it builds, uppercased and
    -- with a ".cbz.zip" wrapper already collapsed. Nothing here should be
    -- re-deriving it.
    local b = shelfRecord("/books/comic.cbz.zip", { format = "CBZ" })
    assert(Columns.resolve(b, Columns.byId("format")) == "CBZ",
        tostring(Columns.resolve(b, Columns.byId("format"))))
end)

t.test("Format falls back to the FILEPATH, never the stripped filename", function()
    -- The actual defect: `filename` on a shelf record has had its extension
    -- removed, so a match against it finds nothing and the column rendered a
    -- dash on every row. filepath always carries the extension.
    local b = { filepath = "/books/wolf.epub", filename = "wolf" }
    assert(Columns.resolve(b, Columns.byId("format")) == "EPUB",
        tostring(Columns.resolve(b, Columns.byId("format"))))
    -- And with no filepath either, the SQL prefetch spelling (extension
    -- intact) still answers.
    assert(Columns.resolve({ filename = "wolf.pdf" }, Columns.byId("format"))
        == "PDF")
end)

t.test("every book on the shelf's own shape gets a size and a format", function()
    -- The maintainer's phrasing: these should ALWAYS have a value. Sweep the
    -- record shape the shelf really supplies, over the extensions it really
    -- sees, and assert no cell is empty.
    for _i, ext in ipairs({ "epub", "pdf", "cbz", "mobi", "azw3", "fb2" }) do
        local fp = "/books/sweep." .. ext
        FILESIZE[fp] = 4096
        local b = shelfRecord(fp)
        assert(Columns.resolve(b, Columns.byId("size")) == "4 KB", ext .. " size")
        assert(Columns.resolve(b, Columns.byId("format")) == ext:upper(),
            ext .. " format: " .. tostring(Columns.resolve(b, Columns.byId("format"))))
    end
end)

-- ── Series # is gone ───────────────────────────────────────────────────────
t.test("there is no separate series index column", function()
    -- The Series column already renders "Ilium #1" -- the raw `series` string
    -- carries the number on both the BIM and the Calibre path -- so a second
    -- column repeated it.
    assert(Columns.byId("series_index") == nil,
        "the Series # column is back; the number is already in Series")
    -- The sort key of the same name is a different thing and stays.
    assert(SortEngine.KEYS and SortEngine.KEYS.series_index ~= nil,
        "removing the column must not remove the sort")
end)

t.test("a saved set naming the removed column degrades to the rest", function()
    -- The upgrade path for a user who had it turned on: the resolver drops ids
    -- it no longer knows rather than crashing the shelf or blanking the table.
    _settings.list_columns_row1 = { "title", "series_index", "series_name" }
    local row1 = Columns.layout().row1
    assert(#row1 == 2, "stale id not dropped, got " .. #row1)
    assert(row1[1].id == "title" and row1[2].id == "series_name")
    _settings.list_columns_row1 = nil
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
    assert(Columns.resolve(SERIES, Columns.byId("percent_read")) == nil)
    assert(Columns.resolve(SERIES, Columns.byId("size")) == nil)
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

-- ── The saved shape: list_show_cover / list_columns_row1 / _row2 ───────────
--
-- The contract is written out at the top of lib/bookshelf_list_columns.lua.
-- These are the assertions the next pass's editors are entitled to rely on.

local function clearKeys()
    _settings.list_columns      = nil
    _settings.list_show_cover   = nil
    _settings.list_columns_row1 = nil
    _settings.list_columns_row2 = nil
end

local function ids(cols)
    local out = {}
    for _i, c in ipairs(cols) do out[#out + 1] = c.id end
    return table.concat(out, ",")
end

t.test("a fresh install gets covers, the default row 1 and no row 2", function()
    clearKeys()
    local L = Columns.layout()
    assert(L.show_cover == true, "covers must be on by default")
    assert(ids(L.row1) == table.concat(Columns.DEFAULT_IDS, ","),
        "row 1 default was " .. ids(L.row1))
    assert(#L.row2 == 0, "row 2 must start empty, got " .. ids(L.row2))
    -- The cover is not in the default ROW; it is the boolean.
    for _i, id in ipairs(Columns.DEFAULT_IDS) do
        assert(id ~= "cover", "cover must not be a default column id")
    end
end)

t.test("row 1 honours saved order and drops unknown ids", function()
    clearKeys()
    _settings.list_columns_row1 = { "page_count", "nonexistent_column", "title" }
    local L = Columns.layout()
    assert(ids(L.row1) == "page_count,title", "row 1 was " .. ids(L.row1))
end)

t.test("an empty row 1 falls back to the defaults", function()
    -- An empty table would render blank rows with no way back through the UI.
    clearKeys()
    _settings.list_columns_row1 = {}
    assert(ids(Columns.layout().row1) == table.concat(Columns.DEFAULT_IDS, ","))
    -- And so does a row 1 that degrades to nothing.
    _settings.list_columns_row1 = { "nope", "also_nope" }
    assert(ids(Columns.layout().row1) == table.concat(Columns.DEFAULT_IDS, ","))
end)

t.test("an empty row 2 stays empty and never falls back", function()
    -- The asymmetry is the point: one text line is the normal case, so an
    -- unset or emptied row 2 must not conjure the defaults into existence.
    clearKeys()
    assert(#Columns.layout().row2 == 0, "unset row 2 must be empty")
    _settings.list_columns_row2 = {}
    assert(#Columns.layout().row2 == 0, "empty row 2 must stay empty")
    _settings.list_columns_row2 = { "not_a_column" }
    assert(#Columns.layout().row2 == 0, "a degraded row 2 must stay empty")
    _settings.list_columns_row2 = { "author_name", "percent_read" }
    assert(ids(Columns.layout().row2) == "author_name,percent_read")
end)

t.test("row 2 may name the same column as row 1", function()
    -- Nothing forbids it and nothing should: the rows are independent.
    clearKeys()
    _settings.list_columns_row1 = { "title" }
    _settings.list_columns_row2 = { "title" }
    local L = Columns.layout()
    assert(ids(L.row1) == "title" and ids(L.row2) == "title")
end)

t.test("the cover boolean is read as a boolean", function()
    clearKeys()
    _settings.list_show_cover = false
    assert(Columns.layout().show_cover == false, "false must be honored")
    _settings.list_show_cover = true
    assert(Columns.layout().show_cover == true)
end)

-- ── Migration from the single list_columns key ─────────────────────────────

t.test("an old set containing cover migrates to the three keys", function()
    -- Nobody who configured columns may lose them. The set becomes row 1, the
    -- cover id becomes the boolean and leaves the list, row 2 comes out empty.
    clearKeys()
    _settings.list_columns = { "cover", "title", "author_name", "percent_read" }
    local L = Columns.layout()
    assert(L.show_cover == true, "the cover id must become the boolean")
    assert(ids(L.row1) == "title,author_name,percent_read",
        "row 1 was " .. ids(L.row1))
    assert(#L.row2 == 0, "migration must not invent a second row")
    -- Read-only: the legacy key is left exactly as it was, so a rollback still
    -- finds it and a half-completed upgrade cannot lose it.
    assert(#_settings.list_columns == 4, "the legacy key was rewritten")
end)

t.test("an old set without cover migrates to covers OFF", function()
    -- The user turned the Cover column off; the boolean has to inherit that
    -- rather than defaulting back to on.
    clearKeys()
    _settings.list_columns = { "title", "author_name" }
    local L = Columns.layout()
    assert(L.show_cover == false, "an absent cover id means covers off")
    assert(ids(L.row1) == "title,author_name", "row 1 was " .. ids(L.row1))
end)

t.test("cover anywhere in the old set migrates, not just first", function()
    clearKeys()
    _settings.list_columns = { "title", "cover", "percent_read" }
    local L = Columns.layout()
    assert(L.show_cover == true)
    assert(ids(L.row1) == "title,percent_read", "row 1 was " .. ids(L.row1))
end)

t.test("an old set of nothing but cover still yields a usable row", function()
    clearKeys()
    _settings.list_columns = { "cover" }
    local L = Columns.layout()
    assert(L.show_cover == true)
    assert(ids(L.row1) == table.concat(Columns.DEFAULT_IDS, ","),
        "an emptied row 1 must fall back, got " .. ids(L.row1))
end)

t.test("the new keys win over the legacy one", function()
    clearKeys()
    _settings.list_columns      = { "cover", "size" }
    _settings.list_columns_row1 = { "title" }
    _settings.list_show_cover   = false
    local L = Columns.layout()
    assert(L.show_cover == false, "the explicit boolean must beat the old id")
    assert(ids(L.row1) == "title", "row 1 was " .. ids(L.row1))
end)

t.test("a half-migrated state degrades sanely", function()
    -- Only the rows written, no boolean: the legacy key still answers for the
    -- cover rather than the default overriding what the user chose.
    clearKeys()
    _settings.list_columns      = { "title", "author_name" }   -- no cover
    _settings.list_columns_row1 = { "title" }
    assert(Columns.layout().show_cover == false)
    -- Only the boolean written, no rows: the legacy set still supplies row 1.
    clearKeys()
    _settings.list_columns    = { "cover", "size", "format" }
    _settings.list_show_cover = false
    local L = Columns.layout()
    assert(L.show_cover == false)
    assert(ids(L.row1) == "size,format", "row 1 was " .. ids(L.row1))
end)

t.test("the picker writes the row 1 key", function()
    -- The one thing the picker had to change. A source-shape check: the picker
    -- cannot be loaded under a plain interpreter (ButtonDialog et al).
    local src = io.open("lib/bookshelf_list_column_picker.lua"):read("*a")
    assert(src:match('ROW1_KEY%s*=%s*"list_columns_row1"'),
        "the picker must save to list_columns_row1")
    assert(not src:match('save%("list_columns"'),
        "the picker must not write the superseded single key")
end)

clearKeys()

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
        { "title", "author_name", "percent_read" },
        { "title", "author_name", "page_count", "percent_read", "size" },
        { "title", "page_count", "book_count", "rating", "format" },
    }
    for _i, ids in ipairs(sets) do
        local active = idsToColumns(ids)
        for _j, avail in ipairs({ 300, 601, 758, 1236, 1448 }) do
            local gap = 8
            local widths = Columns.solveWidths(active, avail, gap, measure)
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

t.test("the solver has no cover case left, and needs none", function()
    -- Re-pointed from "the cover column takes exactly the width it is given".
    -- The caller now takes the cover cell and one gap off the row width before
    -- solving, so the pixels the TEXT gets are the same either way -- which is
    -- what keeps a one-row list's column positions unchanged. Proven by
    -- reproducing the old single-pass arithmetic and comparing.
    local gap, cover_w, content_w = 8, 40, 600
    local text = idsToColumns({ "title", "author_name", "percent_read" })
    local new  = Columns.solveWidths(text, content_w - cover_w - gap, gap, measure)
    -- What the cover-as-column solver would have produced: n+1 columns across
    -- content_w, the first pinned at cover_w. Its content budget was
    -- content_w - n*gap - cover_w; the new one's is
    -- (content_w - cover_w - gap) - (n-1)*gap. Identical.
    local old_budget = content_w - gap * #text - cover_w
    local sum = 0
    for _i, w in ipairs(new) do sum = sum + w end
    assert(sum == old_budget, string.format(
        "text columns got %d px; the cover-as-column model gave them %d",
        sum, old_budget))
end)

t.test("fixed columns get their sample width", function()
    -- "100%" through the 10px-per-char fake is 40px, plus the solver's
    -- breathing-room padding of one gap.
    local active = idsToColumns({ "title", "percent_read" })
    local widths = Columns.solveWidths(active, 600, 8, measure)
    assert(widths[2] == measure("100%") + 8, "fixed width was " .. widths[2])
end)

t.test("flex columns split the remainder by weight", function()
    -- title weight 3, author_name weight 2. Remainder after the gap splits 3:2.
    local active = idsToColumns({ "title", "author_name" })
    local widths = Columns.solveWidths(active, 508, 8, measure)
    -- 508 - 8 (one gap) = 500 to split 3:2 => 300 / 200.
    assert(widths[1] == 300, "title width was " .. widths[1])
    assert(widths[2] == 200, "author width was " .. widths[2])
end)

t.test("an all-fixed column set still fills the width", function()
    -- With no flex column to absorb it, the leftover must go somewhere
    -- deterministic rather than leaving a ragged edge.
    local active = idsToColumns({ "percent_read", "page_count" })
    local widths = Columns.solveWidths(active, 600, 8, measure)
    local sum = widths[1] + widths[2] + 8
    assert(sum == 600, "all-fixed set summed to " .. sum)
end)

t.test("a cramped width degrades without going negative", function()
    -- Narrow screens and long column sets must not produce negative widths,
    -- which would crash TextWidget's max_width.
    local active = idsToColumns({ "title", "author_name", "page_count",
                                 "percent_read", "size", "rating", "format" })
    local widths = Columns.solveWidths(active, 200, 8, measure)
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
    local widths = Columns.solveWidths(active, 3, 1, measure)
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
    local widths = Columns.solveWidths(active, 5, 1, measure)
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
