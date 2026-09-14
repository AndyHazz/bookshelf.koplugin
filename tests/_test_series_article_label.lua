-- tests/_test_series_article_label.lua
-- A calibre-style trailing article reads the right way round on a series card.
--
-- Folders have done this since issue 341: a directory named "Locked Tomb, The"
-- displays as "The Locked Tomb" while the SORT still keys off the raw on-disk
-- name -- which is the whole point of that naming convention, since it puts the
-- book under L rather than T. Series names had no such treatment, so a series
-- recorded as "Dark Tower, The" was shown verbatim.
--
-- The display/sort split is the load-bearing part. Flipping series_name in
-- place would move the series from L back to T and destroy exactly the
-- ordering the convention buys, so the flipped form goes in a separate `label`
-- field -- the same shape folders use, where `label` is display and `name`
-- stays raw.
--
-- Usage (from plugin root): lua tests/_test_series_article_label.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

local H = dofile("tests/_helpers.lua")
local t = H.runner()
local eq = H.eq

local src = assert(io.open("lib/bookshelf_book_repository.lua")):read("*a")

-- The flip itself, extracted so the rules can be exercised directly.
local block = src:match("\n(local function _flipTrailingArticle%(name%).-\nend)\n")
assert(block, "the article-flip helper moved or was renamed")
local env = { type = type }
local f
if _G.setfenv then
    f = assert(_G.loadstring(block .. "\nEXPORT = _flipTrailingArticle", "flip"))
    _G.setfenv(f, env)
else
    f = assert(load(block .. "\nEXPORT = _flipTrailingArticle", "flip", "t", env))
end
f()
local flip = assert(env.EXPORT, "the helper block exported nothing")

t.test("the three English articles flip to the front", function()
    eq(flip("Locked Tomb, The"), "The Locked Tomb")
    eq(flip("Wrinkle in Time, A"), "A Wrinkle in Time")
    eq(flip("Wrinkle in Time, An"), "An Wrinkle in Time")
end)

t.test("anything else is left exactly as it is", function()
    -- Lowercase and initials are deliberately untouched: "Smith, A." is an
    -- author, not a title, and the capitalised form is what calibre writes.
    eq(flip("The Dark Tower"), "The Dark Tower")
    eq(flip("Smith, A."), "Smith, A.")
    eq(flip("Locked Tomb, the"), "Locked Tomb, the")
    eq(flip("Goodbye, Columbus"), "Goodbye, Columbus")
    eq(flip(""), "")
end)

t.test("a non-string is returned untouched rather than erroring", function()
    eq(flip(nil), nil)
end)

-- ── the display / sort split ───────────────────────────────────────────────

t.test("a series card carries the flipped name in `label`", function()
    local rec = src:match("return {%s*series_name%s*=%s*shape%.series_name.-}")
    assert(rec, "the series group record moved")
    assert(rec:find("label", 1, true),
        "the series record has no display label, so the card shows the raw "
        .. "\"Dark Tower, The\": " .. rec)
    assert(rec:match("label%s*=%s*_flipTrailingArticle"),
        "the label is not the flipped form: " .. rec)
end)

t.test("series_name itself stays RAW, so sorting is unchanged", function()
    -- The point of the convention. Flipping in place would put the series back
    -- under T and lose the article-insensitive ordering.
    local rec = src:match("return {%s*series_name%s*=%s*shape%.series_name.-}")
    assert(rec:match("series_name%s*=%s*shape%.series_name"),
        "series_name is no longer the raw value: " .. rec)
end)

-- ── every renderer has to agree ────────────────────────────────────────────

t.test("the renderers prefer the label over the raw name", function()
    -- They disagreed before this: list_lines and one spine_shelf site already
    -- read `label` first, while series_stack, shelf_row and the other
    -- spine_shelf site went straight to series_name -- so the same series
    -- would read one way on a list row and another on a stack tile.
    local sites = {
        { "lib/bookshelf_series_stack.lua", "stack_name" },
        { "lib/bookshelf_shelf_row.lua",    "sname" },
    }
    for _i, site in ipairs(sites) do
        local body = assert(io.open(site[1])):read("*a")
        -- A window, not one line: these assignments wrap once the fallback
        -- chain is added, and a single-line match would miss the label.
        local at = body:find("local " .. site[2], 1, true)
        assert(at, site[1] .. ": the " .. site[2] .. " assignment moved")
        local line = body:sub(at, at + 160)
        assert(line:find("label", 1, true),
            site[1] .. " ignores the display label: " .. line)
    end
end)

t.done()
