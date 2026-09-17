-- tests/_test_color_pct_parity.lua
-- A colour row and the picker it opens must say the same number.
--
-- WHAT WENT WRONG. "Shelf plank colour shows 46% in the top menu, and 45% in
-- the modal menu." Two derivations of one idea, which is how it always goes:
--
--   * the ROW converted whatever was stored. For a hex it took the Rec.601
--     luminance and turned that into "% black on screen". The plank ships as
--     #B08050, luminance 137, which reads 46% by day.
--   * the PICKER only understood a stored `grey`. Handed a hex it found
--     nothing and fell back to the row's hardcoded default_pct, which for the
--     plank is 45.
--
-- So the two numbers were never related. They happened to sit a point apart,
-- which is worse than a wild disagreement: it reads as a rounding bug and
-- sends you looking at the arithmetic rather than at the missing branch.
--
-- Usage (from plugin root): lua tests/_test_color_pct_parity.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq
local src = io.open("lib/bookshelf_settings.lua"):read("*a")

local body = src:match("\nlocal function _rawToScreenPct%(raw%)\n(.-)\nend\n")
assert(body, "_rawToScreenPct missing: the one derivation both sides must share")

local function pct(raw, night)
    local env = {
        type = type, tonumber = tonumber, math = math,
        _byteToScreenPct = function(b)
            if night then return math.floor(b * 100 / 0xFF + 0.5) end
            return math.floor((0xFF - b) * 100 / 0xFF + 0.5)
        end,
    }
    local fn = assert(load("return function(raw)\n" .. body .. "\nend", "pct", "t", env))
    return fn()(raw)
end

t.test("the plank's own hex reads 46%, which is what the row showed", function()
    eq(pct({ hex = "#B08050" }, false), 46)
end)

t.test("a stored grey reads the same as it always did", function()
    eq(pct({ grey = 0x00 }, false), 100, "black is 100% black by day")
    eq(pct({ grey = 0xFF }, false), 0)
end)

t.test("night mode flips it, because the panel inverts at display time", function()
    eq(pct({ grey = 0x00 }, true), 0)
    eq(pct({ hex = "#B08050" }, true), 54)
end)

t.test("nothing stored yields nothing, so the caller can fall back", function()
    eq(pct(nil, false), nil)
    eq(pct({}, false), nil)
    eq(pct("not a table", false), nil)
end)

t.test("the picker starts from the stored value, not from the row's default", function()
    local picker = src:match("function Settings:_pickColor%(raw_key, field, default_pct, title,(.-)\nend\n")
    assert(picker, "_pickColor moved or was renamed")
    assert(picker:find("_rawToScreenPct(raw)", 1, true),
        "the picker still derives its own starting value, so a hex-stored "
        .. "colour opens on the row's default instead of on what is stored")
    assert(not picker:find("byte and _byteToScreenPct(byte) or default_pct", 1, true),
        "the grey-only branch is back")
end)

t.test("both labels go through it too, so all three agree", function()
    local n = select(2, src:gsub("_rawToScreenPct%(", ""))
    assert(n >= 4,
        "expected the definition plus the two labels and the picker, found " .. n)
    -- The Rec.601 constants should now live in exactly one place.
    local lum = select(2, src:gsub("0%.587", ""))
    eq(lum, 1, "the luminance conversion is written " .. lum .. " times; it was three")
end)

t.done()
