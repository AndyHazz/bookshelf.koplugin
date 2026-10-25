-- tests/_test_palette_icon_size.lua
-- The palette icon in a module menu's title (the layout editor's toolbar and
-- a spine shelf module's menu) is drawn large, as a tap target: at 22 pt it
-- was a speck in the corner (maintainer, PW5).
--
-- Usage (from plugin root): lua tests/_test_palette_icon_size.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()

t.test("the palette icon is a large tap target", function()
    local made
    local function W(o) o = o or {}; function o:getSize() return { w = 60, h = 60 } end; return o end
    package.loaded["lib/bookshelf_start_menu_modules"] = { get = function() return { colors = {} } end }
    package.loaded["lib/bookshelf_colour_text"] = { new = function(_s, o) return W(o) end }
    package.loaded["ui/widget/button"] = { new = function(_s, o) made = o; return W(o) end }
    package.loaded["ui/widget/container/centercontainer"] = { new = function(_s, o) return W(o) end }
    package.loaded["ui/widget/horizontalgroup"] = { new = function(_s, o) return W(o) end }
    package.loaded["ui/widget/horizontalspan"] = { new = function(_s, o) return W(o) end }
    package.loaded["ui/geometry"] = { new = function(_s, o) return o end }
    package.loaded["device"] = { screen = { scaleBySize = function(_s, v) return v end } }
    package.loaded["lib/bookshelf_menu_icons"] = { COLORS = "P" }
    package.loaded["lib/bookshelf_module_card"] = { rows = function() return { 1 } end }
    package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }
    package.loaded["ffi/util"] = { template = function(s) return s end }
    local M = dofile("lib/bookshelf_module_card_menu.lua")
    M.titleRow("Title", {}, 600, { module = "x" }, nil, function() end)
    assert(made, "no icon")
    assert(made.text_font_size >= 34, "the icon is " .. tostring(made.text_font_size) .. " pt")
    assert(made.padding >= 8, "too little to tap")
end)

t.done()
