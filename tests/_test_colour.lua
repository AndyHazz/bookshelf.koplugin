-- tests/_test_colour.lua
-- Pure-Lua unit tests for bookshelf_colour.lua value parsers.
-- Usage: cd into the plugin dir, then `lua tests/_test_colour.lua`.

-- The colour module requires ffi/blitbuffer for the parseColorValue path;
-- stub it so the module loads without the KOReader environment. We never
-- call parseColorValue in this file, but `require` evaluates the top of
-- the module, which includes the require for blitbuffer.
package.loaded["ffi/blitbuffer"] = {
    Color8       = function(n) return { _kind = "Color8",       v = n } end,
    ColorRGB32   = function(r, g, b, a) return { _kind = "ColorRGB32", r = r, g = g, b = b, a = a } end,
}

package.path = "./?.lua;" .. package.path
local Colour = require("bookshelf_colour")

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1
    else   fail = fail + 1
           io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n")
    end
end
local function eq(a, e, msg)
    if a ~= e then
        error((msg or "") .. " expected=" .. tostring(e) .. " got=" .. tostring(a), 2)
    end
end
local function deepEq(a, e, msg)
    if type(a) ~= "table" or type(e) ~= "table" then
        return eq(a, e, msg)
    end
    for k, v in pairs(e) do
        if a[k] ~= v then
            error((msg or "") .. " key=" .. tostring(k) .. " expected=" .. tostring(v) .. " got=" .. tostring(a[k]), 2)
        end
    end
    for k, _v in pairs(a) do
        if e[k] == nil then
            error((msg or "") .. " unexpected key=" .. tostring(k), 2)
        end
    end
end

-- normaliseHex ---------------------------------------------------------------

test("normaliseHex: long form upper-cases", function()
    eq(Colour.normaliseHex("#abcdef"), "#ABCDEF")
end)

test("normaliseHex: long form without #", function()
    eq(Colour.normaliseHex("abcdef"), "#ABCDEF")
end)

test("normaliseHex: short form expands", function()
    eq(Colour.normaliseHex("#f0a"), "#FF00AA")
end)

test("normaliseHex: trims whitespace", function()
    eq(Colour.normaliseHex("  #404040  "), "#404040")
end)

test("normaliseHex: rejects 5-char input", function()
    eq(Colour.normaliseHex("#abcde"), nil)
end)

test("normaliseHex: rejects non-hex characters", function()
    eq(Colour.normaliseHex("#zz0000"), nil)
end)

test("normaliseHex: rejects non-strings", function()
    eq(Colour.normaliseHex(0x404040), nil)
    eq(Colour.normaliseHex(nil), nil)
end)

-- isColourHex ----------------------------------------------------------------

test("isColourHex: pure grey returns false", function()
    eq(Colour.isColourHex("#404040"), false)
end)

test("isColourHex: non-neutral returns true", function()
    eq(Colour.isColourHex("#FF0000"), true)
end)

test("isColourHex: malformed returns false", function()
    eq(Colour.isColourHex("not a hex"), false)
end)

-- toStorageShape -------------------------------------------------------------

test("toStorageShape: pure grey collapses to {grey=N}", function()
    deepEq(Colour.toStorageShape("#404040"), { grey = 0x40 })
end)

test("toStorageShape: colour stays as {hex=...}", function()
    deepEq(Colour.toStorageShape("#FF6600"), { hex = "#FF6600" })
end)

test("toStorageShape: short-form expands then collapses", function()
    deepEq(Colour.toStorageShape("#888"), { grey = 0x88 })
end)

test("toStorageShape: malformed returns nil", function()
    eq(Colour.toStorageShape("zzz"), nil)
end)

-- defaultHexFor --------------------------------------------------------------

test("defaultHexFor: fill is #404040", function()
    eq(Colour.defaultHexFor("fill"), "#404040")
end)

test("defaultHexFor: unknown field returns nil", function()
    eq(Colour.defaultHexFor("bogus"), nil)
end)

-- Report ---------------------------------------------------------------------

print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
