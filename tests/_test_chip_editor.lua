-- tests/_test_chip_editor.lua
-- Pure-Lua tests for the chip editor's source/sort configuration tables and
-- the defaults-applier. These are the tables contributors extend when adding a
-- new chip source (e.g. PR #114's "Languages"), so a typo here -- a bad sort
-- key, a missing reverse flag, a group kind with no defaults -- is exactly the
-- kind of regression worth catching cheaply.
--
-- chip_editor is a UI module; it only `require`s its widget deps at load (never
-- calls them), so empty stubs are enough to load it standalone. The config
-- tables + _applySourceDefaults are exposed via Editor._test.

package.path = "./?.lua;./?/init.lua;" .. package.path

for _, m in ipairs({
    "ui/widget/buttondialog", "ui/widget/confirmbox", "ui/uimanager",
    "ui/geometry", "ui/size",
    "lib/bookshelf_tab_model",   -- only used in methods, not at load
}) do
    package.loaded[m] = {}
end
package.loaded["device"] = { screen = {} }
package.loaded["logger"] = {
    dbg = function() end, info = function() end,
    warn = function() end, err = function() end,
}
package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }

local Editor = dofile("lib/bookshelf_chip_editor.lua")
local D = assert(Editor._test, "chip_editor did not expose _test internals")

local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()
local eq = helpers.eq

-- Known sort keys the engine understands; any default referencing something
-- outside this set is almost certainly a typo.
local VALID_SORT_KEYS = {
    filename = true, title = true, author_surname = true, author_name = true,
    series_name = true, series_index = true, series_combined = true,
    last_opened = true, date_added = true, percent_read = true,
    read_status = true, read_status_active = true, rating = true,
    page_count = true, book_count = true, size = true,
}

t.test("every SOURCE_SORT_DEFAULTS entry is a non-empty list of {key,reverse}", function()
    for kind, levels in pairs(D.SOURCE_SORT_DEFAULTS) do
        assert(type(levels) == "table" and #levels > 0,
            kind .. ": defaults must be a non-empty list")
        for i, lv in ipairs(levels) do
            assert(type(lv.key) == "string",
                kind .. "[" .. i .. "]: key must be a string")
            assert(VALID_SORT_KEYS[lv.key],
                kind .. "[" .. i .. "]: unknown sort key '" .. tostring(lv.key) .. "'")
            assert(type(lv.reverse) == "boolean",
                kind .. "[" .. i .. "]: reverse must be a boolean")
        end
    end
end)

t.test("PR #114 language sources have their expected defaults", function()
    -- Languages group: most-populated language first, then within-group order.
    eq(D.SOURCE_SORT_DEFAULTS.languages, {
        { key = "book_count",   reverse = true },
        { key = "series_name",  reverse = false },
        { key = "series_index", reverse = false },
    })
    -- Specific language: a filtered book list.
    eq(D.SOURCE_SORT_DEFAULTS.language, {
        { key = "author_surname", reverse = false },
        { key = "series_name",    reverse = false },
        { key = "series_index",   reverse = false },
    })
end)

t.test("GROUP_KINDS is exactly the expected set", function()
    eq(D.GROUP_KINDS, {
        series = true, authors = true, genres = true,
        tags = true, formats = true, languages = true,
    })
end)

t.test("every group kind has a SOURCE_SORT_DEFAULTS entry", function()
    for kind in pairs(D.GROUP_KINDS) do
        assert(D.SOURCE_SORT_DEFAULTS[kind],
            "group kind '" .. kind .. "' has no sort defaults")
    end
end)

t.test("applySourceDefaults copies the kind's sort priority (deep copy)", function()
    local draft = { source = { kind = "authors" }, label = "Keep me" }
    D.applySourceDefaults(draft)
    eq(draft.sort_priority, D.SOURCE_SORT_DEFAULTS.authors)
    -- Mutating the draft must NOT bleed into the shared defaults table.
    draft.sort_priority[1].reverse = true
    assert(D.SOURCE_SORT_DEFAULTS.authors[1].reverse == false,
        "applySourceDefaults shared the defaults table by reference")
end)

t.test("applySourceDefaults leaves a user-edited label alone", function()
    local draft = { source = { kind = "genres" }, label = "My Genres" }
    D.applySourceDefaults(draft)
    eq(draft.label, "My Genres")
end)

t.test("applySourceDefaults relabels an untouched 'New chip' to the source label", function()
    local draft = { source = { kind = "genres" }, label = "New chip" }
    D.applySourceDefaults(draft)
    -- SOURCE_LABEL.genres() -> _("Genres") -> identity in tests.
    eq(draft.label, "Genres")
end)

t.test("applySourceDefaults uses a specific source id as the label", function()
    local draft = { source = { kind = "author", id = "Ursula K. Le Guin" }, label = "New chip" }
    D.applySourceDefaults(draft)
    eq(draft.label, "Ursula K. Le Guin")
end)

t.test("applySourceDefaults uses the folder basename for folder sources", function()
    local draft = { source = { kind = "folder", id = "/mnt/us/ebooks/Sci-Fi" }, label = "New chip" }
    D.applySourceDefaults(draft)
    eq(draft.label, "Sci-Fi")
end)

t.test("applySourceDefaults is a no-op for an unknown source kind", function()
    local draft = { source = { kind = "totally_unknown" }, label = "New chip" }
    D.applySourceDefaults(draft)
    eq(draft.sort_priority, nil)   -- no defaults applied
end)

t.done()
