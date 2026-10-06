-- tests/_test_footer_on_wall.lua
-- The footer's panel sits on the wall, behind the shelf, and the panels can
-- blur the picture behind them (Panel shading > Blur the picture behind
-- panels).
--
-- 1. PAINT ORDER. The footer row paints after everything else, so its tint
--    used to go over the bottom row's plank design (a sofa's fringe, an
--    apron) where that reaches into the footer. The panel is now painted
--    under the rows -- from inner_content, after the page ground -- and the
--    row paints only its buttons. Source-matched: the widget cannot be run.
-- 2. RESTORE. With the panel under the rows, anything that puts the picture
--    back inside it (restore) must put the panel back too: the footer panel
--    is registered with the wallpaper module, as the top panel always was.
-- 3. THE ERASER. The start menu's close X erases the hamburger. Replaying
--    picture and tint would wipe the plank design in front of the panel, so
--    the shelf keeps a copy of what is under the button before the buttons
--    paint, and the eraser uses it while the shelf is what the menu is over.
-- 4. THE BLUR. Built once per panel rect and picture, then blitted; only
--    asked for over a picture, never at Solid; cleared with the picture.
--
-- Usage (from plugin root): lua tests/_test_footer_on_wall.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
package.loaded["logger"] = { dbg = function() end, info = function() end,
                             warn = function() end, err = function() end }
do
    local W = {}
    W.extend = function(self, sub) sub = sub or {}; setmetatable(sub, { __index = self }); return sub end
    W.new = function(self, o) o = o or {}; setmetatable(o, { __index = self }); if o.init then o:init() end; return o end
    package.loaded["ui/widget/widget"] = W
end
package.loaded["ui/geometry"] = { new = function(_self, o) return o or {} end }

local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq

local widget_src = io.open("lib/bookshelf_widget.lua"):read("*a")
local menu_src   = io.open("lib/bookshelf_start_menu.lua"):read("*a")
local function strip(s) return (s:gsub("%-%-[^\n]*", "")) end
local function method(name)
    local body = widget_src:match("\nfunction BookshelfWidget:" .. name .. "%(.-\nend\n")
    assert(body, name .. " moved or was renamed")
    return body
end

-- ── 1. paint order (source) ───────────────────────────────────────────────

t.test("the shelf paints the footer's panel under the rows, before the footer is built", function()
    local code = strip(widget_src)
    local wrap = code:find("inner_content.paintTo = function(slf, bb, x, y)", 1, true)
    assert(wrap, "inner_content no longer carries the footer's panel")
    local body = code:sub(wrap, wrap + 300)
    local panel = body:find("self:_paintFooterPanel(bb, true)", 1, true)
    local inner = body:find("return inner_paint(slf, bb, x, y)", 1, true)
    assert(panel and inner and panel < inner, "the panel must go down BEFORE the rows paint")
    local flag = code:find("self._footer_on_wall = true", 1, true)
    local build = code:find("local footer_row = self:_buildFooterRow(content_w, self._total_pages, FOOTER_H)", 1, true)
    assert(flag and build and flag < wrap and wrap < build,
        "the footer row is built before it is told the panel is on the wall")
end)

t.test("the footer row paints its own panel only when it is not on the wall", function()
    local body = strip(method("_buildFooterRow"))
    assert(not body:find("Wallpaper.scrim(", 1, true),
        "the footer row tints over the shelf again")
    local paint = body:match("row%.paintTo = function%(slf, bb, x, y%)(.-)\n    end")
    assert(paint, "the footer row's paint wrapper moved")
    assert(paint:find("if not on_wall then self:_paintFooterPanel(bb, false) end", 1, true),
        "the empty-shelf footer lost its panel, or the shelf's got it twice")
    local keep = paint:find("_keepBurgerUnder", 1, true)
    local inner = paint:find("return inner(slf, bb, x, y)", 1, true)
    assert(keep and inner and keep < inner,
        "the copy under the start menu button must be taken before the buttons paint")
end)

t.test("the empty-shelf screen keeps the panel in the footer row", function()
    local code = strip(widget_src)
    local off = code:find("self._footer_on_wall = false", 1, true)
    local build = code:find("local empty_footer = self:_buildFooterRow(", 1, true)
    assert(off and build and off < build, "the empty shelf's footer would paint no panel at all")
end)

t.test("_paintFooterPanel registers the panel with restore only when on the wall", function()
    local body = strip(method("_paintFooterPanel"))
    assert(body:find("Wallpaper.panel(bb, px, py, pw, ph, colour, strength, radius, frost)", 1, true),
        "the footer panel is not painted through Wallpaper.panel (no blur)")
    assert(body:find("if on_wall then\n        Wallpaper.setFooterPanel(px, py, pw, ph, colour, strength, radius, frost)", 1, true),
        "restore is not told where the footer's panel is")
    assert(body:find("_panel_covers_footer", 1, true), "list mode's panel would be tinted twice")
end)

-- ── 2. restore inside the footer panel ────────────────────────────────────

local function freshW()
    package.loaded["lib/bookshelf_wallpaper"] = nil
    local W = dofile("lib/bookshelf_wallpaper.lua")
    W.blurOn = function() return false end
    return W
end
local function screen(w, h, log)
    return { getWidth = function() return w end, getHeight = function() return h end,
             blitFrom = function(_s, src, dx, dy, sx, sy, bw, bh)
                 log[#log + 1] = { "blit", src = src, dx = dx, dy = dy, sx = sx, sy = sy, w = bw, h = bh }
             end }
end

t.test("restore inside the footer's panel puts the tint back; cleared, it does not", function()
    local W = freshW()
    local tints = {}
    W.scrim = function(_bb, x, y, w, h) tints[#tints + 1] = { x = x, y = y, w = w, h = h } end
    W._bg = { w = 100, h = 100, bb = {} }
    local log = {}
    W.setFooterPanel(10, 80, 80, 15, 0xEE, 0.6, 4, false)
    W.restore(screen(100, 100, log), 0, 75, 20, 10)       -- straddles the top-left
    eq(#tints, 1, "the picture went back untinted inside the panel")
    eq(tints[1].x, 10); eq(tints[1].y, 80); eq(tints[1].w, 10); eq(tints[1].h, 5)
    W.setFooterPanel(nil)
    W.restore(screen(100, 100, log), 0, 75, 20, 10)
    eq(#tints, 1, "a cleared footer panel still tints")
end)

t.test("a flat ground put back inside the footer's panel gets the tint too", function()
    local W = freshW()
    local tints = 0
    W.scrim = function() tints = tints + 1 end
    W.setGround(0x20)
    local bb = { getWidth = function() return 100 end, getHeight = function() return 100 end,
                 paintRect = function() end }
    W.setFooterPanel(10, 80, 80, 15, 0xEE, 0.6, 4, false)
    W.restore(bb, 20, 85, 5, 5)
    eq(tints, 1)
end)

t.test("restoreBare leaves both panels registered and tints neither", function()
    local W = freshW()
    local tints = 0
    W.scrim = function() tints = tints + 1 end
    W._bg = { w = 100, h = 100, bb = {} }
    W.setPanel(0, 0, 100, 20, 0xEE, 0.6, 4)
    W.setFooterPanel(10, 80, 80, 15, 0xEE, 0.6, 4)
    W.restoreBare(screen(100, 100, {}), 0, 0, 100, 100)
    eq(tints, 0)
    assert(W._panel and W._fpanel, "restoreBare dropped a registration")
end)

-- ── 3. the eraser ─────────────────────────────────────────────────────────

t.test("the eraser pastes the shelf's copy when it covers the rect", function()
    local W = freshW()
    W._bg = { w = 100, h = 100, bb = {} }
    local snap = { bb = "SNAP", x = 0, y = 70, w = 30, h = 30 }
    local e = W.eraser(true, 12, 9, 0xEE, 0.6, function() return snap end)
    local log = {}
    e:paintTo(screen(100, 100, log), 5, 80)
    eq(#log, 1); eq(log[1].src, "SNAP", "the picture was replayed instead of the copy")
    eq(log[1].sx, 5); eq(log[1].sy, 10, "the copy is indexed from its own origin")
end)

t.test("without a covering copy the eraser replays picture and tint, tinting once", function()
    local W = freshW()
    local tints = 0
    W.scrim = function() tints = tints + 1 end
    W._bg = { w = 100, h = 100, bb = "PIC" }
    W.setFooterPanel(0, 70, 100, 30, 0xEE, 0.6, 4)
    local e = W.eraser(true, 12, 9, 0xEE, 0.6, function() return { bb = "S", x = 50, y = 70, w = 30, h = 30 } end)
    local log = {}
    e:paintTo(screen(100, 100, log), 5, 80)
    eq(log[1].src, "PIC")
    eq(tints, 1, "restore's footer reshade and the eraser's own tint both applied")
    assert(W._fpanel, "the eraser dropped the footer registration")
end)

t.test("burgerUnder answers only while the shelf is right under the menu", function()
    local body = method("burgerUnder")
    local stack = {}
    local env = { UIManager = { _window_stack = stack }, ipairs = ipairs }
    local f = assert(load("return function(self, menu)\n"
        .. body:match("function BookshelfWidget:burgerUnder%(menu%)\n(.*)end\n$") .. "\nend",
        "burgerUnder", "t", env))()
    local shelf, menu, overlay = { _burger_under = { bb = "S" } }, {}, {}
    stack[1] = { widget = shelf }
    eq(f(shelf, menu).bb, "S", "the e-ink open paints before show(): the shelf is on top")
    stack[2] = { widget = menu }
    eq(f(shelf, menu).bb, "S", "shown over the shelf")
    stack[2] = { widget = overlay }; stack[3] = { widget = menu }
    eq(f(shelf, menu), nil, "over the micro-module view the shelf's copy is wrong")
    shelf._burger_under = nil
    stack[2] = nil; stack[3] = nil
    eq(f(shelf, menu), nil)
end)

t.test("the start menu hands its eraser the shelf's copy", function()
    local code = strip(menu_src)
    assert(code:find("bw:burgerUnder(menu)", 1, true), "the start menu does not ask the shelf")
    assert(code:find("Wallpaper.eraser(true, art, box_h, scrim_c, scrim_s, under)", 1, true),
        "the eraser is not given the copy")
end)

-- ── 4. the blur ───────────────────────────────────────────────────────────

local function blurW(builds)
    local W = freshW()
    W.blurOn = function() return true end
    W._bg = { w = 100, h = 100, bb = "PIC" }
    W._bg_key = "/w.png|100x100"
    W._frost_build = function(_src, x, y, w, h)
        builds[#builds + 1] = { x = x, y = y, w = w, h = h }
        return { tag = "FROST" .. #builds, free = function() end }
    end
    W.scrim = function() return true end
    return W
end

t.test("the blur is built once per panel and picture, then only blitted", function()
    local builds, log = {}, {}
    local W = blurW(builds)
    local s = screen(100, 100, log)
    W.panel(s, 0, 0, 100, 20, 0xEE, 0.6, 0, true)
    W.panel(s, 0, 0, 100, 20, 0xEE, 0.6, 0, true)
    W.panel(s, 0, 80, 100, 20, 0xEE, 0.6, 0, true)
    eq(#builds, 2, "a paint rebuilt the blur")
    eq(log[1].src.tag, "FROST1"); eq(log[2].src.tag, "FROST1"); eq(log[3].src.tag, "FROST2")
    W._bg_key = "/w.png|100x100|n"                 -- a night toggle's picture
    W.panel(s, 0, 0, 100, 20, 0xEE, 0.6, 0, true)
    eq(#builds, 3, "the day blur was reused for the night picture")
end)

t.test("no blur when off, not over a picture, at Solid, or on an offscreen buffer", function()
    local builds, log = {}, {}
    local W = blurW(builds)
    W.panel(screen(100, 100, log), 0, 0, 100, 20, 0xEE, 0.6, 0, false)
    W.panel(screen(100, 100, log), 0, 0, 100, 20, 0xEE, 1, 0, true)
    W.panel(screen(40, 40, log), 0, 0, 40, 20, 0xEE, 0.6, 0, true)
    W.blurOn = function() return false end
    W.panel(screen(100, 100, log), 0, 0, 100, 20, 0xEE, 0.6, 0, true)
    eq(#builds, 0); eq(#log, 0)
end)

t.test("a patch put back inside a blurred panel is cut from the panel's blur", function()
    local builds, log = {}, {}
    local W = blurW(builds)
    W.setFooterPanel(10, 80, 80, 15, 0xEE, 0.6, 4, true)
    W.restore(screen(100, 100, log), 20, 85, 5, 5)
    eq(#builds, 1)
    eq(builds[1].x, 10); eq(builds[1].w, 80, "the blur was built for the patch, not the panel")
    local fb = log[#log]
    eq(fb.src.tag, "FROST1"); eq(fb.sx, 10); eq(fb.sy, 5); eq(fb.w, 5)
end)

t.test("a new picture or a night flip drops the blurs", function()
    local builds = {}
    local W = blurW(builds)
    W.panel(screen(100, 100, {}), 0, 0, 100, 20, 0xEE, 0.6, 0, true)
    eq(#W._frost, 1)
    W._bg.bb = { invertRect = function() end, getWidth = function() return 100 end,
                 getHeight = function() return 100 end }
    W.flipNight(true)
    eq(#W._frost, 0, "flipNight kept a blur of the other mode's picture")
    W.panel(screen(100, 100, {}), 0, 0, 100, 20, 0xEE, 0.6, 0, true)
    W.free()
    eq(#W._frost, 0, "free kept the blurs")
end)

t.done()
