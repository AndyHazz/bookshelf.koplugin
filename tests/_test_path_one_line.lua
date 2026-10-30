-- tests/_test_path_one_line.lua
-- The book popup's file line stays on one line (maintainer: a long path
-- wrapped onto three and squeezed the Edit tab). Folders go first, from the
-- front, so the name and the folder it is in show longest; past that the
-- name loses its start, keeping its end (the extension and any volume
-- number).
--
-- Usage (from plugin root): lua tests/_test_path_one_line.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
for _i, m in ipairs({ "ui/font", "ui/widget/textwidget", "device" }) do
    package.loaded[m] = package.loaded[m] or {}
end
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq
local M = dofile("lib/bookshelf_text_fit.lua")

local E = "\xE2\x80\xA6"
-- Characters, not bytes: the ellipsis counts as one.
local function fitsIn(n)
    return function(s) return #s:gsub("[\128-\191]", "") <= n end
end

t.test("a path that fits is left alone", function()
    eq(M.pathOneLine("Mystery/Doyle - Scarlet.epub", fitsIn(40)), "Mystery/Doyle - Scarlet.epub")
end)

t.test("folders go from the front first", function()
    eq(M.pathOneLine("Books/Mystery/Doyle/A Study in Scarlet.epub", fitsIn(36)),
       E .. "/Doyle/A Study in Scarlet.epub")
    eq(M.pathOneLine("Books/Mystery/Doyle/A Study in Scarlet.epub", fitsIn(28)),
       E .. "/A Study in Scarlet.epub")
end)

t.test("then the name loses its start, keeping the end", function()
    eq(M.pathOneLine("Mystery/A Study in Scarlet, Volume 2.epub", fitsIn(14)),
       E .. "Volume 2.epub")
end)

t.test("a long name in no folder, multi-byte letters kept whole", function()
    local out = M.pathOneLine("Les Mis\xC3\xA9rables, tome cinqui\xC3\xA8me.epub", fitsIn(15))
    eq(out, E .. "cinqui\xC3\xA8me.epub")
end)

t.test("the book popup's file line is one line, shortened this way", function()
    local src = io.open("lib/bookshelf_widget.lua"):read("*a")
    local i = src:find("local function _icon_row(glyph, text, one_line)", 1, true)
    assert(i, "the icon row takes no one-line flag")
    assert(src:find("pathOneLine(text,", i, true), "the icon row does not shorten its text")
    assert(src:find('_icon_row("\\xEF\\x80\\x96", fname, true)', 1, true),
        "the file line still wraps")
end)

t.done()
