-- tests/_test_footer_slots.lua
-- lib/bookshelf_footer_slots.lua: how the footer's nav strip is divided.
--
-- The five footer buttons (first, prev, page counter, next, last) used to
-- take fixed shares of the strip. The counter's share did not depend on the
-- counter, so a long range in a wide UI font -- "200-235 of 248" at a large
-- DPI -- overflowed its slot and the Button wrapped it onto two lines, while
-- the four chevrons sat in slots several times wider than their icons.
--
-- The rule this pins: the counter is measured at its WIDEST POSSIBLE value
-- for the shelf, not its current one, so the buttons hold still while you
-- page. Space it needs beyond the default share is borrowed equally from the
-- four chevrons, which keeps them symmetric about the centre.
--
-- Usage (from plugin root): lua tests/_test_footer_slots.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

local H  = dofile("tests/_helpers.lua")
local t  = H.runner()
local eq = H.eq

local FS = require("lib/bookshelf_footer_slots")

local STRIP = 1000
local FLOOR = 60

t.test("slots: a counter that fits keeps the standard split", function()
    local s = FS.widths(STRIP, 100, FLOOR)
    eq(s.edge, 180)
    eq(s.step, 180)
    eq(s.page, 280)
end)

t.test("slots: a counter needing exactly its share does not disturb anything", function()
    local s = FS.widths(STRIP, 280, FLOOR)
    eq(s.page, 280)
    eq(s.edge, 180)
end)

t.test("slots: a wider counter borrows equally from the four chevrons", function()
    -- 120 more than the default share, taken as 30 from each chevron slot.
    local s = FS.widths(STRIP, 400, FLOOR)
    eq(s.page, 400)
    eq(s.edge, 150)
    eq(s.step, 150)
    eq(s.edge * 2 + s.step * 2 + s.page, STRIP)
end)

t.test("slots: the chevrons stay equal, so the buttons keep their spacing", function()
    for _, need in ipairs({ 50, 280, 400, 700, 5000 }) do
        local s = FS.widths(STRIP, need, FLOOR)
        assert(s.edge == s.step,
            "chevron slots diverged at need=" .. need
            .. ": edge=" .. s.edge .. " step=" .. s.step)
    end
end)

t.test("slots: the chevrons never shrink past their floor", function()
    -- A counter greedy enough to swallow the strip still leaves each chevron
    -- a tappable slot; the counter takes what is left and shrinks its own
    -- text instead.
    local s = FS.widths(STRIP, 5000, FLOOR)
    eq(s.edge, FLOOR)
    eq(s.step, FLOOR)
    eq(s.page, STRIP - 4 * FLOOR)
end)

t.test("slots: the split always fills the strip exactly, never over", function()
    for _, need in ipairs({ 0, 1, 99, 280, 281, 333, 700, 999, 1000, 4000 }) do
        for _, strip in ipairs({ 997, 1000, 1001, 1234 }) do
            local s = FS.widths(strip, need, FLOOR)
            local total = s.edge * 2 + s.step * 2 + s.page
            assert(total <= strip,
                "overflowed at need=" .. need .. " strip=" .. strip
                .. ": " .. total)
            assert(strip - total < 4,
                "wasted more than rounding at need=" .. need
                .. " strip=" .. strip .. ": " .. (strip - total))
        end
    end
end)

t.test("slots: a degenerate strip yields nothing rather than negatives", function()
    local s = FS.widths(0, 400, FLOOR)
    assert(s.edge >= 0 and s.step >= 0 and s.page >= 0,
        "negative slot width")
    local s2 = FS.widths(100, 400, FLOOR)  -- floors alone exceed the strip
    assert(s2.page >= 0, "negative page slot")
    assert(s2.edge * 2 + s2.step * 2 + s2.page <= 100, "overflowed a tiny strip")
end)

t.test("slots: the widest-value probe is what sizes the counter", function()
    -- The caller measures a probe, not the live text -- pinned here because
    -- it is the whole reason the buttons hold still. "8" is the widest digit
    -- in the faces we ship, and the range cannot exceed the total's width.
    eq(FS.probeNumber(1), 8)
    eq(FS.probeNumber(249), 888)
    eq(FS.probeNumber(1000), 8888)
    -- Degenerate totals still give something measurable.
    eq(FS.probeNumber(0), 8)
    eq(FS.probeNumber(nil), 8)
end)

t.done()
