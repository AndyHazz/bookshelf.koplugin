-- tests/_test_footer_panel_order.lua
-- The footer floats in FRONT of the shelf, and the panels can blur the
-- picture behind them (Panel shading > Blur the picture behind panels).
--
-- 1. PAINT ORDER. The footer row paints after the rows: its panel tint, then
--    its buttons, over whatever of the bottom row reaches into the footer.
--    Painting the footer behind the shelf was tried for 5.4 and dropped: with
--    a single shelf row the bottom plank's design covered the footer
--    entirely (maintainer). Source-matched: the widget cannot be run.
-- 2. THE ERASER. The start menu's close X erases the hamburger. Replaying
--    picture and tint wiped a plank design's tinted fringe under the button
--    (a seam for as long as the menu was open), so the shelf keeps a copy of
--    what is under the button after the panel and before the buttons, and
--    the eraser uses it while the shelf is what the menu is over.
-- 3. THE BLUR. Built once per panel rect and picture, then blitted; only
--    asked for over a picture, never at Solid; cleared with the picture.
--
-- Usage (from plugin root): lua tests/_test_footer_panel_order.lua
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

t.test("the footer row paints its panel, then keeps the copy, then its buttons", function()
    local body = strip(method("_buildFooterRow"))
    local paint = body:match("row%.paintTo = function%(slf, bb, x, y%)(.-)\n    end")
    assert(paint, "the footer row's paint wrapper moved")
    local panel = paint:find("self:_paintFooterPanel(bb)", 1, true)
    local keep = paint:find("_keepBurgerUnder", 1, true)
    local inner = paint:find("return inner(slf, bb, x, y)", 1, true)
    assert(panel and keep and inner, "the footer row no longer paints panel, copy and buttons")
    assert(panel < keep and keep < inner,
        "the copy must hold the panel and not the buttons: panel, copy, buttons")
    assert(not paint:find("return end", 1, true), "the footer row skips its own paint again")
end)

t.test("nothing paints the footer under the rows", function()
    local code = strip(widget_src)
    assert(not code:find("inner_content.paintTo = function", 1, true),
        "inner_content paints something before the rows again (the footer behind the shelf)")
    assert(not code:find("_footer_on_wall", 1, true), "the footer-behind-the-shelf flag is back")
    local wp = strip(io.open("lib/bookshelf_wallpaper.lua"):read("*a"))
    assert(not wp:find("setFooterPanel", 1, true),
        "restore is told about a footer panel under the rows that is not there")
end)

t.test("the footer panel is painted through Wallpaper.panel, list mode excepted", function()
    local body = strip(method("_paintFooterPanel"))
    assert(body:find("Wallpaper.panel(bb, px, py, pw, ph, colour, strength, radius, self:hasWallpaper())", 1, true),
        "the footer panel is not painted through Wallpaper.panel (no blur)")
    assert(body:find("_panel_covers_footer", 1, true), "list mode's panel would be tinted twice")
end)

-- ── helpers ───────────────────────────────────────────────────────────────

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

-- ── 2. the eraser ─────────────────────────────────────────────────────────

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

t.test("without a covering copy the eraser replays picture and tint", function()
    local W = freshW()
    local tints = 0
    W.scrim = function() tints = tints + 1 end
    W._bg = { w = 100, h = 100, bb = "PIC" }
    local e = W.eraser(true, 12, 9, 0xEE, 0.6, function() return { bb = "S", x = 50, y = 70, w = 30, h = 30 } end)
    local log = {}
    e:paintTo(screen(100, 100, log), 5, 80)
    eq(log[1].src, "PIC"); eq(tints, 1)
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

-- ── 3. the blur ───────────────────────────────────────────────────────────

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
    W.setPanel(10, 80, 80, 15, 0xEE, 0.6, 4, nil, true)
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

-- ── 4. dithered onto the e-ink panel's greys ──────────────────────────────
-- On a greyscale e-ink screen the panel's background (blur AND tint) is built
-- once, dithered onto exact device levels, and blitted with no scrim over it:
-- a tint blended over dithered levels would land between them again.

-- A screen scrim would BLEND on (C blitter usable), as a PW5's is.
local function blendScreen(w, h, log)
    local s = screen(w, h, log)
    s.canUseCbb = function() return true end
    s.blendRectRGB32 = function() end
    return s
end
local function ditherW(builds, scrims)
    local W = blurW(builds)
    W._frost_build = function(_src, x, y, w, h, tint)
        builds[#builds + 1] = { x = x, y = y, w = w, h = h,
                                tint = tint and { colour = tint.colour, strength = tint.strength } }
        return { tag = "FROST" .. #builds, free = function() end }
    end
    W.scrim = function() scrims[#scrims + 1] = true; return true end
    W._dither_on = true
    return W
end

t.test("dithered: the tint is baked into the cached blur and no scrim goes over it", function()
    local builds, scrims, log = {}, {}, {}
    local W = ditherW(builds, scrims)
    local s = blendScreen(100, 100, log)
    W.panel(s, 0, 0, 100, 20, 0xEE, 0.35, 0, true)
    W.panel(s, 0, 0, 100, 20, 0xEE, 0.35, 0, true)
    eq(#builds, 1, "a paint rebuilt the dithered panel")
    assert(builds[1].tint, "the blur was built without the tint")
    eq(builds[1].tint.colour, 0xEE); eq(builds[1].tint.strength, 0.35)
    eq(#scrims, 0, "a tint went over the dithered levels")
    W.panel(s, 0, 0, 100, 20, 0xEE, 0.6, 0, true)
    eq(#builds, 2, "a new shading level reused the old level's baked tint")
    W.panel(s, 0, 0, 100, 20, 0x22, 0.6, 0, true)
    eq(#builds, 3, "a new panel colour reused the old colour's baked tint")
end)

t.test("dithered: a patch inside the panel is cut from the same baked background, untinted", function()
    local builds, scrims, log = {}, {}, {}
    local W = ditherW(builds, scrims)
    local s = blendScreen(100, 100, log)
    W.panel(s, 10, 80, 80, 15, 0xEE, 0.35, 4, true)
    W.setPanel(10, 80, 80, 15, 0xEE, 0.35, 4, nil, true)
    W.restore(s, 20, 85, 5, 5)
    eq(#builds, 1, "the patch built its own background: a seam")
    eq(#scrims, 0, "the patch was tinted twice")
    local fb = log[#log]
    eq(fb.src.tag, "FROST1"); eq(fb.sx, 10); eq(fb.sy, 5)
end)

t.test("not dithered: blur then scrim, as before", function()
    local builds, scrims, log = {}, {}, {}
    local W = ditherW(builds, scrims)
    W._dither_on = false
    W.panel(blendScreen(100, 100, log), 0, 0, 100, 20, 0xEE, 0.35, 0, true)
    eq(#builds, 1); eq(builds[1].tint, nil, "a colour screen got the dither")
    eq(#scrims, 1, "the tint was lost")
end)

t.test("dithered, but where scrim paints solid (no C blend): no bake", function()
    local builds, scrims, log = {}, {}, {}
    local W = ditherW(builds, scrims)
    local s = blendScreen(100, 100, log)
    s.canUseCbb = function() return false end
    W.panel(s, 0, 0, 100, 20, 0xEE, 0.35, 0, true)
    eq(builds[1].tint, nil); eq(#scrims, 1)
end)

t.test("blur off: the plain tint, never the dither", function()
    local builds, scrims, log = {}, {}, {}
    local W = ditherW(builds, scrims)
    W.blurOn = function() return false end
    W.panel(blendScreen(100, 100, log), 0, 0, 100, 20, 0xEE, 0.35, 0, true)
    eq(#builds, 0); eq(#scrims, 1)
end)

t.test("the dither is for greyscale e-ink only: not colour e-ink, not the desktop", function()
    local W = freshW()
    local saved = package.loaded["device"]
    local function dev(eink, colour)
        package.loaded["device"] = { hasEinkScreen = function() return eink end,
                                     hasColorScreen = function() return colour end }
        return W.ditherPanels()
    end
    eq(dev(true, false), true, "a PW5")
    eq(dev(true, true), false, "a colour e-ink screen")
    eq(dev(false, false), false, "the desktop")
    eq(dev(false, true), false, "the desktop")
    package.loaded["device"] = saved
end)

t.done()
