-- tests/_test_bookshelf_lang.lua
-- Unit tests for bookshelf_lang.canonical: maps any ebook language value
-- (2-letter, 3-letter, region-tagged, full name, junk) to a single canonical
-- grouping key plus a localised display label. Pure Lua; stubs KOReader's
-- ui/data/isolanguage. Usage: lua tests/_test_bookshelf_lang.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

-- Stub KOReader's ISO language table. getLocalizedLanguage takes a 3-letter
-- ISO 639-3 code and returns the (here, English) name, or the code itself when
-- unknown -- mirroring the real module's fallback.
local NAMES = {
    eng = "English", deu = "German", fra = "French",
    jpn = "Japanese", spa = "Spanish", zho = "Chinese",
}
package.loaded["ui/data/isolanguage"] = {
    getLocalizedLanguage = function(_self, iso3) return NAMES[iso3] or iso3 end,
}

local Lang = dofile("lib/bookshelf_lang.lua")

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1
    else fail = fail + 1; io.write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n") end
end
local function eq(got, want, what)
    assert(got == want, (what or "value") .. ": expected " .. tostring(want)
        .. ", got " .. tostring(got))
end

test("2-letter code maps to 3-letter key and friendly label", function()
    local key, label = Lang.canonical("en")
    eq(key, "eng", "key"); eq(label, "English", "label")
end)

test("3-letter code passes through to key and label", function()
    local key, label = Lang.canonical("deu")
    eq(key, "deu", "key"); eq(label, "German", "label")
end)

test("region/script suffix is stripped before resolving", function()
    local k1 = Lang.canonical("en-US")
    local k2 = Lang.canonical("en_GB")
    local k3 = Lang.canonical("zh-Hans")
    eq(k1, "eng", "en-US"); eq(k2, "eng", "en_GB"); eq(k3, "zho", "zh-Hans")
end)

test("full language name resolves to the same key as its code", function()
    local key, label = Lang.canonical("English")
    eq(key, "eng", "key"); eq(label, "English", "label")
end)

test("input is case-insensitive", function()
    eq((Lang.canonical("EN")),       "eng", "EN")
    eq((Lang.canonical("english")),  "eng", "english")
    eq((Lang.canonical("FRA")),      "fra", "FRA")
end)

test("code, 3-letter, region and name variants all collapse to one key", function()
    local a = Lang.canonical("en")
    local b = Lang.canonical("eng")
    local c = Lang.canonical("en-GB")
    local d = Lang.canonical("English")
    assert(a == b and b == c and c == d,
        "expected all == 'eng', got " .. table.concat({a, b, c, d}, ","))
end)

test("unknown value keeps a normalised key and the original as label", function()
    local key, label = Lang.canonical("Klingon")
    eq(key, "klingon", "key")        -- normalised (lowercased) so variants merge
    eq(label, "Klingon", "label")    -- best-effort: show what the book declared
end)

test("nil and empty return nil (caller handles the Unknown bucket)", function()
    eq((Lang.canonical(nil)), nil, "nil")
    eq((Lang.canonical("")),  nil, "empty")
    eq((Lang.canonical("   ")), nil, "whitespace")
end)

io.write(string.format("\nbookshelf_lang: %d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
