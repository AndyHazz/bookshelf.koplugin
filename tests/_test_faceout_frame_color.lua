-- tests/_test_faceout_frame_color.lua
-- A face-out on the spine shelf frames in the theme's own border, not the
-- user's Border color (maintainer ruling): there the cover is the front board
-- of a book drawn with its page block and boards, and a chosen colour (white,
-- on a pastel theme) outlined it as a card stood in front of the book. Every
-- other view, and the badges on the face-out itself, keep the setting.
--
-- Usage (from plugin root): lua tests/_test_faceout_frame_color.lua

package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local widget_src = io.open("lib/bookshelf_spine_widget.lua"):read("a")
local cp_src     = io.open("lib/bookshelf_cover_progress.lua"):read("a")

-- The helper itself, pulled out by name so it runs without the widget's deps.
local body = widget_src:match("(function SpineWidget:_frameColor%(colors%).-\nend\n)")
assert(body, "SpineWidget:_frameColor is missing")
local SpineWidget = {}
assert(load("local SpineWidget = ...\n" .. body))(SpineWidget)

local colors = { border = "USER", border_default = "THEME" }

t.test("a spine-shelf face-out frames in the theme's border", function()
    eq(SpineWidget._frameColor({ spine_face_out = true }, colors), "THEME")
end)

t.test("every other card keeps the user's Border color", function()
    eq(SpineWidget._frameColor({}, colors), "USER")
end)

t.test("a palette without the default falls back to the setting", function()
    eq(SpineWidget._frameColor({ spine_face_out = true }, { border = "USER" }), "USER")
end)

t.test("the palette resolves the default per theme, through _paint", function()
    assert(cp_src:match("border_default%s*=%s*_paint%(is_night and NIGHT_DEFAULT_BORDER"),
        "border_default is not the themed default")
end)

t.test("the cover card and the coverless card both use it", function()
    local wrap = widget_src:match("function SpineWidget:_wrapCoverInCard.-\nend\n")
    assert(wrap and wrap:match("cover_args%.border_color = self:_frameColor%(c%)"),
        "the cover card ignores the face-out frame colour")
    local fb = widget_src:match("function SpineWidget:_renderFallback%(%).-\nfunction ")
    assert(fb, "_renderFallback not found")
    assert(not fb:match("color%s*=%s*colors%.border,"),
        "a coverless card still frames in the raw Border color")
    assert(fb:match("self:_frameColor%(colors%)"), "the coverless card ignores it")
end)

t.done()
