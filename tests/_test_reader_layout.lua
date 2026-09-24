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

local L = dofile("lib/bookshelf_reader_layout.lua")

t.test("style tweaks: the global ones, lower priority first, then by id", function()
    settings = {}
    eq(L.tweakCss(), "B {}", "the defaults apply when the reader has none of its own")
    settings = { style_tweaks = { late = true, b_tweak = true, a_tweak = true, gone = true } }
    eq(L.tweakCss(), "A {}\nB {}\nLATE {}")
    settings = { style_tweaks = { a_tweak = false } }
    eq(L.tweakCss(), "", "a tweak switched off is left out")
end)

t.test("the status bar takes its height from the page unless it is off", function()
    settings = { footer = { container_height = 7, container_bottom_padding = 1 } }
    eq(L.footerHeight(package.loaded["device"].screen), 16)
    settings = { reader_footer_mode = 0, footer = { container_height = 7 } }
    eq(L.footerHeight(package.loaded["device"].screen), 0)
    settings = { footer = { container_height = 7, reclaim_height = true } }
    eq(L.footerHeight(package.loaded["device"].screen), 0, "an overlapping bar takes nothing")
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
    local doc, calls = fakeDoc()
    L.apply(doc)
    eq(calls.setFontFace[1], "Neacademia Text")
    eq(calls.setFontSize[1], 50, "the size is scaled like ReaderFont scales it")
    eq(calls.setInterlineSpacePercent[1], 110)
    eq(calls.setPageMargins[1], 100); eq(calls.setPageMargins[2], 140)
    eq(calls.setPageMargins[3], 80);  eq(calls.setPageMargins[4], 200)
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

t.done()
