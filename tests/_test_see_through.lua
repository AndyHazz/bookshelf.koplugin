-- tests/_test_see_through.lua
-- A faded book is see-through (lib/bookshelf_see_through.lua): what was
-- behind it is copied before it paints and mixed back over it afterwards.
-- It used to be washed with white, which only looks faded on a white page.

package.path = "./?.lua;" .. package.path

local made = {}
local function fakeBB(w, h, typ)
    local b = { w = w, h = h, typ = typ, calls = {} }
    function b:getWidth() return self.w end
    function b:getHeight() return self.h end
    function b:getType() return self.typ end
    function b:blitFrom(src, dx, dy, ox, oy, bw, bh)
        self.calls[#self.calls + 1] = { "blit", src, dx, dy, ox, oy, bw, bh }
    end
    function b:addblitFrom(src, dx, dy, ox, oy, bw, bh, a)
        self.calls[#self.calls + 1] = { "add", src, dx, dy, ox, oy, bw, bh, a }
    end
    function b:free() self.freed = true end
    return b
end
package.preload["ffi/blitbuffer"] = function()
    return { new = function(w, h, typ)
        local b = fakeBB(w, h, typ); made[#made + 1] = b; return b
    end }
end
package.preload["lib/bookshelf_clip_bb"] = function()
    return { real = function(bb) return bb._real or bb end }
end

local See = require("lib/bookshelf_see_through")
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq

t.test("take copies the rect behind, in the target's own type", function()
    made = {}
    local screen = fakeBB(600, 800, "T8")
    local keep = See.take(screen, 10, 20, 100, 150)
    assert(keep, "a keep")
    eq(#made, 1); eq(made[1].w, 100); eq(made[1].h, 150); eq(made[1].typ, "T8")
    local c = made[1].calls[1]
    eq(c[1], "blit"); assert(c[2] == screen, "read from the target")
    eq(c[3], 0); eq(c[4], 0); eq(c[5], 10); eq(c[6], 20); eq(c[7], 100); eq(c[8], 150)
end)

t.test("put mixes the copy back over the book at the strength, then frees it", function()
    made = {}
    local screen = fakeBB(600, 800, "T8")
    local keep = See.take(screen, 10, 20, 100, 150)
    eq(See.put(keep, screen, 0.6), true)
    local c = screen.calls[1]
    eq(c[1], "add"); assert(c[2] == made[1], "the copy is what is mixed in")
    eq(c[3], 10); eq(c[4], 20); eq(c[5], 0); eq(c[6], 0); eq(c[7], 100); eq(c[8], 150)
    eq(c[9], 0.6)
    eq(made[1].freed, true)
end)

t.test("a rect hanging off the target is cut to what is on it", function()
    made = {}
    local screen = fakeBB(600, 800, "T8")
    local keep = See.take(screen, -10, 790, 100, 150)
    eq(made[1].w, 90); eq(made[1].h, 10)
    local c = made[1].calls[1]
    eq(c[5], 0); eq(c[6], 790)
    See.put(keep, screen, 0.5)
    local a = screen.calls[1]
    eq(a[3], 0); eq(a[4], 790); eq(a[7], 90); eq(a[8], 10)
end)

t.test("nothing on the target, or nothing to read: no keep", function()
    local screen = fakeBB(600, 800, "T8")
    eq(See.take(screen, 700, 0, 50, 50), nil)
    eq(See.take(screen, 0, 0, 0, 50), nil)
    eq(See.take(nil, 0, 0, 5, 5), nil)
    eq(See.take({}, 0, 0, 5, 5), nil)
end)

t.test("the copy reads the real buffer behind a clipping wrapper", function()
    made = {}
    local screen = fakeBB(600, 800, "T8")
    local wrap = fakeBB(600, 800, "T8"); wrap._real = screen
    See.take(wrap, 1, 2, 3, 4)
    assert(made[1].calls[1][2] == screen, "read from the real buffer")
end)

t.test("put with no keep, no strength or a failing blit paints nothing and is safe", function()
    local screen = fakeBB(600, 800, "T8")
    eq(See.put(nil, screen, 0.6), false)
    made = {}
    local keep = See.take(screen, 0, 0, 5, 5)
    eq(See.put(keep, screen, 0), false)
    eq(made[1].freed, true, "freed even when not painted")
    made = {}
    keep = See.take(screen, 0, 0, 5, 5)
    screen.addblitFrom = function() error("boom") end
    eq(See.put(keep, screen, 0.6), false)
    eq(made[1].freed, true)
end)

t.test("a failed copy is no keep, not an error at paint time", function()
    local screen = fakeBB(600, 800, "T8")
    screen.getType = function() error("no type") end
    eq(See.take(screen, 0, 0, 5, 5), nil)
end)

t.done()
