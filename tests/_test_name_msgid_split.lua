-- tests/_test_name_msgid_split.lua
-- One msgid, one meaning: "Name" no longer serves three different things.
--
-- THE REPORT (#432), from the Slovak translator reviewing the catalogue
-- against its call sites. `_("Name")` was used for:
--
--   1. the group-order sort label on the Authors shelf, where it means a
--      PERSON's name and sits next to "Surname";
--   2. the same label on the Series / Genres / Tags shelves, where it means
--      a thing's name;
--   3. the "New collection" dialog's input hint, a thing's name.
--
-- English covers all three with one word. Slovak needs two -- meno for a
-- person, nazov for a thing -- and one msgid can only carry one msgstr, so
-- the collection dialog was prompting for a given name. Czech, Polish,
-- Russian, Ukrainian and German split the same way.
--
-- msgctxt is the standard answer, but lib/bookshelf_i18n.lua's parser reads
-- only msgid/msgstr and there is no msgctxt anywhere in the catalogue, so
-- that route means extending the loader first. Distinct source strings are
-- the cheaper fix and are what the reporter suggested.
--
-- Note the split is by WHAT IS BEING NAMED, not per tab: only the Authors
-- shelf has people on its cards, so it is the only one that needs its own
-- string. Six per-tab strings would be six translations each for no
-- additional distinction any of these languages can use.
--
-- Usage (from plugin root): lua tests/_test_name_msgid_split.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local editor_src = io.open("lib/bookshelf_chip_editor.lua"):read("*a")
local coll_src   = io.open("lib/bookshelf_collection_manager.lua"):read("*a")

-- The label table and the resolver, lifted out together: the table is an
-- upvalue of the resolver and neither means anything alone.
local by_kind = editor_src:match("(local GROUP_LEVEL1_NAME_BY_KIND = {.-\n})")
local labels  = editor_src:match("(local GROUP_LEVEL1_LABEL = {.-\n})")
local kinds   = editor_src:match("(local GROUP_KINDS = {.-\n})")
local resolve = editor_src:match("(local function _resolveSortLabel.-\nend)")
assert(by_kind, "the per-kind name table moved or was renamed")
assert(labels and kinds and resolve, "the sort-label resolver moved or was renamed")

-- gettext is identity here: this test is about WHICH string is asked for.
local seen = {}
local env = { require = function(name)
        if name == "lib/bookshelf_sort_engine" then return { KEYS = {} } end
        error("unexpected require: " .. tostring(name))
    end }
env._ = function(s) seen[s] = true; return s end
local chunk = kinds .. "\n" .. by_kind .. "\n" .. labels .. "\n" .. resolve
        .. "\nreturn _resolveSortLabel"
local resolveSortLabel = assert(load(chunk, "labels", "t", env))()

t.test("the Authors shelf names a person, and pairs with Surname", function()
    eq(resolveSortLabel(1, "series_name", "authors"), "Full name",
       "author cards are people, so their name label must be its own string")
    eq(resolveSortLabel(1, "author_surname", "authors"), "Surname",
       "and the option beside it is unchanged")
end)

t.test("every other group shape names a thing, and shares one string", function()
    for _, kind in ipairs({ "series", "genres", "tags", "formats", "languages" }) do
        eq(resolveSortLabel(1, "series_name", kind), "Name",
           kind .. " cards are things, so they keep the plain label")
    end
end)

t.test("the collection dialog no longer asks for a bare Name", function()
    assert(coll_src:find('input_hint  = _("Collection name")', 1, true),
        "the New collection hint must carry its own string")
    assert(not coll_src:find('input_hint  = _("Name")', 1, true),
        "the bare Name hint is still there")
end)

t.test("no source string says just \"Name\" for a person any more", function()
    -- The whole point: whatever "Name" still means in the catalogue, it is
    -- one meaning. Anything new sharing it should fail here and think again.
    local n = 0
    for _, path in ipairs({ "lib/bookshelf_chip_editor.lua",
                            "lib/bookshelf_collection_manager.lua" }) do
        local src = io.open(path):read("*a")
        n = n + select(2, src:gsub('_%("Name"%)', ""))
    end
    eq(n, 1, 'exactly one _("Name") should remain, the thing-name sort label')
end)

t.test("level 2, and non-group shelves, are untouched", function()
    -- The override only ever applied to group order at level 1; a regression
    -- here would relabel per-book sorting.
    eq(resolveSortLabel(2, "series_name", "authors"), "series_name",
       "level 2 falls through to the engine")
    eq(resolveSortLabel(1, "series_name", "library"), "series_name",
       "a non-group shelf falls through to the engine")
end)

t.done()
