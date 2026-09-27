-- tests/_test_reader_layout.lua
-- The page-count scan lays a book out the way the reader will.
--
-- Usage (from plugin root): lua tests/_test_reader_layout.lua
--
-- Reddit report: extracted page counts "way off, like a factor of 4". The
-- scan rendered at crengine's own defaults; measured on a PW5 that counted
-- 27 pages where the reader shows 75, and 218 where it shows 852.

package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local settings, defaults = {}, {}
_G.G_reader_settings = { readSetting = function(_s, k) return settings[k] end }
_G.G_defaults = { readSetting = function(_s, k) return defaults[k] end }
package.loaded["device"] = { screen = { scaleBySize = function(_s, n) return n * 2 end } }
package.loaded["ui/data/css_tweaks"] = {
    DEFAULT_GLOBAL_STYLE_TWEAKS = { b_tweak = true },
    { title = "Group", { id = "b_tweak", css = " B {} " }, { id = "a_tweak", css = "A {}" } },
    { title = "Other", { id = "late", priority = 5, css = "LATE {}" } },
}
package.loaded["libs/libkoreader-lfs"] = { attributes = function() return nil end }
package.loaded["datastorage"] = { getDataDir = function() return "/nowhere" end }
store, saves = {}, 0
package.loaded["lib/bookshelf_settings_store"] = {
    read = function(k) return store[k] end,
    save = function(k, v) store[k] = v; saves = saves + 1 end,
}

local L = dofile("lib/bookshelf_reader_layout.lua")

t.test("style tweaks: the global ones, lower priority first, then by id", function()
    settings = {}
    eq(L.tweakCss(), "B {}", "the defaults apply when the reader has none of its own")
    settings = { style_tweaks = { late = true, b_tweak = true, a_tweak = true, gone = true } }
    eq(L.tweakCss(), "A {}\nB {}\nLATE {}")
    settings = { style_tweaks = { a_tweak = false } }
    eq(L.tweakCss(), "", "a tweak switched off is left out")
end)

t.test("the status bar's reserve: what the reader used, else from its settings", function()
    store = {}
    settings = { footer = { container_height = 7, container_bottom_padding = 1 } }
    eq(L.footerHeight(package.loaded["device"].screen), 16)
    -- PW5: the bar hidden, and the reader still reserved it (192 vs 166).
    settings = { reader_footer_mode = 0, footer = { container_height = 7, container_bottom_padding = 1 } }
    eq(L.footerHeight(package.loaded["device"].screen), 16, "a hidden bar still takes its height")
    settings = { footer = { container_height = 7, reclaim_height = true } }
    eq(L.footerHeight(package.loaded["device"].screen), 0, "an overlapping bar takes nothing")
    store[L.FOOTER_KEY] = 26
    eq(L.footerHeight(package.loaded["device"].screen), 26, "the reader's own figure wins")
    store = {}
end)

t.test("recordFooter keeps the reader's figure, and only writes a change", function()
    store, saves = {}, 0
    local ui = { view = { footer = { settings = {}, getHeight = function() return 26 end } } }
    L.recordFooter(ui)
    eq(store[L.FOOTER_KEY], 26)
    L.recordFooter(ui)
    eq(saves, 1, "rewrote an unchanged value on every book open")
    ui.view.footer.settings.reclaim_height = true
    L.recordFooter(ui)
    eq(store[L.FOOTER_KEY], 0)
    store, saves = {}, 0
end)

local function fakeDoc(missing)
    local calls = {}
    local doc = setmetatable({ default_css = "./data/epub.css" }, {
        __index = function(_d, name)
            if missing and missing[name] then return nil end
            if name:match("^set") then
                return function(_self, ...) calls[name] = { ... } end
            end
        end,
    })
    return doc, calls
end

t.test("apply() sets the reader's font, size and margins", function()
    settings = {
        cre_font = "Neacademia Text", copt_font_size = 25, copt_line_spacing = 110,
        copt_h_page_margins = { 50, 40 }, copt_t_page_margin = 70, copt_b_page_margin = 100,
        reader_footer_mode = 0,
    }
    store[L.FOOTER_KEY] = 26   -- what the reader reserved, bar hidden (PW5)
    local doc, calls = fakeDoc()
    L.apply(doc)
    store = {}
    eq(calls.setFontFace[1], "Neacademia Text")
    eq(calls.setFontSize[1], 50, "the size is scaled like ReaderFont scales it")
    eq(calls.setInterlineSpacePercent[1], 110)
    eq(calls.setPageMargins[1], 100); eq(calls.setPageMargins[2], 140)
    eq(calls.setPageMargins[3], 80)
    eq(calls.setPageMargins[4], 226, "the bottom margin lost the status bar's reserve")
    eq(calls.setStyleSheet[1], "./data/epub.css")
    eq(calls.setBlockRenderingFlags[1], 0x7FFFFFFF, "a new book renders in web mode")
end)

t.test("defaults come from G_defaults when the reader never set one", function()
    settings = {}
    defaults = { DCREREADER_CONFIG_DEFAULT_FONT_SIZE = 22,
                 DCREREADER_CONFIG_H_MARGIN_SIZES_MEDIUM = { 10, 10 },
                 DCREREADER_CONFIG_T_MARGIN_SIZES_LARGE = 15,
                 DCREREADER_CONFIG_B_MARGIN_SIZES_LARGE = 15 }
    local doc, calls = fakeDoc()
    L.apply(doc)
    eq(calls.setFontSize[1], 44)
    eq(calls.setPageMargins[4], 30 + L.footerHeight(package.loaded["device"].screen))
end)

t.test("a setter this KOReader lacks costs that one setting, not the count", function()
    settings = { copt_font_size = 25 }
    local doc, calls = fakeDoc({ setWordExpansion = true })
    L.apply(doc)
    assert(calls.setFontSize, "a missing setter stopped the rest")
end)


-- Issue 461: FB2 undercounted (~8%, worst -33%) because the scan laid them out
-- with epub.css. ReaderUI sets is_fb2 on the document CLASS from the file type
-- before opening, and ReaderTypeset re-checks the real format after the load;
-- a bare openDocument does neither, so an FB2 got whatever the last book the
-- reader opened left behind.
t.test("an FB2 is laid out with the FB2 stylesheet, whatever the last book was", function()
    settings = {}
    local doc, calls = fakeDoc()
    doc.file = "/books/Novel.fb2"; doc.is_fb2 = false
    L.beforeLoad(doc)
    eq(doc.is_fb2, true); eq(doc.default_css, "./data/fb2.css")
    eq(calls.setStyleSheet[1], "./data/fb2.css")
    settings = { copt_fb2_css = "./data/my-fb2.css", copt_css = "./data/my.css" }
    doc, calls = fakeDoc(); doc.file = "/books/Novel.FB2.ZIP"; doc.is_fb2 = false
    L.beforeLoad(doc)
    eq(calls.setStyleSheet[1], "./data/my-fb2.css", "the reader's own FB2 stylesheet")
    doc, calls = fakeDoc(); doc.file = "/books/Book.epub"; doc.is_fb2 = true
    L.beforeLoad(doc)
    eq(doc.is_fb2, false, "an EPUB after an FB2 is not an FB2")
    eq(calls.setStyleSheet[1], "./data/my.css")
    settings = {}
end)

t.test("after the load the real format decides, as ReaderTypeset does", function()
    settings = {}
    local doc, calls = fakeDoc()
    doc.file = "/books/odd-name.xml"; doc.is_fb2 = false
    doc.getDocumentFormat = function() return "FictionBook2" end
    L.beforeLoad(doc)
    eq(calls.setStyleSheet[1], "./data/epub.css")
    L.afterLoad(doc)
    eq(doc.is_fb2, true); eq(calls.setStyleSheet[1], "./data/fb2.css", "re-styled once the format is known")
    local doc2, calls2 = fakeDoc()
    doc2.file = "/books/b.epub"; doc2.getDocumentFormat = function() return "EPUB" end
    L.beforeLoad(doc2); calls2.setStyleSheet = nil
    L.afterLoad(doc2)
    eq(calls2.setStyleSheet, nil, "no second styling when the guess was right")
end)

t.done()
