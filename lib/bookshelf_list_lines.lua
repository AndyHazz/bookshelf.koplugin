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
-- ── NO MIGRATION ───────────────────────────────────────────────────────────
--
-- There was one, briefly: a read-only translation of list_columns_row1 /
-- _row2 / list_columns into templates. It is gone, on the maintainer's
-- ruling -- "we do not need any migration to be implemented as list mode
-- never released publicly". Every column key that exists anywhere is a
-- development artefact of this branch, and the only thing the migration
-- actually did in practice was resurrect a half-finished column set on the
-- one device that had one, which read as a bug.
--
-- The old keys are simply not consulted. They stay on disk, inert, until
-- something else clears them; nothing here writes to them and nothing here
-- reads them.

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
    lines = "list_lines",
}

-- The cover is NOT a setting any more. A list row always has its cover cell:
-- the 'Show cover in lists' toggle was reported broken under a chip override
-- ("sometimes works but for some reason not when a chip has its list style
-- overridden") and the ruling was to remove it rather than mend it. layout()
-- still answers show_cover = true so no reader of the model needs to know the
-- toggle ever existed. The old list_show_cover key stays on disk, inert.

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
    -- Italic needs a real font FILE (slant cannot be synthesised the way weight
    -- can), so it resolves to an on-disk variant or degrades to upright --
    -- see ListRow.lineFace and BFont.variantOf.
    italic    = false,
    uppercase = false,
    alignment = "left",
}

-- ── The shipped default: the maintainer's "Descriptions" layout ────────────
--
-- Four lines: title with the rating and favourite pushed to the row's right
-- edge, the author small and italic, the blurb filling whatever the row has
-- left, and a closing progress line whose relative-length bar keeps the
-- row's bottom edge.
--
-- This replaced the two-line copy of KOReader's own list mode when the
-- defaults question came due ("the maintainer said they would choose by
-- experiment once the editor existed"): the experiment was the "Descriptions"
-- preset, lived with on the maintainer's own device, and the ruling was to
-- promote it -- "restore my old 'Description' preset as the default/current
-- settings for the list lines". Two edits on the way in: the {xN} modifiers
-- came off (retired -- lines take what the row can give), and the preset's
-- title font was a device-absolute file path, which cannot ship; the title
-- falls back to the row's own face made bold instead.
--
-- Line 4's guarded half is still the old acceptance test, unchanged:
-- unguarded, "%book_pct of %page_count pages" on an unread book expands to
-- " of 164 pages", which is not a sentence.
--
-- Rows lose lines from the BOTTOM UP as they shrink, so a dense layout
-- collapses toward title / author / blurb, then title / author, then title
-- alone -- which is why one default can serve every row count.
Lines.DEFAULTS = {
    {
        template  = "%title %spacer %rating %favourite",
        font_size = ListGeom.FONT_SIZE_DP,
        bold      = true,
        uppercase = false,
        alignment = "left",
    },
    {
        template  = "%authors_short",
        font_size = 14,
        bold      = false,
        italic    = true,
        uppercase = false,
        alignment = "left",
    },
    {
        template  = "%description",
        font_size = 14,
        bold      = false,
        uppercase = false,
        alignment = "left",
    },
    {
        template  = "%bar{rel}[if:page_count]%spacer[if:book_pct]"
                 .. "%book_pct of [/if]%page_count pages[else]%book_pct[/if]",
        font_size  = 14,
        bold       = false,
        uppercase  = false,
        alignment  = "right",
        bar_height = 50,
        bar_style  = "solid",
    },
}

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
    out.italic    = out.italic == true
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

-- layout() -> { show_cover = boolean, lines = { line, ... } }
--
-- The ONE read of the saved shape; everything that renders or measures a list
-- row goes through it. The two keys resolve INDEPENDENTLY, each falling back to
-- its own default, so a half-written state still produces a sane list rather
-- than a blank one.
-- layout(source) -> { show_cover, lines }
--
-- `source` overrides where the raw values come from -- a saved preset a chip
-- is pinned to, rather than the settings. Only the SOURCE moves: a preset's
-- lines get exactly the same resolution and defaulting as stored ones, which
-- is what lets a preset written by an older build gain whatever has been added
-- to a line since without the reader noticing.
function Lines.layout(source)
    local raw = source and source.lines
    if raw == nil then raw = BookshelfSettings.read(Lines.KEYS.lines) end
    local lines = resolveLines(raw)
    if #lines == 0 then lines = resolveLines(Lines.DEFAULTS) end

    return { show_cover = true, lines = lines }
end

-- ── Writing ────────────────────────────────────────────────────────────────
--
-- save{ show_cover = <bool>, lines = {line...} } -- writes only the fields
-- present, then flushes. layout() is the one read; this is the one write, and
-- between them nothing outside this file names a key.
--
-- Why it exists rather than two BookshelfSettings.save calls at the call
-- sites: pairing the one write with the one read means an editor can only
-- write what layout() can read back, and no caller outside this file ever
-- spells a settings key. A review of the column model caught exactly that gap,
-- with the read side encapsulated and the write side not.
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
    if type(t.lines) == "table" then
        BookshelfSettings.save(Lines.KEYS.lines, copyLines(t.lines))
    end
    -- The action boundary: every caller here is a user tapping something, and
    -- BookshelfSettings.save is in-memory only.
    BookshelfSettings.flush()
end

-- ── Editing the array ──────────────────────────────────────────────────────
--
-- The four things the line editor's menu does to the ORDER and LENGTH of the
-- array, as opposed to the contents of one line. Here rather than in the menu
-- because each one has a rule the menu would have to know:
--
--   * the cap is MAX_LINES, and it is this file's number;
--   * the floor is one line, because a row with none cannot be tapped to get
--     a line back -- deleting the last one would be a one-way trip out of the
--     UI (layout() would then hand back DEFAULTS, so the user would see two
--     lines they did not ask for, which is worse than refusing);
--   * every mutation reads the RESOLVED layout first, so a set that was
--     sparse or partly malformed is normalised by the same rules the renderer
--     uses, rather than written back as found.
--
-- Each returns the new line count, or nil when the edit was refused.

-- What a brand-new line starts as: the shipped default for that slot if there
-- is one, otherwise an empty template at the secondary size. Empty rather than
-- "%title" -- a new line pre-filled with a field the row already shows reads
-- as a bug, and an empty one is unambiguous.
function Lines.newLine(index)
    local d = Lines.DEFAULTS[index]
    if d then return shallowCopy(d) end
    local line = shallowCopy(Lines.LINE_DEFAULT)
    line.template  = ""
    line.font_size = ListGeom.secondaryFontSize(100)
    return line
end

function Lines.addLine()
    local lines = Lines.layout().lines
    if #lines >= Lines.MAX_LINES then return nil end
    lines[#lines + 1] = Lines.newLine(#lines + 1)
    Lines.save{ lines = lines }
    return #lines
end

function Lines.removeLine(index)
    local lines = Lines.layout().lines
    if #lines <= 1 then return nil end
    if not lines[index] then return nil end
    table.remove(lines, index)
    Lines.save{ lines = lines }
    return #lines
end

-- delta is -1 (up) or +1 (down). Refuses at either end rather than wrapping:
-- a Move up on line 1 that silently sent it to the bottom would be a surprise
-- every time it happened.
function Lines.moveLine(index, delta)
    local lines = Lines.layout().lines
    local target = index + delta
    if not lines[index] or not lines[target] then return nil end
    lines[index], lines[target] = lines[target], lines[index]
    Lines.save{ lines = lines }
    return #lines
end

-- writeLine(index, line) -- replace one line's contents, leaving the rest of
-- the array alone. The editor's Save.
function Lines.writeLine(index, line)
    local lines = Lines.layout().lines
    if not lines[index] then return nil end
    lines[index] = line
    Lines.save{ lines = lines }
    return #lines
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
