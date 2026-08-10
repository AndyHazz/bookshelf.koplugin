-- tests/_test_count_badge.lua
-- lib/bookshelf_count_badge: the stack-cover count pill. The layout is a
-- plain FrameContainer (stubbed); what matters is the FORMAT priority -
-- selection "K/N" always beats finished "F/N" beats the default "xN" - and
-- the hair-space typography shared with the other pills.
package.path = "./?.lua;./?/init.lua;" .. package.path

package.loaded["ui/widget/container/framecontainer"] = {
    new = function(_self, o) o.is_frame = true; return o end,
}
package.loaded["ui/widget/textwidget"] = {
    new = function(_self, o) return o end,
}
package.loaded["ui/size"] = {
    border = { thin = 1 },
    padding = { default = 4, small = 2 },
}
package.loaded["ui/font"] = { getFace = function() return {} end }
package.loaded["lib/bookshelf_fonts"] = {
    getFace = function(_self, _name, _size, _opts) return {}, true end,
}
package.loaded["device"] = {
    screen = { scaleBySize = function(_self, n) return n end },
}
package.loaded["lib/bookshelf_cover_progress"] = {
    badgeSize = function(n) return n end,
    resolvedColors = function() return { badge_bg = "BG", badge_fg = "FG" } end,
}

local CountBadge = dofile("lib/bookshelf_count_badge.lua")
local t = dofile("tests/_helpers.lua").runner()

local HAIR = "\xe2\x80\x8a"
local function textOf(badge) return badge and badge[1] and badge[1].text end

t.test("default format is multiplication-sign xN", function()
    assert(textOf(CountBadge.render(7)) == "\xc3\x97" .. HAIR .. "7")
end)

t.test("finished mode renders F/finished_total", function()
    assert(textOf(CountBadge.render(7, nil, 3, 9)) == "3" .. HAIR .. "/" .. HAIR .. "9")
end)

t.test("finished_total falls back to the visible total", function()
    assert(textOf(CountBadge.render(7, nil, 3)) == "3" .. HAIR .. "/" .. HAIR .. "7")
end)

t.test("finished 0 is valid (0/N, not the xN default)", function()
    assert(textOf(CountBadge.render(7, nil, 0, 9)) == "0" .. HAIR .. "/" .. HAIR .. "9")
end)

t.test("selection mode K/N always wins", function()
    assert(textOf(CountBadge.render(7, 2, 3, 9)) == "2" .. HAIR .. "/" .. HAIR .. "7",
        "selection beats finished mode")
end)

t.test("no badge for an empty or absent total", function()
    assert(CountBadge.render(0) == nil)
    assert(CountBadge.render(nil) == nil)
    assert(CountBadge.render(-3) == nil)
end)

t.test("the pill is a framed widget carrying the badge colours", function()
    local badge = CountBadge.render(4)
    assert(badge.is_frame)
    assert(badge.background == "BG" and badge.color == "FG")
end)

t.done()
