-- tests/_test_panel_color.lua
-- Colors > Panel color and Panel text: the top and footer panels' tint, and
-- the ink of what is drawn on them. Unset, nothing changes (white or black
-- from the theme, the chrome's own ink). A panel colour brings black or white
-- text, whichever reads on it, unless Panel text is picked too.
--
-- Usage (from plugin root): lua tests/_test_panel_color.lua

package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()

local cp = io.open("lib/bookshelf_cover_progress.lua"):read("*a")
local body = cp:match("\nfunction M%.panelInk%(%)\n(.-)\nend\n")
assert(body, "no M.panelInk")

local function c8(v) return { a = v, getColor8 = function(self) return self end } end
-- panelInk with these stored parts ({ key = raw }), slot and panel tint.
local function panelInk(parts, suffix, tint)
    local M = {
        resolvePicked = function(raw) return c8(raw.grey) end,
        resolvedColors = function() return { panel_tint = tint } end,
    }
    local env = {
        type = type, pcall = pcall, M = M,
        _modeSuffix = function() return suffix or "" end,
        _partRead = function(k) return parts[k] end,
        require = function(name)
            assert(name == "lib/bookshelf_module_card", name)
            return { autoInk = function(bg) return c8(bg.a < 128 and 0xFF or 0x00) end }
        end,
    }
    return assert(load("return function()\n" .. body .. "\nend", "panelInk", "t", env))()()
end

t.test("unset, the chrome keeps its own ink", function()
    assert(panelInk({}, "", c8(0xFF)) == nil)
end)

t.test("a panel colour brings text that reads on it", function()
    assert(panelInk({ panel_color = { grey = 0x30 } }, "", c8(0x30)).a == 0xFF, "dark panel, dark text")
    assert(panelInk({ panel_color = { grey = 0xD0 } }, "", c8(0xD0)).a == 0x00, "light panel, light text")
end)

t.test("Panel text wins, and each look reads its own slot", function()
    assert(panelInk({ panel_color = { grey = 0x30 }, panel_ink = { grey = 0x99 } }, "", c8(0x30)).a == 0x99)
    assert(panelInk({ panel_color = { grey = 0x30 } }, "_night", c8(0xFF)) == nil, "the dark look read the light slot")
    assert(panelInk({ panel_ink_night = { grey = 0x44 } }, "_night", c8(0xFF)).a == 0x44, "dark slot ignored")
end)

t.test("the palette resolves the tint from its own key, apart from the paper", function()
    assert(cp:find('_readModeColor("panel_color", DEFAULT_PANEL_BG, NIGHT_DEFAULT_PANEL_BG)', 1, true), "no panel_color")
    assert(cp:find("panel_tint        = _paint(panel_tint_raw),", 1, true), "no panel_tint")
    assert(cp:find('panel_color       = _readOwnColor("panel_color", nil),', 1, true), "row label can't read it")
    local tp = io.open("lib/bookshelf_theme_pack.lua"):read("*a")
    assert(tp:find('["panel"]                = "panel_color",', 1, true)
           and tp:find('["panel text"]           = "panel_ink",', 1, true), "not theme parts / pack names")
end)

t.test("the Colors menu has both rows, and Reset clears them", function()
    local st = io.open("lib/bookshelf_settings.lua"):read("*a")
    assert(st:find('pickColor("panel_color", "panel_color"', 1, true), "no Panel color row")
    assert(st:find('pickColor("panel_ink", "panel_ink"', 1, true), "no Panel text row")
    assert(st:find('"panel_color", "panel_ink",', 1, true), "Reset misses them")
end)

t.test("the panels paint the tint, and their text asks panelInk first", function()
    local w = io.open("lib/bookshelf_widget.lua"):read("*a")
    local attach = w:match("\nfunction BookshelfWidget:_attachTopPanel%(vgroup, opts%)\n(.-)\nend\n")
    assert(attach and attach:find("local ground    = colors.panel_tint or colors.panel_bg", 1, true), "top panel")
    local foot = w:match("\nfunction BookshelfWidget:_footerPanelRectRaw%(strength%)\n(.-)\nend\n")
    assert(foot and foot:find("colors.panel_tint or colors.panel_bg", 1, true), "footer panel")
    local chrome = w:match("\nfunction BookshelfWidget:_chromeInk%(%)\n(.-)\nend\n")
    assert(chrome and chrome:find("CP.panelInk", 1, true), "footer glyphs")
    local chips = io.open("lib/bookshelf_chip_bar.lua"):read("*a")
    local raw = chips:match("\nlocal function _chipInkRaw%(%)\n(.-)\nend\n")
    assert(raw and raw:find("_panelChipInk()", 1, true), "shelf menu text")
    -- Only with no bar: the bar's labels stand on Shelf menu background, and
    -- a pale panel's black text went black on the dark bar (rig).
    local pci = chips:match("\nlocal function _panelChipInk%(%)\n(.-)\nend\n")
    assert(pci and pci:find('TP.partRead("chip_bar_transparent") ~= true then return nil', 1, true),
           "the bar's own labels take the panel's ink")
    local act = chips:match("\nlocal function _activeChipColors%(%)\n(.-)\nend\n")
    assert(act and act:find("return panel_ink, colors.panel_tint", 1, true),
           "the selected chip is filled and lettered in the bar's colours over the panel")
    local hero = io.open("lib/bookshelf_hero_card.lua"):read("*a")
    assert(hero:match("\nlocal function _ink%(%)\n(.-)\nend\n"):find("CP.panelInk", 1, true), "top panel text")
end)

t.done()
