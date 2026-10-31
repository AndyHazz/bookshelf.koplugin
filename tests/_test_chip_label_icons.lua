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
    local build = bar:match("local function _buildLabelContent%(label, size, max_w, ink, inverted, own_case, face%)(.-)\nend\n")
    assert(build and build:find('seg.class == "image"', 1, true), "the label builder skips image segments")
    local measure = bar:match("local function _measureLabel%(label, size%)(.-)\nend\n")
    assert(measure and measure:find("_iconSide(size)", 1, true), "an icon's width is not counted")
    assert(bar:find("is_active and not has_custom)", 1, true),
        "the chip does not say when it inverts (a coloured icon would come out inverted)")
end)

-- PW5, 2026-10-31: opening a folder on a shelf named "[icon=NAME] Home"
-- crashed KOReader: the breadcrumb's pill builds the label with no width
-- (arrowPillFrame passes nil) and the mixed branch did max_w - icon_w.
t.test("a mixed label with no width limit is not an error", function()
    local build = bar:match("local function _buildLabelContent%(label, size, max_w, ink, inverted, own_case, face%)(.-)\nend\n")
    assert(build and build:find("local text_budget = max_w and math.max(0, max_w - icon_w)", 1, true),
        "nil max_w is arithmetic on nil")
end)

-- PW5, 2026-10-31: the folder's own crumb (Comedy) sits on the top panel,
-- but took the page's ink unless the bar was transparent: black on the
-- Sewing Room's dark panel. The panel's ink comes first, as the footer's.
t.test("the deepest crumb takes the panel's ink", function()
    local i = bar:find("-- Plain-text widget for the deepest crumb", 1, true)
    local body = bar:sub(i, bar:find("deepest_w = deepest_widget:getSize().w", i, true))
    assert(body:find("(CP.panelInk and CP.panelInk()) or _panelChipInk() or CP.ink()", 1, true),
        "the crumb on the panel ignores the panel's ink")
end)

t.done()
