-- tests/_test_spine_external_cover_key.lua
-- Pure-Lua tests for SpineWidget.externalCoverKey.
--
-- An external cover (one the user picked, or an enricher downloaded) is now
-- cached like any other scaled cover, but keyed on the cover FILE rather than
-- the book. That key is the only thing standing between a replaced cover and
-- the old one being served from disk for good, so it gets its own tests.
--
-- The preamble mirrors _test_spine_widget_aspect.lua: SpineWidget pulls in a
-- lot of KOReader at load time, none of which runs beyond a few constants.
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
_G.__test_settings = {}
package.preload["lib/bookshelf_settings_store"] = function()
    return {
        read = function(k, d)
            local v = _G.__test_settings[k]
            if v == nil then return d end
            return v
        end,
        isTrue = function(k) return _G.__test_settings[k] == true end,
    }
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


-- Controllable lfs, since the key IS a function of the file's attributes.
local fs = {}
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(path, what)
        -- Real LFS raises on a non-string path; a stub that quietly returns
        -- nil would let the guard be deleted without a test noticing.
        if type(path) ~= "string" then
            error("bad argument #1 to 'attributes' (string expected)")
        end
        local a = fs[path]
        if not a then return nil end
        if what then return a[what] end
        return a
    end,
}

local SpineWidget = require("lib/bookshelf_spine_widget")
local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()

local COVER = "/books/A.sdr/cover.jpg"

t.test("a key is derived from the cover file", function()
    fs[COVER] = { modification = 1000, size = 50000 }
    local k = SpineWidget.externalCoverKey(COVER)
    assert(type(k) == "string" and k ~= "", "no key for an existing cover")
    assert(k:find(COVER, 1, true), "the key does not identify the file")
end)

t.test("replacing the cover changes the key", function()
    fs[COVER] = { modification = 1000, size = 50000 }
    local before = SpineWidget.externalCoverKey(COVER)
    -- The whole point: the cover picker rewrites cover.jpg in place, under the
    -- same path and for the same book. If the key did not move, the cache
    -- would keep serving the previous image -- now from disk, so a restart
    -- would not clear it either.
    fs[COVER] = { modification = 2000, size = 50000 }
    assert(SpineWidget.externalCoverKey(COVER) ~= before,
        "a newer cover reused the old key")
end)

t.test("a same-second replacement of a different size still changes the key", function()
    fs[COVER] = { modification = 1000, size = 50000 }
    local before = SpineWidget.externalCoverKey(COVER)
    -- Filesystem mtimes are whole seconds, and picking a cover twice in the
    -- same second is entirely possible. Size is what separates them.
    fs[COVER] = { modification = 1000, size = 61234 }
    assert(SpineWidget.externalCoverKey(COVER) ~= before,
        "a same-second replacement reused the old key")
end)

t.test("two books never share a key", function()
    fs["/books/A.sdr/cover.jpg"] = { modification = 1000, size = 50000 }
    fs["/books/B.sdr/cover.jpg"] = { modification = 1000, size = 50000 }
    assert(SpineWidget.externalCoverKey("/books/A.sdr/cover.jpg")
        ~= SpineWidget.externalCoverKey("/books/B.sdr/cover.jpg"),
        "identical-looking covers for two books collided")
end)

t.test("an unchanged cover keeps its key, or nothing is ever cached", function()
    fs[COVER] = { modification = 1000, size = 50000 }
    assert(SpineWidget.externalCoverKey(COVER) == SpineWidget.externalCoverKey(COVER),
        "the key is not stable for an unchanged file")
end)

t.test("no file, no key", function()
    fs[COVER] = nil
    assert(SpineWidget.externalCoverKey(COVER) == nil, "keyed a missing cover")
    assert(SpineWidget.externalCoverKey(nil) == nil, "keyed a nil path")
    assert(SpineWidget.externalCoverKey("") == nil, "keyed an empty path")
end)

t.done()
