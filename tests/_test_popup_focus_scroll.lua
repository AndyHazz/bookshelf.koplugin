-- tests/_test_popup_focus_scroll.lua
-- The book popup: the keys reached rows below the fold of its scrolling Edit
-- tab with no way to see them (maintainer, desktop). A key that focuses a
-- body row partly out of the scroll's view scrolls it in, by as little as
-- that takes.
--
-- Usage (from plugin root): lua tests/_test_popup_focus_scroll.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq

local src = io.open("lib/bookshelf_reviews_modal.lua"):read("*a")
local body = src:match("\n(function ReviewsModal:_scrollFocusIntoView%(%).-\nend)\n")
assert(body, "no _scrollFocusIntoView")

local function run(item_y, item_h, sel_y)
    local env = setmetatable({ ReviewsModal = {}, Space = { px = function(v) return v end } }, { __index = _G })
    assert(load(body, "s", "t", env))()
    local scrolled
    local m = setmetatable({
        _focus_scroll = { _is_scrollable = true, dimen = { y = 100, h = 300 },
                          _scrollBy = function(_s, _dx, dy) scrolled = dy end },
        _body_rows = { from = 2, to = 5 },
        selected = { x = 1, y = sel_y or 3 },
        layout = { {}, {}, { { dimen = { y = item_y, h = item_h } } }, {}, {}, {} },
    }, { __index = env.ReviewsModal })
    m:_scrollFocusIntoView()
    return scrolled
end

t.test("a row below the fold scrolls up into view, with a margin", function()
    eq(run(380, 60), 52)          -- bottom 440 against 400, +12
end)

t.test("a row above the view scrolls back down", function()
    eq(run(70, 60), -42)          -- top 70 against 100, -12
end)

t.test("a row in view, or not a body row (tabs, footer), leaves it", function()
    eq(run(150, 60), nil)
    eq(run(380, 60, 6), nil)
end)

t.test("each key move brings the focus into view", function()
    assert(src:find("function ReviewsModal:onFocusMove(args)\n    local r = FocusManager.onFocusMove(self, args)\n    self:_scrollFocusIntoView()", 1, true),
        "the move does not scroll")
    local w = io.open("lib/bookshelf_widget.lua"):read("*a")
    assert(w:find("out.focus_scroll = scroll", 1, true), "the Edit tab does not name its scroll")
end)

t.done()
