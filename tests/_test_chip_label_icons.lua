-- tests/_test_chip_label_icons.lua
-- SVG/PNG icons in shelf labels (GitHub issue 469): the icon picker offers the
-- SVG icon folder for a shelf's label, and the shelf bar draws "[icon=NAME]"
-- as that image. Rendering is checked on the rig; this pins the wiring.
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t = H.runner()
local bar = io.open("lib/bookshelf_chip_bar.lua"):read("*a")
local editor = io.open("lib/bookshelf_chip_editor.lua"):read("*a")

t.test("the shelf label's icon picker offers the SVG icon folder", function()
    assert(editor:find("end, { dynamic = false, svg = true })", 1, true), "no SVG folder for shelf labels")
end)

t.test("an image segment is drawn, sized, and coloured as the label", function()
    local seg = bar:match("local function _imageSegment%(name, size, ink, inverted%)(.-)\nend\n")
    assert(seg, "no _imageSegment")
    assert(seg:find("iconHasColour", 1, true), "coloured icons are not told apart")
    assert(seg:find("Wallpaper.mask(true, icon, ink)", 1, true), "line art does not take the label's ink")
    assert(seg:find("notice%-warning", 1, true), "a missing file is not told from KOReader's warning-icon fallback (it should draw nothing)")
    local build = bar:match("local function _buildLabelContent%(label, size, max_w, ink, inverted, own_case%)(.-)\nend\n")
    assert(build and build:find('seg.class == "image"', 1, true), "the label builder skips image segments")
    local measure = bar:match("local function _measureLabel%(label, size%)(.-)\nend\n")
    assert(measure and measure:find("_iconSide(size)", 1, true), "an icon's width is not counted")
    assert(bar:find("is_active and not is_cursor_pre and not has_custom)", 1, true),
        "the chip does not say when it inverts (a coloured icon would come out inverted)")
end)

t.done()
