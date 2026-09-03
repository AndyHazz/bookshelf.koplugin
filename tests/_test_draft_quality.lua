-- tests/_test_draft_quality.lua
-- SpineWidget's draft-quality tally, which decides whether a pinch/zoom step
-- needs its settle rebuild.
--
-- A draft render has three outcomes. Two are downgrades (a placeholder when
-- nothing is cached, a Lua nearest-neighbour upscale when the cached bitmap is
-- smaller than the slot) and one is not: when the cached bitmap is already at
-- least the slot size, the draft builds an ImageWidget with byte-identical
-- arguments to the normal cache-first path. If every cover took that route the
-- settle would repaint identical pixels, and skipping it saves a whole
-- _rebuild (181-420ms on a PW5) plus a second full-screen e-ink refresh.
--
-- Getting this wrong is a VISIBLE quality regression -- covers left soft or
-- blank with no second pass coming -- so each branch is pinned, along with the
-- reset between draft sessions.
--
-- The preamble mirrors _test_spine_external_cover_key.lua.
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


-- Controllable cover cache, replacing the preamble's always-nil stub. Set
-- before the require so it wins.
_G.__fake_cover = nil
package.preload["lib/bookshelf_scaled_cover_cache"] = function()
    return {
        get = function() return _G.__fake_cover end,
        put = function(_, _, bb) return bb end,
    }
end

local SpineWidget = require("lib/bookshelf_spine_widget")
local t = dofile("tests/_helpers.lua").runner()

local function fake_bb(w, h)
    return {
        getWidth  = function() return w end,
        getHeight = function() return h end,
        scale     = function() return fake_bb(w, h) end,
    }
end

-- Minimal self: _renderDraftCover only reaches these three.
local function fake_self()
    return {
        cover_fill        = false,
        _renderFallback   = function() return "FALLBACK" end,
        _wrapCoverInCard  = function() return "CARD" end,
    }
end

local SLOT_W, SLOT_H = 262, 393
local function draft(cover)
    _G.__fake_cover = cover
    SpineWidget._renderDraftCover(fake_self(), "/books/a.epub",
        SLOT_W, SLOT_H, SLOT_W, SLOT_H, 0)
end

t.test("a draft that rendered nothing is not lossless", function()
    SpineWidget.setDraftMode(true)
    assert(SpineWidget.draftWasLossless() == false,
        "zero renders must not read as lossless -- 'no covers involved' is not "
        .. "the same as 'nothing to upgrade'")
    SpineWidget.setDraftMode(false)
end)

t.test("cached bitmap at least slot size is lossless", function()
    SpineWidget.setDraftMode(true)
    draft(fake_bb(SLOT_W, SLOT_H))
    assert(SpineWidget.draftWasLossless() == true, "exact-size cache should be lossless")
    SpineWidget.setDraftMode(false)

    SpineWidget.setDraftMode(true)
    draft(fake_bb(SLOT_W * 2, SLOT_H * 2))
    assert(SpineWidget.draftWasLossless() == true, "larger cache should be lossless")
    SpineWidget.setDraftMode(false)
end)

t.test("cached bitmap smaller than the slot is a downgrade", function()
    for _, c in ipairs({ { SLOT_W - 1, SLOT_H }, { SLOT_W, SLOT_H - 1 } }) do
        SpineWidget.setDraftMode(true)
        draft(fake_bb(c[1], c[2]))
        assert(SpineWidget.draftWasLossless() == false,
            ("%dx%d is an upscale and must force the settle"):format(c[1], c[2]))
        SpineWidget.setDraftMode(false)
    end
end)

t.test("no cached bitmap at all is a downgrade", function()
    SpineWidget.setDraftMode(true)
    draft(nil)
    assert(SpineWidget.draftWasLossless() == false,
        "a placeholder must force the settle")
    SpineWidget.setDraftMode(false)

    -- Paired with a full render, so the placeholder has to be COUNTED rather
    -- than merely skipped: if it were not counted at all, the tally would read
    -- 1 of 1 full and the page would be declared lossless with a blank cover
    -- still on screen.
    SpineWidget.setDraftMode(true)
    draft(nil)
    draft(fake_bb(SLOT_W, SLOT_H))
    assert(SpineWidget.draftWasLossless() == false,
        "an uncounted placeholder would let a blank cover pass as lossless")
    SpineWidget.setDraftMode(false)
end)

t.test("one downgrade among many full renders still forces the settle", function()
    SpineWidget.setDraftMode(true)
    for _ = 1, 8 do draft(fake_bb(SLOT_W, SLOT_H)) end
    draft(fake_bb(SLOT_W - 10, SLOT_H))
    for _ = 1, 8 do draft(fake_bb(SLOT_W, SLOT_H)) end
    assert(SpineWidget.draftWasLossless() == false,
        "a single soft cover in the page must still be sharpened")
    SpineWidget.setDraftMode(false)
end)

t.test("raising draft mode resets the tally", function()
    -- Without the reset a downgraded page would poison every later step, or
    -- worse, a clean page would make a later dirty one look lossless.
    SpineWidget.setDraftMode(true)
    draft(nil)
    SpineWidget.setDraftMode(false)
    assert(SpineWidget.draftWasLossless() == false, "precondition")

    SpineWidget.setDraftMode(true)
    draft(fake_bb(SLOT_W, SLOT_H))
    assert(SpineWidget.draftWasLossless() == true,
        "a fresh draft session should not inherit the previous one's downgrade")
    SpineWidget.setDraftMode(false)
end)

t.done()
