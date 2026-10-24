-- tests/_test_clip_container_gestures.lua
-- The clip container paints a module into an offscreen buffer at its own
-- origin, so the module's widgets know their places relative to the clip, not
-- the screen. With pass_gestures, a gesture reaches them moved into that
-- frame (a module's own buttons work in a card as they do in a bare module);
-- without it they get none (a picker preview must not take the pick's tap).
package.path = "./?.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()

package.loaded["ffi/blitbuffer"] = { COLOR_WHITE = 0 }
package.loaded["ui/geometry"] = { new = function(_s, o) return o end }
local WC = {}
WC.__index = WC
function WC:extend(o) o = o or {}; o.__index = o; return setmetatable(o, self) end
function WC:new(o) o = o or {}; return setmetatable(o, self) end
function WC:propagateEvent(ev)
    for _i, c in ipairs(self) do if c:handleEvent(ev) then return true end end
    return false
end
function WC:handleEvent(ev) return self:propagateEvent(ev) end
package.loaded["ui/widget/container/widgetcontainer"] = WC
local CC = dofile("lib/bookshelf_clip_container.lua")

local function child()
    return { handleEvent = function(self, ev) self.got = ev; return true end }
end
-- Built as KOReader's Event:new builds one: handler = "on" .. name.
local function event(name, ...) return { handler = "on" .. name, args = { ... } } end
local function gesture(x, y) return event("Gesture", { ges = "tap", pos = { x = x, y = y } }) end

t.test("with pass_gestures the child gets the gesture in its painted frame", function()
    local c = child()
    local clip = CC:new{ w = 100, h = 80, pass_gestures = true, c }
    clip.dimen = { x = 300, y = 500, w = 100, h = 80 }
    local ev = gesture(330, 560)
    assert(clip:handleEvent(ev) == true, "not taken")
    local pos = c.got.args[1].pos
    assert(pos.x == 30 and pos.y == 60, "wrong frame: " .. pos.x .. "," .. pos.y)
    assert(ev.args[1].pos.x == 330, "the caller's gesture was changed")
end)

t.test("outside the clip, or before it has painted, nothing reaches the child", function()
    local c = child()
    local clip = CC:new{ w = 100, h = 80, pass_gestures = true, c }
    assert(clip:handleEvent(gesture(330, 560)) == false and c.got == nil, "passed before any paint")
    clip.dimen = { x = 300, y = 500, w = 100, h = 80 }
    assert(clip:handleEvent(gesture(10, 10)) == false and c.got == nil, "passed a tap elsewhere on screen")
end)

t.test("only taps pass: long-press and swipes stay the grid's", function()
    local c = child()
    local clip = CC:new{ w = 100, h = 80, pass_gestures = true, c }
    clip.dimen = { x = 300, y = 500, w = 100, h = 80 }
    for _i, kind in ipairs({ "hold", "swipe", "pinch" }) do
        local ev = gesture(330, 560); ev.args[1].ges = kind
        assert(clip:handleEvent(ev) == false and c.got == nil, kind .. " reached the module")
    end
    local ev = gesture(330, 560); ev.args[1].ges = "double_tap"
    assert(clip:handleEvent(ev) == true, "double tap")
end)

t.test("without pass_gestures the child gets no gestures; other events pass", function()
    local c = child()
    local clip = CC:new{ w = 100, h = 80, c }
    clip.dimen = { x = 300, y = 500, w = 100, h = 80 }
    assert(clip:handleEvent(gesture(330, 560)) == false and c.got == nil, "a preview took the tap")
    assert(clip:handleEvent(event("CloseWidget")) == true, "non-gesture events stopped")
end)

t.test("the grids and the start menu pass gestures; the picker doesn't", function()
    local hero = io.open("lib/bookshelf_hero_modules.lua"):read("*a")
    local sm = io.open("lib/bookshelf_start_menu.lua"):read("*a")
    local pk = io.open("lib/bookshelf_module_picker.lua"):read("*a")
    assert(hero:find("pass_gestures = true", 1, true), "grid cells")
    assert(sm:find("pass_gestures = true", 1, true), "start menu rows")
    assert(not pk:find("pass_gestures", 1, true), "picker previews")
end)

t.test("an in_place module is painted on its card, not through the clip", function()
    local hero = io.open("lib/bookshelf_hero_modules.lua"):read("*a")
    assert(hero:find("local in_place = bare or (def and def.in_place)", 1, true), "in_place not read")
    assert(hero:find("if in_place then\n        clip = CenterContainer", 1, true), "still clipped")
end)

t.done()
