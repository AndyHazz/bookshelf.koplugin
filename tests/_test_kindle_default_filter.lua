-- tests/_test_kindle_default_filter.lua
-- A new Kindle chip starts with the formats KOReader cannot open filtered out.
--
-- The subtlety worth pinning is that openability is a per-BOOK property, not a
-- per-format one: bookshelf_kindle_source weighs DRM and the file's own magic
-- bytes as well as the extension, so two .azw books can differ. The Format
-- dimension is an include list of formats and cannot express "the unlocked
-- ones", so the rule is "a format earns its place if ANY book in it opens" --
-- and these pin both what that gets right and where it stops.
--
-- Driven against the real function body, extracted by name, as
-- _test_disk_available does.
package.path = "./?.lua;./?/init.lua;" .. package.path

local t   = dofile("tests/_helpers.lua").runner()
local src = io.open("lib/bookshelf_chip_editor.lua"):read("*a")

local body = src:match("\nlocal function _kindleOpenableFormats%(%)\n(.-)\nend\n")
assert(body, "could not find _kindleOpenableFormats - renamed?")

local function compile(code, env, name)
    if _G.setfenv then
        local f = assert(_G.loadstring(code, name))
        _G.setfenv(f, env)
        return f
    end
    return assert(load(code, name, "t", env))
end

-- books: the catalogue listing; nil source / raising listBooks are opt-in.
local function run(books, opts)
    opts = opts or {}
    local env = {
        pcall = pcall, type = type, ipairs = ipairs,
        require = function(name)
            assert(name == "lib/bookshelf_kindle_source",
                "unexpected require: " .. tostring(name))
            if opts.no_source then error("absent") end
            return {
                listBooks = opts.list_raises
                    and function() error("boom") end
                    or function() return books end,
            }
        end,
    }
    return compile("return (function()\n" .. body .. "\nend)()", env,
        "_kindleOpenableFormats")()
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
    -- The honest edge: a DRM-locked .azw sits alongside a DRM-free one, and
    -- keeping the format keeps them both. Asserting the opposite would pin
    -- behaviour the Format dimension cannot actually deliver.
    local f = run{ book("KFX"), book("AZW"), book("AZW", true), book("AZW3", true) }
    assert(f.AZW, "a format with an openable book must stay")
    assert(f.AZW3 == nil, "and one without must not")
end)

t.test("no filter at all when nothing is blocked", function()
    -- Pinning the chip to the formats owned today would hide one bought later,
    -- which is a worse default than no filter.
    local f = run{ book("KFX"), book("EPUB") }
    assert(f == nil, "expected no filter when there is nothing to exclude")
end)

t.test("no filter when every book is blocked", function()
    -- An include list of nothing would show an empty shelf and read as a bug.
    local f = run{ book("AZW3", true), book("AZW", true) }
    assert(f == nil, "an empty include list must not be set")
end)

t.test("survives a catalogue that is absent, empty, or raising", function()
    assert(run({}, { no_source = true }) == nil, "no Kindle source")
    assert(run({}, { list_raises = true }) == nil, "listBooks raised")
    assert(run({}) == nil, "empty catalogue")
    assert(run({ book(nil), book("") }) == nil, "records with no usable format")
end)

-- ─── Wiring ────────────────────────────────────────────────────────────────
-- The body above is only half of it: applied to the wrong chip, or over a
-- filter the user already set, it would be a bug rather than a default.
local applied = src:match("\nlocal function _applySourceDefaults%(draft%)\n(.-)\nend\n")
assert(applied, "could not find _applySourceDefaults - renamed?")

t.test("only a Kindle chip gets it, and only an unfiltered one", function()
    assert(applied:match('kind == "kindle"'),
        "the default must be scoped to the Kindle source")
    assert(applied:match("not Filter%.isActive%(draft%.filter%)"),
        "re-picking the source must not discard a filter the user set")
    assert(applied:match("_kindleOpenableFormats%(%)"),
        "_applySourceDefaults must actually ask for the formats")
end)

t.done()
