-- tests/_test_cover_cache_shape.lua
-- A cover is never drawn from a cached copy of another shape.
--
-- The cover cache keeps one copy per book, made for whatever slot asked
-- first: a cover-grid cell is portrait, so a landscape strip collection's
-- copy is a portrait crop of it. A spine shelf's face-out of that book is
-- landscape. Reused there, the portrait crop was stretched sideways, and
-- the near-size path stored the stretch back. A slot of another shape got
-- the cache's larger copy back from put() and stretched that instead: a
-- Same size shelf squashed every landscape cover. A cached copy is now
-- reused only for a slot of (nearly) its shape; any other slot is made from
-- the cover itself and kept at its own size.
package.path = "./?.lua;" .. package.path
package.loaded["logger"] = { dbg = function() end, warn = function() end, info = function() end }
package.loaded["lib/bookshelf_cover_disk_cache"] = { store = function() return true end, load = function() end,
    drop = function() end, clear = function() end }
package.loaded["lib/bookshelf_hero_tier"] = { drop = function() end }
package.loaded["lib/bookshelf_image_contrast"] = { boostImage = function() end, isBoosted = function() return true end }
local SCC = require("lib/bookshelf_scaled_cover_cache")
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq
local SW = io.open("lib/bookshelf_spine_widget.lua"):read("*a")
local body = assert(SW:match("\nfunction SpineWidget:_renderCover%(bb%)\n(.-)\nend\n"), "_renderCover moved")

local shapeSrc = assert(SW:match("\nlocal SAME_SHAPE_TOL = [%d%.]+\nlocal function _sameShape%(bb, w, h%)\n.-\nend\n"), "_sameShape moved")
local _sameShape = assert(load(shapeSrc .. "return _sameShape"))()

local function img(w, h, what)
    return { what = what, getWidth = function() return w end, getHeight = function() return h end,
             getType = function() return 1 end, free = function() end, stride = w }
end
local decodes = 0
local SOURCE = function() decodes = decodes + 1; return img(1200, 900, "source") end
local env = setmetatable({
    ScaledCoverCache = SCC,
    _sameShape = _sameShape,
    CARD_BORDER = 2,
    HeroTier = { target_h = nil, take = function() end },
    _sliceCheck = function() end,
    _boostCover = function() end,
    _derived = function(_src, copy) return copy end,
    _getRepo = function() return { getCoverBB = function() return SOURCE() end } end,
    -- The real one crops or scales to the slot; what matters here is that
    -- it makes a slot-shaped copy of what it is given.
    _coverFillBB = function(src, w, h) return img(w, h, "from " .. tostring(src.what)) end,
    _thumbFor = function(fp, src, w, h)
        return SCC:getSized(fp, w, h) or SCC:putSized(fp, w, h, img(w, h, "thumb of " .. tostring(src.what)))
    end,
    ImageWidget = { new = function(_s, args) return args end },
}, { __index = _G })
local code = "local self, bb = ...\n" .. body
local render
if setfenv then render = assert(loadstring(code)); setfenv(render, env)
else render = assert(load(code, "render", "t", env)) end

local FP = "/b/Sunday Strips 1.cbz"
local function widget(w, h)
    return {
        cover_fill = true, book = { filepath = FP },
        _cardDimensions = function() return w + 4, h + 4 end,
        _wrapCoverInCard = function(_s, inner) return inner end,
    }
end
local function shown(inner)
    local i = inner.image
    return i:getWidth() .. "x" .. i:getHeight()
end
local function shape(inner) return inner.image:getWidth() / inner.image:getHeight() end

t.test("a landscape face-out is not made from the grid's portrait copy", function()
    SCC:clear(); decodes = 0
    SCC:put(FP, img(251, 374, "grid crop"))
    local inner = render(widget(276, 207))
    assert(math.abs(shape(inner) - 276 / 207) < 0.02, "drawn from a " .. shown(inner) .. " copy")
    eq(inner.image.what, "from source", "stretched from the cached copy of another shape")
end)

t.test("a portrait slot is not given the cache's larger landscape copy", function()
    SCC:clear(); decodes = 0
    SCC:put(FP, img(363, 273, "face-out"))
    local inner = render(widget(195, 295))
    eq(shown(inner), "195x295")
    eq(inner.image.what, "from source")
end)

t.test("that slot's copy is kept, so it is made once", function()
    SCC:clear(); decodes = 0
    SCC:put(FP, img(363, 273, "face-out"))
    render(widget(195, 295))
    local inner = render(widget(195, 295))
    eq(shown(inner), "195x295")
    eq(decodes, 1, "decoded again on the next render")
end)

t.test("a copy of the slot's shape is still reused, a little off size included", function()
    SCC:clear(); decodes = 0
    SCC:put(FP, img(300, 450, "kept"))
    local inner = render(widget(200, 300))
    eq(decodes, 0, "a same-shape copy was not reused")
    SCC:clear()
    SCC:put(FP, img(206, 299, "kept"))
    inner = render(widget(210, 303))
    eq(decodes, 0, "a near-size copy of the same shape was not grown")
    eq(inner.image.what, "from kept")
    -- A face-out's box follows its own cover (1.46 beside 1.50): close
    -- enough to share, as before.
    SCC:clear()
    SCC:put(FP, img(200, 300, "kept"))
    render(widget(205, 300))
    eq(decodes, 0)
end)

t.done()
