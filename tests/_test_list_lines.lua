-- tests/_test_list_lines.lua
-- The list row's LINE MODEL: the saved shape, the migration off the two column
-- keys, the defaults, and the acceptance test the whole change exists for.
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

t.test("the default second line reads sensibly in all four progress cases",
function()
    reset()
    local line2 = Lines.DEFAULTS[2].template
    -- Only the progress half is under test here, so the author half is given
    -- something to say and then stripped off at the %spacer.
    local function progressHalf(rec)
        local full = Tokens.expand(line2, rec, nil)
        local _before, after = full:match("^(.-)%%spacer(.*)$")
        assert(after, "the default line lost its %spacer: " .. full)
        return after
    end

    local fp = "/books/salem.epub"
    SIDECAR[fp] = { pct = 0.09, status = "reading", pages = 164 }
    eq(progressHalf(Lines.recordFor(helpers.shelf_record(fp))),
        "9% of 164 pages", "read, with a page count")

    reset()
    SIDECAR[fp] = { pct = nil, status = nil, pages = 164 }
    eq(progressHalf(Lines.recordFor(helpers.shelf_record(fp))),
        "164 pages", "UNREAD: must not read ' of 164 pages'")

    reset()
    SIDECAR[fp] = { pct = 0.09, status = "reading", pages = nil }
    eq(progressHalf(Lines.recordFor(helpers.shelf_record(fp))),
        "9%", "read, no page count")

    reset()
    eq(progressHalf(Lines.recordFor(helpers.shelf_record(fp))),
        "", "neither: the line is just the author")
end)

t.test("the default first line is the title, and both lines are unbold",
function()
    reset()
    eq(Lines.DEFAULTS[1].template, "%title")
    for i, line in ipairs(Lines.DEFAULTS) do
        assert(line.bold ~= true, "default line " .. i
            .. " is bold; 26 bold rows read as a page of headings")
    end
end)

t.test("the default sizes are the two the column model rendered at", function()
    eq(Lines.DEFAULTS[1].font_size, ListGeom.FONT_SIZE_DP)
    eq(Lines.DEFAULTS[2].font_size, ListGeom.secondaryFontSize(100))
    -- Stated in numbers so a change to SECONDARY_PCT has to be deliberate.
    eq(Lines.DEFAULTS[1].font_size, 16)
    eq(Lines.DEFAULTS[2].font_size, 14)
end)

-- ── layout(): the read side ────────────────────────────────────────────────

t.test("nothing saved: the defaults, and the cover on", function()
    reset()
    local L = Lines.layout()
    assert(L.show_cover == true, "covers default on")
    eq(templates(L), { Lines.DEFAULTS[1].template, Lines.DEFAULTS[2].template })
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
    eq(templates(Lines.layout()),
       { Lines.DEFAULTS[1].template, Lines.DEFAULTS[2].template },
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

t.test("show_cover is independent of the lines", function()
    reset()
    STORE[Lines.KEYS.show_cover] = false
    local L = Lines.layout()
    assert(L.show_cover == false, "a saved false must not read as the default")
    assert(#L.lines >= 1, "half a saved state still renders")
end)

-- ── The migration ──────────────────────────────────────────────────────────

t.test("every column id becomes a template fragment, or is knowingly dropped",
function()
    -- The catalogue as it stood, so a mapping that quietly disappears fails
    -- here rather than on a user's device.
    local ids = { "title", "author_name", "series_name", "percent_read",
                  "page_count", "book_count", "read_status", "rating",
                  "last_opened", "date_added", "size", "language", "format",
                  "filename" }
    local dropped = { book_count = true }
    for _i, id in ipairs(ids) do
        local frag = Lines.TOKEN_FOR_COLUMN[id]
        if dropped[id] then
            assert(frag == nil, id .. " now has a token -- map it")
        else
            assert(type(frag) == "string" and frag:find("%%"),
                id .. " has no template fragment")
        end
    end
end)

t.test("every fragment names only tokens that exist", function()
    for id, frag in pairs(Lines.TOKEN_FOR_COLUMN) do
        for name in frag:gmatch("%%([%a_]+)") do
            assert(Tokens.expanders[name] ~= nil or name == "spacer",
                string.format("%s maps to %%%s, which has no expander", id, name))
        end
    end
end)

t.test("the default column set migrates to one line, right-anchored", function()
    reset()
    -- Columns.DEFAULT_IDS as it stood.
    STORE["list_columns_row1"] = { "title", "author_name", "percent_read" }
    local L = Lines.layout()
    eq(#L.lines, 1, "one saved row is one line")
    eq(L.lines[1].template,
       "%title  [if:authors]%authors[else]%author[/if]%spacer%book_pct")
    eq(L.lines[1].font_size, ListGeom.FONT_SIZE_DP)
end)

t.test("two saved rows become two lines, the second at the secondary size",
function()
    reset()
    STORE["list_columns_row1"] = { "title" }
    STORE["list_columns_row2"] = { "author_name", "page_count" }
    local L = Lines.layout()
    eq(#L.lines, 2)
    eq(L.lines[1].template, "%title")
    eq(L.lines[2].template,
       "[if:authors]%authors[else]%author[/if]%spacer%page_count")
    eq(L.lines[1].font_size, 16)
    eq(L.lines[2].font_size, 14)
end)

t.test("a TRAILING RUN of right-aligned columns takes one spacer, not several",
function()
    reset()
    STORE["list_columns_row1"] = { "title", "percent_read", "page_count" }
    local tpl = Lines.layout().lines[1].template
    eq(tpl, "%title%spacer%book_pct  %page_count")
    local n = select(2, tpl:gsub("%%spacer", ""))
    eq(n, 1, "the renderer honours the FIRST spacer only; a second is literal")
end)

t.test("a right-aligned column with nothing to its left gets no spacer",
function()
    reset()
    STORE["list_columns_row1"] = { "percent_read", "title" }
    eq(Lines.layout().lines[1].template, "%book_pct  %title")
    reset()
    STORE["list_columns_row1"] = { "percent_read" }
    eq(Lines.layout().lines[1].template, "%book_pct")
end)

t.test("unknown ids are dropped; a row that loses everything is not a line",
function()
    reset()
    STORE["list_columns_row1"] = { "title", "a_column_from_the_future" }
    STORE["list_columns_row2"] = { "book_count" }   -- the one with no token
    local L = Lines.layout()
    eq(#L.lines, 1, "row 2 had only untranslatable ids, so there is no line 2")
    eq(L.lines[1].template, "%title")
end)

t.test("both column rows empty falls all the way back to the defaults",
function()
    reset()
    STORE["list_columns_row1"] = {}
    STORE["list_columns_row2"] = {}
    eq(templates(Lines.layout()),
       { Lines.DEFAULTS[1].template, Lines.DEFAULTS[2].template })
end)

t.test("the older single key migrates too, cover id and all", function()
    reset()
    STORE["list_columns"] = { "cover", "title", "percent_read" }
    local L = Lines.layout()
    assert(L.show_cover == true, "the 'cover' id must become the boolean")
    eq(#L.lines, 1)
    eq(L.lines[1].template, "%title%spacer%book_pct")

    reset()
    STORE["list_columns"] = { "title" }
    assert(Lines.layout().show_cover == false,
        "no 'cover' id in the legacy set means covers off")
end)

t.test("list_lines wins over the column keys, and nothing is rewritten",
function()
    reset()
    STORE["list_columns_row1"] = { "title", "percent_read" }
    STORE[Lines.KEYS.lines] = { { template = "mine" } }
    eq(templates(Lines.layout()), { "mine" })
    -- The old keys are LEFT ALONE: a read must not half-upgrade a saved set,
    -- so a rollback still finds what it wrote.
    eq(STORE["list_columns_row1"], { "title", "percent_read" })
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

t.test("saving covers OFF is a value, not a falsy no-op", function()
    reset()
    Lines.save{ show_cover = false }
    assert(STORE[Lines.KEYS.show_cover] == false,
        "a truthiness test here refuses to save 'covers off'")
    assert(Lines.layout().show_cover == false)
    Lines.save{ show_cover = true }
    assert(Lines.layout().show_cover == true)
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

t.done()
