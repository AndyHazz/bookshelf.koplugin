-- tests/_test_shelf_module.lua
-- The Shelf micro-module: one of the reader's own shelves, shown in a grid
-- cell in that shelf's style. Its pure decisions: which shelves it can show
-- (books, not groups), its heading, how many rows a cell holds, and that
-- folder cards are left out.
package.path = "./?.lua;./?/init.lua;" .. package.path
package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }
package.loaded["ffi/util"] = { template = function(s) return s end }
package.loaded["logger"] = { dbg = function() end, info = function() end,
    warn = function() end, err = function() end }

local M = dofile("micromodules/shelf.lua")
local H = M._test
local t = dofile("tests/_helpers.lua").runner()

t.test("shelves of books are offered; groups and shelves of shelves are not", function()
    assert(H.isBookShelf({ id = "home", source = { kind = "all" } }))
    assert(H.isBookShelf({ id = "c", source = { kind = "collection", id = "Faves" } }))
    assert(H.isBookShelf({ id = "r", source = { kind = "recent" } }))
    for _i, k in ipairs({ "series", "authors", "genres", "tags", "formats", "ratings", "languages" }) do
        assert(not H.isBookShelf({ id = k, source = { kind = k } }), k .. " should be left out")
    end
    assert(not H.isBookShelf({ id = "s", source = { kind = "shelves" } }), "shelf of shelves")
    assert(not H.isBookShelf(nil))
end)

t.test("the heading defaults to the shelf's name, and can be renamed", function()
    assert(H.headingText(nil, { label = "Want to read" }) == "Want to read")
    assert(H.headingText("", { label = "Want to read" }) == "Want to read", "empty text means default")
    assert(H.headingText("Next up", { label = "Want to read" }) == "Next up")
end)

t.test("rows: as many as fit at a readable height, at most four", function()
    assert(H.rowsFor(175, 200) == 1, "a 1-row cell")
    assert(H.rowsFor(600, 200) == 3)
    assert(H.rowsFor(5000, 200) == 4)
    assert(H.rowsFor(50, 200) == 1, "never zero")
end)

t.test("folder cards are left out", function()
    local out = H.booksOnly({
        { kind = "folder", path = "/b/x" },
        { filepath = "/b/a.epub", title = "A" },
        { filepath = "/b/b.epub", title = "B" },
    })
    assert(#out == 2 and out[1].title == "A")
end)

t.test("online (OPDS) shelves are left out: a card never fetches on its own", function()
    assert(not H.isBookShelf({ id = "ia", source = { kind = "opds" } }))
end)

t.test("the default heading is the shelf's label, icons and all", function()
    -- Drawn like the chip (lib/bookshelf_chip_bar.buildLabel), so a label's
    -- [icon=NAME] pictures and icon glyphs show in the heading too.
    assert(H.headingText(nil, { label = "Home[icon=tab_manga]" }) == "Home[icon=tab_manga]")
end)

t.test("the shelf picker's plain-text buttons leave out picture markup only", function()
    assert(H.plainLabel("Home[icon=tab_manga]") == "Home")
    assert(H.plainLabel("[icon=x] Faves") == "Faves")
    assert(H.plainLabel("\xEE\xAC\xB0 Faves") == "\xEE\xAC\xB0 Faves", "glyphs stay: the dialog can draw them")
    assert(H.plainLabel("[icon=x]") == nil, "nothing left: let the caller fall back")
end)

t.test("a folder shelf shows its books flattened, not its folder cards", function()
    -- Home with folders (kind "all") on a fresh install is genre folders and
    -- no loose books: as a card it showed "No books on this shelf".
    local s = H.bookSource({ kind = "all" })
    assert(s.kind == "library", s.kind)
    s = H.bookSource({ kind = "folder", id = "/books/Comics" })
    assert(s.kind == "folder_flat" and s.id == "/books/Comics")
    local c = { kind = "collection", id = "Faves" }
    assert(H.bookSource(c) == c, "other kinds pass through")
end)

t.done()
