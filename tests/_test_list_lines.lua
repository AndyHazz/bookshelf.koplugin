-- tests/_test_list_lines.lua
-- The list row's LINE MODEL: the saved shape, the defaults, the array surgery
-- the line editor's menu drives, and the acceptance test the whole change
-- exists for.
--
-- Usage (from plugin root): lua tests/_test_list_lines.lua
--
-- What this replaces: tests/_test_list_columns.lua, which pinned the column
-- catalogue's sixteen accessors. Those accessors are gone -- a line is a token
-- template now -- but two of the regressions they caught are NOT about columns
-- and had to survive the move, so they are asserted here through the tokens
-- instead: an OPDS catalogue row must show no percentage and no file size.

package.path = "./?.lua;./?/init.lua;" .. package.path

package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }
package.loaded["lib/bookshelf_localdate"] = { localize = function(s) return s end }

-- The settings store, in memory. Lines.layout()/save() are the only two things
-- that touch it, which is the property being tested.
local STORE = {}
local flushes = 0
package.loaded["lib/bookshelf_settings_store"] = {
    read   = function(k, default)
        local v = STORE[k]
        if v == nil then return default end
        return v
    end,
    save   = function(k, v) STORE[k] = v end,
    delete = function(k) STORE[k] = nil end,
    isTrue = function(k) return STORE[k] == true end,
    flush  = function() flushes = flushes + 1 end,
}

-- The repository, stubbed and counted: the acceptance test has to run against
-- a record the SHELF renders, which means the page count and the percentage
-- come off a sidecar, through lib/bookshelf_token_record.lua.
local SIDECAR, FILESIZE = {}, {}
local calls = { progress = 0, size = 0 }
package.loaded["lib/bookshelf_book_repository"] = {
    progressFor = function(fp)
        calls.progress = calls.progress + 1
        local s = SIDECAR[fp]
        if not s then return nil, nil, nil, nil, false end
        return s.pct, s.status, s.rating, s.pages, true
    end,
    fileSizeFor = function(fp)
        calls.size = calls.size + 1
        return FILESIZE[fp]
    end,
}
package.loaded["libs/libkoreader-lfs"] = { attributes = function() return nil end }
package.loaded["readhistory"] = { hist = {} }
_G.G_reader_settings = setmetatable({}, {
    __index = function() return function() return false end end,
})

local helpers = dofile("tests/_helpers.lua")
local t       = helpers.runner()
local eq      = helpers.eq

local Lines       = require("lib/bookshelf_list_lines")
local Tokens      = require("lib/bookshelf_tokens")
local TokenRecord = require("lib/bookshelf_token_record")
local ListGeom    = require("lib/bookshelf_list_geom")

local function reset()
    for k in pairs(STORE) do STORE[k] = nil end
    for k in pairs(SIDECAR) do SIDECAR[k] = nil end
    for k in pairs(FILESIZE) do FILESIZE[k] = nil end
    calls.progress, calls.size, flushes = 0, 0, 0
    TokenRecord.forgetReadHistory()
end

local function templates(layout)
    local out = {}
    for i, line in ipairs(layout.lines) do out[i] = line.template end
    return out
end

-- ═══════════════════════════════════════════════════════════════════════════
-- THE ACCEPTANCE TEST
-- ═══════════════════════════════════════════════════════════════════════════
--
--   "koreader's standard list mode shows e.g. '9% of 164 pages' - as long as
--    we can replicate that I think we're all good"
--
-- This is the single assertion that says the migration achieved its purpose:
-- literal text interleaved with two fields, which is precisely what a column
-- model could not express. It goes end to end -- a record shaped like the ones
-- the shelf really renders, wrapped by the adapter, through the real
-- Tokens.expand -- because every part of that chain is somewhere the string
-- could have come apart.

t.test("ACCEPTANCE: '%book_pct of %page_count pages' on a real shelf record",
function()
    reset()
    local fp = "/books/salem.epub"
    -- 0.09 and 164 are the maintainer's own example. The record carries
    -- NEITHER: buildBookMeta is BookInfoManager-only, and BIM computes no page
    -- count for a reflowed EPUB. Both come off the sidecar.
    SIDECAR[fp] = { pct = 0.09, status = "reading", rating = nil, pages = 164 }
    local record = helpers.shelf_record(fp)
    assert(record.book_pct == nil and record.page_count == nil,
        "the fixture is carrying the answer; see helpers.shelf_record")

    local got = Tokens.expand("%book_pct of %page_count pages",
                              TokenRecord.wrap(record), nil)
    assert(got == "9% of 164 pages",
        string.format("expected %q, got %q", "9% of 164 pages", got))

    -- And it cost ONE sidecar read for the two fields, not one each.
    assert(calls.progress == 1,
        "expected 1 progressFor call for the two fields, got " .. calls.progress)
end)

t.test("ACCEPTANCE: the same line through Lines.recordFor, as the row builds it",
function()
    reset()
    local fp = "/books/salem.epub"
    SIDECAR[fp] = { pct = 0.09, status = "reading", pages = 164 }
    local got = Tokens.expand("%book_pct of %page_count pages",
                              Lines.recordFor(helpers.shelf_record(fp)), nil)
    assert(got == "9% of 164 pages", string.format("got %q", got))
end)

t.test("ACCEPTANCE: unwrapped, the same line is the bug it would have been",
function()
    -- The control. Without the adapter the shelf's own record answers nothing
    -- for either field, so the line reads " of  pages" -- which is what would
    -- have shipped if this had been tested against a fixture carrying the
    -- fields.
    reset()
    local fp = "/books/salem.epub"
    SIDECAR[fp] = { pct = 0.09, status = "reading", pages = 164 }
    local got = Tokens.expand("%book_pct of %page_count pages",
                              helpers.shelf_record(fp), nil)
    assert(got == " of  pages", string.format("got %q", got))
end)

-- ── The unread case, and the shipped default that handles it ───────────────

t.test("the default progress line reads sensibly in all four progress cases",
function()
    -- Line 4 of the Descriptions default carries the guard now. Its %spacer
    -- sits INSIDE the page-count branch -- with no page count there is
    -- nothing to push right, so the two no-count cases are bar-then-text with
    -- no gap and the shape itself is part of what is pinned here.
    reset()
    local line4 = Lines.DEFAULTS[4].template
    local function expanded(rec)
        return Tokens.expand(line4, rec, nil)
    end

    local fp = "/books/salem.epub"
    SIDECAR[fp] = { pct = 0.09, status = "reading", pages = 164 }
    eq(expanded(Lines.recordFor(helpers.shelf_record(fp))),
        "%bar{rel}%spacer9% of 164 pages", "read, with a page count")

    reset()
    SIDECAR[fp] = { pct = nil, status = nil, pages = 164 }
    eq(expanded(Lines.recordFor(helpers.shelf_record(fp))),
        "%bar{rel}%spacer164 pages", "UNREAD: must not read ' of 164 pages'")

    reset()
    SIDECAR[fp] = { pct = 0.09, status = "reading", pages = nil }
    eq(expanded(Lines.recordFor(helpers.shelf_record(fp))),
        "%bar{rel}9%", "read, no page count")

    reset()
    eq(expanded(Lines.recordFor(helpers.shelf_record(fp))),
        "%bar{rel}", "neither: the line is just the bar")
end)

t.test("the default is the Descriptions layout: four lines, ladder-shaped",
function()
    -- The maintainer's own preset, promoted: "restore my old 'Description'
    -- preset as the default/current settings for the list lines". The shape
    -- that matters for the ladder: title first (kept longest), progress bar
    -- LAST (kept second-longest, holds the row's bottom edge), and the blurb
    -- at position 3 so it is the first thing a dense layout gives up.
    reset()
    eq(#Lines.DEFAULTS, 4)
    assert(Lines.DEFAULTS[1].template:find("%%title"), "title leads")
    eq(Lines.DEFAULTS[2].template, "%authors_short")
    eq(Lines.DEFAULTS[3].template, "%description")
    assert(Lines.DEFAULTS[4].template:find("%%bar{rel}"),
        "the bar closes the row")
    -- ONLY the title is bold: a page of bold rows reads as headings, but one
    -- bold line per row is what makes the title scannable -- the preset's
    -- ExtraBold title face, expressed portably.
    assert(Lines.DEFAULTS[1].bold == true)
    for i = 2, 4 do
        assert(Lines.DEFAULTS[i].bold ~= true, "line " .. i .. " must not be bold")
    end
    -- No {xN} (retired) and no device-absolute font path (cannot ship).
    for i, line in ipairs(Lines.DEFAULTS) do
        assert(not line.template:find("{x%%d"), "line " .. i .. " carries {xN}")
        assert(line.font_face == nil, "line " .. i .. " names a font file")
    end
end)

t.test("the default sizes are 16 over 14", function()
    eq(Lines.DEFAULTS[1].font_size, ListGeom.FONT_SIZE_DP)
    eq(Lines.DEFAULTS[1].font_size, 16)
    for i = 2, 4 do eq(Lines.DEFAULTS[i].font_size, 14) end
end)

-- ── layout(): the read side ────────────────────────────────────────────────

t.test("nothing saved: the defaults, and the cover on", function()
    reset()
    local L = Lines.layout()
    assert(L.show_cover == true, "covers default on")
    local want = {}
    for i, line in ipairs(Lines.DEFAULTS) do want[i] = line.template end
    eq(templates(L), want)
end)

t.test("a saved set wins, and sparse entries fill in", function()
    reset()
    STORE[Lines.KEYS.lines] = { { template = "%title" } }
    local L = Lines.layout()
    eq(#L.lines, 1)
    local line = L.lines[1]
    eq(line.template, "%title")
    eq(line.font_size, ListGeom.FONT_SIZE_DP, "an unset size takes the base")
    eq(line.alignment, "left")
    eq(line.bold, false)
    eq(line.uppercase, false)
    assert(line.font_face == nil, "an unset face must stay nil, not \"\"")
end)

t.test("malformed entries are dropped, and an all-malformed set degrades",
function()
    reset()
    STORE[Lines.KEYS.lines] = {
        { template = "%title" },
        "not a line",
        { font_size = 20 },          -- no template
        { template = 42 },           -- template must be a string
        { template = "%author", font_size = "big", alignment = "diagonal",
          font_face = "" },
    }
    local L = Lines.layout()
    eq(templates(L), { "%title", "%author" })
    eq(L.lines[2].font_size, ListGeom.FONT_SIZE_DP, "a junk size falls back")
    eq(L.lines[2].alignment, "left", "a junk alignment falls back")
    assert(L.lines[2].font_face == nil, "an empty face string is no face")

    reset()
    STORE[Lines.KEYS.lines] = { "junk", 7 }
    local want = {}
    for i, line in ipairs(Lines.DEFAULTS) do want[i] = line.template end
    eq(templates(Lines.layout()), want,
       "an all-malformed set must fall back, not render a row with no lines")
end)

t.test("the line count is capped", function()
    reset()
    local many = {}
    for i = 1, Lines.MAX_LINES + 4 do many[i] = { template = "%title" } end
    STORE[Lines.KEYS.lines] = many
    eq(#Lines.layout().lines, Lines.MAX_LINES)
end)

t.test("one line, three lines: the count is whatever is saved", function()
    reset()
    STORE[Lines.KEYS.lines] = { { template = "a" } }
    eq(#Lines.layout().lines, 1)
    STORE[Lines.KEYS.lines] = { { template = "a" }, { template = "b" },
                                { template = "c" } }
    eq(templates(Lines.layout()), { "a", "b", "c" })
end)

t.test("the cover is not a setting: layout answers true, always", function()
    -- The 'Show cover in lists' toggle was removed rather than mended -- it
    -- was reported broken under a chip override. The old key must be IGNORED,
    -- not honoured: a device that saved false while the toggle existed would
    -- otherwise keep a coverless list nothing in the UI can explain or undo.
    reset()
    STORE["list_show_cover"] = false
    assert(Lines.layout().show_cover == true,
        "a leftover saved false must not strip the covers")
    reset()
    assert(Lines.layout().show_cover == true)
end)

-- ── No migration ───────────────────────────────────────────────────────────
--
-- The column keys are not read at all any more. The maintainer's ruling: list
-- mode never shipped, so there is nothing in the field to migrate, and the one
-- device that HAD a column set saw it resurrected as a two-line row nobody
-- had configured -- which read as a bug, because it was one.
--
-- Pinned, because "layout ignores them" is the whole contract and a helpful
-- future reader restoring a fallback would bring the bug back with it.

t.test("the retired column keys are ignored, not migrated", function()
    reset()
    STORE["list_columns_row1"] = { "title" }
    STORE["list_columns_row2"] = { "author_name", "series_name" }
    STORE["list_columns"]      = { "cover", "title" }
    local L = Lines.layout()
    local want = {}
    for i, line in ipairs(Lines.DEFAULTS) do want[i] = line.template end
    eq(templates(L), want, "a column set must not become the lines")
    assert(L.show_cover == true,
        "the legacy 'cover' id must not decide anything")
    -- Ignoring a key is not the same as clearing it: still not rewritten.
    eq(STORE["list_columns_row1"], { "title" })
end)

-- ── The write side ─────────────────────────────────────────────────────────

t.test("save writes through the same keys layout reads, and flushes", function()
    reset()
    Lines.save{ lines = { { template = "%title", font_size = 22, bold = true } } }
    assert(flushes == 1, "save must flush: the store is in-memory only")
    local L = Lines.layout()
    eq(#L.lines, 1)
    eq(L.lines[1].template, "%title")
    eq(L.lines[1].font_size, 22)
    eq(L.lines[1].bold, true)
end)

t.test("save copies the lines rather than aliasing the caller's table",
function()
    reset()
    local working = { { template = "%title" } }
    Lines.save{ lines = working }
    working[1].template = "mutated after the save"
    working[2] = { template = "appended after the save" }
    eq(templates(Lines.layout()), { "%title" },
        "the settings file is aliasing the editor's working table")
end)

t.test("save ignores show_cover: there is nothing to write any more",
function()
    reset()
    Lines.save{ show_cover = false, lines = { { template = "%title" } } }
    assert(STORE["list_show_cover"] == nil,
        "save must not resurrect the removed key")
    assert(STORE[Lines.KEYS.lines] ~= nil, "the lines half must still save")
end)

t.test("save ignores what it was not given", function()
    reset()
    Lines.save{ lines = { { template = "%title" } } }
    Lines.save{ show_cover = false }
    eq(templates(Lines.layout()), { "%title" },
        "writing the cover flag wiped the lines")
    Lines.save("not a table")
    Lines.save{ lines = "not an array" }
    eq(templates(Lines.layout()), { "%title" })
end)

-- ── Items that are not books ───────────────────────────────────────────────

t.test("a group is projected onto the field names the tokens read", function()
    reset()
    local folder = { kind = "folder", name = "Sci-fi", total_pages = 4200,
                     latest = 1755000000, latest_added = 1700000000,
                     avg_rating = 4 }
    local rec = Lines.recordFor(folder)
    eq(Tokens.expand("%title", rec, nil), "Sci-fi")
    eq(Tokens.expand("%page_count", rec, nil), "4200")
    eq(Tokens.expand("%opened", rec, nil), os.date("%Y-%m-%d", 1755000000))
    eq(Tokens.expand("%added", rec, nil), os.date("%Y-%m-%d", 1700000000))
    eq(Tokens.expand("%book_pct", rec, nil), "",
        "a folder has no reading percentage and must not claim one")
    assert(calls.progress == 0 and calls.size == 0,
        "a group must cost no disk at all")
end)

t.test("the group kinds whose name IS a book field say so", function()
    reset()
    eq(Tokens.expand("%author", Lines.recordFor{ kind = "author",
        name = "Dan Simmons" }, nil), "Dan Simmons")
    eq(Tokens.expand("%series", Lines.recordFor{ kind = "series",
        name = "Hyperion Cantos" }, nil), "Hyperion Cantos")
    eq(Tokens.expand("%lang", Lines.recordFor{ kind = "language",
        name = "en" }, nil), "en")
    -- A series group detected the legacy way, by its books array.
    eq(Tokens.expand("%series", Lines.recordFor{ name = "Ilium",
        books = { { filepath = "/a.epub" } } }, nil), "Ilium")
    -- ...and a genre's name is its title and nothing else.
    local genre = Lines.recordFor{ kind = "genre", name = "Horror" }
    eq(Tokens.expand("%title", genre, nil), "Horror")
    eq(Tokens.expand("%author", genre, nil), "")
end)

t.test("isGroup knows the kinds ShelfRow dispatches on", function()
    for _i, kind in ipairs({ "folder", "opds_nav", "author", "genre", "tag",
                             "language", "series" }) do
        assert(Lines.isGroup{ kind = kind }, kind .. " is a group")
    end
    assert(Lines.isGroup{ books = {} }, "the legacy series shape is a group")
    assert(not Lines.isGroup{ filepath = "/a.epub" }, "a book is not a group")
    assert(not Lines.isGroup("a string"))
end)

t.test("a book goes through the lazy adapter, a group does not", function()
    reset()
    local wrapped = Lines.recordFor(helpers.shelf_record("/books/a.epub"))
    assert(require("lib/bookshelf_token_record").isWrapper(wrapped),
        "a book must be wrapped, or its rich fields read empty")
    assert(not require("lib/bookshelf_token_record").isWrapper(
        Lines.recordFor{ kind = "folder", name = "x" }),
        "a group carries no filepath, so a wrapper would only cost a miss "
        .. "per field")
end)

-- ── The two regressions carried over from the column suite ─────────────────

t.test("an OPDS catalogue row shows no percentage and no file size", function()
    -- bookshelf_opds_feed.lua stamps status = "unread", read_status =
    -- "unread" and attr = { size = 0, modification = 0 } on every record it
    -- parses. Under the columns that put "0%" and "0 B" down every row of an
    -- Internet Archive feed on the maintainer's Paperwhite 5.
    reset()
    local rec = Lines.recordFor{
        filepath = "OPDS://server/42", title = "A catalogue book",
        status = "unread", read_status = "unread",
        attr = { mode = "file", size = 0, modification = 0 },
    }
    eq(Tokens.expand("%book_pct", rec, nil), "",
        "a catalogue row has no reading history to report")
    eq(Tokens.expand("%size", rec, nil), "",
        "a catalogue row has no file, so it has no size")
    eq(Tokens.expand("%added", rec, nil), "")
    assert(calls.progress == 0 and calls.size == 0,
        "a page of catalogue rows must cost no stats: progress="
        .. calls.progress .. " size=" .. calls.size)
end)

-- ── The array surgery ──────────────────────────────────────────────────────
--
-- What the List view menu does to the ORDER and LENGTH of the array. The rules
-- live in the model rather than the menu so the menu cannot offer an edit the
-- model will refuse; these pin the refusals, which are the half that is easy to
-- lose in a refactor (the happy paths announce themselves on screen).

t.test("a new line is added at the end, empty rather than pre-filled",
function()
    reset()
    STORE[Lines.KEYS.lines] = { { template = "%title" } }
    eq(Lines.addLine(), 2)
    local L = Lines.layout()
    eq(#L.lines, 2)
    eq(L.lines[1].template, "%title", "the existing line is untouched")
    -- Slots 2-4 have shipped defaults (the Descriptions layout), so added
    -- lines start as those defaults.
    eq(L.lines[2].template, Lines.DEFAULTS[2].template)
    eq(Lines.addLine(), 3)
    eq(Lines.addLine(), 4)
    eq(Lines.layout().lines[4].template, Lines.DEFAULTS[4].template)
    -- Slot 5 has none, and an empty template is the honest starting point: a
    -- new line pre-filled with a field the row already shows reads as a bug.
    eq(Lines.addLine(), 5)
    eq(Lines.layout().lines[5].template, "")
end)

t.test("the line count is capped at MAX_LINES", function()
    reset()
    local full = {}
    for i = 1, Lines.MAX_LINES do full[i] = { template = "line " .. i } end
    STORE[Lines.KEYS.lines] = full
    assert(Lines.addLine() == nil, "a seventh line must be refused")
    eq(#Lines.layout().lines, Lines.MAX_LINES)
end)

t.test("the last line cannot be deleted", function()
    reset()
    STORE[Lines.KEYS.lines] = { { template = "only" } }
    assert(Lines.removeLine(1) == nil, "deleting the last line must be refused")
    eq(templates(Lines.layout()), { "only" },
        "and it must still be there afterwards")
    -- The reason it is refused: with none saved, layout() hands back the
    -- SHIPPED DEFAULTS, so a successful delete would silently give the user two
    -- lines they never asked for. Pinned, because that is a surprising failure
    -- to rediscover.
    STORE[Lines.KEYS.lines] = {}
    eq(#Lines.layout().lines, #Lines.DEFAULTS)
end)

t.test("delete removes the named line, not the last one", function()
    reset()
    STORE[Lines.KEYS.lines] = { { template = "a" }, { template = "b" },
                                { template = "c" } }
    eq(Lines.removeLine(2), 2)
    eq(templates(Lines.layout()), { "a", "c" })
end)

t.test("move swaps with the neighbour, and refuses at both ends", function()
    reset()
    STORE[Lines.KEYS.lines] = { { template = "a" }, { template = "b" } }
    eq(Lines.moveLine(2, -1), 2)
    eq(templates(Lines.layout()), { "b", "a" })
    -- No wrapping: a Move up on line 1 that sent it to the bottom would be a
    -- surprise every single time.
    assert(Lines.moveLine(1, -1) == nil, "move up off the top must be refused")
    assert(Lines.moveLine(2, 1) == nil, "move down off the end must be refused")
    eq(templates(Lines.layout()), { "b", "a" }, "a refused move changes nothing")
end)

t.test("writeLine replaces one line and leaves the rest alone", function()
    reset()
    STORE[Lines.KEYS.lines] = { { template = "a" }, { template = "b" },
                                { template = "c" } }
    eq(Lines.writeLine(2, { template = "B", bold = true, font_size = 30 }), 3)
    local L = Lines.layout()
    eq(templates(L), { "a", "B", "c" })
    assert(L.lines[2].bold == true and L.lines[2].font_size == 30,
        "the whole line, not just its template")
    assert(Lines.writeLine(9, { template = "x" }) == nil,
        "writing a line that does not exist must not append one")
    eq(#Lines.layout().lines, 3)
end)

t.test("every surgery normalises through layout, so a junk entry cannot spread",
function()
    reset()
    -- A malformed entry (no template) is dropped by layout(). The mutators
    -- read the RESOLVED layout, so the write-back is the cleaned array rather
    -- than the junk with one more item on the end.
    STORE[Lines.KEYS.lines] = { { template = "a" }, { font_size = 20 },
                                { template = "c" } }
    Lines.addLine()
    local saved = STORE[Lines.KEYS.lines]
    eq(#saved, 3, "two good lines plus the new one; the junk entry is gone")
    eq(saved[1].template, "a")
    eq(saved[2].template, "c")
end)

t.done()
