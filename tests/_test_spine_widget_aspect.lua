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

local SpineWidget = require("lib/bookshelf_spine_widget")

-- _cardDimensions consults self:_noShadow(), so a fixture has to resolve
-- methods on SpineWidget rather than being a bare table.
local function spine(t) return setmetatable(t or {}, { __index = SpineWidget }) end

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
    -- Asserted as a RANGE, not a literal: the cap is a deliberate
    -- fidelity-versus-rows trade that gets retuned against real libraries
    -- (1.65 -> 1.60 on 2026-08-14), and a test that has to be edited every
    -- time it is tuned only ever gets edited, never consulted. What must hold
    -- is that it stays above the standard 2:3 and does not run away.
    local cap = SpineWidget.COVER_ASPECT_CAP
    if not (type(cap) == "number" and cap > 1.5 and cap <= 1.7) then
        error("cover aspect cap should be a sane overshoot of 2:3, got " .. tostring(cap), 2)
    end
end)

test("bookAspect: reads the WxH cover_sizetag", function()
    eq(SpineWidget.bookAspect(book(100, 150)), 1.5)
end)

test("bookAspect: clamps to the cap for very tall covers", function()
    eq(SpineWidget.bookAspect(book(100, 500)), SpineWidget.COVER_ASPECT_CAP)
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

-- downloadedTickOffset: placement of the OPDS "you already have this" tick.
-- Screen:scaleBySize is the identity in this harness, so CARD_BORDER = 1 and
-- both bar margins = 3. The tick must land bottom-right and stay fully inside
-- the card: it is the one corner badge with no pill frame to make an overhang
-- read as intentional.
test("downloadedTickOffset: bottom-right, fully inside the card", function()
    local x, y = SpineWidget.downloadedTickOffset(200, 300, 20, 27, 1)
    -- x = card_w - CARD_BORDER - side - (glyph_w + 2*halo_w)
    eq(x, 200 - 1 - 3 - 22, "right-anchored, inset by the bar's side margin")
    -- y = card_h - CARD_BORDER - bar_pad - widget_h (the page-count pill's
    -- own vertical anchor, so the two badges sit on one baseline)
    eq(y, 300 - 1 - 3 - 27, "bottom-anchored on the pill's baseline")
    assert(x + 22 <= 200, "right edge must not leave the card")
    assert(y + 27 <= 300, "bottom edge must not leave the card")
end)

test("downloadedTickOffset: matches the page-count pill's vertical anchor", function()
    -- The pill computes badge_y as bottom_y + bar_h - badge_h where
    -- bottom_y = card_h - CARD_BORDER - bar_pad - bar_h. Same value, and the
    -- bar height cancels: card_h - CARD_BORDER - bar_pad - <own height>.
    local _x, y = SpineWidget.downloadedTickOffset(200, 300, 20, 18, 1)
    local card_h, CARD_BORDER, bar_pad, bar_h, badge_h = 300, 1, 3, 8, 18
    local bottom_y = card_h - CARD_BORDER - bar_pad - bar_h
    eq(y, bottom_y + bar_h - badge_h)
end)

test("downloadedTickOffset: a glyph too big for the card clamps to the border", function()
    -- Degenerate only (the caller refuses a glyph wider than 40% of the card),
    -- but the clamp must never hand back a negative offset: a negative padding
    -- on a FrameContainer paints outside the parent.
    local x, y = SpineWidget.downloadedTickOffset(20, 20, 40, 60, 1)
    eq(x, 1, "clamped to CARD_BORDER")
    eq(y, 1, "clamped to CARD_BORDER")
end)

-- _cardDimensions: the LAYOUT half of the drop shadow. The shadow paints into
-- an L of pixels on the right and bottom edges, and those pixels are taken off
-- the card here -- so "no drop shadow" and "give the cover its slot back" are
-- the same request, and a flag that only stopped the ShadowRect being built
-- would leave a flat thumbnail paying for chrome it declined.
--
-- Called as a plain function with a table of fields rather than through :new,
-- so no rendering runs; the method reads only self.width/height/flat_thumb.
test("_cardDimensions: a normal card reserves the shadow's pixels", function()
    local cw, ch = SpineWidget._cardDimensions(spine{ width = 100, height = 150 })
    eq(cw, 100 - SpineWidget.SHADOW_OFFSET, "card width")
    eq(ch, 150 - SpineWidget.SHADOW_OFFSET, "card height")
end)

test("_cardDimensions: a flat thumbnail keeps the whole slot", function()
    local cw, ch = SpineWidget._cardDimensions(spine{ width = 100, height = 150,
                                                flat_thumb = true })
    eq(cw, 100, "flat card takes the full width")
    eq(ch, 150, "flat card takes the full height")
end)

test("_cardDimensions: flat_card is NOT flat_thumb", function()
    -- The Text folder style suppresses the shadow's PAINT but keeps its
    -- reserved pixels, so the tile stays aligned with the folder cardboard
    -- drawn around it (bookshelf_folder_stack.lua sizes that art off the same
    -- SHADOW_OFFSET). Overloading one flag for both would have moved six
    -- folder tiles; this pins the two apart.
    local cw, ch = SpineWidget._cardDimensions(spine{ width = 100, height = 150,
                                                flat_card = true })
    eq(cw, 100 - SpineWidget.SHADOW_OFFSET, "flat_card still reserves width")
    eq(ch, 150 - SpineWidget.SHADOW_OFFSET, "flat_card still reserves height")
end)

test("flat_thumb defaults off, so the grid and hero are untouched", function()
    -- Every existing caller (ShelfRow's grid covers, HeroCard, the folder and
    -- series stacks, the cover picker) omits the flag entirely. If the default
    -- ever flips, every card surface in the plugin goes square-cornered at
    -- once.
    eq(SpineWidget.flat_thumb, false, "flat_thumb default")
end)

-- ---------------------------------------------------------------------------
-- #353: square corners / no drop shadow as user options. flat_thumb (the list
-- view's cover column) still forces both; these let the grid and hero opt in
-- independently, because someone may want square corners and keep the shadow.
local function withSettings(t, fn)
    _G.__test_settings = t
    local ok, err = pcall(fn)
    _G.__test_settings = {}
    if not ok then error(err, 2) end
end

test("corners: rounded by default, so nothing changes for existing users", function()
    withSettings({}, function()
        eq(SpineWidget._squareCorners{}, false, "default corner style")
        eq(SpineWidget._noShadow{},      false, "default shadow")
    end)
end)

test("corners: the setting squares them off", function()
    withSettings({ cover_square_corners = true }, function()
        eq(SpineWidget._squareCorners{}, true, "setting on")
        eq(SpineWidget._noShadow{}, false, "shadow is a separate setting")
    end)
end)

test("shadow: the setting drops it, independently of the corners", function()
    withSettings({ cover_no_shadow = true }, function()
        eq(SpineWidget._noShadow{}, true, "setting on")
        eq(SpineWidget._squareCorners{}, false, "corners are a separate setting")
    end)
end)

test("flat_thumb still forces both, whatever the settings say", function()
    withSettings({}, function()
        eq(SpineWidget._squareCorners{ flat_thumb = true }, true, "corners")
        eq(SpineWidget._noShadow{ flat_thumb = true },      true, "shadow")
    end)
end)

test("no-shadow gives the reserved pixels back to the card", function()
    withSettings({ cover_no_shadow = true }, function()
        local cw, ch = SpineWidget._cardDimensions(spine{ width = 100, height = 150 })
        eq(cw, 100, "width reclaimed")
        eq(ch, 150, "height reclaimed")
    end)
end)

test("no-shadow does NOT disturb flat_card's reservation", function()
    -- flat_card keeps the shadow's pixels on purpose, so a Text-style folder
    -- tile stays aligned with the cardboard drawn around it. A global
    -- no-shadow preference must not move those six tiles.
    withSettings({ cover_no_shadow = true }, function()
        local cw, ch = SpineWidget._cardDimensions(spine{ width = 100, height = 150,
                                                    flat_card = true })
        eq(cw, 100 - SpineWidget.SHADOW_OFFSET, "flat_card still reserves width")
        eq(ch, 150 - SpineWidget.SHADOW_OFFSET, "flat_card still reserves height")
    end)
end)

-- ── force_shadow: a stack keeps its shadow (#362) ──────────────────────────
-- Inside a pile the grey is not a shadow cast on the page, it is what
-- separates the front book from the ones behind it. Without it the tile reads
-- as a stack of blank sheets, and the front cover's rounded corner opens onto
-- the white page-edge behind it -- the chipped corner the issue reported.
--
-- THREE places have to honour the flag and missing ANY ONE leaves white at the
-- corner, which is exactly what happened while fixing this: the reservation
-- and the shadow paint were both corrected and the corner was STILL white,
-- because the corner mask was still restoring page white. So all three are
-- pinned, the mask included.
test("force_shadow keeps the reservation with the setting on", function()
    withSettings({ cover_no_shadow = true }, function()
        local cw, ch = SpineWidget._cardDimensions(spine{ width = 100, height = 150,
                                                    force_shadow = true })
        eq(cw, 100 - SpineWidget.SHADOW_OFFSET, "width must stay reserved")
        eq(ch, 150 - SpineWidget.SHADOW_OFFSET, "height must stay reserved")
    end)
end)

test("force_shadow defaults off, so ordinary covers are untouched", function()
    withSettings({ cover_no_shadow = true }, function()
        local cw = SpineWidget._cardDimensions(spine{ width = 100, height = 150 })
        eq(cw, 100, "a plain cover still reclaims its pixels")
    end)
    eq(SpineWidget.force_shadow, false, "the field must default to off")
end)

test("all three force_shadow sites are wired", function()
    -- Source-shape: the shadow PAINT and the corner MASK are inside render
    -- paths this suite cannot drive without a full widget tree, and a fix that
    -- reaches only some of them looks correct until it is rendered.
    local src = io.open("lib/bookshelf_spine_widget.lua"):read("*a")
    assert(src:match("self:_noShadow%(%) and not self%.flat_card and not self%.force_shadow"),
        "_cardDimensions must keep the reservation for force_shadow")
    assert(src:match("elseif self:_noShadow%(%) and not self%.force_shadow then"),
        "the shadow must actually be painted for force_shadow")
    assert(src:match("self:_squareCorners%(%) or %(self:_noShadow%(%) and not self%.force_shadow%)"),
        "the corner mask must restore shadow grey, not page white, for "
        .. "force_shadow -- this is the one that produced the white pixels")
end)

test("both stack builders ask for it, and only in stack mode", function()
    for _, f in ipairs({ "lib/bookshelf_series_stack.lua", "lib/bookshelf_folder_stack.lua" }) do
        local src = io.open(f):read("*a")
        -- EVERY cover these files build is a tile's front cover, so every one
        -- needs the flag. Counting rather than matching: a single surviving
        -- occurrence satisfies a match while the branch a given tile actually
        -- takes has quietly lost it.
        local covers, flagged = 0, 0
        for _ in src:gmatch("SpineWidget:new{") do covers = covers + 1 end
        for _ in src:gmatch("force_shadow%s*=%s*%(display_mode == StackDisplay%.STACK%)") do
            flagged = flagged + 1
        end
        assert(covers > 0, f .. " builds no covers -- did it move?")
        assert(flagged == covers,
            f .. " passes force_shadow on " .. flagged .. " of " .. covers
            .. " covers; every branch builds a tile's front cover")
        assert(src:match("keep_shadow%s*=%s*cover_flat or display_mode == StackDisplay%.STACK"),
            f .. " must keep the cardboard's reservation for a stack too, or "
            .. "the cover has no room to cast the shadow into")
    end
end)

test("squaring the corners alone leaves the shadow reservation alone", function()
    withSettings({ cover_square_corners = true }, function()
        local cw, ch = SpineWidget._cardDimensions(spine{ width = 100, height = 150 })
        eq(cw, 100 - SpineWidget.SHADOW_OFFSET, "width still reserved")
        eq(ch, 150 - SpineWidget.SHADOW_OFFSET, "height still reserved")
    end)
end)

-- ── the drop shadow's corners ───────────────────────────────────────────────
-- The shadow sits directly under the card, offset down-right, so its corners
-- have to match the CARD's. Painted at a constant radius it stayed rounded
-- under a square cover and left a light notch at every corner, exactly where
-- the two outlines should coincide (seen on a PW5 at 10x: 12 pixels per
-- corner, gone after the fix). ShadowRect is a module local with no way in
-- from here, so these are source-shape guards against that regression; the
-- fix itself was confirmed against the device.
local spine_src = io.open("lib/bookshelf_spine_widget.lua"):read("*a")

test("the shadow takes a radius rather than assuming one", function()
    local paint = spine_src:match("function ShadowRect:paintTo%(bb, x, y%)\n(.-)\nend")
    assert(paint, "ShadowRect:paintTo is gone or was renamed")
    assert(not paint:match("_shadowGray%(%), CARD_RADIUS"),
        "the shadow is painted at the constant radius again")
    assert(paint:match("self%.radius"), "the shadow no longer honours a radius")
end)

test("the card passes its own corner choice to its shadow", function()
    local ctor = spine_src:match("ShadowRect:new{(.-)}")
    assert(ctor, "the ShadowRect construction site moved")
    assert(ctor:match("_squareCorners"),
        "the shadow is built without asking whether the card is square")
end)

print(string.format("\n%d pass, %d fail", pass, fail))
os.exit(fail == 0 and 0 or 1)
