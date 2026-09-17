-- tests/_test_start_menu_close_ink.lua
-- The start menu's close X has to ask what colour to be.
--
-- WHAT WENT WRONG. "When shelf theme is set to light, and device is in dark
-- mode, the close icon is invisible (probably white on white)."
--
-- Right diagnosis, one layer out. The X was painted with a literal
-- COLOR_BLACK, on the reasoning that holds almost everywhere: device night
-- mode inverts the whole frame, so black paint reaches the panel as white
-- without anyone asking. It stops holding the moment the LOOK and the FRAME
-- disagree. A light shelf on an inverting panel paints its chrome
-- pre-inverted so it comes out light; a literal black beside it comes out
-- white, on a light panel.
--
-- The shelf already has the answer. _chromeInk() is what the footer's own
-- hamburger, grid and close-X take their colour from, and it covers BOTH
-- halves of the disagreement -- a dark shelf on a panel that is not
-- inverting, and a light shelf on one that is. The start menu paints the same
-- glyph in the same slot and simply was not asking.
--
-- Same for the eraser underneath: white is not a colour here, it is "rub out
-- the hamburger", and rubbing out with white on a pre-inverted panel leaves a
-- black box.
--
-- Usage (from plugin root): lua tests/_test_start_menu_close_ink.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()
local src = io.open("lib/bookshelf_start_menu.lua"):read("*a")

-- The close-X block: from its own comment down to the frame it is wrapped in.
local block = src:match("(Custom%-painted X, NOT a glyph.-local close_frame = FrameContainer)")
assert(block, "the close-X block moved or was renamed")

-- A literal is allowed as a FALLBACK, the way _glyphInk keeps one for a
-- palette that cannot be read. What must never happen is a literal reaching
-- the paint itself. These check the paint calls, not the file's vocabulary.

t.test("the strokes paint the resolved ink, never a literal", function()
    assert(block:find("_chromeInk", 1, true),
        "the X still picks its own colour; on a light shelf over an "
        .. "inverting panel that paints white on white")
    local painter = block:match("function XWidget:paintTo(.-)\n        end")
    assert(painter, "the X's painter moved")
    assert(not painter:find("Blitbuffer%."),
        "a literal colour reaches paintRect inside the X")
    local strokes = select(2, painter:gsub("stroke, stroke, ink", ""))
    assert(strokes == 2, "expected both diagonals to use the resolved ink, found " .. strokes)
end)

t.test("the eraser is the shelf's own paper, not a literal white", function()
    assert(block:find("chrome_bg", 1, true),
        "the eraser no longer resolves the shelf's paper; a literal white "
        .. "rubs out with a black box on a pre-inverted panel")
    -- The literal may only be the value it starts from, before the lookup.
    local at_lit = block:find("close_bg = Blitbuffer.COLOR_WHITE", 1, true)
    local at_res = block:find("close_bg = paper", 1, true)
        or block:find("close_bg = paper", 1, true)
    assert(at_lit and block:find("chrome_bg", 1, true) > at_lit,
        "the literal is not a fallback; it is chosen after the lookup")
end)

t.test("it asks the same question the footer does", function()
    -- One source of truth: the footer paints these same two glyphs at these
    -- same coordinates. If they ever answer differently, one of them is wrong.
    local widget = io.open("lib/bookshelf_widget.lua"):read("*a")
    local body = widget:match("function BookshelfWidget:_chromeInk%(%)(.-)\nend\n")
    assert(body, "_chromeInk moved or was renamed")
    assert(body:find("_themeFlips()", 1, true),
        "_chromeInk no longer keys off the look/frame disagreement")
    assert(body:find("CP.ink()", 1, true),
        "_chromeInk no longer resolves through the palette")
end)

t.done()
