-- safeText: makes untrusted module text (network APIs, metadata, user input)
-- safe to feed to crengine/HarfBuzz. Invalid UTF-8 is the prime cause of a
-- hard text-shaping segfault (issue #163: trivia's urlDecode emits raw bytes
-- from %XX with no validation); control chars and pathological lengths are
-- stripped/capped too. fixUtf8 comes from KOReader's util at runtime - here we
-- inject a fake `util` so the wiring is exercised under a standalone lua.
package.path = "./?.lua;./?/init.lua;" .. package.path

-- Fake util.fixUtf8 (installed BEFORE the helper loads, since it requires util
-- at load time). Mimics the real one's contract: replace each invalid byte
-- with `replacement`. Here we treat 0xFF as the lone "invalid" byte.
package.loaded["util"] = {
    fixUtf8 = function(str, replacement)
        return (str:gsub("\255", replacement))
    end,
}

local Safe = dofile("lib/bookshelf_text_safe.lua")
local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()

local FFFD = "\xEF\xBF\xBD" -- U+FFFD replacement char

t.test("non-string input yields empty string", function()
    assert(Safe.safe(nil) == "")
    assert(Safe.safe(42) == "")
    assert(Safe.safe({}) == "")
end)

t.test("plain ASCII passes through unchanged", function()
    assert(Safe.safe("Hello, world!") == "Hello, world!")
end)

t.test("valid multibyte UTF-8 is preserved", function()
    -- "café" with é = U+00E9 (0xC3 0xA9); fixUtf8 must not touch valid bytes.
    assert(Safe.safe("caf\xC3\xA9") == "caf\xC3\xA9")
end)

t.test("invalid UTF-8 byte is replaced via fixUtf8", function()
    -- 0xFF is not valid UTF-8; the fake fixUtf8 swaps it for U+FFFD.
    assert(Safe.safe("a\xFFb") == "a" .. FFFD .. "b",
        "invalid bytes must be routed through fixUtf8, not passed raw")
end)

t.test("C0 control chars are stripped, but tab/newline kept", function()
    assert(Safe.safe("a\1b\8c\127d") == "abcd", "control chars must be removed")
    assert(Safe.safe("a\tb\nc\rd") == "a\tb\nc\rd",
        "tab, newline and carriage return must survive")
end)

t.test("pathologically long text is capped", function()
    local long = string.rep("x", 10000)
    local out = Safe.safe(long)
    assert(#out <= 4000, "over-long text must be capped, got " .. #out)
    assert(out == string.rep("x", 4000))
end)

t.done()
