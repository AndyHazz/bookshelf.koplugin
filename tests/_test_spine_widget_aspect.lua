-- tests/_test_spine_widget_aspect.lua
-- Pure-Lua tests for SpineWidget's true-aspect helpers (bookAspect,
-- trueAspectBoxHeight, trueAspectBoxWidth, alignTopCoverHeight). The module
-- pulls in a lot of KOReader widget + ffi requires at load time for its
-- rendering paths, but none of that runs at module scope beyond a few
-- Screen:scaleBySize() / Blitbuffer.gray() calls used to build shadow/border
-- constants -- stubbed below so the module loads, then we exercise the pure
-- aspect math only.

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
    "ui/widget/widget",
    "ui/widget/overlapgroup",
    "ui/widget/container/framecontainer",
    "ui/widget/container/centercontainer",
    "ui/widget/container/bottomcontainer",
    "ui/widget/container/rightcontainer",
    "ui/widget/container/inputcontainer",
    "ui/widget/imagewidget",
}) do
    package.preload[name] = function() return make_widget_base() end
end
package.preload["ui/geometry"] = function()
    return { new = function(_, t) return setmetatable(t or {}, { __index = {} }) end }
end
package.preload["ui/gesturerange"] = function() return { new = function(_, t) return t end } end
package.preload["ui/size"] = function()
    return {
        padding = { small = 3, default = 5, large = 10, fullscreen = 15 },
        border  = { thin = 1, medium = 2 },
    }
end
package.preload["ui/bidi"] = function() return { mirroredUILayout = function() return false end } end
package.preload["ffi/blitbuffer"] = function()
    return {
        Color8      = function(n) return { v = n } end,
        ColorRGB32  = function(r,g,b,a) return { r=r, g=g, b=b, a=a } end,
        COLOR_WHITE = {}, COLOR_BLACK = {},
        gray        = function(n) return { gray = n } end,
        new         = function() return {} end,
    }
end
package.preload["ffi"] = function()
    return {
        typeof   = function() return {} end,
        istype   = function() return false end,
        metatype = function() end,
        cdef     = function() end,
        new      = function() return {} end,
    }
end
package.preload["ffi/util"] = function() return { template = function(s) return s end } end
package.preload["device"] = function()
    return {
        isAndroid = function() return false end,
        screen = {
            isColorEnabled = function() return false end,
            scaleBySize    = function(_, n) return n end,
        },
    }
end
package.preload["lib/bookshelf_settings_store"] = function()
    return { read = function() return nil end, isTrue = function() return false end }
end
package.preload["lib/bookshelf_scaled_cover_cache"] = function()
    return { get = function() return nil end, put = function(_, _, bb) return bb end }
end
package.preload["lib/bookshelf_fonts"] = function()
    return { getFace = function() return {}, {} end }
end
package.preload["lib/bookshelf_cover_progress"] = function()
    return {
        badgeSize      = function(n) return n end,
        glyphRenderedH = function() return 0 end,
        resolvedColors = function() return {} end,
        decide         = function() return {} end,
    }
end
package.preload["lib/bookshelf_i18n"] = function() return { gettext = function(s) return s end } end

_G.G_reader_settings = {
    isTrue    = function() return false end,
    nilOrTrue = function() return true end,
}

local SpineWidget = require("lib/bookshelf_spine_widget")

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1
    else fail = fail + 1; io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n") end
end
local function eq(a, e, msg)
    if a ~= e then error((msg or "") .. " expected=" .. tostring(e) .. " got=" .. tostring(a), 2) end
end

local function book(w, h) return { cover_sizetag = w .. "x" .. h } end

test("smoke: aspect helpers exist", function()
    eq(type(SpineWidget.bookAspect), "function")
    eq(type(SpineWidget.trueAspectBoxHeight), "function")
    eq(type(SpineWidget.trueAspectBoxWidth), "function")
    eq(SpineWidget.COVER_ASPECT_CAP, 1.65)
end)

test("bookAspect: reads the WxH cover_sizetag", function()
    eq(SpineWidget.bookAspect(book(100, 150)), 1.5)
end)

test("bookAspect: clamps to the cap for very tall covers", function()
    eq(SpineWidget.bookAspect(book(100, 500)), 1.65)
end)

test("trueAspectBoxHeight: caps at max_h", function()
    local h = SpineWidget.trueAspectBoxHeight(100, book(100, 500), 120)
    eq(h, 120)
end)

-- alignTopCoverHeight: the folder/series stack cover-image sizer. Distinct
-- from trueAspectBoxHeight -- this sizes the IMAGE inside an unchanged card,
-- not the card's own box, so it takes img_w/img_h (already chrome-excluded)
-- rather than box_w/max_h.
test("alignTopCoverHeight: undistorted height for a normal cover, well under img_h", function()
    -- aspect 1.5, img_w=100 -> natural 150, comfortably under img_h=300.
    local h = SpineWidget.alignTopCoverHeight(100, book(100, 150), 300)
    eq(h, 150)
end)

test("alignTopCoverHeight: caps at img_h for a very tall (capped-aspect) cover", function()
    -- aspect clamps to 1.65 -> natural 165, but img_h budget is only 120.
    local h = SpineWidget.alignTopCoverHeight(100, book(100, 500), 120)
    eq(h, 120)
end)

test("alignTopCoverHeight: a short/landscape cover clamps UP to min_img_h (the folder floor)", function()
    local natural = SpineWidget.alignTopCoverHeight(100, book(100, 100), 300)
    local floored = SpineWidget.alignTopCoverHeight(100, book(100, 100), 300, 220)
    assert(natural < 220, "test setup: natural height should be below the floor")
    eq(floored, 220, "result must clamp UP to min_img_h")
end)

test("alignTopCoverHeight: a cover already taller than min_img_h is left untouched", function()
    local natural = SpineWidget.alignTopCoverHeight(100, book(100, 150), 300)
    local floored = SpineWidget.alignTopCoverHeight(100, book(100, 150), 300, 50)
    eq(floored, natural, "min_img_h below the natural height must not change the result")
end)

test("alignTopCoverHeight: min_img_h never pushes the result past img_h", function()
    -- Degenerate input (min_img_h > img_h): img_h is the hard interior
    -- budget and must still win, even though this shouldn't arise from
    -- FolderCard's own cover_floor (always well under the slot height).
    local h = SpineWidget.alignTopCoverHeight(100, book(100, 100), 200, 250)
    eq(h, 200, "img_h is the hard ceiling")
end)

test("alignTopCoverHeight: never returns less than 1px", function()
    local h = SpineWidget.alignTopCoverHeight(100, book(100, 100), 0)
    eq(h, 1)
end)

print(string.format("\n%d pass, %d fail", pass, fail))
os.exit(fail == 0 and 0 or 1)
