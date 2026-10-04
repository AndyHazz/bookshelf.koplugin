-- tests/_test_list_footer_rule.lua
-- In list mode the footer gets a hairline where its panel would have been.
--
-- WHAT NEEDS PINNING. Over a ground in list mode the shelf draws ONE scrim
-- panel from the top of the content down through the footer, and suppresses
-- the footer's own scrim so the area is not tinted twice. That leaves the
-- footer glyphs sitting in an unbroken surface with nothing to sit against,
-- which reads as misaligned rather than as a bar. The full-screen micro
-- module hit this first and solved it with a rule along the top of the footer
-- band rather than by splitting the panel back into two objects; the shelf
-- now does the same, and the two must stay matched in colour and thickness
-- (maintainer: "like we did with the full screen micro module panel").
--
-- Geometry comes from footerPanelRect, the same source the panel itself uses,
-- so the rule cannot drift from the edge it is standing in for.
--
-- Usage (from plugin root): lua tests/_test_list_footer_rule.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()
local eq = helpers.eq
local widget = io.open("lib/bookshelf_widget.lua"):read("*a")
local micro  = io.open("lib/bookshelf_micro_fullscreen.lua"):read("*a")

-- The override lives in BookshelfWidget:_attachTopPanel, which both the
-- shelf and the empty-chip branch call (issue 423).
local paint = widget:match("(vgroup%.paintTo = function%(slf, bb, x, y%).-\n    end\n)")
assert(paint, "the list-mode panel paint override moved")
local code = paint:gsub("%-%-[^\n]*", "")

t.test("a 1px gap, not a rule, where the panel swallowed the footer", function()
    -- Maintainer, 2026-10-04: "instead of the hairline divider ... a 1px full
    -- width gap that shows the background through".
    assert(code:find("list_full", 1, true), "the gap belongs to the full-panel branch")
    assert(not code:find("paintRect", 1, true), "the hairline rule is still painted")
    assert(code:find("rule_y = fy", 1, true), "the gap's row must come straight from footerPanelRect")
    local r = code:match("Wallpaper%.restoreBare%((.-)%)")
    assert(r and r:find("rule_y", 1, true) and r:find("w2", 1, true) and r:find("1", 1, true),
        "the gap is not the picture put back, one pixel high, across the panel")
    assert(code:find("setPanel(px, py, w2, h2, ground, strength, radius, rule_y)", 1, true),
        "restore is not told about the gap, so a later repaint would tint it again")
end)

-- The registered gap: a repaint over it puts the picture back untinted.
t.test("restore leaves the panel's gap row untinted", function()
    package.loaded["logger"] = package.loaded["logger"] or
        { dbg = function() end, info = function() end, warn = function() end, err = function() end }
    package.loaded["lib/bookshelf_wallpaper"] = nil
    local W = dofile("lib/bookshelf_wallpaper.lua")
    local tinted = {}
    W.scrim = function(_bb, x, y, w, h) tinted[#tinted + 1] = { y = y, h = h } end
    W._bg = { w = 100, h = 100, bb = {} }
    local target = { getWidth = function() return 100 end, getHeight = function() return 100 end,
                     blitFrom = function() end }
    W.setPanel(0, 0, 100, 100, 0xFF, 0.85, 0, 50)
    W.restore(target, 0, 40, 100, 20)          -- rows 40..59, across the gap at 50
    local rows = {}
    for _i, r in ipairs(tinted) do for y = r.y, r.y + r.h - 1 do rows[y] = true end end
    assert(rows[49] and rows[51], "the panel either side of the gap was not tinted again")
    assert(not rows[50], "the gap row was tinted")
end)

t.test("restoreBare puts the picture back without tinting it, whatever panel is registered", function()
    package.loaded["lib/bookshelf_wallpaper"] = nil
    local W = dofile("lib/bookshelf_wallpaper.lua")
    local tinted, blits = 0, 0
    W.scrim = function() tinted = tinted + 1 end
    W._bg = { w = 100, h = 100, bb = {} }
    local target = { getWidth = function() return 100 end, getHeight = function() return 100 end,
                     blitFrom = function() blits = blits + 1 end }
    W.setPanel(0, 0, 100, 100, 0xFF, 0.85, 0)
    eq(W.restoreBare(target, 0, 50, 100, 1), true)
    eq(blits, 1); eq(tinted, 0, "the bare row was tinted")
    assert(W._panel, "restoreBare dropped the registered panel")
end)

t.test("the micro-module view: the same 1px gap in its panel, no hairline rule", function()
    local m = micro:gsub("%-%-[^\n]*", "")
    assert(not m:find("footer_rule", 1, true), "the micro-module view still draws its footer rule")
    local paint = m:match("function panel:paintTo%(b%)(.-)\n                end")
    assert(paint, "the micro-module panel paint moved")
    assert(paint:find("Wallpaper.scrim(", 1, true), "the panel is no longer painted")
    local r = paint:match("Wallpaper%.restoreBare%((.-)%)")
    assert(r and r:find("gap_y", 1, true) and r:find("pw", 1, true), "no 1px gap across the panel")
end)

t.done()
