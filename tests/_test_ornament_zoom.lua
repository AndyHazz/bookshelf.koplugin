-- tests/_test_ornament_zoom.lua
-- The "zoom" tap action: an ornament full screen, with its info (or its name)
-- in a panel under it. Pins the wiring (the shelf's tap handler, the
-- long-press menu's tap row and chooser) and the view's pure parts (the
-- text it shows, the size it gives the picture).
package.path = "./?.lua;./?/init.lua;" .. package.path
package.loaded["logger"] = { dbg = function() end, info = function() end,
                             warn = function() end, err = function() end }
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq

local widget = io.open("lib/bookshelf_widget.lua"):read("*a")
local menu   = io.open("lib/bookshelf_ornament_menu.lua"):read("*a")

t.test("the shelf's tap handler zooms a zoom piece and dispatches the rest", function()
    local h = widget:match("tap = function%(entry%)(.-)\n            end,\n        }")
    assert(h, "the ornament tap handler moved")
    local z = h:find("entry.tap.zoom", 1, true)
    local zoom = h:find('require("lib/bookshelf_ornament_zoom").show(entry', 1, true)
    local disp = h:find("bookshelf_action_exec", 1, true)
    assert(z and zoom and disp, "the handler does not tell zoom from a stored action")
end)

t.test("the menu's tap row names Zoom, and the chooser offers it", function()
    assert(menu:find('tap.zoom and _("Zoom")', 1, true), "the tap row does not say Zoom")
    local choose = menu:match("function M%.chooseTap%(entry, done%)(.-)\nend")
    assert(choose and choose:find('readerSet(entry, "tap", "zoom")', 1, true),
        "the chooser does not offer Zoom")
end)

-- The view's pure parts, loaded with the UI stubbed out.
local function class()
    local c = {}
    function c:extend(t) t = t or {}; return setmetatable(t, { __index = self }) end
    function c:new(t) return setmetatable(t or {}, { __index = self }) end
    return c
end
local function load()
    for _i, m in ipairs({ "device", "ui/uimanager", "ui/geometry", "ui/font", "ui/size",
                          "ui/widget/container/inputcontainer", "ui/widget/container/framecontainer",
                          "ui/widget/overlapgroup", "ui/widget/textboxwidget", "ui/widget/widget",
                          "ui/widget/scrolltextwidget", "ui/gesturerange", "ffi/blitbuffer",
                          "lib/bookshelf_ornaments" }) do
        package.loaded[m] = class()
    end
    package.loaded["device"] = { screen = { getWidth = function() return 1236 end,
                                            getHeight = function() return 1648 end,
                                            scaleBySize = function(_s, v) return v end } }
    package.loaded["lib/bookshelf_ornament_zoom"] = nil
    return dofile("lib/bookshelf_ornament_zoom.lua")
end

t.test("the panel shows the piece's info, or its name when it has none", function()
    local Z = load()
    eq(Z.infoText({ name = "Japan/Hokusai - South Wind.png", info = "South Wind, Clear Sky" }),
       "South Wind, Clear Sky")
    eq(Z.infoText({ name = "Autumn/Owl.png" }), nil, "a piece without info grows invented text")
    eq(Z.titleOf({ name = "Autumn/Owl.png" }), "Owl")
    eq(Z.titleOf({ name = "Japan/Hokusai - South Wind.png" }), "Hokusai - South Wind")
end)

t.test("the picture fits the space left, keeping its shape", function()
    local Z = load()
    local w, h = Z.fit(2, 1000, 600)           -- landscape into a 1000 x 600 box
    eq(w, 1000); eq(h, 500)
    w, h = Z.fit(0.5, 1000, 600)               -- portrait: height-bound
    eq(h, 600); eq(w, 300)
end)

t.test("the drawing, not the file's padding, fills the space", function()
    -- A pack's piece carries transparent padding (its share of the tallest
    -- piece, a side margin): sized whole, a framed print came out small.
    local Z = load()
    -- aspect 0.5 file whose drawing is its lower 60%, middle 80%
    local W, H, c = Z.cropFit(0.5, { 0.1, 0.4, 0.9, 1.0 }, 1000, 600)
    eq(c.h, 600, "the drawing is not height-bound in a tall box")
    assert(math.abs(c.w - 400) <= 1, "the drawing lost its shape: " .. c.w)   -- 0.5*0.8/0.6 = 0.667
    assert(math.abs(H - 1000) <= 1 and math.abs(W - 500) <= 1, "the file is not scaled around the drawing")
    assert(math.abs(c.x - 50) <= 1 and math.abs(c.y - 400) <= 1, "the crop is not where the drawing is")
    local W2, H2, c2 = Z.cropFit(2, nil, 1000, 600)            -- no box: the whole file
    eq(c2.x, 0); eq(c2.y, 0); eq(c2.w, W2); eq(c2.h, H2); eq(W2, 1000)
end)

t.test("a name-only panel fits its title and is centred; an info panel is full width", function()
    local Z = load()
    local px, pw = Z.panelBox(1236, 50, 12, 300, false)
    eq(pw, 324, "the name-only panel is not its title's width plus padding")
    eq(px, math.floor((1236 - 324) / 2), "the name-only panel is not centred")
    px, pw = Z.panelBox(1236, 50, 12, 300, true)
    eq(px, 50); eq(pw, 1136)
    px, pw = Z.panelBox(1236, 50, 12, 5000, false)         -- a very long name
    eq(px, 50); eq(pw, 1136, "a long name ran past the screen")
end)

t.test("the panel's text is in the bookshelf UI font", function()
    local z = io.open("lib/bookshelf_ornament_zoom.lua"):read("*a")
    assert(z:find('BFont:getFace("infofont"', 1, true), "the panel does not use the bookshelf UI font")
    assert(not z:find('Font:getFace("tfont"', 1, true) and not z:find('Font:getFace("cfont"', 1, true),
        "a stock KOReader face is still used")
end)

t.test("KOReader's own gestures pass through the zoom view", function()
    -- Side swipes for brightness, the top swipe for KOReader's menu, the
    -- diagonal refresh: the full-screen view swallowed them (maintainer).
    local P = dofile("lib/bookshelf_gesture_passthrough.lua")
    local fired = {}
    local zone = function(id) return {
        def = { id = id },
        gs_range = { match = function(_s, ev) return ev.ges == "swipe" end },
        handler = function() fired[#fired + 1] = id; return true end,
    } end
    local fm = { _ordered_touch_zones = { zone("filemanager_swipe"), zone("my_custom") },
                 gestures = { gestures = {} } }
    eq(P.gesture({ ges = "swipe" }, fm), true, "a KOReader zone did not take the swipe")
    eq(fired[1], "filemanager_swipe")
    fired = {}
    fm._ordered_touch_zones = { zone("my_custom") }
    eq(P.gesture({ ges = "swipe" }, fm), false, "a zone the reader did not set up fired")
    fm.gestures.gestures = { my_custom = true }
    eq(P.gesture({ ges = "swipe" }, fm), true, "the reader's own gesture did not fire")
    local z = io.open("lib/bookshelf_ornament_zoom.lua"):read("*a")
    assert(z:find("Passthrough.gesture(", 1, true) and z:find("Passthrough.event(", 1, true),
        "the zoom view does not pass gestures and their actions through")
end)

t.test("the description panel follows the blur preference, like the shelf's panels", function()
    -- Maintainer: the zoom view's panel should use "Blur the picture behind
    -- panels" too. Wallpaper.panel blurs (and dithers on e-ink) when the
    -- wallpaper is behind it; scrim never does.
    local z = io.open("lib/bookshelf_ornament_zoom.lua"):read("*a")
    assert(z:find('require("lib/bookshelf_wallpaper").panel(b, px, py, pw, ph, ground, strength, radius, on_wall)', 1, true),
        "the zoom panel does not paint through Wallpaper.panel with the wallpaper as its frost")
    assert(not z:find('bookshelf_wallpaper").scrim(b, px, py', 1, true), "the zoom panel still paints a plain scrim")
    assert(z:find("bg, on_wall = wp, true", 1, true), "the frost flag does not follow the wallpaper ground")
end)

t.done()
