-- tests/_test_published_format_token.lua
-- %published{format}: the publication date in the reader's own layout. Plain
-- %published stays the year. A date with fewer parts than the layout shows
-- the short form; no date shows nothing, so [if:published] still gates.
-- Usage (from plugin root): lua tests/_test_published_format_token.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq

package.loaded["device"] = {
    getPowerDevice = function() return nil end,
    isKindle = function() return false end,
    hasNaturalLight = function() return false end,
    home_dir = "/",
}
package.loaded["datetime"] = { secondsToClockDuration = function() return "" end }
local i18n = { gettext = function(s) return s end, ngettext = function(s, p, n) return n == 1 and s or p end }
package.loaded["bookshelf_i18n"] = i18n
package.loaded["lib/bookshelf_i18n"] = i18n
_G.G_reader_settings = setmetatable({}, {
    __index = function() return function() return false end end,
})

-- The date each book resolves to, as lib/bookshelf_published would give it.
local dates = {}
package.loaded["lib/bookshelf_published"] = {
    info = function(b) return dates[b.filepath] end,
    forRecord = function(b)
        local d = dates[b.filepath]
        return d and d:sub(1, 4) or ""
    end,
}
local Tokens = dofile("lib/bookshelf_tokens.lua")
local book = { filepath = "/b.epub" }

t.test("a full date in the reader's layout", function()
    dates["/b.epub"] = "1851-10-18"
    eq(Tokens.expand("%published{%-d %B %Y}", book), "18 October 1851")
    eq(Tokens.expand("%<published{%Y}>s", book), "1851s")
end)

t.test("plain %published beside the braced form stays the year", function()
    dates["/b.epub"] = "1851-10-18"
    eq(Tokens.expand("%published / %published{%Y-%m}", book), "1851 / 1851-10")
end)

t.test("fewer parts than the layout: the short form", function()
    dates["/b.epub"] = "1851"
    eq(Tokens.expand("%published{%-d %B %Y}", book), "1851")
    dates["/b.epub"] = "1851-10"
    eq(Tokens.expand("%published{%-d %B %Y}", book), "Oct 1851")
end)

t.test("no date: empty, and [if:published] still gates", function()
    dates["/b.epub"] = nil
    eq(Tokens.expand("%published{%B %Y}", book), "")
    eq(Tokens.expand("[if:published]x[/if]", book), "")
    dates["/b.epub"] = "1851"
    eq(Tokens.expand("[if:published]x[/if]", book), "x")
end)

t.test("a menu row shows the formatted date", function()
    dates["/b.epub"] = "1851-10-18"
    eq(Tokens.menuPreview("%published{%B %Y}", book), "October 1851")
end)

t.test("the picker offers it", function()
    local seen
    for _i, e in ipairs(Tokens.CATALOGUE or {}) do
        if e.token == "%published{format}" then seen = true end
    end
    assert(seen, "no %published{format} entry in the token catalogue")
end)

t.done()
