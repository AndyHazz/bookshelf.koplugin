-- tests/_test_spine_cjk_title.lua
-- CJK spine titles: which titles go upright, and how the column is divided.
--
-- From PR #393 (ksaMask123), which paints CJK-dominant titles as an upright
-- vertical column (tategaki) instead of rotating them 90 degrees like Latin
-- ones -- a rotated CJK string simply is not how the script is read.
--
-- The PR arrived with its own standalone stub harness, which is not in the
-- tree; this covers the same pure logic the way the rest of the suite does, so
-- it runs in CI with everything else. The three functions here are the ones
-- that DECIDE things: everything downstream is measurement and painting, which
-- needs a real Screen and font cache.
--
-- Extracted rather than required: they are file-locals inside a module that
-- pulls in Screen, BFont and Blitbuffer at load.
--
-- Usage (from plugin root): lua tests/_test_spine_cjk_title.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

local H = dofile("tests/_helpers.lua")
local t = H.runner()
local eq = H.eq

local src = assert(io.open("lib/bookshelf_spine_shelf.lua")):read("*a")
-- One contiguous run: _splitChars, _isCJKChar, _isCJKText, the VERT_
-- constants, _mainTitle and _groupRuns. Nothing in it touches a widget.
local block = src:match("\n(local function _splitChars%(text%).-\nend)\n\n%-%- Solve for the largest font size")
assert(block, "the CJK helper block moved or was renamed")

local env = { string = string, table = table, math = math, ipairs = ipairs,
              pairs = pairs, tonumber = tonumber, type = type }
local function compile(code)
    if _G.setfenv then
        local f = assert(_G.loadstring(code, "cjk"))
        _G.setfenv(f, env)
        return f
    end
    return assert(load(code, "cjk", "t", env))
end
-- EXPORTED under a name the block does NOT declare: a bare `_splitChars =
-- _splitChars` would assign to the in-scope LOCAL, not to a global, and the
-- environment would come back empty.
compile(block .. "\nEXPORT = { cjk = _isCJKText, split = _splitChars,"
        .. " group = _groupRuns, main = _mainTitle }")()
local E = assert(env.EXPORT, "the helper block exported nothing")
local isCJK, split = E.cjk, E.split
local groupRuns, mainTitle = E.group, E.main

-- ── splitting UTF-8 by hand ────────────────────────────────────────────────
-- Hand-rolled on purpose: the `utf8` library's availability varies across
-- KOReader builds, and this file already runs under both lua and luajit.

t.test("split: counts CHARACTERS, not bytes", function()
    eq(#split("三体"), 2, "two glyphs, six bytes")
    eq(#split("1984"), 4)
    eq(#split(""), 0)
    eq(#split("漫威Marvel"), 8, "two CJK plus six Latin")
end)

t.test("split: a truncated multi-byte tail does not run off the end", function()
    -- A title cut mid-glyph by some upstream truncation must not loop or
    -- index past the string.
    local ok = pcall(function() return #split("三\xE4\xB8") end)
    assert(ok, "a malformed tail must not throw")
end)

-- ── which titles go upright ────────────────────────────────────────────────

t.test("detect: a Chinese title goes vertical", function()
    assert(isCJK("三体"), "pure CJK")
    assert(isCJK("解憂雜貨店"))
end)

t.test("detect: a Latin title does NOT", function()
    assert(not isCJK("Dune"), "Latin must keep the rotated path")
    assert(not isCJK("1984"))
    assert(not isCJK(""), "an empty title has nothing to stand upright")
end)

t.test("detect: a mixed title goes by VISUAL WIDTH, not character count", function()
    -- "漫威Marvel" is 2 of 8 characters CJK -- 25% by count, which a naive
    -- ratio would reject -- but a fullwidth glyph occupies two columns, so it
    -- is ~40% of the width and reads as a Chinese title.
    assert(isCJK("漫威Marvel"), "a reader sees this as Chinese")
end)

t.test("detect: zero-width characters cannot tip the balance", function()
    -- Calibre and Legado exports sneak U+200B/C/D and U+FEFF into names. They
    -- are invisible but count as characters, so without stripping they drag
    -- the CJK ratio below the threshold and the title gets rotated.
    assert(isCJK("三体\xE2\x80\x8B"), "zero-width space")
    assert(isCJK("三体\xEF\xBB\xBF"), "BOM")
    assert(isCJK("书\xE2\x80\x8B\xE2\x80\x8C\xE2\x80\x8Dab"),
        "several of them, which is what an export actually produces")
end)

t.test("detect: Japanese and Korean count, not just Han", function()
    assert(isCJK("ひらがな"), "hiragana")
    assert(isCJK("カタカナ"), "katakana")
    assert(isCJK("한국어"),   "hangul syllables")
end)

t.test("detect: a four-byte extension glyph is recognised", function()
    -- CJK Extension B (U+20000+). The ranges are checked on the codepoint, so
    -- a four-byte sequence has to be decoded rather than refused outright --
    -- obscure titles were otherwise mis-classified and rotated.
    assert(isCJK("\xF0\xA0\x80\x8B"), "U+2000B")
end)

-- ── dividing the column ────────────────────────────────────────────────────

t.test("group: each CJK glyph gets its own cell", function()
    eq(#groupRuns(split("三体问题")), 4)
end)

t.test("group: a Latin run shares ONE cell (tate-chu-yoko)", function()
    -- "1984" lies across a single cell rather than stacking four cells, which
    -- is both how it is set and how it stays legible.
    local runs = groupRuns(split("1984年"))
    eq(#runs, 2, "the year, then the glyph")
    eq(runs[1], "1984")
    eq(runs[2], "年")
end)

t.test("group: an over-long Latin run is split rather than crushed", function()
    -- Otherwise one long word would shrink to fit a single cell and the rest
    -- of the title would shrink with it.
    local runs = groupRuns(split("ABCDEFGH"))
    assert(#runs >= 2, "eight Latin characters cannot be one cell")
    for _i, r in ipairs(runs) do
        assert(#r <= 4, "a group must not exceed the cap, got " .. r)
    end
end)

t.test("group: an empty title yields no cells", function()
    eq(#groupRuns(split("")), 0)
end)

-- ── keeping the book's actual name when it will not all fit ────────────────

t.test("main title: cuts at the first separator", function()
    eq(mainTitle("三体：地球往事"), "三体")
    eq(mainTitle("三体 (第一部)"), "三体")
end)

t.test("main title: a separator search is BYTE-EXACT, never a character class", function()
    -- Lua 5.1 patterns are byte-wise, so putting CJK punctuation in a class
    -- would split it into bytes -- one of which (0x80) is a middle byte of
    -- almost every CJK glyph, wrecking the match. A plain find is the fix,
    -- and this is the case that would expose a regression to a pattern.
    eq(mainTitle("解憂雜貨店"), "解憂雜貨店",
        "no separator present, so the title survives whole")
end)

t.test("main title: a separator too early leaves the title alone", function()
    -- Cutting would leave less than one glyph, which is not a title.
    eq(mainTitle("：三体"), "：三体")
end)

t.done()
