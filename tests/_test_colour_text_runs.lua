-- tests/_test_colour_text_runs.lua
-- A single line of text in which some runs (the rating stars) take a colour
-- of their own. The line is drawn glyph by glyph, so each glyph takes the
-- colour of the run its character falls in, or the line's ink.
--
-- Usage (from plugin root): lua tests/_test_colour_text_runs.lua
package.path = "./?.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()

local function color8(v) return { a = v, kind = "c8" } end
local INK, GOLD = color8(0), { kind = "rgb", name = "gold" }

local base_paints
local function load()
    base_paints = 0
    local TextWidget = {}
    TextWidget.__index = TextWidget
    function TextWidget:extend(o) o = o or {}; o.__index = o; return setmetatable(o, self) end
    function TextWidget:paintTo() base_paints = base_paints + 1 end
    function TextWidget:updateSize() end
    package.loaded["ui/widget/textwidget"] = TextWidget
    package.loaded["ffi/blitbuffer"] = {
        isColor8 = function(c) return type(c) == "table" and c.kind == "c8" end,
        COLOR_BLACK = INK,
        TYPE_BBRGB32 = 5,
    }
    package.loaded["ui/rendertext"] = {
        getGlyphByIndex = function(_s, _face, glyph_id)
            return { l = 0, t = 0, bb = { id = glyph_id,
                getWidth = function() return 8 end, getHeight = function() return 8 end } }
        end,
    }
    package.loaded["ui/font_color"] = nil
    package.loaded["lib/common"] = nil
    package.loaded["lib/bookshelf_colour_runs"] = dofile("lib/bookshelf_colour_runs.lua")
    package.loaded["lib/bookshelf_colour_text"] = nil
    return dofile("lib/bookshelf_colour_text.lua")
end

-- Five glyphs, characters 1..5, 10px apart.
local function widget(CT, fg, runs)
    local shaping = {}
    for i = 1, 5 do
        shaping[i] = { text_index = i, glyph = i, font_num = 0, x_advance = 10, x_offset = 0, y_offset = 0 }
    end
    return setmetatable({
        fgcolor = fg, runs = runs, use_xtext = true, _xshaping = shaping, _baseline_h = 12,
        face = { getFallbackFont = function() return {} end },
    }, { __index = CT })
end

local function target(kind)
    local grey, rgb = {}, {}
    return {
        getType = function() return kind end,
        getWidth = function() return 1000 end,
        colorblitFrom = function(_s, src, x, _y, _ox, _oy, _w, _h, c)
            grey[#grey + 1] = { id = src.id, x = x, c = c } end,
        colorblitFromRGB32 = function(_s, src, x, _y, _ox, _oy, _w, _h, c)
            rgb[#rgb + 1] = { id = src.id, x = x, c = c } end,
    }, grey, rgb
end

-- The colour-buffer type name the module checks for.
local COLOUR_KIND = 5   -- Blitbuffer.TYPE_BBRGB32

t.test("on a colour screen the run's glyphs are drawn in its colour, the rest in the ink", function()
    local CT = load()
    local w = widget(CT, INK, { { s = 2, e = 3, colour = GOLD } })
    local bb, grey, rgb = target(COLOUR_KIND)
    w:paintTo(bb, 100, 0)
    assert(base_paints == 0, "the one-ink base paint ran")
    assert(#rgb == 2, "run glyphs in colour: " .. #rgb)
    assert(rgb[1].id == 2 and rgb[2].id == 3)
    assert(rgb[1].c == GOLD and rgb[2].c == GOLD)
    assert(rgb[1].x == 110 and rgb[2].x == 120, "each at its own place on the line")
    assert(#grey == 3, "ink glyphs: " .. #grey)
    assert(grey[1].id == 1 and grey[2].id == 4 and grey[3].id == 5)
    assert(grey[1].c == INK)
end)

t.test("on a greyscale screen every glyph goes through the grey blit, the run in its own value", function()
    local CT = load()
    local w = widget(CT, INK, { { s = 4, e = 5, colour = GOLD } })
    local bb, grey, rgb = target(1)
    w:paintTo(bb, 0, 0)
    assert(#rgb == 0)
    assert(#grey == 5)
    assert(grey[4].c == GOLD and grey[5].c == GOLD and grey[3].c == INK)
end)

t.test("no runs: the line paints exactly as before", function()
    local CT = load()
    local w = widget(CT, INK, nil)
    local bb, grey, rgb = target(COLOUR_KIND)
    w:paintTo(bb, 0, 0)
    assert(base_paints == 1 and #grey == 0 and #rgb == 0)
    w = widget(CT, INK, {})
    w:paintTo(bb, 0, 0)
    assert(base_paints == 2)
end)

t.test("without advanced text shaping the line is drawn in its one ink", function()
    local CT = load()
    local w = widget(CT, INK, { { s = 2, e = 3, colour = GOLD } })
    w.use_xtext = false
    local bb, grey, rgb = target(COLOUR_KIND)
    w:paintTo(bb, 0, 0)
    assert(base_paints == 1 and #grey == 0 and #rgb == 0)
end)

t.test("glyphs past the width the line was given are not drawn", function()
    local CT = load()
    local w = widget(CT, INK, { { s = 1, e = 5, colour = GOLD } })
    w.max_width = 25
    local bb, _grey, rgb = target(COLOUR_KIND)
    w:paintTo(bb, 0, 0)
    assert(#rgb == 3, "drew " .. #rgb)
end)

t.done()
