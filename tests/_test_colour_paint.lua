-- tests/_test_colour_paint.lua
-- Picked colours came out grey on colour screens (reported on Reddit: "the
-- background colors I selected for the progress bar and shelf menu are all in
-- grayscale"). Blitbuffer's paintRect and TextWidget's glyph blit both flatten
-- a colour to one grey; these pin the colour-safe routes Bookshelf uses instead.
package.path = "./?.lua;./?/init.lua;" .. package.path

local t  = dofile("tests/_helpers.lua").runner()
local eq = dofile("tests/_helpers.lua").eq

-- A Blitbuffer stand-in: a colour is a table with .r, a grey one has only .a.
local calls
local BB = {
    isColor8 = function(c) return c.r == nil end,
    TYPE_BB8 = 1, TYPE_BBRGB32 = 5,
}
package.loaded["ffi/blitbuffer"] = BB
local function fakeBB(bbtype, with_rgb)
    local bb = {
        paintRect = function(_s, x, y, w, h, c) calls[#calls + 1] = { "paintRect", c } end,
        getType = function() return bbtype end,
    }
    if with_rgb ~= false then
        bb.paintRectRGB32 = function(_s, x, y, w, h, c) calls[#calls + 1] = { "paintRectRGB32", c } end
    end
    return bb
end
package.loaded["lib/bookshelf_color"] = nil
local Color = require("lib/bookshelf_color")

t.test("a picked colour is filled with paintRectRGB32", function()
    calls = {}
    Color.paintRect(fakeBB(5), 0, 0, 10, 10, { r = 32, g = 96, b = 208 })
    eq(calls[1][1], "paintRectRGB32")
end)

t.test("a grey is filled exactly as before", function()
    calls = {}
    Color.paintRect(fakeBB(5), 0, 0, 10, 10, { a = 0x80 })
    eq(calls[1][1], "paintRect")
end)

t.test("a KOReader without paintRectRGB32 falls back to paintRect", function()
    calls = {}
    Color.paintRect(fakeBB(5, false), 0, 0, 10, 10, { r = 1, g = 2, b = 3 })
    eq(calls[1][1], "paintRect")
end)

t.test("no colour, no paint", function()
    calls = {}
    Color.paintRect(fakeBB(5), 0, 0, 10, 10, nil)
    eq(#calls, 0)
end)

t.test("the colour text module hands back a stubbed TextWidget untouched", function()
    local stub = { name = "stub" }
    package.loaded["ui/widget/textwidget"] = stub
    package.loaded["lib/bookshelf_colour_text"] = nil
    eq(require("lib/bookshelf_colour_text"), stub, "a stub without extend must pass straight through")
    package.loaded["lib/bookshelf_colour_text"] = nil
    package.loaded["ui/widget/textwidget"] = nil
end)

-- The swap is one line per file; a file that goes back to KOReader's own
-- TextWidget would quietly draw its picked colours grey again.
t.test("nothing requires KOReader's TextWidget directly", function()
    local p = io.popen("grep -rln 'require(\"ui/widget/textwidget\")' lib micromodules main.lua 2>/dev/null")
    local out = p:read("*a"); p:close()
    local offenders = {}
    for f in out:gmatch("[^\n]+") do
        if f ~= "lib/bookshelf_colour_text.lua" then offenders[#offenders + 1] = f end
    end
    assert(#offenders == 0, "use lib/bookshelf_colour_text instead in: " .. table.concat(offenders, ", "))
end)

t.test("the shelf menu strip and the hero fallback bar paint colour-safely", function()
    local chip = io.open("lib/bookshelf_chip_bar.lua"):read("*a")
    assert(chip:find('require("lib/bookshelf_color").paintRect(bb, x, y, w or 0, h or 0, colors.chrome_bg)', 1, true),
        "the strip ground must go through Color.paintRect")
    local bar = io.open("lib/bookshelf_hero_bar.lua"):read("*a")
    assert(bar:find("ColourBar", 1, true) and bar:find("Color.paintRect(bb, x + bw, y + bw, fw", 1, true),
        "without bookends, a picked bar colour must be painted by ColourBar")
    local card = io.open("lib/bookshelf_hero_card.lua"):read("*a")
    assert(card:find("keeps_colour", 1, true),
        "a coloured hero bar must stay out of the one-colour wallpaper mask")
end)

-- Night mode: the night slot is stored pre-inverted for a frame that flips it.
-- The colour picker stored what the reader SAW, so a night pick displayed as
-- its opposite (red as cyan) once colours stopped being flattened to grey.
t.test("the colour picker inverts the night slot on the way in and out", function()
    local src = io.open("lib/bookshelf_settings.lua"):read("*a")
    local body = src:match("function Settings:_pickColor%(.-\nend\n")
    assert(body, "could not find _pickColor")
    assert(body:find("local night = _isNight()", 1, true), "the picker must ask which slot it edits")
    assert(body:find("Color.invertValue(raw)", 1, true), "the shown colour must be the displayed one")
    assert(body:find("if night then stored = Color.invertValue(stored) end", 1, true),
        "a night pick must be stored pre-inverted")
end)

t.test("the hero and list bars take the current mode's picked colours", function()
    for _i, f in ipairs({ "lib/bookshelf_hero_card.lua", "lib/bookshelf_list_row.lua" }) do
        local src = io.open(f):read("*a")
        assert(src:find("pickedBarColors()", 1, true), f .. " must use CoverProgress.pickedBarColors")
        assert(not src:find('BookshelfSettings.read("progress_fill")', 1, true),
            f .. " reads the day key directly again")
    end
end)

t.done()
