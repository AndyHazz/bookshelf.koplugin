-- tests/_test_kindle_default_filter.lua
-- A new Kindle shelf starts with the formats KOReader cannot open filtered out.
--
-- The subtlety worth pinning is that openability is a per-BOOK property, not a
-- per-format one: bookshelf_kindle_source weighs DRM and the file's own magic
-- bytes as well as the extension, so two .azw books can differ. The Format
-- dimension is an include list of formats and cannot express "the unlocked
-- ones", so the rule is "a format earns its place if ANY book in it opens" --
-- and these pin both what that gets right and where it stops.
--
-- Driven through the Kindle source's new_shelf hook (lib/bookshelf_builtin_sources),
-- the way the shelf editor calls it: through the registry, pcall'd.
package.path = "./?.lua;./?/init.lua;" .. package.path
package.loaded["logger"] = { dbg = function() end, info = function() end,
                              warn = function() end, err = function() end }

local t = dofile("tests/_helpers.lua").runner()
package.loaded["lib/bookshelf_sources"] = nil
local Sources = require("lib/bookshelf_sources")

-- books: the catalogue listing; no_source / list_raises are opt-in failures.
local function run(books, opts, draft)
    opts = opts or {}
    if opts.no_source then
        package.loaded["lib/bookshelf_kindle_source"] = nil
        package.preload["lib/bookshelf_kindle_source"] = function() error("absent") end
    else
        package.preload["lib/bookshelf_kindle_source"] = nil
        package.loaded["lib/bookshelf_kindle_source"] = {
            listBooks = opts.list_raises and function() error("boom") end
                        or function() return books end,
        }
    end
    draft = draft or {}
    Sources.call(Sources.get("kindle"), "new_shelf", draft)
    package.loaded["lib/bookshelf_kindle_source"] = nil
    package.preload["lib/bookshelf_kindle_source"] = nil
    return draft.filter and draft.filter.formats or nil, draft
end

local function book(fmt, blocked)
    return { format = fmt, kindle_blocked = blocked or nil }
end

t.test("a format whose books are all blocked is left out", function()
    local f = run{
        book("KFX"), book("KFX"), book("EPUB"),
        book("AZW3", true),                       -- no provider, never opens
    }
    assert(f, "expected a filter")
    assert(f.KFX and f.EPUB, "openable formats must be offered")
    assert(f.AZW3 == nil, "a format that can only refuse must not be included")
end)

t.test("a format with even one openable book stays -- the documented limit", function()
    local f = run{ book("KFX"), book("AZW"), book("AZW", true), book("AZW3", true) }
    assert(f.AZW, "a format with an openable book must stay")
    assert(f.AZW3 == nil, "and one without must not")
end)

t.test("no filter at all when nothing is blocked", function()
    -- Pinning the shelf to the formats owned today would hide one bought later.
    assert(run{ book("KFX"), book("EPUB") } == nil, "expected no filter")
end)

t.test("no filter when every book is blocked", function()
    -- An include list of nothing would show an empty shelf and read as a bug.
    assert(run{ book("AZW3", true), book("AZW", true) } == nil, "an empty include list must not be set")
end)

t.test("survives a catalogue that is absent, empty, or raising", function()
    assert(run({}, { no_source = true }) == nil, "no Kindle source")
    assert(run({}, { list_raises = true }) == nil, "listBooks raised")
    assert(run({}) == nil, "empty catalogue")
    assert(run({ book(nil), book("") }) == nil, "records with no usable format")
end)

t.test("a filter the reader set is never replaced", function()
    local mine = { ratings = { ["5"] = true } }
    local _f, draft = run({ book("KFX"), book("AZW3", true) }, nil, { filter = mine })
    assert(draft.filter == mine and draft.filter.formats == nil,
        "re-picking the source must not discard a filter the user set")
end)

-- ─── Wiring ────────────────────────────────────────────────────────────────
local src = io.open("lib/bookshelf_chip_editor.lua"):read("*a")
local applied = src:match("\nlocal function _applySourceDefaults%(draft%)\n(.-)\nend\n")
assert(applied, "could not find _applySourceDefaults - renamed?")

t.test("the shelf editor asks the source for its new-shelf defaults", function()
    assert(applied:match('Sources%.call%(src_spec, "new_shelf", draft%)'),
        "_applySourceDefaults must hand a new shelf to its source's new_shelf")
end)

t.done()
