-- tests/_test_tap_cell_nested.lua
-- A kit tap cell inside another (a sort level's card holding its direction
-- switch) was handed the outer card's Tap: KOReader re-sends a matched
-- gesture as a "Tap" event to the card's children first, and the switch's
-- first segment took it whatever was tapped. A tap on level 2's name did
-- nothing, or flipped level 1's direction (maintainer, PW5). A cell acts
-- only on a tap inside it; one outside goes on to the card.
--
-- Usage (from plugin root): lua tests/_test_tap_cell_nested.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq

local stack, dirty = {}, {}
package.loaded["ui/uimanager"] = {
    widgetRepaint = function() end,
    forceRePaint = function() end,
    yieldToEPDC = function() end,
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

local function cellAt(x, y, w, h)
    local hits = 0
    local cell = Kit.tapCell({}, w, h, function() hits = hits + 1 end)
    cell.dimen.x, cell.dimen.y = x, y
    return cell, function() return hits end
end

t.test("a tap outside the cell is left for the card around it", function()
    local seg, hits = cellAt(618, 336, 212, 68)
    local handled = seg.onTap(seg, nil, { pos = { x = 300, y = 370 } })
    eq(hits(), 0, "the switch acted on a tap on the level's name")
    assert(not handled, "the switch swallowed a tap that wasn't on it")
end)

t.test("a tap inside the cell acts", function()
    local seg, hits = cellAt(618, 336, 212, 68)
    assert(seg.onTap(seg, nil, { pos = { x = 700, y = 370 } }))
    eq(hits(), 1)
end)

t.test("a tap with no position (sent by code, not a finger) still acts", function()
    local seg, hits = cellAt(618, 336, 212, 68)
    assert(seg.onTap(seg, nil, nil))
    eq(hits(), 1)
end)

-- A choice (a sort key, an option) shows itself picked once the page is
-- drawn again. Shown pressed first as well, each tap went through a black
-- and white "fast" frame, the page, then the shelf (maintainer, PW5: "each
-- card style button goes through several states before settling").
t.test("an instant cell acts with no pressed frame", function()
    dirty = {}
    local card = { _kit_card = true }
    local hits = 0
    local cell = Kit.tapCell({ card }, 100, 50, function()
        hits = hits + 1
        assert(not card._pressed, "shown pressed while acting")
    end, true, nil, true)
    cell.dimen.x, cell.dimen.y = 10, 10
    stack = { "page" }
    assert(cell.onTap(cell, nil, { pos = { x = 20, y = 20 } }))
    eq(hits, 1)
    eq(#dirty, 0, "a refresh of its own")
end)

t.test("a cell that goes somewhere is still shown pressed", function()
    dirty = {}
    local card = { _kit_card = true }
    local cell = Kit.tapCell({ card }, 100, 50, function() end)
    cell.dimen.x, cell.dimen.y = 10, 10
    stack = { "page" }
    cell.onTap(cell, nil, { pos = { x = 20, y = 20 } })
    eq(dirty[1] and dirty[1].mode, "ui")
end)

t.done()
