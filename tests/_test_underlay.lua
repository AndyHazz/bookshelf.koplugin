-- tests/_test_underlay.lua
-- The shelf's pixels under a window shown over it are kept, and put back
-- when the window closes, instead of the shelf repainting itself whole
-- (lib/bookshelf_underlay).
--
-- Usage (from plugin root): lua tests/_test_underlay.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local t  = dofile("tests/_helpers.lua").runner()
local eq = dofile("tests/_helpers.lua").eq

-- A screen of W x H "pixels" (a 2-D table), and buffers the same shape.
local W, H = 100, 100
local function newBB(w, h)
    local b = { w = w, h = h, px = {} }
    for y = 0, h - 1 do b.px[y] = {} end
    function b:getType() return 1 end
    function b:getWidth() return self.w end
    function b:getHeight() return self.h end
    function b:blitFrom(src, dx, dy, ox, oy, cw, ch)
        for yy = 0, ch - 1 do for xx = 0, cw - 1 do
            self.px[dy + yy][dx + xx] = src.px[oy + yy][ox + xx]
        end end
    end
    function b:fillRect(x, y, w2, h2, v)
        for yy = y, y + h2 - 1 do for xx = x, x + w2 - 1 do self.px[yy][xx] = v end end
    end
    b.paintRect = b.fillRect
    function b:free() self.freed = true end
    return b
end
local Screen = { bb = newBB(W, H), getWidth = function() return W end, getHeight = function() return H end }
package.loaded["device"] = { screen = Screen }
package.loaded["logger"] = { dbg = function() end, warn = function() end, info = function() end }
package.loaded["ffi/blitbuffer"] = { new = function(w, h) return newBB(w, h) end }

package.loaded["ui/uimanager"] = { show = function() end, close = function() end,
                                   isWidgetShown = function() return true end }
local U = dofile("lib/bookshelf_underlay.lua")
U.TILE = 10

local function window(name, x, y, w, h)
    local win = { name = name }
    function win:getSize() return { w = w, h = h } end
    -- Drawn the way a widget draws: a fill on the buffer it is handed.
    function win.paintTo(self, bb) bb:paintRect(x, y, w, h, "dialog:" .. name) end
    return win, x, y
end

t.test("a window's close puts the shelf back where it painted", function()
    U._reset()
    Screen.bb:fillRect(0, 0, W, H, "shelf")
    U.install({})                 -- no UIManager here: only shown/closing are driven
    local menu, x, y = window("menu", 10, 10, 20, 20)
    local own = menu.paintTo
    U.shown(menu)
    menu:paintTo(Screen.bb, x, y)
    eq(Screen.bb.px[15][15], "dialog:menu")
    assert(U.closing(menu), "nothing was put back")
    eq(Screen.bb.px[15][15], "shelf")
    assert(rawget(menu, "paintTo") == own, "the window kept the wrapper, or lost its own paintTo")
end)

t.test("overlapping windows: the oldest copy wins, so no dialog pixels come back", function()
    U._reset()
    Screen.bb:fillRect(0, 0, W, H, "shelf")
    U.install({})
    local a, ax, ay = window("a", 10, 10, 30, 30)
    local b, bx, by = window("b", 20, 20, 30, 30)
    U.shown(a); a:paintTo(Screen.bb, ax, ay)
    U.shown(b); b:paintTo(Screen.bb, bx, by)     -- copies a's pixels at 20..40
    U.closing(b)
    -- Every covered pixel is the shelf again; a repaints itself (UIManager
    -- marks the windows still up as dirty).
    eq(Screen.bb.px[25][25], "shelf"); eq(Screen.bb.px[45][45], "shelf")
    U.closing(a)
    eq(Screen.bb.px[15][15], "shelf")
end)

t.test("a shelf paint under a window drops the copies; a big window isn't copied", function()
    U._reset()
    Screen.bb:fillRect(0, 0, W, H, "shelf")
    U.install({})
    local m, x, y = window("m", 0, 0, 10, 10)
    U.shown(m); m:paintTo(Screen.bb, x, y)
    U.invalidate()
    assert(not U.closing(m), "put back a stale copy")
    local big, bx, by = window("reader", 0, 0, 90, 90)
    U.shown(big); big:paintTo(Screen.bb, bx, by)
    assert(not U.closing(big), "a large window was copied")
    -- ...but the sleep screen is, whole.
    local ss, sx, sy = window("ScreenSaver", 0, 0, W, H)
    Screen.bb:fillRect(0, 0, W, H, "shelf")
    U.shown(ss); ss:paintTo(Screen.bb, sx, sy)
    assert(U.closing(ss), "the sleep screen wasn't put back")
    eq(Screen.bb.px[50][50], "shelf")
end)

t.test("only the tiles a window draws on are copied, each once", function()
    U._reset()
    Screen.bb:fillRect(0, 0, W, H, "shelf")
    U.install({})
    local m, x, y = window("m", 5, 5, 10, 10)        -- tiles (0,0)-(1,1)
    U.shown(m); m:paintTo(Screen.bb, x, y); m:paintTo(Screen.bb, x, y)
    -- 4 tiles, copied as two row runs.
    local n = 0
    for _k in pairs(U._debugPieces()) do n = n + 1 end
    eq(n, 2)
    assert(U.closing(m)); eq(Screen.bb.px[6][6], "shelf")
end)

t.test("a window that reads the screen back is painted directly, and not kept", function()
    U._reset()
    Screen.bb:fillRect(0, 0, W, H, "shelf")
    U.install({})
    local m = { name = "reader-back" }
    function m:getSize() return { w = 10, h = 10 } end
    local direct = false
    function m.paintTo(self, bb)
        if rawget(bb, "_is_cow") then error("cannot convert table") end
        direct = true
        bb:paintRect(0, 0, 10, 10, "dialog")
    end
    U.shown(m); m:paintTo(Screen.bb, 0, 0)
    assert(direct, "not painted at all")
    assert(not U.closing(m), "kept what it couldn't copy")
end)

t.test("a window covering the whole screen (the reader) isn't tracked or copied", function()
    U._reset()
    Screen.bb:fillRect(0, 0, W, H, "shelf")
    U.install({})
    local r, x, y = window("ReaderUI", 0, 0, W, H)
    r.covers_fullscreen = true
    local own = r.paintTo
    U.shown(r)
    assert(rawget(r, "paintTo") == own, "the reader paints through the stand-in")
    assert(not U.covered())
    local ss = window("ScreenSaver", 0, 0, W, H)
    ss.covers_fullscreen = true
    U.shown(ss)
    assert(U.covered(), "the sleep screen isn't tracked")
end)

t.test("a draw that would pass the limit copies nothing", function()
    U._reset()
    Screen.bb:fillRect(0, 0, W, H, "shelf")
    U.install({})
    local big, x, y = window("popup", 0, 0, 90, 90)
    U.shown(big); big:paintTo(Screen.bb, x, y)
    eq(#U._debugPieces(), 0, "copied tiles it then threw away")
    assert(not U.closing(big))
end)

t.test("the shelf lets only the restoring close go unpainted", function()
    local src = io.open("lib/bookshelf_widget.lua"):read("*a")
    assert(src:find('if widget == self and refreshtype == nil\n            and require("lib/bookshelf_underlay").restoring() then', 1, true))
    assert(src:find("if Underlay.covered() then Underlay.invalidate() end", 1, true),
        "a shelf paint under a window keeps a stale copy")
    local main = io.open("main.lua"):read("*a")
    assert(main:find('UIManager:setDirty(nil, "full")', 1, true), "wake still repaints the shelf whole")
end)

t.done()
