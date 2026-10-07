-- tests/_test_pack_pickers_wiring.lua
-- One place to choose each kind (5.3): where the menus send the reader.
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq
local settings = io.open("lib/bookshelf_settings.lua"):read("*a")

t.test("the two wallpaper rows open the wallpaper picker", function()
    local menu = settings:match("function Settings:_wallpaperMenu%(%)(.-)\nend\n")
    assert(menu, "_wallpaperMenu moved")
    assert(menu:find('bookshelf_wallpaper_browser").show(key', 1, true), "the rows do not open the picker")
    assert(menu:find("openPicker(Wallpaper.SETTING)", 1, true)
        and menu:find("openPicker(Wallpaper.FULL_SETTING)", 1, true), "a row is not wired")
    assert(not settings:find("_wallpaperSubItems", 1, true), "the old list menu is still there")
end)

t.test("the Plank row opens the plank picker, and is in one place only", function()
    local row = settings:match("function Settings:_plankRow%(.-\nend\n")
    assert(row and row:find('bookshelf_plank_browser").show(', 1, true), "the plank row does not open the picker")
    local bg = settings:match("function Settings:_backgroundSubItems%(%)(.-)\nend\n")
    assert(bg and bg:find("self:_plankRow(", 1, true), "no plank row next to the wallpaper rows")
    local colours = settings:match("function Settings:_colorsSubItems%(.-\nend\n")
    assert(colours and not colours:find("_plankRow", 1, true),
        "the plank row is in Colors as well: it belongs in one place (maintainer, 2026-10-07)")
    assert(not settings:find("plank active - tap to deactivate", 1, true), "the deactivate row is still there")
end)

t.test("the plank colour dialog no longer offers Oak", function()
    local pp = settings:match("function Settings:_pickPlank%(.-\nend\n")
    assert(pp and not pp:find("special_tile", 1, true) and not pp:find("Oak wood", 1, true))
    assert(pp:find('choosePlank("colour")', 1, true), "picking a colour does not make the plank the colour")
end)

t.test("Performance tweaks names the plank from plankRowLabel", function()
    local perf = settings:match("function Settings:_performanceSubItems%(%)(.-)\nend\n")
    assert(perf and perf:find(").plankRowLabel()", 1, true), "the row does not name the plank in use")
    assert(perf:find("TP.setDesignsOn(", 1, true), "the row does not switch designs")
    assert(not settings:find("plank colour dialog or the ornaments browser", 1, true), "old help text")
end)

t.test("pickers mark the choice with painted marks, not words", function()
    local pb = io.open("lib/bookshelf_plank_browser.lua"):read("*a")
    assert(pb:find("Marks.Radio:new{ checked = PB.inUse(o) }", 1, true), "no radio mark on a plank")
    assert(not pb:find('_("In use")', 1, true), "the plank picker still says In use")
    local ob = io.open("lib/bookshelf_ornament_browser.lua"):read("*a")
    assert(ob:find("Marks.Check:new{ checked = not item.off, enabled = not item.pack_off }", 1, true),
        "no checkbox on an ornament card")
    assert(not ob:find('_("Off")', 1, true), "the card still says Off")
end)

local browser = io.open("lib/bookshelf_ornament_browser.lua"):read("*a")
t.test("the collection shows ornaments only, with no theme buttons", function()
    local items = browser:match("function Browser:_items%(%)(.-)\nend\n")
    assert(items and not items:find("plankEntries", 1, true), "plank tiles are still listed")
    assert(not browser:find("is_plank", 1, true), "plank branches are still there")
    local foot = browser:match("function Browser:_footerRows%(%)(.-)\nend\n")
    assert(foot, "_footerRows moved")
    for _i, gone in ipairs({ "Apply pack theme", "Undo pack theme", "applySummary", "appliedPack" }) do
        assert(not browser:find(gone, 1, true), gone .. " is still in the collection")
    end
    assert(not browser:find("function Browser:_applyTheme", 1, true), "_applyTheme is still there")
    assert(not browser:find("_packAction", 1, true), "the whole-pack switch is still in the footer")
end)

t.test("Colors starts with the Light | Dark slot switch; no Color theme row, nothing greyed by a pack", function()
    local body = settings:match("function Settings:_colorsSubItems%(.-\nend\n")
    assert(body, "_colorsSubItems moved")
    assert(not body:find('_("Color theme: %1")', 1, true), "the Color theme row is back")
    assert(not body:find("activeColoursPack", 1, true), "the rows are still greyed by a pack's colors")
    assert(not settings:find("withOverride", 1, true), "withOverride is still used")
    local first = body:match("local items = {%s*{(.-)\n        },")
    assert(first and first:find('_("Colors for: %1")', 1, true), "the slot switch is not the first row")
    assert(first:find("setEditSlot", 1, true), "the switch does not change the slot")
    -- The old row broadcast ToggleNightMode: with a dark theme the light
    -- colours could not be reached, and the whole menu inverted.
    assert(not first:find("ToggleNightMode", 1, true) and not body:find("ToggleNightMode", 1, true),
        "the slot switch toggles KOReader's night mode")
end)

t.test("pickers never switch a pack on or off, and show no off state", function()
    for _i, f in ipairs({ "lib/bookshelf_plank_browser.lua", "lib/bookshelf_wallpaper_browser.lua" }) do
        local src = io.open(f):read("*a"):gsub("%-%-[^\n]*", "")
        assert(not src:find("setPackOff", 1, true), f .. " switches a pack")
        assert(not src:find("pack_off", 1, true), f .. " still reads the pack switch")
        assert(not src:find('_("Pack off")', 1, true) and not src:find('_("%1 (off)")', 1, true),
            f .. " still shows an off state")
    end
end)

t.test("the pickers put KOReader's menu away while open and bring it back once", function()
    local body = settings:match("\n(function Settings:_hidePickerMenu%(.-\nend)\n")
    assert(body, "no _hidePickerMenu")
    local env = setmetatable({ Settings = {} }, { __index = _G })
    local chunk = assert((loadstring or load)(body, "=hide", "t", env))
    if setfenv then setfenv(chunk, env) end
    chunk()
    local hidden, restored = 0, 0
    local S = { _plugin = { hideMenu = function(_p, tmi) hidden = hidden + 1; return function() restored = restored + 1 end end } }
    local restore = env.Settings._hidePickerMenu(S, {})
    eq(hidden, 1, "hidden through the plugin's guarded hideMenu")
    restore(); restore()
    eq(restored, 1, "brought back once, however many ways the picker closes")
    local row = settings:match("function Settings:_plankRow%(.-\nend\n")
    assert(row:find("self:_hidePickerMenu(touchmenu_instance)", 1, true) and row:find("on_closed = restore", 1, true),
        "the plank picker does not put the menu away")
    local menu = settings:match("function Settings:_wallpaperMenu%(%)(.-)\nend\n")
    assert(menu:find("self:_hidePickerMenu(touchmenu_instance)", 1, true) and menu:find("end, restore)", 1, true),
        "the wallpaper picker does not put the menu away")
end)

t.test("choosing a plain plank colour comes back to the plank picker, not the menu", function()
    local pb = io.open("lib/bookshelf_plank_browser.lua"):read("*a")
    local tap = pb:match("on_cell_tap = function%(o%)(.-)\n        end,")
    assert(tap and tap:find("opts.pick_colour(before, reopen)", 1, true), "the colour dialog is not told to come back")
    local closed = pb:match("on_closed = function%(%)(.-)\n        end,")
    assert(closed and closed:find("if not self.reopening", 1, true), "the menu comes back between the picker and the dialog")
    local pc = settings:match("function Settings:_pickColor%(.-\nend\n")
    assert(pc and pc:find("wood.on_done", 1, true), "the colour dialogs have no way to say they closed")
    local pp = settings:match("function Settings:_pickPlank%(.-\nend\n")
    assert(pp and pp:find("on_done = on_done", 1, true), "the plank colour dialog does not pass it on")
end)

t.test("the collection's footer: Select all and Select none, Add ornaments on All", function()
    -- Maintainer, 2026-10-02: Select all / Select none read more simply than
    -- Switch pack on/off; the whole-pack switch is the theme packs' now.
    local foot = browser:match("function Browser:_footerRows%(%)(.-)\nend\n")
    assert(foot:find("if self.opts.pick then return { { close } } end", 1, true), "picking lost its Cancel-only footer")
    assert(foot:find("self:_selectButton(true), self:_selectButton(false)", 1, true), "no Select all / Select none")
    assert(foot:find("self:_addButton()", 1, true), "Add ornaments is gone")
    assert(browser:find('_("Select all")', 1, true) and browser:find('_("Select none")', 1, true))
end)

t.test("Select all and Select none switch every ornament on the tab", function()
    local body = browser:match("\nfunction Browser:_setAll%(on%)\n(.-)\nend\n")
    assert(body, "no Browser:_setAll(on)")
    local off, packs_off, changed = { ["Autumn/a.png"] = true }, { Autumn = true }, 0
    local Orn = {
        setOff = function(n, v) off[n] = v and true or nil end,
        isPackOff = function(p) return packs_off[p] == true end,
        setPackOff = function(p, v) packs_off[p] = v and true or nil end,
    }
    local f = load("return function(self, on)\n" .. body .. "\nend", "setAll", "t",
        { O = function() return Orn end, ipairs = ipairs })()
    local self = { items = { { entry = { name = "Autumn/a.png", pack = "Autumn" } },
                             { entry = { name = "Autumn/b.png", pack = "Autumn" } },
                             { entry = { name = "loose.png" } } },
                   _changed = function() changed = changed + 1 end }
    f(self, false)
    assert(off["Autumn/a.png"] and off["Autumn/b.png"] and off["loose.png"], "Select none left one on")
    eq(packs_off.Autumn, true, "Select none switched the pack")
    f(self, true)
    eq(next(off), nil, "Select all left one off")
    eq(packs_off.Autumn, nil, "Select all did not switch on a pack a theme had off")
    eq(changed, 2, "the browser was not redrawn")
end)

t.done()
