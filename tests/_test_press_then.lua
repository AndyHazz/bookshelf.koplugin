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

local stack, dirty, seq = {}, {}, {}
package.loaded["ui/uimanager"] = {
    widgetRepaint = function() end,
    forceRePaint = function() seq[#seq + 1] = "flush" end,
    yieldToEPDC = function() seq[#seq + 1] = "yield" end,
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
local screen = { scaleBySize = function(_s, v) return v end }
package.loaded["device"] = { screen = screen }
package.loaded["lib/bookshelf_space"] = setmetatable({ px = function(v) return v end },
    { __index = function() return setmetatable({}, { __index = function() return 1 end }) end })
local FC = package.loaded["ui/widget/container/framecontainer"]
function FC:new(o) return setmetatable(o or {}, { __index = FC }) end
function FC:getSize() local c = self[1]:getSize(); return { w = c.w, h = c.h } end
function FC.paintTo() end
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

-- The book popup's action cards are set to the row's height, so a one-line
-- card is taller than its content. FrameContainer fills its set height but
-- measures (getSize) its content, and the shadow followed the measure: it
-- stopped part way down each card (maintainer, PW5).
t.test("a card's shadow runs its whole set height", function()
    local content = { getSize = function() return { w = 80, h = 40 } end }
    local card = Kit.card{ content, width = 120, height = 100 }
    local shadow
    local bb = { paintRoundedRect = function(_s, x, y, w, h, c)
        if c == Kit.SHADOW and not shadow then shadow = { w = w, h = h } end
    end }
    card:paintTo(bb, 0, 0)
    eq(shadow.w, 120); eq(shadow.h, 100)
end)

t.test("a button whose window closed is left alone", function()
    local editor = press(function() stack = {} end)
    assert(not letUp(editor), "repainted a window that had closed")
end)

-- A press refreshed "fast" is black and white only on e-ink: a grey card
-- went white (maintainer: the module card "loses its grey background on
-- tap"), and a black button's rounded corners went jagged ("ugly
-- corners"). Every press refreshes with "ui".
local function pressMode(card)
    stack = { { name = "editor" } }
    for i = #dirty, 1, -1 do dirty[i] = nil end
    Kit.pressThen({ dimen = { x = 10, y = 20, w = 90, h = 80 } }, card, function() end)
    return dirty[1] and dirty[1].mode
end

t.test("a grey card is pressed with a refresh that keeps its grey", function()
    eq(pressMode({ _kit_card = true }), "ui")
end)

t.test("a button pressed black keeps its smooth corners", function()
    eq(pressMode({}), "ui")
end)

-- The Modules card closes the editor: the shelf behind showed through the
-- card for a moment (maintainer, PW5). The panel had not finished reading
-- the pressed card's refresh when the close painted the shelf under it.
-- KOReader's Button yields to the EPDC between the two; so does this.
t.test("the panel gets a moment between the press and the action", function()
    for i = #seq, 1, -1 do seq[i] = nil end
    press(function() seq[#seq + 1] = "act" end)
    eq(table.concat(seq, ","), "flush,yield,act")
end)

-- The 1 ms was not enough on the PW5 (a MediaTek Kindle): KOReader sends a
-- refresh there without waiting for the panel to take it, and the close
-- wrote the shelf back under the card 20 ms later (logged on the device).
-- Where the screen can say when a refresh was taken, the press waits for it.
t.test("the press waits until the panel has taken the pressed card", function()
    for i = #seq, 1, -1 do seq[i] = nil end
    screen.marker = 41
    screen.mech_wait_update_submission = function(_fb, marker) seq[#seq + 1] = "taken " .. marker; return 0 end
    press(function() seq[#seq + 1] = "act" end)
    screen.marker, screen.mech_wait_update_submission = nil, nil
    eq(table.concat(seq, ","), "flush,taken 41,act")
end)

t.done()
