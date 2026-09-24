-- tests/_test_font_picker.lua
-- The font picker's list: one row per family, fonts FreeType cannot load left
-- out, and a current face found whatever form it arrives in.
--
-- Usage (from plugin root): lua tests/_test_font_picker.lua
--
-- Issue 450: bookshelf's own picker was a Menu over FontList:getFontList() --
-- every file, every weight its own row, no preview -- and on Kobo that list
-- included the encrypted system fonts in /mnt/onboard/fonts/kobo, which
-- FreeType cannot open. The port reads FontList.fontinfo and checks each pick.

package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local unloadable = {}
local function stub(name, v) package.loaded[name] = v end
local Widget = setmetatable({}, { __index = function() return function() end end })
for _i, m in ipairs({ "ffi/blitbuffer", "ui/widget/buttontable",
        "ui/widget/container/centercontainer", "ui/widget/container/framecontainer",
        "ui/geometry", "ui/gesturerange", "ui/widget/horizontalgroup",
        "ui/widget/horizontalspan", "ui/widget/container/inputcontainer",
        "ui/widget/container/leftcontainer", "ui/widget/linewidget", "ui/size",
        "ui/widget/textwidget", "ui/widget/container/topcontainer", "ui/uimanager",
        "ui/widget/verticalgroup", "ui/widget/verticalspan" }) do
    stub(m, Widget)
end
stub("device", { screen = { scaleBySize = function(_s, n) return n end } })
stub("logger", { info = function() end, warn = function() end })
stub("ffi/util", { strcoll = function(a, b) return a < b end })
stub("lib/bookshelf_i18n", { gettext = function(s) return s end })
stub("ui/font", { getFace = function(_s, file) return not unloadable[file] and {} or nil end })

local FontPicker = dofile("lib/bookshelf_font_picker.lua")

local function fontlist(info)
    return {
        fontinfo = info,
        getLocalizedFontName = function(_s, file) return info[file] and info[file][1].name end,
    }
end

local FL = fontlist{
    ["/f/Noto/NotoSerif-Regular.ttf"]    = { { name = "Noto Serif" } },
    ["/f/Noto/NotoSerif-Bold.ttf"]       = { { name = "Noto Serif", bold = true } },
    ["/f/Noto/NotoSerif-Italic.ttf"]     = { { name = "Noto Serif", italic = true } },
    ["/f/Noto/NotoSerif-Light.ttf"]      = { { name = "Noto Serif" } },
    ["/f/Script/Caveat-Italic.ttf"]      = { { name = "Caveat", italic = true } },
    ["/f/Inter/Inter-ExtraBold.ttf"]     = { { name = "Inter ExtraBold" } },
    ["/mnt/onboard/fonts/kobo/Enc.ttf"]  = { { name = "Encrypted" } },
}

t.test("one row per family, its Regular preferred", function()
    unloadable = {}
    local list = FontPicker.families(FL)
    local by = {}
    for _i, e in ipairs(list) do by[e.name] = e.file end
    eq(by["Noto Serif"], "/f/Noto/NotoSerif-Regular.ttf")
    local n = 0
    for _i, e in ipairs(list) do if e.name == "Noto Serif" then n = n + 1 end end
    eq(n, 1, "a weight got its own row")
end)

t.test("a family with only a variant keeps it", function()
    unloadable = {}
    local _list, by_family = FontPicker.families(FL)
    eq(by_family["Caveat"].file, "/f/Script/Caveat-Italic.ttf")
end)

t.test("a font FreeType cannot load is not listed", function()
    unloadable = { ["/mnt/onboard/fonts/kobo/Enc.ttf"] = true }
    local list = FontPicker.families(FL)
    for _i, e in ipairs(list) do
        assert(e.name ~= "Encrypted", "an unloadable font was offered")
    end
end)

t.test("sorted by name", function()
    unloadable = {}
    local list = FontPicker.families(FL)
    for i = 2, #list do assert(list[i - 1].name <= list[i].name) end
end)

t.test("the current face finds its row in any form", function()
    unloadable = {}
    local list, by_family = FontPicker.families(FL)
    local vis = function(f) return FontPicker.visibleFace(f, list, by_family, FL) end
    eq(vis("/f/Noto/NotoSerif-Regular.ttf"), "/f/Noto/NotoSerif-Regular.ttf")
    eq(vis("/f/Noto/NotoSerif-Bold.ttf"), "/f/Noto/NotoSerif-Regular.ttf",
       "another weight did not map to its family's row")
    eq(vis("Inter-ExtraBold.ttf"), "/f/Inter/Inter-ExtraBold.ttf",
       "a bundled font's bare file name found no row")
    eq(vis(nil), nil)
    eq(vis("/gone.ttf"), "/gone.ttf", "an unknown face is handed back unchanged")
end)

t.test("the line editor no longer borrows bookends' picker", function()
    local le = io.open("lib/bookshelf_line_editor.lua"):read("*a")
    assert(le:find('require("lib/bookshelf_font_picker").show', 1, true))
    assert(not le:find("plugin.showFontPicker", 1, true))
end)

t.done()
