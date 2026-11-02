-- tests/_test_book_menu_card_cover.lua
-- The book menu's cover card, opened from a plain spine (575). A spine
-- page's records are light: they carry no has_cover, and the card read that
-- as "no cover" and drew the text placeholder. The menu's own full record
-- fills it in; the shelf's record keeps everything else.
-- Usage (from plugin root): lua tests/_test_book_menu_card_cover.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq

local src = io.open("lib/bookshelf_widget.lua"):read("*a")
local body = src:match("\nfunction BookshelfWidget%._headerCardBook%(book, fresh%)\n(.-)\nend\n")
assert(body, "BookshelfWidget._headerCardBook not found")
local f = assert((loadstring or load)("local book, fresh = ...\n" .. body))
local function cardBook(book, fresh) return f(book, fresh) end

t.test("a light spine record gains the full record's cover facts", function()
    local light = { filepath = "/b/a.epub", title = "A", status = "reading" }
    local fresh = { filepath = "/b/a.epub", has_cover = true, cover_image_path = "/c/a.jpg" }
    local b = cardBook(light, fresh)
    eq(b.has_cover, true, "spine book shown with the placeholder")
    eq(b.cover_image_path, "/c/a.jpg")
    eq(b.status, "reading")
    eq(light.has_cover, nil, "the shelf's record was changed")
end)

t.test("a record that already knows is used as it is", function()
    local full = { filepath = "/b/a.epub", has_cover = false }
    eq(cardBook(full, { has_cover = true }), full)
    local covered = { filepath = "/b/a.epub", has_cover = true }
    eq(cardBook(covered, { has_cover = true }), covered)
end)

t.test("no full record: the shelf's record", function()
    local light = { filepath = "/b/a.epub" }
    eq(cardBook(light, nil), light)
    eq(cardBook(light, light), light)
end)

t.test("the rich header's card is built from it", function()
    assert(src:find("book   = BookshelfWidget._headerCardBook(book, fresh),", 1, true))
end)

t.done()
