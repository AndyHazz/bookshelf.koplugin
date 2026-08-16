-- bookshelf_list_lines.lua
-- What a list row says, and how it says it: an ordered array of token
-- templates, one per text line, each with its own face, size, weight, case and
-- alignment.
--
-- ── WHY THIS REPLACED THE COLUMNS ──────────────────────────────────────────
--
-- The model this supersedes was two arrays of column ids, each id naming a
-- fixed cell with a fixed accessor and a solved width. It could put the title,
-- the author and the progress on a row. It could not put "9% of 164 pages" on
-- one -- literal text interleaved with two fields -- which is what KOReader's
-- own list mode shows and is the bar the maintainer set:
--
--     "koreader's standard list mode shows e.g. '9% of 164 pages' - as long as
--      we can replicate that I think we're all good"
--
-- and, separately:
--
--     "We can lose the columns, with the %spacer token I think that gives all
--      you need (a way to align left or right)."
--
-- So a line is a template expanded through lib/bookshelf_tokens.lua, exactly
-- as a hero region is, and %spacer -- an elastic gap the renderer splits the
-- line on -- does the work the right-aligned columns did. Everything the
-- columns could express, the templates can; the reverse was never true.
--
-- ── THE SAVED SHAPE ────────────────────────────────────────────────────────
--
--   list_show_cover  boolean. Is there a cover cell on the row at all.
--   list_lines       ordered array of line definitions:
--                      { template, font_face, font_size,
--                        bold, uppercase, alignment }
--
-- An item renders as
--
--     +--------+-----------------------------------------+
--     |        |  line 1                                 |
--     | cover  +-----------------------------------------+
--     |        |  line 2                                 |
--     |        +-----------------------------------------+
--     |        |  line 3 ...                             |
--     +--------+-----------------------------------------+
--
-- The cover is NOT a line. It is a boolean, it is always the first cell, and
-- it spans the full height of the row however many lines there are -- which is
-- what more than one text line is FOR.
--
-- The COUNT IS VARIABLE. One line, two, or up to MAX_LINES: nothing may assume
-- two. The row-height budget sums the measured height of each line
-- (bookshelf_list_geom.lua's rowHeight takes an array), and the renderer lays
-- down exactly as many bands as there are lines.
--
-- The per-line field set is the hero's, deliberately -- see
-- lib/bookshelf_hero_regions.lua's DEFAULTS. These two surfaces are converging
-- on one idea of "a line of tokens you can style", and the line editor that
-- lands later edits both through the same vocabulary.
--
-- One field means something slightly different here: font_size is a point size
-- BEFORE list_font_scale, which the renderer applies on top (the hero does the
-- same with its own global font-scale knob). That is what keeps list_font_scale
-- a density control -- nudge it and the whole row, type and height together,
-- moves -- rather than a knob that grows type inside a band that cannot hold
-- it.
--
-- Degrade rules, unchanged in spirit from the column model:
--   * a malformed entry is dropped, never fatal -- a hand-edited settings file
--     or a set written by a later release must still render;
--   * an empty result falls back to DEFAULTS, because a row with no lines
--     would leave the user no way back through the UI;
--   * more than MAX_LINES is truncated. A row taller than the screen is not a
--     configuration, it is a way to lose the shelf.
--
-- ── MIGRATION ──────────────────────────────────────────────────────────────
--
-- Everything the two column keys could hold becomes a template. See
-- TOKEN_FOR_COLUMN and legacyLines() below for the mapping and the two column
-- ids that have no token to become.
--
-- Translated on READ, not rewritten: the old keys are left alone, so a
-- rollback still finds them. The first write through the editor lands on
-- list_lines, which then wins.

local BookshelfSettings = require("lib/bookshelf_settings_store")
local ListGeom          = require("lib/bookshelf_list_geom")

local Lines = {}

-- ── The keys, spelled once ─────────────────────────────────────────────────
--
-- Every read goes through layout() and every write through save(); both name
-- the keys from here, so no caller ever types one. The column model learned
-- this the hard way -- three strings hand-spelled across three files with only
-- a comment holding them together -- and a review caught the write side
-- escaping the encapsulation the read side had.
Lines.KEYS = {
    show_cover = "list_show_cover",
    lines      = "list_lines",
}

-- Read-only. Nothing writes these; layout() reads them when list_lines is
-- unset, and that is their whole remaining life.
Lines.LEGACY_KEYS = {
    row1 = "list_columns_row1",
    row2 = "list_columns_row2",
    flat = "list_columns",        -- the single-key model row1/row2 replaced
}

-- Covers on by default, which is what every existing configuration is looking
-- at (the original single-key default set opened with "cover").
Lines.DEFAULT_SHOW_COVER = true

-- A row taller than the screen is not a configuration. Six lines at the
-- default sizes is already most of a Kindle basic's shelf band.
Lines.MAX_LINES = 6

-- ── One line's defaults ────────────────────────────────────────────────────
--
-- Every OPTIONAL field a line can carry, with the value a sparse entry falls
-- through to. Same shape and same names as a hero region, so the two are one
-- vocabulary.
--
-- `template` is deliberately absent: it is the one field an entry must supply
-- itself, and defaulting it to "" would turn a corrupt entry -- a stored table
-- that lost its template, an editor bug that wrote none -- into a line that
-- renders as a blank band the user cannot see the cause of. An entry with no
-- template of its own is not a line. An entry with an EMPTY one is: that is
-- something the user can type, and it is theirs.
--
-- font_size is in points BEFORE list_font_scale. The base is the chip strip's
-- own 16, which is what a list row has always rendered at.
Lines.LINE_DEFAULT = {
    font_face = nil,          -- nil = the row's own face (ListGeom.FONT_FACE)
    font_size = ListGeom.FONT_SIZE_DP,
    bold      = false,
    uppercase = false,
    alignment = "left",
}

-- ── The shipped default: KOReader's own list mode ──────────────────────────
--
-- Two lines, because that is what the standard list shows and what the
-- maintainer named as the bar: the title, then the author on the left with the
-- reading position on the right.
--
-- Line 2's second half is the acceptance test itself, wrapped in the
-- conditional that makes it read for a book nobody has opened. Unguarded,
-- "%book_pct of %page_count pages" on an unread book expands to " of 164
-- pages", which is not a sentence. Guarded, the four cases are:
--
--   read, page count known    9% of 164 pages
--   unread, page count known  164 pages
--   read, no page count       9%
--   neither                   (nothing -- the line is just the author)
--
-- Weight: NOT bold, on either line. That is a ruling rather than an oversight
-- -- bold on 26 rows of a table reads as a page of headings (see
-- bookshelf_list_row.lua's own note on the chip strip's weight).
--
-- Size: 16 and 14 at list_font_scale 100, which is exactly what the two lines
-- of the column model rendered at -- 14 is ListGeom.secondaryFontSize(100),
-- taken through that function rather than typed, so SECONDARY_PCT stays the
-- one place the proportion is decided.
Lines.DEFAULTS = {
    {
        template  = "%title",
        font_size = ListGeom.FONT_SIZE_DP,
        bold      = false,
        uppercase = false,
        alignment = "left",
    },
    {
        template  = "[if:authors]%authors[else]%author[/if]%spacer"
                 .. "[if:page_count][if:book_pct]%book_pct of [/if]"
                 .. "%page_count pages[else]%book_pct[/if]",
        font_size = ListGeom.secondaryFontSize(100),
        bold      = false,
        uppercase = false,
        alignment = "left",
    },
}

-- ── The migration map ──────────────────────────────────────────────────────
--
-- Each column id, as the template fragment that says the same thing. Some are
-- a bare token; some are the conditional the column's accessor was, written
-- out. Faithfulness beats brevity here -- a migrated user must see what they
-- saw -- and the line editor will show them the template so they can shorten
-- it themselves.
--
--   author_name  the accessor preferred the authors ARRAY, joined, and fell
--                back to the single author string. %authors is the join;
--                %author is the fallback. Same conditional the hero's own
--                author region ships with.
--   series_name  `b.series or b.series_name`, in that order.
--   rating       the column drew N filled stars; %rating draws N filled and
--                (5-N) empty. A deliberate difference: the token's form is
--                already the plugin's rating rendering everywhere else.
--   read_status  %status renders the four CANONICAL strings ("reading",
--                "finished", "on_hold", "unread"), where the column rendered a
--                translated label. The token's contract is those four strings
--                -- conditionals depend on them -- so this is the one mapping
--                that loses polish. A user who wants the label back can write
--                it: [if:status=reading]Reading[/if] and so on.
--
-- TWO IDS HAVE NO TOKEN AND ARE DROPPED, by the same rule that drops any id
-- this build does not know:
--
--   book_count   a group's member count. Nothing in the token vocabulary
--                counts a folder's books, and inventing a token for it is a
--                separate decision from this migration.
--   (that is the only one; every other catalogue id maps above.)
local T = {
    title        = "%title",
    author_name  = "[if:authors]%authors[else]%author[/if]",
    series_name  = "[if:series]%series[else]%series_name[/if]",
    percent_read = "%book_pct",
    page_count   = "%page_count",
    read_status  = "%status",
    rating       = "%rating",
    last_opened  = "%opened",
    date_added   = "%added",
    size         = "%size",
    language     = "%lang",
    format       = "%format",
    filename     = "%filename",
}
Lines.TOKEN_FOR_COLUMN = T

-- Which column ids were RIGHT-aligned, so the migration can reproduce their
-- anchoring with %spacer. Copied from the catalogue's own `align` fields.
local RIGHT = {
    percent_read = true,
    page_count   = true,
    book_count   = true,
    last_opened  = true,
    date_added   = true,
    size         = true,
}
Lines.RIGHT_ALIGNED_COLUMNS = RIGHT

-- What went between two columns of one row. Two spaces, which is the hero's
-- own convention for separating runs inside a template
-- ("%book_pct  %bar  %book_time_left"), and enough to read as a gap without
-- inventing a punctuation mark the user did not ask for.
local COLUMN_JOIN = "  "

-- templateForColumns(ids) -> one template, or nil when nothing is left.
--
-- Unknown ids and ids with no token are dropped. A TRAILING RUN of
-- right-aligned columns gets one %spacer in front of it, which is exactly the
-- anchoring the solved-width grid gave them: everything before the spacer sits
-- left, everything after it sits right. One spacer, not one per column -- the
-- renderer honours the first and only the first, so a second would render as
-- literal text.
local function templateForColumns(ids)
    if type(ids) ~= "table" then return nil end
    local kept = {}
    for _i, id in ipairs(ids) do
        local frag = T[id]
        if frag then kept[#kept + 1] = { id = id, frag = frag } end
    end
    if #kept == 0 then return nil end
    -- Walk back over the trailing right-aligned run. Position 1 is excluded:
    -- a row whose FIRST column is right-aligned had nothing to its left to be
    -- pushed away from, and a leading %spacer would right-align the lot --
    -- which the grid did not do.
    local split = #kept + 1
    while split > 2 and RIGHT[kept[split - 1].id] do split = split - 1 end
    local out = {}
    for i, entry in ipairs(kept) do
        if i == split then
            out[#out + 1] = "%spacer"
        elseif i > 1 then
            out[#out + 1] = COLUMN_JOIN
        end
        out[#out + 1] = entry.frag
    end
    return table.concat(out)
end
Lines.templateForColumns = templateForColumns

-- ── Reading ────────────────────────────────────────────────────────────────

local function shallowCopy(t)
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end

-- resolveLine(raw) -> a complete line, or nil when raw cannot be one.
--
-- Sparse entries fall through to LINE_DEFAULT field by field, the same way a
-- hero region resolves. Only scalars are taken off the stored entry: a table
-- or a function in there is a corrupt settings file, not a value.
function Lines.resolveLine(raw)
    if type(raw) ~= "table" then return nil end
    if type(raw.template) ~= "string" then return nil end
    local out = shallowCopy(Lines.LINE_DEFAULT)
    for k, v in pairs(raw) do
        local vt = type(v)
        if vt == "string" or vt == "number" or vt == "boolean" then
            out[k] = v
        end
    end
    if type(out.font_size) ~= "number" or out.font_size < 1 then
        out.font_size = Lines.LINE_DEFAULT.font_size
    end
    if out.alignment ~= "center" and out.alignment ~= "right" then
        out.alignment = "left"
    end
    out.bold      = out.bold == true
    out.uppercase = out.uppercase == true
    if type(out.font_face) ~= "string" or out.font_face == "" then
        out.font_face = nil
    end
    return out
end

-- resolveLines(raw_array) -> array of complete lines. Never nil; may be empty,
-- which is layout()'s signal to fall back.
local function resolveLines(raw)
    local out = {}
    if type(raw) ~= "table" then return out end
    for _i, entry in ipairs(raw) do
        local line = Lines.resolveLine(entry)
        if line then
            out[#out + 1] = line
            if #out >= Lines.MAX_LINES then break end
        end
    end
    return out
end

-- legacyLines() -> show_cover, raw_lines   (nil, nil when nothing is saved)
--
-- The two column models, read as the line model. Pure: nothing is written
-- back, so a read cannot lose a saved set by half-upgrading it.
--
-- Both old keys are consulted, in the order they were introduced. The
-- single-key `list_columns` held one array with "cover" as one of its ids;
-- list_columns_row1 / _row2 split that into two rows and made the cover a
-- boolean. A user may have either.
--
-- Sizes come from the same two numbers the column renderer used, so a migrated
-- two-row set renders at the size it did: the first line at the base, every
-- line below it at the secondary size. That is the whole of what the column
-- model let a second line differ by.
local function legacyLines()
    local row1 = BookshelfSettings.read(Lines.LEGACY_KEYS.row1)
    local row2 = BookshelfSettings.read(Lines.LEGACY_KEYS.row2)
    local show_cover, flat_ids
    if type(row1) ~= "table" then
        local flat = BookshelfSettings.read(Lines.LEGACY_KEYS.flat)
        if type(flat) ~= "table" then return nil, nil end
        show_cover, flat_ids = false, {}
        for _i, id in ipairs(flat) do
            if id == "cover" then show_cover = true
            else flat_ids[#flat_ids + 1] = id end
        end
        row1, row2 = flat_ids, nil
    end
    local sizes = { ListGeom.FONT_SIZE_DP, ListGeom.secondaryFontSize(100) }
    local out = {}
    for _i, ids in ipairs({ row1, row2 }) do
        local template = templateForColumns(ids)
        if template then
            out[#out + 1] = {
                template  = template,
                font_size = sizes[#out + 1] or sizes[2],
                bold      = false,
                uppercase = false,
                alignment = "left",
            }
        end
    end
    if #out == 0 then return show_cover, nil end
    return show_cover, out
end
Lines.legacyLines = legacyLines

-- layout() -> { show_cover = boolean, lines = { line, ... } }
--
-- The ONE read of the saved shape; everything that renders or measures a list
-- row goes through it, so no caller can see un-migrated state. The two keys
-- resolve INDEPENDENTLY, each falling back to the legacy keys and then to the
-- default, so a half-written state still produces a sane list rather than a
-- blank one.
function Lines.layout()
    local legacy_cover, legacy_lines = legacyLines()

    local show = BookshelfSettings.read(Lines.KEYS.show_cover)
    local show_cover
    if type(show) == "boolean" then
        show_cover = show
    elseif legacy_cover ~= nil then
        show_cover = legacy_cover
    else
        show_cover = Lines.DEFAULT_SHOW_COVER
    end

    local saved = BookshelfSettings.read(Lines.KEYS.lines)
    local lines = resolveLines(saved)
    if #lines == 0 and type(saved) ~= "table" then
        lines = resolveLines(legacy_lines)
    end
    if #lines == 0 then lines = resolveLines(Lines.DEFAULTS) end

    return { show_cover = show_cover, lines = lines }
end

-- ── Writing ────────────────────────────────────────────────────────────────
--
-- save{ show_cover = <bool>, lines = {line...} } -- writes only the fields
-- present, then flushes. layout() is the one read; this is the one write, and
-- between them nothing outside this file names a key.
--
-- Why it exists rather than two BookshelfSettings.save calls at the call
-- sites: layout() does more than fetch two keys -- it also migrates the two
-- column models on READ -- and a writer that does not pair with it is how a
-- half-migrated user loses a configuration. Pairing them here means an editor
-- can only write what layout() can read back. A review of the column model
-- caught exactly this gap, with the read side encapsulated and the write side
-- not.
--
-- Two things it is careful about, both of which have a wrong version that
-- compiles and looks fine:
--
--   * `show_cover` is tested with type(), not truthiness. false is a value a
--     user chose, and `if t.show_cover then` would quietly refuse to save
--     "covers off".
--   * the lines are COPIED, one level deep. The store keeps whatever table it
--     is handed, and an editor goes on producing new arrays from the old ones;
--     handing over a live working table leaves the settings file aliasing it.
--
-- It deliberately does NOT normalise: layout() resolves sparse entries and
-- drops malformed ones on the way out, for every reader, including a set this
-- build never wrote. Doing it in both places would be two rules for one
-- invariant.
local function copyLines(lines)
    local out = {}
    for i, line in ipairs(lines) do
        if type(line) == "table" then out[i] = shallowCopy(line) end
    end
    return out
end

function Lines.save(t)
    if type(t) ~= "table" then return end
    if type(t.show_cover) == "boolean" then
        BookshelfSettings.save(Lines.KEYS.show_cover, t.show_cover)
    end
    if type(t.lines) == "table" then
        BookshelfSettings.save(Lines.KEYS.lines, copyLines(t.lines))
    end
    -- The action boundary: every caller here is a user tapping something, and
    -- BookshelfSettings.save is in-memory only.
    BookshelfSettings.flush()
end

-- ── Items that are not books ───────────────────────────────────────────────
--
-- A list row can hold a folder, a series, an author, a genre, a tag or a
-- language as easily as a book, and the token vocabulary is written for books.
-- The column model handled this with a second accessor per column; a template
-- has no second accessor, so the ITEM is projected onto the field names the
-- tokens read instead.
--
-- Where a group's own field means the same thing as a book's, that is the
-- mapping. Where it does not, there is nothing -- a folder has no reading
-- percentage and should not claim one.

-- Group kinds ShelfRow dispatches on (bookshelf_shelf_row.lua:448-627). Series
-- groups are absent from the list: they predate the `kind` field and are
-- detected by their `books` array instead (bookshelf_shelf_row.lua:648).
local GROUP_KINDS = {
    folder   = true,
    opds_nav = true,
    author   = true,
    genre    = true,
    tag      = true,
    language = true,
    series   = true,
}

function Lines.isGroup(item)
    if type(item) ~= "table" then return false end
    if item.kind and GROUP_KINDS[item.kind] then return true end
    return type(item.books) == "table"
end

-- Group shapes disagree about which field holds the display name, so this is
-- the one place that knows the whole list.
local function groupName(g)
    return g.name or g.label or g.series_name or g.title
end

-- groupRecord(g) -> a plain, book-shaped table the token expanders can read.
--
-- Deliberately NOT wrapped by lib/bookshelf_token_record.lua: it carries no
-- filepath, so every resolver in there would answer "no value" after paying
-- for a metatable and a miss per field. A projection is the cheaper and more
-- honest object.
--
-- The mappings are the column catalogue's own group accessors, one for one:
-- page_count sums the members (NOT their count), rating is the group average,
-- and the two dates are the group's latest.
function Lines.groupRecord(g)
    local name = groupName(g)
    local rec = {
        title       = name,
        page_count  = g.total_pages,
        rating      = g.avg_rating,
        last_opened = g.latest,
        date_added  = g.latest_added,
    }
    -- On an Authors chip the group IS the author, so its name is the honest
    -- value; on any other kind there is no single author. Same for the two
    -- other kinds whose name is a book field.
    if g.kind == "author" then
        rec.author  = name
        rec.authors = { name }
    end
    if g.kind == "series" or g.books then rec.series = name end
    if g.kind == "language" then rec.lang = name end
    return rec
end

-- recordFor(item) -> the table a template is expanded against.
--
-- One call, so the renderer does not have to know which kind of thing it is
-- drawing. A book gets the lazy adapter (rich fields resolved on demand, and
-- not at all for a template that names none); a group gets the projection.
function Lines.recordFor(item)
    if type(item) ~= "table" then return item end
    if Lines.isGroup(item) then return Lines.groupRecord(item) end
    return require("lib/bookshelf_token_record").wrap(item)
end

return Lines
