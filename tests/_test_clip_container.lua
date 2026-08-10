-- tests/_test_clip_container.lua
-- lib/bookshelf_clip_container: the fixed-size cell that paints its child
-- into a real offscreen buffer (correct pixel_stride, hard containment) and
-- blits the result. Contracts: centring/clamping of the child, bg fill every
-- paint, and the scratch-buffer reuse that replaced a fresh alloc+free per
-- cell per repaint (the minute clock tick repainted every cell).
package.path = "./?.lua;./?/init.lua;" .. package.path

-- ── stubs ───────────────────────────────────────────────────────────────────
local made = {}   -- every Blitbuffer.new result, in order
local function make_bb(w, h, bbtype)
    local bb = {
        w = w, h = h, bbtype = bbtype,
        fills = {}, blits = {}, freed = 0,
    }
    function bb:getType() return self.bbtype end
    function bb:fill(color) self.fills[#self.fills + 1] = color end
    function bb:blitFrom(src, x, y, sx, sy, bw, bh)
        self.blits[#self.blits + 1] = { src = src, x = x, y = y,
                                        sx = sx, sy = sy, w = bw, h = bh }
    end
    function bb:free() self.freed = self.freed + 1 end
    return bb
end
package.loaded["ffi/blitbuffer"] = {
    COLOR_WHITE = "WHITE",
    new = function(w, h, bbtype)
        local bb = make_bb(w, h, bbtype)
        made[#made + 1] = bb
        return bb
    end,
}
package.loaded["ui/geometry"] = {
    new = function(_self, t) return t or {} end,
}
local WidgetContainer = {}
WidgetContainer.__index = WidgetContainer
function WidgetContainer:extend(props)
    local cls = props or {}
    cls.__index = cls
    setmetatable(cls, { __index = self })
    function cls:new(o)
        o = o or {}
        setmetatable(o, cls)
        return o
    end
    return cls
end
package.loaded["ui/widget/container/widgetcontainer"] = WidgetContainer

local Clip = dofile("lib/bookshelf_clip_container.lua")
local t = dofile("tests/_helpers.lua").runner()

local function child(w, h)
    return {
        getSize = function() return { w = w, h = h } end,
        painted = {},
        paintTo = function(self, bb, x, y)
            self.painted[#self.painted + 1] = { bb = bb, x = x, y = y }
        end,
    }
end

local function screen() return make_bb(800, 600, 7) end

t.test("getSize reports the fixed cell, not the child", function()
    local c = Clip:new{ w = 40, h = 30, child(200, 200) }
    local s = c:getSize()
    assert(s.w == 40 and s.h == 30)
end)

t.test("a smaller child is centred in the offscreen buffer", function()
    local kid = child(10, 10)
    local c = Clip:new{ w = 20, h = 20, kid }
    c:paintTo(screen(), 100, 50)
    local p = kid.painted[1]
    assert(p.x == 5 and p.y == 5, "centred at (5,5), got " .. p.x .. "," .. p.y)
    assert(p.bb ~= nil and p.bb.w == 20 and p.bb.h == 20,
        "child painted into the w x h offscreen buffer")
end)

t.test("an oversized child is top-/left-aligned (offsets clamp at 0)", function()
    local kid = child(50, 50)
    local c = Clip:new{ w = 20, h = 20, kid }
    c:paintTo(screen(), 0, 0)
    local p = kid.painted[1]
    assert(p.x == 0 and p.y == 0, "clamped, got " .. p.x .. "," .. p.y)
end)

t.test("the offscreen result is blitted at the cell position", function()
    local kid = child(10, 10)
    local c = Clip:new{ w = 20, h = 20, kid }
    local scr = screen()
    c:paintTo(scr, 100, 50)
    local b = scr.blits[1]
    assert(b and b.x == 100 and b.y == 50 and b.w == 20 and b.h == 20)
    assert(b.src == kid.painted[1].bb, "blit source is the buffer the child painted into")
end)

t.test("no child, no offscreen work", function()
    local c = Clip:new{ w = 20, h = 20 }
    local scr = screen()
    local before = #made
    c:paintTo(scr, 0, 0)
    assert(#made == before, "no buffer allocated for an empty cell")
    assert(#scr.blits == 0, "nothing blitted")
end)

t.test("scratch buffer is reused across paints of the same size", function()
    local kid = child(10, 10)
    local c = Clip:new{ w = 20, h = 20, kid }
    c:paintTo(screen(), 0, 0)
    local off = kid.painted[1].bb
    -- The 20x20 scratch is shared with earlier tests' cells, so measure the
    -- fill DELTA rather than an absolute count.
    local fills_before = #off.fills
    c:paintTo(screen(), 0, 0)
    c:paintTo(screen(), 0, 0)
    assert(kid.painted[2].bb == off and kid.painted[3].bb == off,
        "same scratch buffer on every paint")
    assert(#off.fills == fills_before + 2, "background re-filled on every paint")
    assert(off.freed == 0, "reused scratch is never freed mid-life")
end)

t.test("cells of the same size share one scratch; sizes get their own", function()
    local a, b, cwide = child(5, 5), child(5, 5), child(5, 5)
    local ca = Clip:new{ w = 20, h = 20, a }
    local cb = Clip:new{ w = 20, h = 20, b }
    local cw = Clip:new{ w = 40, h = 20, cwide }
    local scr = screen()
    ca:paintTo(scr, 0, 0); cb:paintTo(scr, 0, 0); cw:paintTo(scr, 0, 0)
    assert(a.painted[1].bb == b.painted[1].bb, "same size shares the scratch")
    assert(cwide.painted[1].bb ~= a.painted[1].bb, "another size gets its own")
end)

t.test("bg fill: custom colour used, white by default", function()
    local kid = child(5, 5)
    Clip:new{ w = 10, h = 10, bg = "GRAY", kid }:paintTo(screen(), 0, 0)
    assert(kid.painted[1].bb.fills[#kid.painted[1].bb.fills] == "GRAY")
    local kid2 = child(5, 5)
    Clip:new{ w = 11, h = 11, kid2 }:paintTo(screen(), 0, 0)
    assert(kid2.painted[1].bb.fills[1] == "WHITE")
end)

t.test("child centring offsets are recorded for tap-region translation", function()
    local kid = child(10, 10)
    local c = Clip:new{ w = 20, h = 20, kid }
    c:paintTo(screen(), 100, 50)
    assert(c._child_dx == 5 and c._child_dy == 5,
        "centred child offsets recorded, got " .. tostring(c._child_dx)
        .. "," .. tostring(c._child_dy))
    -- Screen position of the child's origin = dimen + recorded offsets:
    -- the sum the hosts use to translate a tap into child-local coords.
    assert(c.dimen.x + c._child_dx == 105 and c.dimen.y + c._child_dy == 55)
    local big = child(50, 50)
    local c2 = Clip:new{ w = 20, h = 20, big }
    c2:paintTo(screen(), 0, 0)
    assert(c2._child_dx == 0 and c2._child_dy == 0, "clamped offsets recorded")
end)

t.test("scratch map caps at 8 sizes, then frees and starts over", function()
    -- Paint 8 distinct sizes, hold on to their buffers...
    local firsts = {}
    for i = 1, 8 do
        local kid = child(1, 1)
        Clip:new{ w = 100 + i, h = 50, kid }:paintTo(screen(), 0, 0)
        firsts[i] = kid.painted[1].bb
    end
    -- ...the 9th size trips the cap: all cached scratches are freed.
    local kid9 = child(1, 1)
    Clip:new{ w = 200, h = 50, kid9 }:paintTo(screen(), 0, 0)
    local freed = 0
    for _i, bb in ipairs(firsts) do freed = freed + bb.freed end
    assert(freed > 0, "overflow frees the stale scratch set")
    -- The map restarts cleanly: the new size is cached and reused.
    local kid9b = child(1, 1)
    Clip:new{ w = 200, h = 50, kid9b }:paintTo(screen(), 0, 0)
    assert(kid9b.painted[1].bb == kid9.painted[1].bb, "fresh map reuses again")
end)

t.done()
