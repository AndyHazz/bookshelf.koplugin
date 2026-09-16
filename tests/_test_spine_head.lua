-- tests/_test_spine_head.lua
-- The head of a spine, given to the pixel by the maintainer. For a book
-- eight thick, the top two rows are:
--
--     0 1 0 0 0 0 1 0
--     1 1 2 2 2 2 1 1
--
-- 1 board, 2 pages, 0 the shadow behind the head. Read off that:
--
--   * the boards rise exactly ONE row above the paper, not a fraction of the
--     visible edge -- a fraction grew with the book's thickness, so a fat book
--     wore ears and a thin one had none;
--   * in that row only each board's INNER pixel is drawn. The outer one is
--     left unpainted, and THAT omission is the nick: over a ground the slot
--     buffer starts transparent, so the corner shows the shadow behind rather
--     than a bright chip cut out of the board;
--   * the span between the boards in that row is shadow too. It is neither
--     paper nor a filled hollow, both of which have been tried here.
--
-- Painting the nick afterwards cannot work, whatever colour it uses: the
-- board goes down first, so over a ground the cut either left the board's own
-- pixels in place or put a bright speck where the shadow should be.
--
-- Usage (from plugin root): lua tests/_test_spine_head.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()
local src = io.open("lib/bookshelf_spine_shelf.lua"):read("*a")
local head = src:match("(if edge_h > 0 then.-\n    end\n)")
assert(head, "the head block moved")

t.test("the boards rise exactly one row above the paper", function()
    assert(head:find("local lip     = hairline", 1, true),
        "the lip must be one pixel, not a fraction of the edge")
    assert(not src:find("BOARD_LIP_FRAC", 1, true),
        "the fraction should be gone, not left unused")
end)

t.test("row two: both boards at full width, beside the paper", function()
    assert(head:find("bb:paintRectRGB32(x,  top + lip, board_w, edge_h - lip, bc)", 1, true))
    assert(head:find("bb:paintRectRGB32(rx, top + lip, board_w, edge_h - lip, bc)", 1, true))
end)

t.test("row one: the inner pixel of each board, and nothing else", function()
    assert(head:find("bb:paintRectRGB32(x + nick, top, board_w - nick, lip, bc)", 1, true),
        "the left board keeps its INNER pixel, giving up the outer one")
    assert(head:find("bb:paintRectRGB32(rx,       top, board_w - nick, lip, bc)", 1, true),
        "and the right board gives up ITS outer one")
    assert(head:find("local nick = hairline", 1, true), "the nick is one pixel")
end)

t.test("nothing is painted between the boards in that row", function()
    -- A filled hollow there was tried and is wrong: the span is the shadow
    -- behind the head, which is what the 0s in the diagram are.
    assert(not head:find("spine_w - 2 * board_w, lip", 1, true),
        "the span between the boards must be left to the shadow")
    assert(not head:find("the hollow at the head", 1, true),
        "the filled-hollow attempt should be gone, not commented out")
end)

t.test("the shadow in those gaps is the recess's own gradient, reaching one row further", function()
    -- Not a flat tone painted into the slot: that was far too dark and did
    -- not match the gradient sitting right above the head (maintainer). The
    -- ramp for a book's OWN column now runs one row past its top edge, which
    -- is exactly the row the head leaves to the shadow.
    local place = src:match("(local function place%(bx, bw, tall, halo_only%).-\n                    end\n)")
    assert(place, "the recess column placement moved")
    assert(place:find("shoulder = shoulder + Screen:scaleBySize(1)", 1, true),
        "the halo must reach the head's shadow row")
    assert(place:find("if halo_only then", 1, true),
        "only a book's own column: a gap column already ramps past this")
    assert(not head:find("tone(0x50)", 1, true), "no flat shadow tone in the slot")
end)

t.test("the nick is never painted over the board afterwards", function()
    assert(not src:find("nothing to paint: the corner is already clear", 1, true),
        "the old post-hoc cut is gone")
    assert(not src:find("_boardCornerColor", 1, true),
        "and so is the darker-corner attempt")
end)

t.done()
