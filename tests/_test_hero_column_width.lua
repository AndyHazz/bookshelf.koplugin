-- tests/_test_hero_column_width.lua
-- The top panel's right column ends at the content edge, like the chip bar,
-- the expanded strip, the full-screen micro-module status line and the
-- reader's status line (maintainer, 2026-10-04: the full-screen status line
-- was "slightly wider" than the top panel's). The cover frame is sw_w plus
-- ONE shadow offset (it pads left and top only); the column was sized as if
-- it were two, so it stopped one offset (7px on a PW5) short.
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t = H.runner()
local src = io.open("lib/bookshelf_hero_card.lua"):read("*a")

t.test("the right column is the width left after the cover frame as laid out", function()
    local frame = src:match("local cover_widget = FrameContainer:new{(.-)\n    }")
    assert(frame, "the cover frame moved")
    assert(frame:find("padding_left = SHADOW_OFFSET", 1, true) and not frame:find("padding_right", 1, true),
        "the cover frame's width is no longer sw_w + one SHADOW_OFFSET; recheck the column width")
    assert(src:find("local right_w = math.max(1, self.width - (sw_w + SHADOW_OFFSET) - text_padding)", 1, true),
        "the right column is not sized from the cover frame's real width")
end)

t.done()
