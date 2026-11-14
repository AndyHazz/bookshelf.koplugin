-- tests/_test_plugin_button.lua
-- lib/bookshelf_plugin_button: the icon a plugin's button gets on a card in the
-- book popup's Actions tab.
-- Runs standalone: `lua tests/_test_plugin_button.lua`.

package.path = "./?.lua;./?/init.lua;" .. package.path

local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()
local eq = helpers.eq

local PB = require("lib/bookshelf_plugin_button")

local FOLDER_MOVE = "\xEE\xA5\x91" -- a 3-byte glyph, U+E951
local ASTRAL = "\xF3\xB0\x80\x80"  -- a 4-byte glyph, U+F0000

t.test("a button with no icon gets the puzzle piece", function()
    eq(PB.icon({ text = "Add" }), PB.DEFAULT)
end)

t.test("a button can choose its own glyph", function()
    eq(PB.icon({ text = "Add", bookshelf_icon = FOLDER_MOVE }), FOLDER_MOVE)
end)

-- Only the symbols font's private use area, U+E000 to U+F8FF: what the font
-- covers, and the plugin's rule for every icon (a glyph outside it once
-- crashed a render on a PW5, lib/bookshelf_menu_icons).
t.test("only a glyph of the symbols font's private use area", function()
    eq(PB.icon({ bookshelf_icon = "\xEE\x80\x80" }), "\xEE\x80\x80")   -- U+E000, the first
    eq(PB.icon({ bookshelf_icon = "\xEF\xA3\xBF" }), "\xEF\xA3\xBF")   -- U+F8FF, the last
    eq(PB.icon({ bookshelf_icon = "\xEF\xA4\x80" }), PB.DEFAULT)          -- U+F900, past it
    eq(PB.icon({ bookshelf_icon = "\xED\x9F\xBF" }), PB.DEFAULT)          -- U+D7FF, before it
    eq(PB.icon({ bookshelf_icon = "\xE2\x82\xAC" }), PB.DEFAULT)          -- a euro sign
    eq(PB.icon({ bookshelf_icon = "\xC3\xA9" }), PB.DEFAULT)               -- a two-byte letter
    eq(PB.icon({ bookshelf_icon = ASTRAL }), PB.DEFAULT)                     -- U+F0000, not in the font
end)

t.test("a stock KOReader icon name is not mistaken for a glyph", function()
    -- `icon` is KOReader's own field, an icon file name; bookshelf must not read it.
    eq(PB.icon({ icon = FOLDER_MOVE }), PB.DEFAULT)
    eq(PB.icon({ bookshelf_icon = "check" }), PB.DEFAULT)
    eq(PB.icon({ bookshelf_icon = "A" }), PB.DEFAULT)
end)

t.test("anything that is not exactly one glyph gets the puzzle piece", function()
    eq(PB.icon({ bookshelf_icon = "" }), PB.DEFAULT)
    eq(PB.icon({ bookshelf_icon = FOLDER_MOVE .. FOLDER_MOVE }), PB.DEFAULT)
    eq(PB.icon({ bookshelf_icon = FOLDER_MOVE .. "x" }), PB.DEFAULT)
    eq(PB.icon({ bookshelf_icon = "\xEE\xA5" }), PB.DEFAULT)      -- cut short
    eq(PB.icon({ bookshelf_icon = "\x91\xA5\xEE" }), PB.DEFAULT)  -- stray continuation bytes first
    eq(PB.icon({ bookshelf_icon = "\xC0\x80" }), PB.DEFAULT)      -- overlong, not a real character
    eq(PB.icon({ bookshelf_icon = 42 }), PB.DEFAULT)
    eq(PB.icon({ bookshelf_icon = true }), PB.DEFAULT)
    eq(PB.icon({ bookshelf_icon = {} }), PB.DEFAULT)
end)

t.test("a missing or odd spec does not error", function()
    eq(PB.icon(nil), PB.DEFAULT)
    eq(PB.icon("text"), PB.DEFAULT)
    eq(PB.icon({}), PB.DEFAULT)
end)

-- wrap: redraw the popup after a plugin's button runs.
local function fakeUI()
    local ui = { shown = {}, ticks = {} }
    function ui:isWidgetShown(w) return self.shown[w] == true end
    function ui:nextTick(fn) self.ticks[#self.ticks + 1] = fn end
    function ui:run() local q = self.ticks; self.ticks = {}; for _i, fn in ipairs(q) do fn() end end
    return ui
end

local function fakeModal(ui, shown)
    local m = { rebuilt = 0 }
    function m:rebuildTab() self.rebuilt = self.rebuilt + 1 end
    ui.shown[m] = shown
    return m
end

t.test("after the button runs, the popup is redrawn on the next tick", function()
    local ui = fakeUI()
    local modal = fakeModal(ui, true)
    local ran = 0
    local tap = PB.wrap(function() ran = ran + 1 end, modal, ui)
    tap()
    eq(ran, 1)
    eq(modal.rebuilt, 0, "not redrawn until the tick")
    ui:run()
    eq(modal.rebuilt, 1)
end)

t.test("a button that closed the popup is not followed by a redraw", function()
    local ui = fakeUI()
    local modal = fakeModal(ui, true)
    local tap = PB.wrap(function() ui.shown[modal] = false end, modal, ui) -- e.g. it opened the reader
    tap()
    ui:run()
    eq(modal.rebuilt, 0)
end)

t.test("a popup that is not showing is left alone", function()
    local ui = fakeUI()
    local modal = fakeModal(ui, false)
    PB.wrap(function() end, modal, ui)()
    ui:run()
    eq(modal.rebuilt, 0)
end)

t.test("the callback gets its arguments and its results come back", function()
    local ui = fakeUI()
    local modal = fakeModal(ui, true)
    local a, b = PB.wrap(function(x, y) return y, x end, modal, ui)(1, 2)
    eq(a, 2); eq(b, 1)
end)

t.test("no popup, or a plugin without a tap, is handled", function()
    local ui = fakeUI()
    PB.wrap(function() end, nil, ui)()
    ui:run()
    eq(PB.wrap(nil, fakeModal(ui, true), ui), nil)
end)

t.done()
