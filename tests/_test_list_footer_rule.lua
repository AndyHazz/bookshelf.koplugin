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
local widget = io.open("lib/bookshelf_widget.lua"):read("*a")
local micro  = io.open("lib/bookshelf_micro_fullscreen.lua"):read("*a")

-- The override lives in BookshelfWidget:_attachTopPanel, which both the
-- shelf and the empty-chip branch call (issue 423).
local paint = widget:match("(vgroup%.paintTo = function%(slf, bb, x, y%).-\n    end\n)")
assert(paint, "the list-mode panel paint override moved")
local code = paint:gsub("%-%-[^\n]*", "")

t.test("the rule is painted, and only where the panel swallowed the footer", function()
    assert(code:find("list_full", 1, true), "the rule belongs to the list-mode branch")
    assert(code:find("paintRect", 1, true), "no rule is painted")
end)

t.test("it sits on the footer panel's own top edge, from the same rect", function()
    assert(code:find("footerPanelRect", 1, true), "geometry must come from footerPanelRect")
    -- `.` spans newlines in a Lua pattern, so this reads a call that wraps.
    local rule = code:match("paintRect%((.-)%)")
    assert(rule, "could not read the rule's arguments")
    assert(rule:find("rule_y", 1, true), "the rule must sit at the footer panel's top, not a re-derived y")
    assert(code:find("rule_y = fy", 1, true),
        "the rule's height must be taken straight from footerPanelRect")
    -- Width is the CONTENT's, not the panel's. The panel bleeds past the
    -- content on both sides, so a rule spanning it overhangs the chip bar
    -- above and reads as a wider object than the bar it is aligning with
    -- (maintainer: "not full width I think the same width as the shelf menu
    -- bar"). content_w is what the chip strip and the micro module both use.
    assert(rule:find("content_w", 1, true), "the rule must be the content's width, like the chip bar")
    assert(not rule:find("rule_w", 1, true), "the panel's own width bleeds past the chip bar")
end)

t.test("colour and thickness match the micro module's rule", function()
    assert(code:find("Size.line.medium", 1, true), "thickness must match the micro module's")
    assert(code:find("Blitbuffer.gray(0.4)", 1, true), "colour must match the micro module's")
    local m = micro:gsub("%-%-[^\n]*", "")
    assert(m:find("Size.line.medium", 1, true) and m:find("Blitbuffer.gray(0.4)", 1, true),
        "the micro module's own rule changed; the pair is no longer matched")
end)

t.done()
