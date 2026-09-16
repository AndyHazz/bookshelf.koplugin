-- tests/_test_spine_head.lua
-- The head of a spine: boards, the hollow between them, and the corner nick.
--
-- WHAT NEEDS PINNING. Three faults, all reported together once the recess
-- began painting behind the head on plain grounds, which gave the eye
-- something to measure the head against (maintainer, on device).
--
--  * The strip between the raised boards, above the paper, was never painted
--    at all. The slot buffer is transparent where nothing is drawn, so over a
--    picture it showed the wallpaper and on a plain ground it showed the page:
--    a bright rectangle sitting between the boards and the shadow above them.
--    It is the hollow at the head of a bound book, so it is painted as one.
--  * The boards stood a tenth of the visible edge proud of the paper, which
--    reads as ears rather than as a cover -- the very thing the constant's own
--    comment warns about.
--  * The corner nick was one hairline, invisible at 300dpi, so the board tips
--    read as square corners instead of curving outward.
--
-- Usage (from plugin root): lua tests/_test_spine_head.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq
local src = io.open("lib/bookshelf_spine_shelf.lua"):read("*a")

t.test("the boards stand only slightly proud of the paper", function()
    local frac = tonumber(src:match("local BOARD_LIP_FRAC = ([%d%.]+)"))
    assert(frac, "BOARD_LIP_FRAC missing")
    assert(frac > 0, "the boards must still rise above the paper")
    assert(frac <= 0.08, "a tenth of the edge reads as ears, got " .. frac)
end)

t.test("the hollow between the boards is painted, not left as a hole", function()
    local head = src:match("(if edge_h > 0 then.-The boards, rising the lip)")
    assert(head, "the head block moved")
    assert(head:find("x + board_w, top, spine_w - 2 * board_w, lip", 1, true),
        "the strip above the paper and between the boards must be filled")
end)

t.test("the hollow sits between the paper and the boards in tone", function()
    -- Darker than the page block's own ground, lighter than the board, so the
    -- boards still read as standing proud of it.
    local head = src:match("(if edge_h > 0 then.-The boards, rising the lip)")
    local hollow = tonumber(head:match("spine_w %- 2 %* board_w, lip,%s*\n%s*tone%(0x(%x+)%)"), 16)
    local paper  = tonumber(head:match("sw_edge, sh_edge, tone%(0x(%x+)%)"), 16)
    assert(hollow and paper, "could not read the tones")
    assert(hollow < paper, "the hollow must be darker than the paper")
end)

t.test("the corner nick is big enough to see", function()
    local nick = src:match("local nick = math%.max%((%d+), hairline %* (%d+)%)")
    assert(nick, "the nick size is no longer stated")
    local floor, mult = src:match("local nick = math%.max%((%d+), hairline %* (%d+)%)")
    assert(tonumber(floor) >= 2 and tonumber(mult) >= 2,
        "one hairline is invisible at 300dpi")
    assert(src:find("bb:paintRectRGB32(x, top, nick, nick, g)", 1, true),
        "the left tip must use it")
    assert(src:find("bb:paintRectRGB32(x + spine_w - nick, top, nick, nick, g)", 1, true),
        "and so must the right")
end)

t.done()
