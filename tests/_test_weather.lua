-- tests/_test_weather.lua
-- The weather module's urlencode (exposed via the spec's _urlencode hook).
-- It must escape by explicit ASCII ranges, never Lua's %w class - %w tests
-- bytes through C isalnum() under the runtime locale, and a locale that
-- accepts high bytes would pass UTF-8 continuation bytes through unescaped,
-- mangling multibyte city names (the stock-plugin bug koreader#13693).
package.path = "./?.lua;./?/init.lua;" .. package.path

package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }
package.loaded["ffi/util"] = { template = function(s, ...) return s end }
package.loaded["lib/bookshelf_text_safe"] = { safe = function(s) return s end }

local spec = dofile("micromodules/weather.lua")
local enc = spec._urlencode
local t = dofile("tests/_helpers.lua").runner()

t.test("hook exposed", function()
    assert(type(enc) == "function")
end)

t.test("plain ASCII city passes through", function()
    assert(enc("London") == "London")
end)

t.test("spaces become +", function()
    assert(enc("New York") == "New+York")
end)

t.test("unreserved ASCII (- _ . ~) stays literal", function()
    assert(enc("a-b_c.d~e") == "a-b_c.d~e")
end)

t.test("every byte of a multibyte character is escaped", function()
    -- "München": u-umlaut is C3 BC. Under a permissive locale the old %w
    -- pattern let the continuation byte through; both bytes must escape.
    assert(enc("M\xC3\xBCnchen") == "M%C3%BCnchen", enc("M\xC3\xBCnchen"))
    -- "São Paulo": a-tilde is C3 A3, plus the space rule.
    assert(enc("S\xC3\xA3o Paulo") == "S%C3%A3o+Paulo", enc("S\xC3\xA3o Paulo"))
end)

t.test("URL metacharacters are escaped", function()
    assert(enc("a&b=c") == "a%26b%3Dc", enc("a&b=c"))
    assert(enc("50%") == "50%25", enc("50%"))
end)

t.test("newline normalises to escaped CRLF", function()
    assert(enc("a\nb") == "a%0D%0Ab", enc("a\nb"))
end)

t.test("nil passes through untouched", function()
    assert(enc(nil) == nil)
end)

t.done()
