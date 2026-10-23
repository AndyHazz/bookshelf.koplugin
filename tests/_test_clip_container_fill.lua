-- tests/_test_clip_container_fill.lua
-- The clip buffer's fill: a colour card on a colour screen keeps its colour
-- (fill() would flatten it to grey), and a grey card fills as before. A grey
-- is a Color8 cdata, which RAISES on a field it doesn't have: testing it for
-- `.r` crashed the start menu on a greyscale PW5.
package.path = "./?.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()

-- Strict colours, like cdata: reading a missing field is an error.
local function strict(fields, kind)
    return setmetatable(fields, { __index = function(_, k)
        error("'struct " .. kind .. "' has no member named '" .. tostring(k) .. "'")
    end })
end
local function color8(v)
    return strict({ a = v, getColorRGB32 = function() return { r = v, g = v, b = v } end }, "Color8")
end
local function rgb32(r, g, b)
    local c
    c = strict({ r = r, g = g, b = b, alpha = 255, getColorRGB32 = function() return c end }, "ColorRGB32")
    return c
end

local calls
local function bufferOf(kind)
    return {
        getType = function() return kind end,
        fill = function(_, c) calls[#calls + 1] = { "fill", c } end,
        paintRectRGB32 = function(_, _x, _y, _w, _h, c) calls[#calls + 1] = { "rgb", c } end,
    }
end

local Blitbuffer = {
    TYPE_BB8 = "bb8", TYPE_BBRGB32 = "rgb32",
    COLOR_WHITE = color8(0xFF),
    isColor8 = function(c) return rawget(c, "a") ~= nil and rawget(c, "r") == nil end,
}
local current_off
Blitbuffer.new = function() return current_off end

package.loaded["ffi/blitbuffer"] = Blitbuffer
package.loaded["ui/geometry"] = { new = function(_, o) return o end }
local WC = {}
WC.__index = WC
function WC:extend(o) o = o or {}; o.__index = o; return setmetatable(o, self) end
package.loaded["ui/widget/container/widgetcontainer"] = WC
local Clip = dofile("lib/bookshelf_clip_container.lua")

local child = { getSize = function() return { w = 10, h = 10 } end, paintTo = function() end }
local function paint(screen_kind, bg)
    calls = {}
    current_off = bufferOf(screen_kind)
    local c = setmetatable({ w = 10, h = 10, bg = bg, child }, { __index = Clip })
    c:paintTo({ getType = function() return screen_kind end, blitFrom = function() end }, 0, 0)
    return calls[1]
end

t.test("a grey card on a greyscale screen fills, and does not crash", function()
    local call = paint("bb8", color8(0xEE))
    assert(call and call[1] == "fill", "a grey card was not filled")
end)

t.test("a grey card on a colour screen fills too", function()
    local call = paint("rgb32", color8(0xEE))
    assert(call and call[1] == "fill", "a grey card took the colour path")
end)

t.test("a colour card on a colour screen keeps its colour", function()
    local call = paint("rgb32", rgb32(0xF3, 0xED, 0xE0))
    assert(call and call[1] == "rgb", "a colour card was flattened by fill()")
end)

t.done()
