-- tests/_test_rounded_rect_night_invert.lua
-- CoverProgress.paintRoundedRect with a true-colour fill on Android in night
-- mode. KOReader's paintRoundedRectRGB32 draws its corners through
-- paintRoundedCorner, a Lua pixel loop that applies the buffer's invert flag
-- itself; on Android the whole frame is inverted again at blit time, so the
-- corners land back on the raw colour while the straight parts are inverted
-- once (the selection ring: white edges, black corners in dark mode). Same
-- cause as the border fix for #217 (_paintColorSafeBorder): the flag has to
-- be off for just that call.
-- Usage: `lua tests/_test_rounded_rect_night_invert.lua` from the plugin dir.

package.path = "./?.lua;" .. package.path

local function make_widget_base()
    local W = {}
    W.__index = W
    function W:extend(o) o = o or {}; setmetatable(o, self); self.__index = self; return o end
    function W:new(o) o = o or {}; setmetatable(o, self); self.__index = self; if self.init then self:init() end; return o end
    function W:init() end
    return W
end
for _, name in ipairs({
    "ui/widget/widget", "ui/widget/overlapgroup",
    "ui/widget/container/framecontainer", "ui/widget/container/centercontainer",
}) do
    package.preload[name] = function() return make_widget_base() end
end
package.preload["ui/widget/textwidget"] = function() return { new = function(_, t) return t end } end
package.preload["ui/font"] = function() return { getFace = function() return {} end } end
package.preload["ui/geometry"] = function()
    return { new = function(_, t) return setmetatable(t or {}, { __index = {} }) end }
end
package.preload["ffi/blitbuffer"] = function()
    return {
        Color8 = function(n) return { v = n } end,
        ColorRGB32 = function(r, g, b, a) return { rgb = true, r = r, g = g, b = b, a = a } end,
        COLOR_WHITE = {}, COLOR_BLACK = {},
        isColor8 = function(c) return not (type(c) == "table" and c.rgb) end,
    }
end
package.preload["ffi"] = function()
    return {
        typeof = function(name) return name end,
        istype = function(t, v) return t == "ColorRGB32" and type(v) == "table" and v.rgb == true end,
        metatype = function() end, cdef = function() end, new = function() return {} end,
    }
end
local android = true
package.preload["device"] = function()
    return {
        isAndroid = function() return android end,
        screen = {
            isColorEnabled = function() return true end,
            scaleBySize = function(_, n) return n end,
        },
    }
end
package.preload["lib/bookshelf_settings_store"] = function()
    return {
        read = function() return nil end, save = function() end,
        isTrue = function() return false end, nilOrTrue = function() return true end,
        generation = function() return 1 end,
    }
end

local CP = require("lib/bookshelf_cover_progress")
local Color = require("lib/bookshelf_color")

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1
    else fail = fail + 1; io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n") end
end

-- A buffer that records the invert flag each paint ran with.
local function fakeBB(inverse)
    local bb = { inv = inverse, calls = {} }
    function bb:getInverse() return self.inv end
    function bb:setInverse(v) self.inv = v end
    function bb:paintRoundedRectRGB32() self.calls[#self.calls + 1] = { "rgb", self.inv } end
    function bb:paintRoundedRect() self.calls[#self.calls + 1] = { "c8", self.inv } end
    function bb:paintBorderRGB32() self.calls[#self.calls + 1] = { "rgb", self.inv } end
    function bb:paintBorder() self.calls[#self.calls + 1] = { "c8", self.inv } end
    return bb
end
local RED = { rgb = true, r = 200, g = 0, b = 0 }

test("Android night, true colour: painted with the invert flag off, then restored", function()
    android = true
    local bb = fakeBB(1)
    CP.paintRoundedRect(bb, 0, 0, 100, 150, RED, 12)
    assert(#bb.calls == 1 and bb.calls[1][1] == "rgb", "painted once, RGB32")
    assert(bb.calls[1][2] == 0, "invert flag during the paint: " .. tostring(bb.calls[1][2]))
    assert(bb.inv == 1, "flag restored")
end)

test("not Android: the flag is left alone (the device inverts nothing itself)", function()
    android = false
    local bb = fakeBB(1)
    CP.paintRoundedRect(bb, 0, 0, 100, 150, RED, 12)
    assert(bb.calls[1][2] == 1)
    android = true
end)

test("a grey colour takes the C path and keeps the flag", function()
    local bb = fakeBB(1)
    CP.paintRoundedRect(bb, 0, 0, 100, 150, { v = 0 }, 12)
    assert(bb.calls[1][1] == "c8" and bb.calls[1][2] == 1)
end)

test("by day nothing changes", function()
    local bb = fakeBB(0)
    CP.paintRoundedRect(bb, 0, 0, 100, 150, RED, 12)
    assert(bb.calls[1][2] == 0 and bb.inv == 0)
end)

-- The same guard on every rounded true-colour paint that shares it.
for _, case in ipairs({
    { "CoverProgress.paintBorder", function(bb) CP.paintBorder(bb, 0, 0, 100, 150, 4, RED, 12) end },
    { "Color.paintRoundedRect", function(bb) Color.paintRoundedRect(bb, 0, 0, 100, 150, RED, 12) end },
    { "Color.paintBorder", function(bb) Color.paintBorder(bb, 0, 0, 100, 150, 4, RED, 12) end },
}) do
    test(case[1] .. ": Android night paints with the flag off and restores it", function()
        android = true
        local bb = fakeBB(1)
        case[2](bb)
        assert(#bb.calls == 1 and bb.calls[1][1] == "rgb", "painted once, RGB32")
        assert(bb.calls[1][2] == 0, "invert flag during the paint: " .. tostring(bb.calls[1][2]))
        assert(bb.inv == 1, "flag restored")
    end)
end

print(string.format("PASS %d  FAIL %d", pass, fail))
if fail > 0 then os.exit(1) end
