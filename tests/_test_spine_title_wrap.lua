-- tests/_test_spine_title_wrap.lua
-- A title too long for its spine takes a second line where the spine is thick
-- enough to hold two.
--
-- Usage (from plugin root): lua tests/_test_spine_title_wrap.lua
--
-- Issue 440: omnibuses have the thickest spines on the shelf and the longest
-- titles, and a single rotated line cut most of the title away while the spine
-- stood mostly empty across its width. The painter now breaks such a title in
-- two, at the word boundary that balances the lines -- only when the one line
-- was cut, and only when two lines fit across the spine.

package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local src = io.open("lib/bookshelf_spine_shelf.lua"):read("*a")
local body = src:match("\nfunction SpineShelf%._splitTitle%(text, run_len, measure%)\n(.-)\nend\n")
assert(body, "SpineShelf._splitTitle is missing")
local split = assert(load("return function(text, run_len, measure)\n" .. body .. "\nend",
    "_splitTitle", "t", { tostring = tostring, table = table, math = math }))()

-- One pixel per character: a monospace stand-in for the font.
local function mono(str) return #str end

t.test("the break balances the two lines", function()
    local a, b = split("The Complete Chronicles of Narnia", 20, mono)
    eq(a, "The Complete")
    eq(b, "Chronicles of Narnia")
end)

t.test("the first line always fits whole", function()
    local a = split("Aaaaaaaaaa Bbbbbbbbbb Cc", 12, mono)
    assert(#a <= 12, "line one overran the run: " .. a)
end)

t.test("the second line may still be long; it is what a broken title has left", function()
    local a, b = split("Short Averyveryverylongwordindeed", 10, mono)
    eq(a, "Short"); eq(b, "Averyveryverylongwordindeed")
end)

t.test("one word cannot break", function()
    eq(split("Supercalifragilistic", 5, mono), nil)
end)

t.test("a first word longer than the run cannot break either", function()
    eq(split("Incomprehensibilities of Things", 8, mono), nil)
end)

t.test("runs of spaces are one boundary", function()
    local a, b = split("Alpha   Beta", 6, mono)
    eq(a, "Alpha"); eq(b, "Beta")
end)

-- ── the painter's gate ─────────────────────────────────────────────────────

local painter = src:match("\nlocal function _paintRotatedTitle%(.-%)\n(.-)\nend\n")
assert(painter, "_paintRotatedTitle moved")

t.test("only a title that was cut is broken", function()
    assert(painter:find("tw:isTruncated()", 1, true),
        "a title that fits would be split for no reason")
end)

t.test("only where two lines fit across the spine", function()
    assert(painter:find("2 * line_h + line_gap <= band_w", 1, true),
        "two lines would be painted wider than the spine")
end)

t.test("the prefill ramp spans the whole block, not one line", function()
    -- Each scratch row is a screen column after rotation; a ramp over one
    -- line's height would leave the second line on a stripe.
    assert(painter:find("local sh = #lines * line_h + (#lines - 1) * line_gap", 1, true))
    assert(painter:find("local band_off = math.floor((band_w - sh) / 2)", 1, true))
end)

t.done()
