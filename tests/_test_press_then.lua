-- tests/_test_press_then.lua
-- Kit.pressThen shows a button pressed, runs its action, then lets it up.
-- Letting it up only while its window was still the top one left it black
-- whenever the action put something over it: the layout editor's d-pad
-- with nowhere to go ("No room" note) and Settings (its menu) stayed
-- filled on the PW5 (maintainer).
--
-- Usage (from plugin root): lua tests/_test_press_then.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq

local stack, dirty = {}, {}
package.loaded["ui/uimanager"] = {
    widgetRepaint = function() end,
    forceRePaint = function() end,
    setDirty = function(_s, w, mode, box) dirty[#dirty + 1] = { w = w, mode = mode, box = box } end,
    getTopmostVisibleWidget = function() return stack[#stack] end,
    isWidgetShown = function(_s, w)
        for _i, s in ipairs(stack) do if s == w then return true end end
        return false
    end,
    tickAfterNext = function(_s, f) f() end,
}
local function widget()
    local C = {}
    function C:new(o) return o or {} end
    function C:extend(o) o = o or {}; return setmetatable(o, { __index = self }) end
    return C
end
for _i, name in ipairs({ "ui/widget/container/centercontainer", "ui/widget/container/framecontainer",
        "ui/widget/horizontalgroup", "ui/widget/horizontalspan", "ui/widget/container/inputcontainer",
        "ui/widget/container/widgetcontainer", "lib/bookshelf_colour_text" }) do
    package.loaded[name] = widget()
end
package.loaded["ffi/blitbuffer"] = { COLOR_BLACK = 0, COLOR_WHITE = 1, COLOR_DARK_GRAY = 2,
    COLOR_LIGHT_GRAY = 3, gray = function(v) return v end, Color8 = function(v) return v end }
package.loaded["ui/geometry"] = { new = function(_s, o) return o end }
package.loaded["ui/gesturerange"] = { new = function(_s, o) return o end }
package.loaded["ui/size"] = setmetatable({}, { __index = function() return setmetatable({}, { __index = function() return 1 end }) end })
package.loaded["device"] = { screen = { scaleBySize = function(_s, v) return v end } }
package.loaded["lib/bookshelf_space"] = setmetatable({ px = function(v) return v end },
    { __index = function() return setmetatable({}, { __index = function() return 1 end }) end })
local Kit = require("lib/bookshelf_popup_kit")

local function press(action)
    local editor = { name = "editor" }
    stack = { editor }
    for i = #dirty, 1, -1 do dirty[i] = nil end
    local card = {}
    local cell = { dimen = { x = 10, y = 20, w = 90, h = 80 } }
    Kit.pressThen(cell, card, action)
    return editor, card
end
local function letUp(editor)
    for _i, d in ipairs(dirty) do
        if d.w == editor and d.mode == "ui" then return true end
    end
    return false
end

t.test("a button lets up when its action shows something over it", function()
    local editor, card = press(function() stack[#stack + 1] = { name = "No room" } end)
    eq(card._pressed, false)
    assert(letUp(editor), "the button's window wasn't repainted, so it stayed pressed")
end)

t.test("a button lets up when its action does nothing", function()
    local editor, card = press(function() end)
    eq(card._pressed, false)
    assert(letUp(editor), "the button stayed pressed")
end)

t.test("a button whose window closed is left alone", function()
    local editor = press(function() stack = {} end)
    assert(not letUp(editor), "repainted a window that had closed")
end)

t.done()
