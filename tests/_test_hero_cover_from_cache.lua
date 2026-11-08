-- tests/_test_hero_cover_from_cache.lua
-- SpineWidget:_renderCover's last-resort cover source: when BookInfoManager
-- has nothing to decode for a book (row gone after a re-sync, extraction
-- pending or failed, cover ignored) but ScaledCoverCache still holds a
-- SMALLER copy from an earlier shelf paint, the slot grows that copy into
-- a widget-owned image instead of painting the no-cover placeholder.
--
-- Device report behind this: "books with covers on the shelf that do not
-- show the cover image in the hero area". The shelf painted from its cache
-- entry; the hero (a larger slot) missed the >= size test, the hero tier
-- was empty, BIM returned nil, and the fallback card was the result.
--
-- Same stub set as _test_spine_widget_aspect.lua so the whole module loads;
-- the cache and repository stubs here are controllable per test.

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

-- Fake blitbuffers: dimensions plus the two operations the grow path uses.
-- scale() returns a NEW fake (never the receiver), mirroring the real
-- bb:scale, so a test can tell the grown copy from the cache's own buffer.
local made = {}
local function fakebb(w, h, opts)
    opts = opts or {}
    local bb = { w = w, h = h, freed = false, tag = opts.tag }
    function bb:getWidth() return self.w end
    function bb:getHeight() return self.h end
    function bb:getType() return 4 end
    function bb:free() self.freed = true end
    function bb:scale(nw, nh)
        if opts.scale_fails then error("scale exploded") end
        local n = fakebb(nw, nh, { tag = (self.tag or "?") .. "->scaled" })
        made[#made + 1] = n
        return n
    end
    function bb:blitFrom() end
    return bb
end

package.preload["ffi/blitbuffer"] = function()
    return {
        Color8      = function(n) return { v = n } end,
        ColorRGB32  = function(r,g,b,a) return { r=r, g=g, b=b, a=a } end,
        COLOR_WHITE = {}, COLOR_BLACK = {},
        gray        = function(n) return { gray = n } end,
        new         = function(w, h) return fakebb(w, h, { tag = "bb.new" }) end,
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
        generation = function() return 1 end,
    }
end

-- Controllable cache: one entry, and a record of every put().
local Cache = { entry = nil, puts = {} }
package.preload["lib/bookshelf_scaled_cover_cache"] = function()
    return {
        get = function(_, fp) return Cache.entry end,
        put = function(_, fp, bb) Cache.puts[#Cache.puts + 1] = bb; return bb end,
        -- Sized copies (stack covers, thumbnails): none kept here.
        getSized = function() return nil end,
        putSized = function(_, _fp, _w, _h, bb) return bb end,
    }
end

-- Controllable repository: what BIM hands back, and whether it was asked.
local Repo = { cover = nil, asked = 0 }
package.preload["lib/bookshelf_book_repository"] = function()
    return {
        getCoverBB = function(fp) Repo.asked = Repo.asked + 1; return Repo.cover end,
    }
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
local HeroTier    = require("lib/bookshelf_hero_tier")   -- the real one

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1
    else fail = fail + 1; io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n") end
end
local function eq(a, e, msg)
    if a ~= e then error((msg or "") .. " expected=" .. tostring(e) .. " got=" .. tostring(a), 2) end
end

-- A slot fixture. The card is fixed at 200x300 so the image box is a known
-- 198x298 (1dp border each side under the identity scaleBySize stub). The
-- two render sinks are replaced with recorders: what the slot decided is
-- the whole question here.
local CARD_W, CARD_H = 200, 300
local function slot(o)
    o = o or {}
    local s = setmetatable({
        book        = { filepath = o.fp or "/lib/colour-of-magic.epub" },
        cover_fill  = o.cover_fill,
        cover_bb    = nil,
        _out        = {},
    }, { __index = SpineWidget })
    function s:_cardDimensions() return CARD_W, CARD_H end
    function s:_wrapCoverInCard(img, cw, ch, border)
        self._out.kind = "cover"; self._out.img = img
        self._out.card_w, self._out.card_h, self._out.border = cw, ch, border
        return "card"
    end
    function s:_renderFallback()
        self._out.kind = "fallback"
        return "fallback"
    end
    return s
end

local function reset(cache_entry, bim_cover)
    Cache.entry = cache_entry
    Cache.puts  = {}
    Repo.cover  = bim_cover
    Repo.asked  = 0
    made = {}
    HeroTier:clear()
    HeroTier.target_h = nil
end

local IMG_W, IMG_H = CARD_W - 2, CARD_H - 2

test("smaller cache entry + BIM nil: paints a grown copy, not the placeholder", function()
    local small = fakebb(100, 150, { tag = "cache" })
    reset(small, nil)
    local s = slot{}
    s:_renderCover(nil)
    eq(s._out.kind, "cover", "sink")
    eq(Repo.asked, 1, "BIM was consulted first")
    local img = s._out.img
    eq(img.image_disposable, true, "widget owns the grown copy")
    if img.image == small then error("painted the cache's own buffer instead of a copy") end
    -- Aspect-preserving (not cover_fill), so state the PROPERTIES rather
    -- than re-deriving the implementation's arithmetic: it fits the box,
    -- fills one axis, and keeps the source's 2:3 shape.
    local gw, gh = img.image:getWidth(), img.image:getHeight()
    if gw > IMG_W or gh > IMG_H then error("grown image overflows the box: " .. gw .. "x" .. gh) end
    if gw < IMG_W - 1 and gh < IMG_H - 1 then error("grown image fills neither axis: " .. gw .. "x" .. gh) end
    if math.abs(gw / gh - 100 / 150) > 0.02 then error("aspect not preserved: " .. gw .. "x" .. gh) end
    if gw <= 100 or gh <= 150 then error("image was not grown at all: " .. gw .. "x" .. gh) end
    eq(img.scale_factor, 1, "painted 1:1")
    eq(img.width, gw, "widget width = grown width")
end)

test("the grown copy is NEVER put in the shared cache", function()
    -- prefer-larger would otherwise pin the blurry copy as the canonical
    -- and a later real decode at hero size could no longer replace it.
    reset(fakebb(100, 150, { tag = "cache" }), nil)
    local s = slot{}
    s:_renderCover(nil)
    eq(#Cache.puts, 0, "puts")
    eq(s._out.kind, "cover")
end)

test("cover_fill slot grows to exactly the image box", function()
    reset(fakebb(100, 150, { tag = "cache" }), nil)
    local s = slot{ cover_fill = true }
    s:_renderCover(nil)
    eq(s._out.kind, "cover")
    eq(s._out.img.image:getWidth(),  IMG_W, "fill w")
    eq(s._out.img.image:getHeight(), IMG_H, "fill h")
    eq(s._out.img.image_disposable, true)
    eq(#Cache.puts, 0, "still never cached")
end)

test("no cache entry + BIM nil: the placeholder (nothing to grow)", function()
    reset(nil, nil)
    local s = slot{}
    s:_renderCover(nil)
    eq(s._out.kind, "fallback")
    eq(Repo.asked, 1)
end)

test("a real decode wins over the cached copy", function()
    -- BIM has the row: the slot must take the full-size source, so the
    -- hero gets real pixels and the result flows to the cache as before.
    local small = fakebb(100, 150, { tag = "cache" })
    local src   = fakebb(600, 900, { tag = "bim" })
    reset(small, src)
    local s = slot{ cover_fill = true }
    s:_renderCover(nil)
    eq(s._out.kind, "cover")
    eq(#Cache.puts, 1, "the scaled decode was cached")
    eq(Cache.puts[1]:getWidth(),  IMG_W)
    eq(Cache.puts[1]:getHeight(), IMG_H)
    eq(src.freed, true, "source freed after scaling")
    eq(small.freed, false, "cache buffer untouched")
end)

test("hero tier hit still pre-empts BIM and the cached copy", function()
    local small = fakebb(100, 150, { tag = "cache" })
    reset(small, nil)
    HeroTier.target_h = IMG_H
    local tier_src = fakebb(400, 600, { tag = "tier" })
    HeroTier.noteSource(HeroTier, "/lib/colour-of-magic.epub", tier_src)
    local s = slot{ cover_fill = true }
    s:_renderCover(nil)
    eq(s._out.kind, "cover")
    eq(Repo.asked, 0, "BIM not consulted on a tier hit")
    eq(#Cache.puts, 1, "tier copy scaled and cached like any source")
end)

test("a failing grow degrades to the placeholder, never raises", function()
    reset(fakebb(100, 150, { tag = "cache", scale_fails = true }), nil)
    local s = slot{}
    local ok = pcall(function() s:_renderCover(nil) end)
    eq(ok, true, "no error escapes _renderCover")
    eq(s._out.kind, "fallback")
end)

test("a cache entry that already covers the slot paints straight from cache (unchanged path)", function()
    local big = fakebb(400, 600, { tag = "cache" })
    reset(big, nil)
    local s = slot{}
    s:_renderCover(nil)
    eq(s._out.kind, "cover")
    eq(Repo.asked, 0, "no decode needed")
    eq(s._out.img.image, big, "paints the cache buffer itself")
    eq(s._out.img.image_disposable, false, "cache owns it")
end)

print(string.format("PASS %d  FAIL %d", pass, fail))
if fail > 0 then os.exit(1) end
