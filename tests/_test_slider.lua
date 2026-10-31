-- tests/_test_slider.lua
-- The slider (lib/bookshelf_slider.lua): a value on a track, set by a tap
-- anywhere on it or a drag (saved when the finger lifts, not on every move:
-- each change redraws a preview on e-ink), fine steps on - and +. Its maths:
-- where a value sits on the track and which value a point on it is,
-- snapped to the step and kept in range.
--
-- Usage (from plugin root): lua tests/_test_slider.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq
local Slider = dofile("lib/bookshelf_slider.lua")

local pct = { min = 50, max = 200, step = 5 }

t.test("a value snaps to the step and stays in range", function()
    eq(Slider.snap(123, pct), 125)
    eq(Slider.snap(122, pct), 120)
    eq(Slider.snap(10, pct), 50)
    eq(Slider.snap(999, pct), 200)
end)

t.test("fractional steps (an ornament's size) snap without float noise", function()
    local f = { min = 0.5, max = 2, step = 0.05 }
    eq(Slider.snap(1.234, f), 1.25)
    eq(Slider.snap(0.1 + 0.2, f), 0.5)
end)

t.test("a point on the track is a value, and back", function()
    eq(Slider.valueAt(0, 300, pct), 50)
    eq(Slider.valueAt(300, 300, pct), 200)
    eq(Slider.valueAt(100, 300, pct), 100)
    eq(Slider.valueAt(-40, 300, pct), 50, "past the start is the minimum")
    eq(Slider.xOf(100, 300, pct), 100)
    eq(Slider.xOf(200, 300, pct), 300)
end)

t.test("the ticks: the range's ends and Default, in order, without repeats", function()
    eq(table.concat(Slider.ticks{ min = 50, max = 200, default = 100 }, " "), "50 100 200")
    eq(table.concat(Slider.ticks{ min = 50, max = 200, default = 50 }, " "), "50 200")
end)

t.test("a page's slider block, and the nudge page uses it", function()
    local ep = io.open("lib/bookshelf_editor_page.lua"):read("*a")
    assert(ep:find("function R.slider(ctx, b)", 1, true), "no slider block")
    local st = io.open("lib/bookshelf_settings.lua"):read("*a")
    local nudge = st:match("\nfunction Settings:_nudgePage%(.-\nend\n")
    assert(nudge:find('type = "slider"', 1, true), "the nudge page has no slider")
    assert(nudge:find("at_bottom = true", 1, true), "the nudge page is not a slim panel at the bottom")
end)

-- Maintainer, PW5: the knob dragged with a "fast" refresh, which is black
-- and white only, so the grey track broke up and left ghosts behind it.
t.test("a drag redraws the track with a ui refresh, not fast", function()
    local src = io.open("lib/bookshelf_slider.lua"):read("*a")
    assert(not src:find('return "fast"', 1, true), "the drag still refreshes fast")
    assert(src:find('UIManager:setDirty(top, function() return "ui", track.dimen end)', 1, true), "the drag does not refresh ui")
end)

-- Maintainer: a hollow knob, a thicker track, in the reader's own
-- progress bar colours (Colors > Progress bar), as the hero's bar has them.
t.test("the track takes the reader's picked bar colours, else black on light grey", function()
    local D = { fill = "black", track = "lightgray" }
    local f, tr = Slider.colors(nil, D)
    eq(f, "black"); eq(tr, "lightgray")
    f, tr = Slider.colors({ fill = "red" }, D)
    eq(f, "red"); eq(tr, "lightgray", "an unpicked track keeps its default")
    f, tr = Slider.colors({ fill = "red", bg = "pink" }, D)
    eq(f, "red"); eq(tr, "pink")
    local src = io.open("lib/bookshelf_slider.lua"):read("*a")
    assert(src:find("Slider.colors(CP.pickedBarColors(),", 1, true),
        "the slider does not read the picked bar colours")
end)

t.test("the knob is a ring, the track thicker", function()
    local src = io.open("lib/bookshelf_slider.lua"):read("*a")
    local paint = src:match("function track:paintTo%(bb, x, y%)(.-)\n    end\n")
    assert(paint, "no track paint")
    assert(paint:find("knob(bb, kx, cy, r, fill)", 1, true), "the knob's ring is not the fill colour")
    assert(paint:find("knob(bb, kx, cy, r - ring, Blitbuffer.COLOR_WHITE)", 1, true), "the knob is not hollow")
    assert(src:find("local bar_h = math.max(4, Space.px(12))", 1, true), "the track is not thicker")
end)

-- Maintainer: the value in the heading, not on a row of its own above the
-- bar, for a tighter panel. The nudge page's title carries it (a PageDialog
-- title may be a function, read on every refresh) and the slider block
-- leaves its value row out (no_value).
t.test("the size page shows its value in the title, not over the bar", function()
    local pd = io.open("lib/bookshelf_page_dialog.lua"):read("*a")
    assert(pd:find("function PageDialog:_titleText()", 1, true), "a title cannot be a function")
    assert(pd:find("title = self:_titleText(),", 1, true), "the title bar does not read it afresh")
    local st = io.open("lib/bookshelf_settings.lua"):read("*a")
    local nudge = st:match("\nfunction Settings:_nudgePage%(.-\nend\n")
    assert(nudge:find("title = function() return spec.title .. \": \" .. show(getValue()) end,", 1, true),
        "the title does not carry the value")
    assert(nudge:find("no_value = true", 1, true), "the value still has its own row")
    local ep = io.open("lib/bookshelf_editor_page.lua"):read("*a")
    local r = ep:match("\n(function R%.slider%(ctx, b%).-\nend)\n")
    assert(r and r:find("if b.no_value and not b.label then return w end", 1, true), "the slider block always has a value row")
end)

t.done()
