-- tests/_test_pinyin.lua
-- Pure-Lua unit tests for bookshelf_pinyin.lua and its sort_engine
-- integration (the "cjk_pinyin_sort" toggle, issue #43).
-- Run from the plugin root: `lua tests/_test_pinyin.lua`
package.loaded["logger"] = { dbg = function() end, info = function() end,
                              warn = function() end, err = function() end }

-- Fake settings store: lets the tests flip the cjk_pinyin_sort toggle and
-- bump the generation counter the way the real store does on save.
local fake_settings = {}
local fake_gen = 1
local FakeStore = {
    generation = function() return fake_gen end,
    read = function(key, default)
        local v = fake_settings[key]
        if v == nil then return default end
        return v
    end,
}
local function setSetting(k, v)
    fake_settings[k] = v
    fake_gen = fake_gen + 1
end

package.preload["lib/bookshelf_settings_store"] = function() return FakeStore end
package.preload["lib/bookshelf_pinyin"] = function()
    return dofile("lib/bookshelf_pinyin.lua")
end
package.preload["lib/bookshelf_author_name"] = function()
    return dofile("lib/bookshelf_author_name.lua")
end

local Pinyin = require("lib/bookshelf_pinyin")
local SortEngine = dofile("lib/bookshelf_sort_engine.lua")

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1
    else fail = fail + 1; io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n") end
end

local function ids(list) local r = {} for i, b in ipairs(list) do r[i] = b.id end return r end
local function eq(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do if a[i] ~= b[i] then return false end end
    return true
end

-- UTF-8 literals used below (written as escapes so the file itself stays
-- ASCII-safe under any editor): 刘慈欣 = Liu Cixin, 三体 = santi (The
-- Three-Body Problem), 留 = liu (same toneless syllable as 刘, higher
-- codepoint), 金庸 = Jin Yong.
local LIU  = "\229\136\152"             -- 刘 U+5218
local LIU2 = "\231\149\153"             -- 留 U+7559
local LCX  = "\229\136\152\230\133\136\230\172\163"  -- 刘慈欣
local SANTI = "\228\184\137\228\189\147"             -- 三体
local JY   = "\233\135\145\229\186\184"              -- 金庸

test("sylOf: known readings", function()
    assert(Pinyin.sylOf(0x5218) == "liu",   "0x5218 (liu): got " .. tostring(Pinyin.sylOf(0x5218)))
    assert(Pinyin.sylOf(0x6148) == "ci",    "0x6148 (ci)")
    assert(Pinyin.sylOf(0x6B23) == "xin",   "0x6B23 (xin)")
    assert(Pinyin.sylOf(0x91D1) == "jin",   "0x91D1 (jin)")
    assert(Pinyin.sylOf(0x4E09) == "san",   "0x4E09 (san)")
end)

test("sylOf: out-of-range and unmapped return nil", function()
    assert(Pinyin.sylOf(0x4DFF) == nil, "below URO")
    assert(Pinyin.sylOf(0xA000) == nil, "above URO")
    assert(Pinyin.sylOf(0x0041) == nil, "ASCII A")
    -- U+5159 is inside the URO but has no kMandarin reading in Unihan.
    assert(Pinyin.sylOf(0x5159) == nil, "URO codepoint without reading")
end)

test("hasHan: detects Han lead bytes only", function()
    assert(Pinyin.hasHan(LCX) == true,        "Chinese string")
    assert(Pinyin.hasHan("Pride and Prejudice") == false, "ASCII")
    assert(Pinyin.hasHan("h\195\169llo") == false, "accented Latin (e-acute)")
    assert(Pinyin.hasHan("abc" .. SANTI) == true, "mixed")
end)

test("key: converts Han to syllable-space pairs with \\1 tie-break", function()
    assert(Pinyin.key(LCX) == "liu ci xin \1" .. LCX,
           "got " .. Pinyin.key(LCX):gsub("\1", "<1>"))
    -- Mixed content: ASCII passes through in place.
    assert(Pinyin.key(SANTI .. " 3") == "san ti  3\1" .. SANTI .. " 3",
           "mixed got " .. Pinyin.key(SANTI .. " 3"):gsub("\1", "<1>"))
end)

test("key: non-Han strings come back unchanged", function()
    local s = "The Left Hand of Darkness"
    assert(Pinyin.key(s) == s, "ASCII changed")
    local accented = "\195\137mile Zola"  -- Émile
    assert(Pinyin.key(accented) == accented, "accented Latin changed")
    assert(Pinyin.key("") == "", "empty")
    assert(Pinyin.key(nil) == nil, "nil")
end)

test("key: same-syllable characters tie-break by codepoint", function()
    local a, b = Pinyin.key(LIU), Pinyin.key(LIU2)
    assert(a ~= b, "keys identical")
    assert(a < b, "U+5218 should sort before U+7559: "
           .. a:gsub("\1", "<1>") .. " vs " .. b:gsub("\1", "<1>"))
end)

test("key: multi-char names compare syllable-by-syllable", function()
    -- "liu ci ..." < "liu xin ..." -- the space after each syllable sorts
    -- below letters, so the SECOND syllable decides, not raw concatenation.
    local liu_ci  = Pinyin.key("\229\136\152\230\133\136")  -- 刘慈
    local liu_xin = Pinyin.key("\229\136\152\230\172\163")  -- 刘欣
    assert(liu_ci < liu_xin, "liu ci should sort before liu xin")
end)

-- ---- sort_engine integration --------------------------------------------

local function freshBooks()
    return {
        { id = 1, title = "Alice in Wonderland" },
        { id = 2, title = LCX },     -- liu... files under L when pinyin on
        { id = 3, title = "Zen and the Art" },
        { id = 4, title = SANTI },   -- san... files under S when pinyin on
    }
end

test("integration: toggle off sorts CJK after Latin (codepoint order)", function()
    setSetting("cjk_pinyin_sort", false)
    local books = freshBooks()
    SortEngine.sort(books, { { key = "title", reverse = false } })
    -- UTF-8 lead bytes 0xE4/0xE5 sort above all ASCII letters.
    assert(eq(ids(books), { 1, 3, 4, 2 }), "got " .. table.concat(ids(books), ","))
end)

test("integration: toggle on interleaves CJK by pinyin", function()
    setSetting("cjk_pinyin_sort", true)
    local books = freshBooks()
    SortEngine.sort(books, { { key = "title", reverse = false } })
    -- alice < liu(2) < san(4) < zen
    assert(eq(ids(books), { 1, 2, 4, 3 }), "got " .. table.concat(ids(books), ","))
end)

test("integration: flipping the toggle invalidates cached keys on records", function()
    setSetting("cjk_pinyin_sort", true)
    local books = freshBooks()
    SortEngine.sort(books, { { key = "title", reverse = false } })
    assert(eq(ids(books), { 1, 2, 4, 3 }), "pinyin pass got " .. table.concat(ids(books), ","))
    -- SAME records, toggle off: the epoch bump must wipe their cached keys,
    -- otherwise the stale pinyin keys would keep the interleaved order.
    setSetting("cjk_pinyin_sort", false)
    SortEngine.sort(books, { { key = "title", reverse = false } })
    assert(eq(ids(books), { 1, 3, 4, 2 }), "codepoint pass got " .. table.concat(ids(books), ","))
end)

test("integration: author_surname keys by pinyin when on", function()
    setSetting("cjk_pinyin_sort", true)
    -- Chinese name order is surname-first, and the no-space name parses as
    -- a single token, so the key leads with the surname syllable.
    local v = SortEngine.sortKeyValue({ id = 1, author = JY }, "author_surname")
    assert(type(v) == "string" and v:sub(1, 3) == "jin",
           "expected jin..., got " .. tostring(v))
end)

test("integration: sortKeyValue letter-jump value follows the toggle", function()
    setSetting("cjk_pinyin_sort", true)
    local v = SortEngine.sortKeyValue({ title = SANTI }, "title")
    assert(v:sub(1, 1) == "s", "pinyin on: expected s..., got " .. tostring(v))
    setSetting("cjk_pinyin_sort", false)
    local v2 = SortEngine.sortKeyValue({ title = SANTI }, "title")
    assert(v2 == SANTI, "pinyin off: expected raw title, got " .. tostring(v2))
end)

test("integration: Latin-only library is unaffected by the toggle", function()
    setSetting("cjk_pinyin_sort", true)
    local books = {
        { id = 1, title = "Charlie" },
        { id = 2, title = "Alice" },
        { id = 3, title = "Bob" },
    }
    SortEngine.sort(books, { { key = "title", reverse = false } })
    assert(eq(ids(books), { 2, 3, 1 }), "got " .. table.concat(ids(books), ","))
    setSetting("cjk_pinyin_sort", false)
end)

print(string.format("pinyin: %d pass, %d fail", pass, fail))
if fail > 0 then os.exit(1) end
