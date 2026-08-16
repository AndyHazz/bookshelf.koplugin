-- bookshelf_list_columns.lua
-- The catalogue of list-view columns, and how each reads a value out of an
-- item.
--
-- ── THE SAVED SHAPE ────────────────────────────────────────────────────────
--
-- Three settings keys, and this comment is the contract for anything editing
-- them (the column picker, and whatever replaces it):
--
--   list_show_cover     boolean. Is there a cover cell on the row at all.
--   list_columns_row1   ordered array of column ids: the first text line.
--   list_columns_row2   ordered array of column ids: the second text line.
--                       LEGITIMATELY EMPTY, and an empty row 2 is not the
--                       same thing as an unset one -- both mean "one text
--                       line", and neither falls back to anything.
--
-- An item renders as
--
--     +--------+-----------------------------------------+
--     |        |  row 1 columns ...                      |
--     | cover  +-----------------------------------------+
--     |        |  row 2 columns ...                      |
--     +--------+-----------------------------------------+
--
-- The cover is NOT a column. It is a boolean, it is always the first cell, and
-- it always spans the full height of the row -- which is what a second text
-- line is FOR: "put the author name below the book title to give more room for
-- longer text" (the maintainer's ruling) only works if the cover does not have
-- to pick a line to sit on. There is deliberately no "cover" entry in
-- CATALOGUE any more, so it cannot be reordered into the middle of a row or
-- added twice.
--
-- Each text row solves its own column widths across the full width left over
-- beside the cover, so row 2 is not constrained to row 1's grid.
--
-- Degrade rules, unchanged in spirit from the single-row model:
--   * an id no version knows is dropped, never fatal -- a saved set can name a
--     column a later release removed;
--   * an empty row 1 falls back to DEFAULT_IDS, because blank rows would leave
--     the user no way back through the UI;
--   * an empty row 2 stays empty. See above.
--
-- ── MIGRATION FROM list_columns ────────────────────────────────────────────
--
-- The single key this replaces held one ordered array with "cover" as one of
-- its ids. A saved set is translated on READ, not rewritten: the set becomes
-- row 1, a "cover" entry in it becomes list_show_cover = true and is dropped
-- from the list, and row 2 comes out empty -- so a user who had configured
-- columns sees exactly the row they had before. The old key is left alone
-- rather than deleted; the first write through the picker lands on the new
-- keys, which then win, and the stale key costs nothing but is still there if
-- the user rolls back.
--
-- ── The catalogue itself ───────────────────────────────────────────────────
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
-- The Progress column renders exactly what the percent_read sort orders by,
-- so it calls that sort's own rule rather than restating it (see percentOf).
-- Soft-required: this catalogue must stay loadable even if the sort engine
-- does not, and every use of it below is nil-guarded.
local _ok_sort, SortEngine = pcall(require, "lib/bookshelf_sort_engine")
if not _ok_sort then SortEngine = nil end

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

-- The record's OWN format label first. buildBookMeta computes one for every
-- book it builds (bookshelf_book_repository.lua:823, `_formatLabel(filepath)`),
-- uppercased and with a ".cbz.zip" wrapper collapsed to "CBZ" -- so on the
-- shelf's own record shape the answer is already there and no string work is
-- needed at all.
--
-- The extension match behind it is the fallback for shapes buildBookMeta did
-- not make, and the ORDER of its candidates is the bug this replaces. The
-- previous revision read `item.filename` FIRST, and buildBookMeta's `filename`
-- is deliberately the basename with the extension STRIPPED (:804,
-- `:gsub("%.[^.]+$", "")`), so the match had nothing to match and the column
-- rendered a dash on every row on the device. `filepath` always carries the
-- extension; `file` is the lfs shape's spelling of a full basename and keeps
-- its own. `filename` stays last rather than being dropped: the SQL prefetch
-- shape (:1957) spells it that way, with the extension intact.
local function fmtFormat(item)
    if type(item.format) == "string" and item.format ~= "" then
        return item.format:upper()
    end
    local name = item.filepath or item.file or item.filename
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

-- ── The four sidecar-backed values ─────────────────────────────────────────
--
-- Progress, status, rating and page count are NOT on the record the shelf
-- renders. Measured rather than assumed: driving this plugin offscreen at
-- 1248x1648 over a real library and dumping every candidate field for every
-- book on the page returns
--
--   book_pct=nil percent_finished=nil _pct=nil status=nil read_status=nil
--   _status=nil rating=nil page_count=nil
--
-- for every book, on every chip, under a title sort AND under a rating,
-- page_count or percent_read sort -- while Repo.readProgress for the same
-- filepath answers pct=0.0016 status=reading pages=616. The Progress column
-- was reading b.book_pct, which only Repo.buildBook sets, and the shelf never
-- calls buildBook (see its header, and buildBookMeta's directly above it).
--
-- Why the repository's own enrichment does not reach here: the getAll and
-- getBySource sort prefetches write _pct / _status (and rating / page_count
-- when the sort asks for them) onto the LIGHT candidate records they sort,
-- and both then throw those records away -- getAll rebuilds the visible slice
-- from its `shapes` list through _safeBuildBookMeta, getBySource from its
-- `paths` list. So the sort-conditional enrichment the review flagged is real
-- in the repository and invisible at the row: rating and page_count are not
-- "populated depending on the sort", they are uniformly absent. page_count
-- survives buildBookMeta only as BIM's `info.pages`, which BIM does not
-- compute for reflowed EPUBs.
--
-- So the value is fetched here. That is not a new cost model for this plugin:
-- the cover grid already does exactly this per visible cover in
-- bookshelf_cover_progress.decide ("Most shelf chips ... use the light book
-- constructor and don't open DocSettings -- book.status arrives nil", then
-- Repo.readProgress on the filepath, "so the per-cover cost stays bounded by
-- the TTL"), and KOReader's own file-browser list does it per visible row
-- (frontend/ui/widget/booklist.lua's getBookInfo: hasSidecarFile, then
-- DocSettings:open, memoized). What is NOT done is calling Repo.buildBook per
-- row: that would re-decode a cover and re-query BIM as well, 27 times a page.
--
-- Three things bound the cost, and all three are load-bearing:
--   1. Repo.progressFor is sidecar-gated (a memoized stat), so the unread
--      majority never opens a sidecar at all -- decide() does not even do
--      that.
--   2. Repo.readProgress memoizes on a 120s TTL, so the four columns on one
--      row cost ONE read between them and paging back costs none.
--   3. A record field always wins, and an accessor only runs for a column the
--      user has actually turned on. A list with no sidecar-backed column
--      never touches the disk.
--
-- File size sits alongside these but is NOT one of them: it needs no sidecar,
-- only a stat, and it is memoized in the repository the same way. See sizeOf.
local _Repo
local function _repo()
    if _Repo == nil then
        local ok, r = pcall(require, "lib/bookshelf_book_repository")
        _Repo = (ok and type(r) == "table") and r or false
    end
    return _Repo or nil
end

-- localPath(b) -> a filepath that names a file on disk, or nil.
--
-- "OPDS://server/id" is a pseudo-path for a catalogue entry with no file
-- behind it, and the codebase already refuses to treat one as a file in the
-- two places it matters (bookshelf_book_repository.lua:715 in buildBookMeta
-- and :914 in getCoverBB, bookshelf_widget.lua:9698 in _isRemoteRecord).
-- Every disk-touching accessor below goes through
-- here so a page of catalogue rows costs no stats at all -- and so those rows
-- show the honest dash rather than a percentage derived from nothing.
local function localPath(b)
    local fp = b.filepath
    if type(fp) ~= "string" or fp == "" then return nil end
    if fp:find("^OPDS://") then return nil end
    return fp
end

-- sidecarOf(b) -> pct, status, rating, page_count, opened
--
-- Any of the first four may be nil; `opened` is Repo.progressFor's own gate
-- answer -- has KOReader ever opened this file -- which is the only honest
-- signal for "this book has reading history" and is what separates a dash from
-- "0%" in the Progress column.
--
-- Never raises: a corrupt sidecar, a missing repository (the pure test
-- harness) or an OPDS pseudo-path all degrade to "no value, never opened",
-- which every accessor already renders as the empty-cell dash.
local function sidecarOf(b)
    local fp = localPath(b)
    if not fp then return nil, nil, nil, nil, false end
    local R = _repo()
    if not R or type(R.progressFor) ~= "function" then
        return nil, nil, nil, nil, false
    end
    local ok, pct, status, rating, pages, opened = pcall(R.progressFor, fp)
    if not ok then return nil, nil, nil, nil, false end
    return pct, status, rating, pages, opened == true
end

-- sizeOf(b) -> bytes on disk, or nil.
--
-- Repo.fileSizeFor is one memoized lfs stat, which is the whole cost: a file's
-- size needs no sidecar, no BIM query and no metadata of any kind, so this
-- never goes near the DocSettings path the four columns above use. Measured
-- offscreen over the 20 books of one 1248x1648 page: 0.08ms cold, 0.00ms warm
-- -- but that is a laptop SSD, so the honest device figure is the ~50us per
-- stat that bookshelf_book_repository.lua's _dirsChanged already quotes for
-- Kindle flash, i.e. of the order of 1ms for a full page, once.
local function sizeOf(b)
    local fp = localPath(b)
    if not fp then return nil end
    local R = _repo()
    if not R or type(R.fileSizeFor) ~= "function" then return nil end
    local ok, bytes = pcall(R.fileSizeFor, fp)
    if not ok then return nil end
    return bytes
end

-- progressOf(b) -> pct, status, opened
-- Record fields first, in the order the shapes actually occur: `book_pct` /
-- `status` (Repo.buildBook -- the previewed book, spliced back into its own
-- row by _refreshListRowInPlace), then `percent_finished` / `read_status`
-- (SQL prefetch and group shapes), then `_pct` / `_status` (the lfs and light
-- shapes SortEngine documents). Only what is still missing is fetched.
--
-- A book file with no sidecar has never been opened, so "unread" is the
-- truthful STATUS rather than a value we failed to find -- the same
-- normalisation Repo's own _statusForFp applies. Records with no file behind
-- them (an OPDS nav row, a catalogue entry, a stub) are left nil: there is
-- nothing to be unread.
--
-- Note that this is the Status column's answer, not the Progress column's.
-- "Unread" is a fact about a never-opened book; "0%" is not (see percentOf).
--
-- `opened` is the third return: does this book have reading history at all.
-- A record field is itself proof that it does -- every one of the six read
-- below is written from a DocSettings read (buildBook) or from a progress
-- prefetch over one, and a never-opened book leaves all six nil -- so the
-- sidecar gate is consulted only for records that carry neither, which is the
-- shelf's own shape and every case that matters.
--
-- With ONE exception, which is why `status` alone is not taken as proof:
-- bookshelf_book_repository.lua:3623 stamps `b._status = "unread"` in place,
-- on a record for a book with no sidecar, whenever a status or rating filter
-- is active -- a value that means "never opened" being read as evidence of
-- having been opened, which renders "0%" where the dash is correct. The
-- equivalent site at :5767 sets `_status = nil` for a no-sidecar book, so
-- :3623 is the outlier and nil is the established convention. Excluding
-- "unread" here costs nothing (the sidecar gate below still answers for real
-- records) and does not depend on which of the two conventions a future
-- caller follows. Latent rather than live at the time of writing: both paths
-- carrying those mutated records replace them before a row renders.
local function progressOf(b)
    local pct    = b.book_pct or b.percent_finished or b._pct
    local status = b.status or b.read_status or b._status
    local opened = (pct ~= nil) or (status ~= nil and status ~= "unread")
    if pct ~= nil and status ~= nil then return pct, status, true end
    local s_pct, s_status, _rating, _pages, has_sidecar = sidecarOf(b)
    if has_sidecar then opened = true end
    if pct == nil then pct = s_pct end
    if status == nil then
        status = s_status
        if status == nil and localPath(b) then status = "unread" end
    end
    return pct, status, opened
end

-- percentOf(b) -> 0..1, or nil
--
-- The dash means "no reading history"; ANY number means "this has been read to
-- that point". A book that has never been opened gets the dash, and a book
-- that has been opened gets its percentage even when that percentage is 0.
--
-- That distinction is the whole point of the rule and it is worth stating why
-- the obvious simplification is wrong: rendering unread books as "0%" makes
-- *never opened* indistinguishable from *opened and barely started*, and both
-- are common. Six of ten rows on the maintainer's own screen were unread, and
-- two of the books in that library sit at ~0.16% -- which rounds to "0%" and
-- so read identically to the untouched ones.
--
-- DELIBERATE DIVERGENCE FROM THE SORT, so please do not "fix" it back into
-- agreement: SortEngine.effectivePercent answers 0 for a never-opened book
-- because a sort needs a total order over every book on the page. A column
-- does not -- it can say "nothing here", and that is more useful than a
-- number it would be inventing. Everywhere the two CAN agree they still do,
-- through the one call below rather than a second copy of its rules: a
-- finished book reads 100% whatever percentage is stored against it.
--
-- The shim table is what lets it: effectivePercent reads exactly
-- read_status/_status and percent_finished/_pct, which is the lfs + light
-- record shape it was written for. progressOf has already widened that to
-- every shape a rendered row can hold. Same rule, wider input.
local function percentOf(b)
    local pct, status, opened = progressOf(b)
    -- No reading history: no file, or a file KOReader has never opened. Also
    -- every catalogue row, which has no file to have read at all.
    if not opened then return nil end
    -- Opened, with a stored percentage but no status to go with it. Reachable
    -- only from a legacy sidecar -- current KOReader writes
    -- summary.status = "reading" on every open, and progressOf's own fallback
    -- calls a statusless book "unread" -- but where it IS reachable,
    -- effectivePercent would read that nil/"unread" status as 0 and show a
    -- 62%-read book as 0%. The stored number is the better evidence here.
    if pct ~= nil and (status == nil or status == "unread" or status == "new") then
        return pct
    end
    if not (SortEngine and SortEngine.effectivePercent) then
        -- Harness fallback only. Mirrors effectivePercent so the catalogue
        -- stays loadable without the sort engine; the tests exercise the real
        -- one.
        if status == "finished" or status == "complete" then return 1.0 end
        if status == nil or status == "new" or status == "unread" then return 0 end
        return pct
    end
    return SortEngine.effectivePercent{
        read_status      = status,
        percent_finished = pct,
    }
end

-- ── Catalogue ──────────────────────────────────────────────────────────────
-- Order here is the order the "Add column" picker offers, sorted by likely
-- usefulness rather than alphabetically (same convention as SortEngine.ORDER).
--
-- weight  = flex column; shares whatever width is left, in proportion.
-- sample  = fixed column; sized once from this worst-case string.
-- Exactly one of the two, enforced by the test suite.

-- No "cover" entry, deliberately: the cover is the list_show_cover boolean
-- and is rendered as the row's own first cell, spanning both text rows (see
-- the header). It was a column, with kind = "cover" and a filepath accessor
-- nothing read; as a column it could only ever occupy one of the two rows,
-- and it could be dragged into the middle of one. A saved set naming it
-- migrates to the boolean rather than being dropped.
Columns.CATALOGUE = {
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

    -- No "Series #" column, deliberately: the Series column above renders the
    -- raw `series` string, which is already "<name> #<n>" on both the BIM and
    -- the Calibre path (bookshelf_book_repository.lua:841-843) -- "Ilium #1",
    -- "Discworld #4". A separate index column repeated the number that was
    -- already on the row. The sort key of the same name stays: ordering by
    -- position within a series is a real thing to want, showing it twice is
    -- not. Columns.active() drops a saved id it no longer knows, so a user who
    -- had this column turned on simply loses it on the next rebuild.

    { id = "percent_read", label = tr("Progress"), kind = "text",
      align = "right", sample = "100%",
      book  = function(b) return fmtPercent(percentOf(b)) end,
      group = function() return nil end },

    { id = "page_count", label = tr("Pages"), kind = "text",
      align = "right", sample = "99999",
      -- BIM's own count (buildBookMeta's info.pages) first: it is already on
      -- the record for pre-paginated formats. Reflowed EPUBs have none there
      -- -- BIM skips crengine documents -- and the count lives in the sidecar
      -- instead, which is where the miss above came from.
      book  = function(b)
          local n = b.page_count
          if n == nil then n = select(4, sidecarOf(b)) end
          return fmtInt(n)
      end,
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
      -- Second return of progressOf, so Status and Progress can never
      -- contradict each other on the same row (a "Finished" book showing 62%
      -- is exactly what effectivePercent exists to prevent).
      book  = function(b) return fmtStatus(select(2, progressOf(b))) end,
      group = function() return nil end },

    { id = "rating", label = tr("Rating"), kind = "text",
      align = "left", sample = "\xE2\x98\x85\xE2\x98\x85\xE2\x98\x85\xE2\x98\x85\xE2\x98\x85",
      book  = function(b)
          local r = b.rating
          if r == nil then r = select(3, sidecarOf(b)) end
          return fmtRating(r)
      end,
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
      -- A book on disk always has a size, so a dash here is always a bug.
      -- `size` and `attr.size` are the walk and lfs shapes' spellings and are
      -- checked first (walkBooks keeps size alongside mtime for exactly this
      -- reason, bookshelf_book_repository.lua:1837), but NEITHER is on the
      -- record the shelf renders -- buildBookMeta is BookInfoManager-only and
      -- BIM does not store a file size at all. Hence the stat, and hence the
      -- column being empty on every row before this.
      book  = function(b)
          local n = b.size or (b.attr and b.attr.size)
          if n == nil then n = sizeOf(b) end
          return fmtSize(n)
      end,
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

-- The default first text row. "cover" is no longer one of these -- it is
-- DEFAULT_SHOW_COVER below -- so this array is exactly what row 1 falls back
-- to when nothing is saved and when a saved row 1 degrades to nothing.
Columns.DEFAULT_IDS = { "title", "author_name", "percent_read" }

-- Covers on by default, which is what the single-key default set said (it
-- opened with "cover") and what every existing user is therefore looking at.
Columns.DEFAULT_SHOW_COVER = true

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

-- resolveIds(ids) -> ordered array of column tables, unknown ids dropped.
local function resolveIds(ids)
    local out = {}
    if type(ids) ~= "table" then return out end
    for _i, id in ipairs(ids) do
        local c = Columns.byId(id)
        if c then out[#out + 1] = c end
    end
    return out
end

-- legacyShape() -> show_cover, ids   (nil, nil when there is no legacy key)
--
-- The single-key model, read as the three-key one. See MIGRATION in the
-- header: the set becomes row 1, and a "cover" id in it becomes the boolean.
-- Pure -- nothing is written back here, so a read cannot lose a saved set by
-- half-upgrading it.
local function legacyShape()
    local saved = BookshelfSettings.read("list_columns")
    if type(saved) ~= "table" then return nil, nil end
    local show_cover, ids = false, {}
    for _i, id in ipairs(saved) do
        if id == "cover" then show_cover = true
        else ids[#ids + 1] = id end
    end
    return show_cover, ids
end

-- layout() -> { show_cover = boolean, row1 = {col...}, row2 = {col...} }
--
-- The one read of the saved shape; everything that renders or measures a list
-- row goes through it. The three keys are resolved INDEPENDENTLY, each falling
-- back to the legacy key and then to the default, so a half-written state (a
-- cover boolean saved but no rows, say) still produces a sane list rather than
-- a blank one.
function Columns.layout()
    local legacy_cover, legacy_ids = legacyShape()

    local show = BookshelfSettings.read("list_show_cover")
    local show_cover
    if type(show) == "boolean" then
        show_cover = show
    elseif legacy_cover ~= nil then
        show_cover = legacy_cover
    else
        show_cover = Columns.DEFAULT_SHOW_COVER
    end

    local saved_row1 = BookshelfSettings.read("list_columns_row1")
    local row1 = resolveIds(type(saved_row1) == "table" and saved_row1
                            or legacy_ids)
    if #row1 == 0 then row1 = resolveIds(Columns.DEFAULT_IDS) end

    -- No fallback of any kind: an empty row 2 is the one-line row, which is
    -- both the default and a perfectly ordinary thing to have chosen.
    local row2 = resolveIds(BookshelfSettings.read("list_columns_row2"))

    return { show_cover = show_cover, row1 = row1, row2 = row2 }
end

-- solveWidths(active, available_w, gap, measure) -> array of widths
--
-- Deterministic and single-pass. Content is deliberately NOT measured:
-- auto-fitting every cell would make column positions depend on which page
-- you are looking at, so the table would shift under the user as they page.
-- Fixed positions are worth more than tight packing here.
--
-- Solves ONE text row. The cover is not a column any more, so it is not this
-- function's business: the caller takes the cover cell and its trailing gap
-- off the row width first and hands what is left to each of the two rows in
-- turn (see ListRow.pageLayout). That is why the widths a one-row list solves
-- are unchanged by the two-row model -- available_w minus the cover minus one
-- gap, then n-1 gaps inside, is the same arithmetic the cover-as-column
-- version did in a single pass.
--
-- Invariants, in priority order:
--   1. Widths plus gaps sum EXACTLY to available_w (always).
--   2. Every column gets at least 1 pixel, WHEN the available width can afford it
--      (i.e., content_w >= column_count). When the available width is smaller
--      than the column count, exact-sum wins and some columns may be zero.
--
-- The algorithm:
--   1. Columns declaring a `sample` take that sample's rendered width plus one
--      gap of breathing room. These are the numeric and short columns.
--   2. Whatever is left splits among `weight` columns in proportion.
--   3. If the floor is affordable, every column is raised to >= 1 and deficit
--      is reclaimed from the widest columns.
--   4. The rounding remainder is reconciled with the widest column, taking 1px
--      at a time if needed (for negative slack), to ensure exact-sum always holds.
--
-- `measure` is injected rather than required, so the solver stays pure and
-- testable without a font stack.
function Columns.solveWidths(active, available_w, gap, measure)
    local n = #active
    local widths = {}
    if n == 0 then return widths end

    local content_w = available_w - gap * (n - 1)
    if content_w < 0 then content_w = 0 end

    -- Pass 1: everything that is not flex.
    local fixed_total  = 0
    local weight_total = 0
    for i, c in ipairs(active) do
        if type(c.sample) == "string" then
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
            if type(c.sample) == "string" then
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
            if type(c.sample) ~= "string" then
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
