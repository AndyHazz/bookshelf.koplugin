-- Guards footer_geom's remembered launcher rects against stale screen geometry
-- (issue #196). The rects hold ABSOLUTE pixels captured from the home-screen
-- footer; reusing one after a rotation or window resize paints the reader
-- launcher off-screen. rememberedButtonRect/rememberedGridRect must return nil
-- when the current geometry differs from capture, so callers fall back to the
-- computed (size-relative) anchor.
package.path = "./?.lua;./?/init.lua;" .. package.path

local screen_w, screen_h = 1264, 1680  -- mutable: simulate rotation/resize
package.loaded["device"] = { screen = {
    getWidth    = function() return screen_w end,
    getHeight   = function() return screen_h end,
    scaleBySize = function(_, n) return n end,
} }
package.loaded["ui/geometry"] = { new = function(_, tab) return tab end }
package.loaded["ui/size"] = { padding = { fullscreen = 10, default = 5 } }
package.loaded["lib/bookshelf_settings_store"] = { read = function(_k, d) return d end }

local FG = dofile("lib/bookshelf_footer_geom.lua")
local t = dofile("tests/_helpers.lua").runner()

t.test("remembered button rect is returned at the capture geometry", function()
    FG.rememberButtonRect({ x = 10, y = 1620, w = 100, h = 60 })
    local r = FG.rememberedButtonRect("left")
    assert(r and r.x == 10 and r.y == 1620,
        "captured rect must be returned at the same geometry")
end)

t.test("remembered button rect is dropped after a geometry change (#196)", function()
    screen_w, screen_h = 1680, 1264  -- rotate / resize
    assert(FG.rememberedButtonRect("left") == nil,
        "stale-geometry rect must be nil so the computed anchor is used")
    screen_w, screen_h = 1264, 1680  -- back to capture geometry
    assert(FG.rememberedButtonRect("left") ~= nil,
        "rect is valid again once geometry matches")
end)

t.test("remembered grid rect honours geometry the same way", function()
    screen_w, screen_h = 1264, 1680
    FG.rememberGridRect({ x = 1150, y = 1620, w = 100, h = 60 })
    assert(FG.rememberedGridRect("right") ~= nil, "grid rect returned at capture geometry")
    screen_w, screen_h = 1680, 1264
    assert(FG.rememberedGridRect("right") == nil, "grid rect dropped after geometry change")
end)

t.test("stale-geometry launcherBarsAnchor remaps, preserving the bottom gap (#196)", function()
    screen_w, screen_h = 1264, 1680
    FG.rememberButtonRect({ x = 10, y = 1620, w = 100, h = 60 })
    local _cx0, y0 = FG.launcherBarsAnchor(screen_w, screen_h, "left")  -- exact, same geometry
    screen_w, screen_h = 1680, 1264                                     -- rotate / resize shorter
    local cx1, y1 = FG.launcherBarsAnchor(screen_w, screen_h, "left")
    assert(y1 < screen_h, "remapped bars must be on-screen, not below the bottom edge")
    assert((1680 - y0) == (screen_h - y1),
        "bottom gap from the remembered button must be preserved across geometry")
    assert(cx1 > 0 and cx1 < screen_w, "remapped x stays within the screen")
end)

t.done()
