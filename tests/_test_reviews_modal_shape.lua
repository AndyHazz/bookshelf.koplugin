-- tests/_test_reviews_modal_shape.lua
-- SOURCE-SHAPE checks for the book-detail popup (issue 338 #1 and #2).
--
-- bookshelf_reviews_modal.lua needs the full widget stack to load, so these
-- read the source -- named as such, per the repo's convention. The behaviour
-- itself was driven offscreen (footer order, the at-top yield, the swipe
-- closing the modal); what these pin is that nobody quietly reverts the
-- decisions. Comment lines are stripped first so prose quoting the patterns
-- cannot satisfy a check.

package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()

local src
do
    local code = {}
    for line in io.lines("lib/bookshelf_reviews_modal.lua") do
        if not line:match("^%s*%-%-") then code[#code + 1] = line end
    end
    src = table.concat(code, "\n")
end

t.test("the Reviews tab's scroller yields swipe-down at the top", function()
    -- The Reviews tab body is built in bookshelf_widget.lua, not the modal,
    -- and its first version used a raw ScrollHtmlWidget -- whose stock
    -- onScrollText claims every south swipe even at the top, so swipe-down
    -- close (issue 338) worked on every tab except Reviews. Pin that the
    -- builder routes through modal:_scroller, the yielding factory.
    local f = io.open("lib/bookshelf_widget.lua", "r")
    assert(f, "cannot read bookshelf_widget.lua")
    local wsrc = f:read("*a")
    f:close()
    local i = wsrc:find("function BookshelfWidget:_buildReviewsTab", 1, true)
    assert(i, "_buildReviewsTab went missing")
    local j = wsrc:find("\nend", i, true) or #wsrc
    local body = wsrc:sub(i, j)
    assert(body:find("modal:_scroller(", 1, true),
        "_buildReviewsTab must build its scroller through modal:_scroller")
end)

t.test("Open leads the row and Close holds the far-right corner", function()
    -- Issue 338 #2 was a straight SWAP of the original Close-left/Open-right
    -- row: ImageViewer, the cover viewer and the description viewer all put
    -- Close at the bottom-RIGHT, and a reader trained by those kept opening
    -- the book when they meant to close. Order in the row spec IS the
    -- on-screen order.
    local close = src:find('text = _("Close"),', 1, true)
    local zoom  = src:find("ZOOM_IN_GLYPH,", 1, true)
    local open  = src:find('text = _("Open"),', 1, true)
    assert(close and zoom and open, "a footer button went missing")
    assert(open < zoom, "Open must sit BEFORE the zoom controls")
    assert(zoom < close, "Close must hold the far-right corner")
end)

t.test("the HTML bodies are built through the yielding scroller", function()
    -- Issue 338 #1: ScrollHtmlWidget's own onScrollText claims EVERY south
    -- swipe, even at page 1 where the scroll is a no-op -- so swipe-down over
    -- the body never reached the modal. _scroller overrides that one branch.
    assert(src:find("function ReviewsModal:_scroller"),
        "the _scroller wrapper is gone or was renamed")
    assert(not src:find("= ScrollHtmlWidget:new{", 1, true),
        "a body scroller bypasses _scroller and will swallow swipe-down at "
        .. "the top")
    local body = src:match("function ReviewsModal:_scroller(.-)\nend\n")
    assert(body:find("page_number <= 1", 1, true),
        "the yield must be gated on being AT THE TOP -- mid-document a "
        .. "swipe-down is a scroll, not a close")
    assert(body:find('"south"', 1, true) and not body:find('"north"', 1, true),
        "only south yields; an at-the-end north close would fire while "
        .. "someone reads the last page")
end)

t.test("the modal closes on the swipe-down that reaches it", function()
    local swipe = src:match("function ReviewsModal:onSwipe(.-)\nend\n")
    assert(swipe, "onSwipe is gone or was renamed")
    local pass  = swipe:find("_tryPassthrough", 1, true)
    local south = swipe:find('dir == "south"', 1, true)
    assert(south, "onSwipe must handle south")
    assert(pass and pass < south,
        "the reserved-zone passthrough must be asked BEFORE the close, or a "
        .. "right-edge brightness swipe starts dismissing the popup")
    assert(swipe:find("onClose", 1, true), "south must close")
end)

t.done()
