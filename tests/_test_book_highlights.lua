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
    { text = "First line", page = "/body/p[3]", pageno = 4 },
    { page = "/body/p[9]", pageno = 9 },          -- a page bookmark
    { text = "With a note", note = "Mine", page = "/body/p[20]" },
} }
sidecars["/legacy.epub"] = { highlight = { [1] = { { text = "old" } } } }

t.test("counts highlights, not page bookmarks", function()
    assert(H.count("/b.epub") == 2, tostring(H.count("/b.epub")))
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

-- The tab: KOReader's own list (the bookmark browser's Menu) at the tab's
-- size; nil without the file manager, so the tab falls back to a button.
t.test("buildList: KOReader's list at the tab's size, nil when it can't", function()
    local BB = package.loaded["ui/widget/bookmarkbrowser"]
    local made, filled, details
    package.loaded["ui/widget/menu"] = {
        items_per_page_default = 14,
        getItemFontSize = function() return 20 end,
        new = function(_self, o) made = o; o.item_table = {}; return o end,
    }
    package.loaded["ffi/blitbuffer"] = { COLOR_DARK_GRAY = 1, COLOR_WHITE = 2 }
    package.loaded["apps/reader/modules/readerhighlight"] = { getHighlightColor = function() return 3 end }
    package.loaded["device"] = { screen = { isColorEnabled = function() return false end } }
    _G.G_reader_settings = { readSetting = function() return nil end, isTrue = function() return false end }
    BB.getBookList = function(_self, files) return files["/b.epub"] and { { file = "/b.epub" } } or {} end
    BB.updateBookmarkList = function() filled = true end
    BB.showBookmarkDetails = function(_self, item) details = item end

    FM.instance = nil
    assert(H.buildList("/b.epub", 600, 800) == nil, "built with no file manager")
    FM.instance = { name = "fm" }
    local list = H.buildList("/b.epub", 600, 800)
    assert(list and made.width == 600 and made.height == 800, "not at the tab's size")
    assert(made.no_title == true and made.is_enable_shortcut == false, "title bar or key hints shown")
    assert(filled, "the browser did not fill it")
    made.onMenuSelect(made, { file = "/b.epub" })
    assert(details == nil, "the book's own row opened something")
    made.onMenuSelect(made, { page = 5 })
    assert(details and details.page == 5, "a highlight's detail did not open")
    H.releaseList()
    assert(BB.bm_list == nil, "the browser kept hold of the tab's list")
end)

t.test("the book modal has a Highlights tab, with the button as its fallback", function()
    local w = io.open("lib/bookshelf_widget.lua"):read("*a")
    assert(w:find('id = "highlights", label = _("Highlights")', 1, true), "no Highlights tab")
    assert(w:find("Highlights.count(book.filepath)", 1, true), "shown without highlights")
    assert(w:find("local list = Highlights.buildList(book.filepath, avail_w, avail_h)", 1, true), "not KOReader's list")
    assert(w:find("return self:_highlightsFallback(book, hl_count, avail_w, avail_h, show_parent)", 1, true), "no fallback")
    assert(w:find('require("lib/bookshelf_book_highlights").releaseList()', 1, true), "the list is not released on close")
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

t.done()
