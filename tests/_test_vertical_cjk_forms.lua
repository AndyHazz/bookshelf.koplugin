-- tests/_test_vertical_cjk_forms.lua
-- Issue 462: in a vertical (CJK) spine title, brackets are drawn upright like
-- every other glyph, so "(" and "（" stand sideways to the text. Unicode has
-- vertical presentation forms for them; the title swaps them in.
-- Run from the plugin root: lua tests/_test_vertical_cjk_forms.lua
package.path = "./?.lua;" .. package.path
local t  = dofile("tests/_helpers.lua").runner()
local eq = dofile("tests/_helpers.lua").eq
local src = io.open("lib/bookshelf_spine_shelf.lua"):read("*a")
local body = src:match("(local VERTICAL_FORMS = .-\nfunction SpineShelf%.verticalForms%(.-\nend)\n")
assert(body, "SpineShelf.verticalForms not found")
local SpineShelf = {}
assert(load("local SpineShelf = ...\n" .. body))(SpineShelf)
local V = SpineShelf.verticalForms

t.test("Latin and full-width parentheses become their vertical forms", function()
    local out = V({ "三", "(", "体", ")", "（", "上", "）" })
    eq(table.concat(out), "三︵体︶︵上︶")
end)

t.test("the other CJK brackets too; everything else is left alone", function()
    eq(table.concat(V({ "【", "书", "】", "「", "」", "《", "》" })), "︻书︼﹁﹂︽︾")
    eq(table.concat(V({ "1", "9", "8", "4", "A" })), "1984A", "Latin letters and digits stay for tate-chu-yoko")
end)

t.test("the spine applies it before grouping and after the main-title retry", function()
    local p = src:match("local function _paintVerticalCJK%(.-\nend\n")
    assert(p, "_paintVerticalCJK moved")
    local a = p:find("SpineShelf.verticalForms(_splitChars(text))", 1, true)
    local b = p:find("SpineShelf.verticalForms(_splitChars(_mainTitle(text)))", 1, true)
    assert(a and b, "both character lists must be mapped before _groupRuns")
end)

t.done()
