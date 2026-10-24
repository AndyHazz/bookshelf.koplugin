-- tests/_test_shelf_module.lua
-- The Shelf micro-module: one of the reader's own shelves, shown in a grid
-- cell in that shelf's style. Its pure decisions: which shelves it can show
-- (books, not groups), its heading, how many rows a cell holds, and that
-- folder cards are left out.
package.path = "./?.lua;./?/init.lua;" .. package.path
package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }
package.loaded["ffi/util"] = { template = function(s, a) return (s:gsub("%%1", tostring(a))) end }
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

-- A tall card always drew three or four rows of tiny covers (PW5: 27 covers
-- in a 6x3 card): rows were "as many as fit at 100px". The card now has its
-- own Rows; the rows set the cover size, the card's width how many fit.
-- Auto: as many rows as fit at the main shelf's own cover height, so a card
-- looks like the shelf it shows.
t.test("rows: the card's own setting wins, 1 to 6", function()
    assert(H.cardRows(2, 600, 8, 300) == 2)
    assert(H.cardRows(9, 600, 8, 300) == 6, "clamped")
    assert(H.cardRows(0, 600, 8, 300) == 1, "clamped")
end)

t.test("rows: Auto fits the main shelf's cover rows, at least one", function()
    -- 600px body, rows of 290px + 8px gaps: two fit.
    assert(H.cardRows(nil, 600, 8, 290) == 2)
    assert(H.cardRows(nil, 200, 8, 290) == 1, "a short card still shows a row")
    assert(H.cardRows(nil, 2000, 8, 290) == 6, "never more than six")
end)

t.test("rows: Auto without the shelf's size falls back to the old rule", function()
    assert(H.cardRows(nil, 600, 8, nil, 100) == H.rowsFor(600, 100))
end)

-- Covers need the full records: light ones carry no cover, and the module
-- drew every book as a plain title card (rig, 2026-10-24). Spines stay light.
t.test("a covers module asks for full records; a spines module stays light", function()
    local src = io.open("micromodules/shelf.lua"):read("*a")
    local cover = src:match("\nlocal function coverBody%(.-\nend\n")
    local spine = src:match("\nlocal function spineBody%(.-\nend\n")
    assert(cover and spine, "bodies not found")
    assert(not cover:find("light_only", 1, true), "covers are asked for light records: no cover to draw")
    assert(spine:find("light_only = true", 1, true), "spines lost their light records")
end)

t.test("the shelf list reads as the shelf menu does: in order, sub-shelves under their parent", function()
    -- On a PW5 a sub-shelf "Recently read" (a Recent shelf filtered to one
    -- folder) sat in the list as if it were a second Recent, with one book.
    local tabs = {
        { id = "all", label = "Home", source = { kind = "all" } },
        { id = "recent", label = "Recent", source = { kind = "recent" } },
        { id = "sos", label = "Shelf of shelves", source = { kind = "shelves" } },
        { id = "genres", label = "Genres", source = { kind = "genres" } },
        { id = "c5", label = "Recently read", source = { kind = "recent" }, parent = "sos" },
        { id = "inner", label = "Shelfy", source = { kind = "shelves" }, parent = "sos" },
        { id = "c6", label = "Notebooks", source = { kind = "collection", id = "n" }, parent = "inner" },
        { id = "off", label = "Old", source = { kind = "recent" }, enabled = false },
        { id = "card", label = "Mine", source = { kind = "recent" }, card_only = true },
    }
    local got = {}
    for _i, c in ipairs(H.shelfChoices(tabs, function(t) return t.card_only == true end)) do
        got[#got + 1] = c.text
    end
    assert(table.concat(got, "|") == "Home|Recent|Shelf of shelves \u{203A} Recently read"
        .. "|Shelf of shelves \u{203A} Shelfy \u{203A} Notebooks|Old (hidden)", table.concat(got, "|"))
end)

t.test("adding a module offers to create a shelf first, then the shelves", function()
    local src = io.open("micromodules/shelf.lua"):read("*a")
    local add = src:match("\n    on_add = function%(host_ctx, done%)\n(.-)\n    end,\n")
    assert(add and add:find("addShelf(host_ctx, done)", 1, true), "on_add does not offer a new shelf")
    local body = src:match("\nlocal function addShelf%(host_ctx, done%)\n(.-)\nend\n")
    assert(body, "no addShelf")
    local new_at = body:find([[_("Create new shelf\xE2\x80\xA6")]], 1, true)
    local list_at = body:find("shelfChoices(", 1, true)
    assert(new_at and list_at and new_at < list_at, "New shelf is not first")
    -- A new shelf is only added once it has a source; backing out adds nothing.
    assert(body:find("if info and info.source_changed and not added then", 1, true))
    assert(body:find("on_discard = function() end", 1, true))
end)

t.test("a module's own shelf is offered only sources the module can show", function()
    -- A grouped source (Series, Authors, Shelf of shelves) or an online one
    -- made a module that could only say "Choose a shelf".
    local ed = io.open("lib/bookshelf_chip_editor.lua"):read("*a")
    local body = ed:match("\nfunction Editor:_pickSource%(draft, on_close%)\n(.-)\nend\n")
    local card = body:match("if TabModel.isCardOnly%(draft%) then\n(.-)\n    end\n")
    assert(card, "the picker is the same for a module's shelf")
    for _i, s in ipairs({ 'btn("series"', 'btn("authors"', 'btn("genres"', 'btn("tags"',
            'btn("shelves"', '"opds"' }) do
        assert(not card:find(s, 1, true), s .. " offered to a module's shelf")
    end
    for _i, s in ipairs({ '"single_series"', '"author"', '"genre"', '"collection"', '"format"',
            '"rating"', '"language"', 'btn("recent"', '"folder_flat"' }) do
        assert(card:find(s, 1, true), s .. " missing for a module's shelf")
    end
end)

t.test("a module's own shelf is edited without the shelf menu's controls", function()
    local ed = io.open("lib/bookshelf_chip_editor.lua"):read("*a")
    local cut = ed:match("if draft%.card_only then\n            buttons%[1%] = { buttons%[1%]%[2%] }\n            buttons%[#buttons%] = {}\n        end")
    assert(cut, "arrows, Delete, Copy, Move to and + still shown for a module's shelf")
    -- Edit label is the middle of the first row; the actions the last.
    local first = ed:match("local buttons = {\n(.-)%-%- Row 1a: source")
    assert(first and first:find('_("Edit label")', 1, true))
end)

t.test("a module's shelf's source list says what it is choosing", function()
    local ed = io.open("lib/bookshelf_chip_editor.lua"):read("*a")
    assert(ed:find('title   = TabModel.isCardOnly(draft) and _("Shelf module source") or _("Shelf source or grouping"),', 1, true),
        "titled Shelf source or grouping with no grouping offered")
end)

t.test("a module's shelf is offered each folder source once, flattened", function()
    -- The module shows a folder shelf's books flattened (bookSource), so
    -- "Home (folders)" and "Specific folder" were the flattened ones twice.
    local ed = io.open("lib/bookshelf_chip_editor.lua"):read("*a")
    local body = ed:match("\nfunction Editor:_pickSource%(draft, on_close%)\n(.-)\nend\n")
    local card = body:match("if TabModel.isCardOnly%(draft%) then\n(.-)\n    end\n")
    assert(not card:find('btn("all"', 1, true), "Home (folders) offered")
    assert(not card:find('specific_btn("folder",', 1, true), "the folder tree offered")
    assert(card:find('btn("library",   _("Home"))', 1, true), "no Home")
    assert(card:find('specific_btn("folder_flat", _("Specific folder\\xE2\\x80\\xA6"),', 1, true), "no folder")
end)

t.test("a module's shelf's editor says Source, not Source / grouping", function()
    local ed = io.open("lib/bookshelf_chip_editor.lua"):read("*a")
    assert(ed:find('if TabModel.isCardOnly(draft) then\n                        return _("Source: ") .. _resolveSourceLabel(draft.source)', 1, true),
        "the editor's source row still offers grouping")
end)

t.done()
