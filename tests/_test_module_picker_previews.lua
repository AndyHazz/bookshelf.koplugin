-- tests/_test_module_picker_previews.lua
-- The module picker's preview cards (maintainer, PW5):
--  - the Shelf module previews the reader's Home shelf, not "Choose a shelf";
--  - the previews are drawn in the default light card colours, like the
--    picker dialog around them, not a dark theme's cards;
--  - the Ornament preview has room round the piece;
--  - the Action preview says what the module does, filling its panel.
--
-- Usage (from plugin root): lua tests/_test_module_picker_previews.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local t  = dofile("tests/_helpers.lua").runner()
local eq = dofile("tests/_helpers.lua").eq

package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }
package.loaded["ffi/util"] = { template = function(s, a) return (s:gsub("%%1", tostring(a))) end }
package.loaded["logger"] = { dbg = function() end, info = function() end,
    warn = function() end, err = function() end }

local function widget(o) o = o or {}; function o:getSize() return self.dimen or { w = 0, h = 0 } end; return o end
local W = { new = function(_s, o) return widget(o) end }
package.loaded["ui/widget/container/centercontainer"] = W
package.loaded["ui/widget/verticalgroup"] = W
package.loaded["ui/widget/verticalspan"] = W
package.loaded["ui/geometry"] = { new = function(_s, o) return o end }
package.loaded["device"] = { screen = { scaleBySize = function(_s, v) return v end } }

t.test("with no shelf chosen, the Shelf module previews Home", function()
    local tabs = {
        { id = "all", label = "Home", source = { kind = "all" } },
        { id = "recent", label = "Recent", source = { kind = "recent" } },
    }
    package.loaded["lib/bookshelf_tab_model"] = {
        getById = function(id) for _i, x in ipairs(tabs) do if x.id == id then return x end end end,
        load = function() return tabs end,
    }
    local H = dofile("micromodules/shelf.lua")._test
    local cfg = { get = function() return nil end }
    eq(H.previewTab({ preview = true, config = cfg }).id, "all")
    eq(H.previewTab({ preview = false, config = cfg }), nil, "a real card without a shelf still asks for one")
    -- Home that isn't a shelf of books: the first one that is.
    tabs[1].source = { kind = "shelves" }
    eq(H.previewTab({ preview = true, config = cfg }).id, "recent")
    package.loaded["lib/bookshelf_tab_model"] = nil
end)

t.test("the Ornament preview leaves room round the piece; the card does not", function()
    local got
    package.loaded["lib/bookshelf_ornaments"] = { listAll = function() return { { name = "Cactus" } } end }
    package.loaded["lib/bookshelf_ornament_browser"] = {
        preview = function(_p, w, h) got = { w = w, h = h }; return widget({ dimen = { w = w, h = h } }) end }
    package.loaded["lib/bookshelf_module_kit"] = { fitText = function() return widget() end }
    local M = dofile("micromodules/ornament.lua")
    local cfg = { get = function() return nil end }
    M.render({ width = 400, height = 300, preview = true, config = cfg })
    assert(got.w < 400 and got.h < 300, "the piece fills the preview edge to edge")
    assert(got.h <= 300 * 0.8, "not enough room round the piece")
    package.loaded["lib/bookshelf_ornaments"] = nil
    package.loaded["lib/bookshelf_ornament_browser"] = nil
end)

t.test("the Action preview says what it can launch", function()
    local texts = {}
    package.loaded["lib/bookshelf_module_kit"] = {
        COLOR_PRIMARY = "INK", COLOR_MUTED = "MUTED",
        sc = function() return function(v) return v end end,
        fitText = function(o) texts[#texts + 1] = o.text; return widget({ dimen = { w = o.width, h = 40 } }) end,
    }
    package.loaded["lib/bookshelf_start_menu_model"] = { imageIconName = function() return nil end }
    package.loaded["lib/bookshelf_colour_text"] = W
    package.loaded["ui/font"] = { getFace = function() return {} end }
    package.loaded["ui/widget/textwidget"] = W
    local M = dofile("micromodules/action.lua")
    pcall(M.render, { width = 400, height = 300, preview = true, scale = 100 })
    local found = false
    for _i, s in ipairs(texts) do
        if s == "Launch any plugin, menu item or gesture action, and choose your own icon." then found = true end
    end
    assert(found, "no description in the preview")
end)

t.test("picker cards draw in the default light card colours, then the theme's come back", function()
    local src = io.open("lib/bookshelf_module_picker.lua"):read("*a")
    local body = src:match("\nfunction ModulePicker%._renderCell%(.-\nend\n")
    assert(body, "_renderCell moved")
    local reset_at   = body:find("Modules.resetTheme()", 1, true)
    local render_at  = body:find("pcall(def.render", 1, true)
    local card_at    = body:find("background = Modules.CARD_BG", 1, true)
    local restore_at = body:find("Modules.setCardBg(saved_bg)", 1, true)
    assert(reset_at and render_at and reset_at < render_at, "the preview renders in the theme's colours")
    assert(card_at and restore_at and card_at < restore_at, "the card is painted after the theme comes back")
    assert(body:find("Modules.setInk(saved_ink, saved_muted)", 1, true), "the theme's ink is not put back")
    -- Only a dark card is swapped: a light theme's own card (warm paper on a
    -- colour screen, or the reader's pick) already suits the dialog.
    assert(body:find("if Card.isDark(saved_bg) then Modules.resetTheme() end", 1, true), "every theme's cards are reset")
end)

t.test("isDark tells a dark card from a light one", function()
    package.loaded["ffi/blitbuffer"] = { Color8 = function(v) return { v = v } end }
    local Card = dofile("lib/bookshelf_module_card.lua")
    local function col(a) return { getColor8 = function() return { a = a } end } end
    assert(Card.isDark(col(0x1E)), "near-black card")
    assert(not Card.isDark(col(0xEE)), "the default grey")
    assert(not Card.isDark(nil), "no card: not dark")
    package.loaded["ffi/blitbuffer"] = nil
end)

t.done()
