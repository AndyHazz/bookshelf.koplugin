-- %<token> delimited wrapping (bookends #92, ported for #348 parity).
--
-- Bookshelf's expander loop matches literal token names longest-first with NO
-- word boundary, so text written immediately after a token can be absorbed into
-- a longer name: "%author" followed by a literal "s" reads as "%authors" and
-- prints every author. Angle brackets mark where the name ends. Bookends has
-- had this since its #92; bookshelf rendered "%<title>" as literal text, so a
-- template copied across broke visibly.
-- Usage: cd into the plugin dir, then `lua tests/_test_token_wrapping.lua`.

package.loaded["device"] = {
    getPowerDevice = function() return nil end,
    isKindle = function() return false end,
    hasNaturalLight = function() return false end,
    home_dir = "/",
}
package.loaded["datetime"] = { secondsToClockDuration = function() return "" end }
local _i18n = {
    gettext = function(s) return s end,
    ngettext = function(s, p, n) return n == 1 and s or p end,
}
package.loaded["bookshelf_i18n"] = _i18n
package.loaded["lib/bookshelf_i18n"] = _i18n
_G.G_reader_settings = setmetatable({}, {
    __index = function() return function() return false end end,
})

local t = dofile("tests/_helpers.lua").runner()
local Tokens = dofile("lib/bookshelf_tokens.lua")

local function book()
    return {
        title = "Dune",
        author = "Frank Herbert",
        -- bookshelf keeps authors as a LIST, not a joined string.
        authors = { "Frank Herbert", "Brian Herbert" },
        page_num = 42,
        page_count = 500,
        series_name = "Dune",
    }
end

local function ex(fmt) return Tokens.expand(fmt, book(), {}) end

t.test("a wrapped token resolves like the bare form", function()
    assert(ex("%<title>") == "Dune", 'got "' .. ex("%<title>") .. '"')
    assert(ex("%<page_num>") == "42")
end)

-- The reason the feature exists.
t.test("wrapping stops a following letter joining the name", function()
    assert(ex("%authors") == "Frank Herbert, Brian Herbert",
           "sanity: the bare longer token still wins")
    assert(ex("%<author>s") == "Frank Herberts",
           'expected "Frank Herberts" got "' .. ex("%<author>s") .. '"')
end)

t.test("wrapping works with adjacent punctuation and digits", function()
    assert(ex("%<page_num>/%<page_count>") == "42/500",
           'got "' .. ex("%<page_num>/%<page_count>") .. '"')
    assert(ex("%<page_num>2") == "422", 'got "' .. ex("%<page_num>2") .. '"')
end)

-- Matching bookends exactly, probed against it rather than guessed: the
-- delimiters are consumed and the unknown NAME is left as literal text. Not
-- empty - an unknown bare %token behaves the same way, so this keeps the two
-- forms consistent with each other as well as with bookends.
t.test("an unknown wrapped token loses its delimiters, keeps its name", function()
    assert(ex("%<nosuchtoken>") == "%nosuchtoken",
           'got "' .. ex("%<nosuchtoken>") .. '"')
end)

t.test("an unclosed %<name is left alone as literal text", function()
    assert(ex("%<title") == "%<title",
           'unclosed form should not be touched, got "' .. ex("%<title") .. '"')
end)

t.test("no sentinel character survives into output", function()
    local got = ex("%<title> and %<author>s")
    assert(not got:find("\4", 1, true), "boundary sentinel leaked into output")
    assert(got == "Dune and Frank Herberts", 'got "' .. got .. '"')
end)

t.test("wrapping composes with conditionals", function()
    assert(ex("[if:title]%<title>![/if]") == "Dune!",
           'got "' .. ex("[if:title]%<title>![/if]") .. '"')
end)

t.done()
