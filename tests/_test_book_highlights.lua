-- tests/_test_book_highlights.lua
-- The book modal's link to a book's highlights: counted from the sidecar
-- (highlights, not page bookmarks), and opened in KOReader's own bookmark
-- browser, which needs the file manager as its parent.
package.path = "./?.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()

local sidecars = {}
package.loaded["docsettings"] = {
    hasSidecarFile = function(_self, fp) return sidecars[fp] ~= nil end,
    open = function(_self, fp)
        return { readSetting = function(_ds, key) return (sidecars[fp] or {})[key] end }
    end,
}
local shown
package.loaded["ui/widget/bookmarkbrowser"] = {
    show = function(_self, files, parent) shown = { files = files, parent = parent } end,
}
local FM = {}
package.loaded["apps/filemanager/filemanager"] = FM
local H = dofile("lib/bookshelf_book_highlights.lua")

sidecars["/b.epub"] = { annotations = {
    { text = "First line", page = "/body/p[3]", pageno = 4, drawer = "lighten" },
    { page = "/body/p[9]", pageno = 9 },          -- a page bookmark
    { text = "With a note", note = "Mine", page = "/body/p[20]", drawer = "lighten" },
    { text = "in Chapter Two", page = "/body/p[30]", pageno = 30 }, -- a bookmark with KOReader's text
} }
sidecars["/legacy.epub"] = { highlight = { [1] = { { text = "old" } } } }

t.test("counts every annotation, page bookmarks too, as KOReader's list does", function()
    assert(H.count("/b.epub") == 4, tostring(H.count("/b.epub")))
    assert(H.count("/none.epub") == 0, "no sidecar")
    assert(H.count("/legacy.epub") == 0, "a legacy-only sidecar the browser can't list")
end)

t.test("opens KOReader's browser on the book, with the file manager as parent", function()
    shown = nil
    FM.instance = nil
    assert(H.showBrowser("/b.epub") == nil and shown == nil, "opened with no parent UI")
    FM.instance = { name = "fm" }
    assert(H.showBrowser("/b.epub") ~= nil, "did not open")
    assert(shown.files["/b.epub"] == true and shown.parent == FM.instance, "wrong files set or parent")
end)

-- The tab's own list: highlights (not page bookmarks) in book order, with
-- their notes; a tapped row's panel reads where it is, the text, the note.
t.test("the tab lists every annotation in book order, typed as KOReader's list types them", function()
    package.loaded["lib/bookshelf_text_safe"] = { safe = function(x) return x end }
    local l = H.list("/b.epub")
    assert(#l == 4, "got " .. #l)
    assert(l[1].type == "highlight" and l[1].text == "First line" and l[1].pageno == 4)
    assert(l[2].type == "bookmark" and l[2].text == nil and l[2].pageno == 9, "a page bookmark")
    assert(l[3].type == "note" and l[3].note == "Mine", "a highlight with a note")
    assert(l[4].type == "bookmark" and l[4].text == "in Chapter Two", "a bookmark with text taken for a highlight")
    assert(H.rowText(l[2]) == "", "a bookmark with no chapter says only its page (beside it)")
    assert(H.rowText({ type = "bookmark", chapter = "Two", pageno = 9 }) == "Two", "a bookmark's chapter")
    assert(#H.list("/none.epub") == 0)
end)

t.test("a tapped highlight's panel: chapter, page, day, text, note", function()
    local txt = H.detailText({ type = "note", text = "T", note = "N", chapter = "One", pageno = 4,
                               datetime = "2026-10-01 10:00:00" })
    assert(txt:find("One \xC2\xB7 Page 4 \xC2\xB7 2026-10-01", 1, true), txt)
    assert(not txt:find("10:00", 1, true), "the time shown")
    assert(txt:find(H.PREFIX.note .. "T", 1, true), "a noted highlight without the pencil")
    assert(txt:find("\n\nN", 1, true), "the note missing")
end)

t.test("the book modal has a Highlights tab: our list, at the modal's size, scrolling", function()
    local w = io.open("lib/bookshelf_widget.lua"):read("*a")
    assert(w:find('id = "highlights", label = _("Highlights")', 1, true), "no Highlights tab")
    assert(w:find("Highlights.count(book.filepath)", 1, true), "shown without highlights")
    assert(w:find("return Highlights.buildTab(self, book.filepath, show_parent or modal, avail_w, avail_h)", 1, true), "not our list")
    local hl = io.open("lib/bookshelf_book_highlights.lua"):read("*a")
    assert(hl:find("local font_size = (modal and modal.font_size) or 20", 1, true), "ignores the modal's font size")
    assert(hl:find("return SnugScroll:new{", 1, true), "doesn't scroll like the other tabs")
    local q = io.open("micromodules/quote_of_day.lua"):read("*a")
    assert(q:find('require("lib/bookshelf_book_highlights").showBrowser(q.filepath)', 1, true), "the quote module opens its own copy")
end)

-- Over a book still open in the reader there is no file manager: the reader
-- is the browser's parent then (both the tab's list and the button).
t.test("with no file manager the reader is the browser's parent", function()
    local RUI = { instance = { name = "reader" } }
    package.loaded["apps/reader/readerui"] = RUI
    FM.instance = nil
    assert(H.parentUI() == RUI.instance, "the reader was not used")
    shown = nil
    assert(H.showBrowser("/b.epub") ~= nil and shown.parent == RUI.instance, "the button did nothing")
    RUI.instance = nil
    assert(H.parentUI() == nil, "a parent with neither")
    package.loaded["apps/reader/readerui"] = nil
end)

-- Highlight colours on the row's square only, and only on a colour screen.
t.test("a highlight's square takes its colour on a colour screen only", function()
    package.loaded["apps/reader/modules/readerhighlight"] = { getHighlightColor = function(_s, n) return "C:" .. n end }
    _G.G_reader_settings = { readSetting = function() return "yellow" end, isTrue = function() return false end }
    assert(H.iconColour({ type = "highlight", drawer = "lighten", color = "red" }, true) == "C:red")
    assert(H.iconColour({ type = "highlight", drawer = "lighten" }, true) == "C:yellow", "no colour is the default")
    assert(H.iconColour({ type = "highlight", drawer = "lighten", color = "red" }, false) == nil, "coloured on greyscale")
    assert(H.iconColour({ type = "bookmark" }, true) == nil, "a page bookmark coloured")
end)

t.done()
