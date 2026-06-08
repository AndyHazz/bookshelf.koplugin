-- tests/_test_color.lua
-- Pure-Lua unit tests for bookshelf_color: hex normalisation, the colour-vs-grey
-- classification, storage-shape collapsing, field defaults, and parseColorValue
-- (the colour-enabled vs greyscale render-time conversion).
--
-- Replaces the old _test_colour.lua, which targeted the long-removed
-- bookshelf_colour module. The colour module only needs ffi/blitbuffer, which we
-- stub so the value-object factories are observable.

package.path = "./?.lua;./?/init.lua;" .. package.path

package.loaded["ffi/blitbuffer"] = {
    Color8     = function(n) return { _kind = "Color8", v = n } end,
    ColorRGB32 = function(r, g, b, a)
        return { _kind = "ColorRGB32", r = r, g = g, b = b, a = a }
    end,
}

local Color   = dofile("lib/bookshelf_color.lua")
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

-- normaliseHex ---------------------------------------------------------------
t.test("normaliseHex: long form upper-cases", function()
    eq(Color.normaliseHex("#abcdef"), "#ABCDEF")
end)
t.test("normaliseHex: long form without #", function()
    eq(Color.normaliseHex("abcdef"), "#ABCDEF")
end)
t.test("normaliseHex: short form expands", function()
    eq(Color.normaliseHex("#f0a"), "#FF00AA")
end)
t.test("normaliseHex: trims whitespace", function()
    eq(Color.normaliseHex("  #404040  "), "#404040")
end)
t.test("normaliseHex: rejects 5-char input", function()
    eq(Color.normaliseHex("#abcde"), nil)
end)
t.test("normaliseHex: rejects non-hex characters", function()
    eq(Color.normaliseHex("#zz0000"), nil)
end)
t.test("normaliseHex: rejects non-strings", function()
    eq(Color.normaliseHex(0x404040), nil)
    eq(Color.normaliseHex(nil), nil)
end)

-- isColorHex -----------------------------------------------------------------
t.test("isColorHex: pure grey returns false", function()
    eq(Color.isColorHex("#404040"), false)
end)
t.test("isColorHex: non-neutral returns true", function()
    eq(Color.isColorHex("#FF0000"), true)
end)
t.test("isColorHex: malformed returns false", function()
    eq(Color.isColorHex("not a hex"), false)
end)

-- toStorageShape -------------------------------------------------------------
t.test("toStorageShape: pure grey collapses to {grey=N}", function()
    eq(Color.toStorageShape("#404040"), { grey = 0x40 })
end)
t.test("toStorageShape: colour stays as {hex=...}", function()
    eq(Color.toStorageShape("#FF6600"), { hex = "#FF6600" })
end)
t.test("toStorageShape: short-form expands then collapses", function()
    eq(Color.toStorageShape("#888"), { grey = 0x88 })
end)
t.test("toStorageShape: malformed returns nil", function()
    eq(Color.toStorageShape("zzz"), nil)
end)

-- defaultHexFor --------------------------------------------------------------
t.test("defaultHexFor: fill is #404040", function()
    eq(Color.defaultHexFor("fill"), "#404040")
end)
t.test("defaultHexFor: unknown field returns nil", function()
    eq(Color.defaultHexFor("bogus"), nil)
end)

-- parseColorValue ------------------------------------------------------------
t.test("parseColorValue: nil -> nil, false -> false (transparent)", function()
    Color.flushCache()
    eq(Color.parseColorValue(nil, true), nil)
    eq(Color.parseColorValue(false, true), false)
end)
t.test("parseColorValue: {hex} on a colour screen -> ColorRGB32", function()
    Color.flushCache()
    eq(Color.parseColorValue({ hex = "#FF0000" }, true),
        { _kind = "ColorRGB32", r = 255, g = 0, b = 0, a = 0xFF })
end)
t.test("parseColorValue: {hex} on a greyscale screen -> Color8(Rec.601 luma)", function()
    Color.flushCache()
    -- 0.299*255 + 0.587*0 + 0.114*0 = 76.245 -> round 76
    eq(Color.parseColorValue({ hex = "#FF0000" }, false), { _kind = "Color8", v = 76 })
end)
t.test("parseColorValue: {grey=N} -> Color8(N)", function()
    Color.flushCache()
    eq(Color.parseColorValue({ grey = 0x40 }, true), { _kind = "Color8", v = 0x40 })
end)
t.test("parseColorValue: a byte number -> Color8; >=0xFF -> false", function()
    Color.flushCache()
    eq(Color.parseColorValue(0x40, false), { _kind = "Color8", v = 0x40 })
    eq(Color.parseColorValue(0xFF, false), false)
end)

t.done()
