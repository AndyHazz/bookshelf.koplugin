-- tests/_test_selection_shadow_colors.lua
-- The selection ring and cover shadow are user-settable (issue #199), and
-- default to exactly what was hard-coded before.
--
-- Usage (from plugin root): lua tests/_test_selection_shadow_colors.lua
--
-- WHAT NEEDS PINNING. Two colours moved from constants in the render path to
-- entries in the palette, and the risk of that is not the new option -- it is
-- the DEFAULT. A reader who never opens these rows must see the shelf they saw
-- yesterday, in both modes, and the previous values were asymmetric in a way
-- that is easy to "tidy" wrongly: the ring was black in BOTH modes while the
-- shadow was two different greys. Anyone matching the ring's night default to
-- the border's near-white would silently restyle every selected cover.
--
-- The shadow's night value is also load-bearing beyond taste: night mode
-- inverts the framebuffer, so the pair is what keeps the shadow reading as a
-- shadow rather than a halo.

package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local src = io.open("lib/bookshelf_cover_progress.lua"):read("a")
local settings_src = io.open("lib/bookshelf_settings.lua"):read("a")
local spine_src = io.open("lib/bookshelf_spine_widget.lua"):read("a")

local function default(name)
    return src:match(name .. "%s*=%s*{ hex = \"(#%x+)\" }")
end

t.test("the ring defaults to black in BOTH modes, as it was", function()
    -- It was Blitbuffer.COLOR_BLACK unconditionally. Not the border's
    -- near-white night value, which is the plausible-looking wrong answer.
    eq(default("DEFAULT_SELECTION"), "#000000")
    eq(default("NIGHT_DEFAULT_SELECTION"), "#000000")
end)

-- KOReader's Blitbuffer.gray is INVERTED. From ffi/blitbuffer.lua:
--
--     -- 0 is white, 1.0 is black
--     function BB.gray(level)
--         return Color8(bxor(floor(0xFF * level), 0xFF))
--     end
--
-- so gray(0.15) is 0xD9, not 38. Derived here rather than written out,
-- because an earlier version of this test restated the hand-arithmetic
-- "128 and 38 on the 0-255 scale" and pinned the night shadow to 0x26 --
-- which paints dark and DISPLAYS 0xD9, the bright halo the file header says
-- this pair exists to prevent. bxor(v, 0xFF) is 255 - v over 0..255, spelled
-- that way because these suites run under Lua 5.1 as well, where binary `~`
-- is not an operator.
local function grayHex(level)
    local v = 255 - math.floor(255 * level)
    return string.format("#%02X%02X%02X", v, v, v)
end

t.test("the shadow defaults reproduce the old greys", function()
    -- "The old greys" = what the hard-coded constants EVALUATED to before
    -- issue 199 made them settable, which is still what spine_widget falls
    -- back to. Both levels are read from that source so the two cannot drift.
    local day_level   = spine_src:match("SHADOW_GRAY_DAY%s*=%s*Blitbuffer%.gray%(([%d%.]+)%)")
    local night_level = spine_src:match("SHADOW_GRAY_NIGHT%s*=%s*Blitbuffer%.gray%(([%d%.]+)%)")
    assert(day_level and night_level, "the spine widget's shadow fallbacks moved")
    eq(default("DEFAULT_CARD_SHADOW"),       grayHex(tonumber(day_level)))
    eq(default("NIGHT_DEFAULT_CARD_SHADOW"), grayHex(tonumber(night_level)))
end)

t.test("the night shadow paints LIGHT so it displays dark", function()
    -- Stated as the property rather than a value: whatever the level becomes,
    -- a shadow must survive the framebuffer inversion as something darker than
    -- the card it falls from. Painting below mid-grey in night mode means
    -- displaying above it, which is a halo.
    local hex = default("NIGHT_DEFAULT_CARD_SHADOW")
    local painted = tonumber(hex:sub(2, 3), 16)
    assert(painted > 0x80,
        "night shadow paints " .. hex .. ", which displays 0x"
        .. string.format("%02X", 255 - painted) .. " -- a halo, not a shadow")
end)

t.test("both colours are resolved per mode, not read raw", function()
    -- _readModeColor is what routes day and night to separate keys; reading
    -- the setting directly would let a night edit clobber the day colour.
    assert(src:match('_readModeColor%("selection_color"'),
        "the selection colour bypasses the day/night split")
    assert(src:match('_readModeColor%("card_shadow_color"'),
        "the shadow colour bypasses the day/night split")
end)

t.test("the glyph shadow is left alone", function()
    -- resolvedColors already had a `shadow`, for the offset shadow on GLYPHS,
    -- and it is deliberately hard-coded so it always displays dark. Issue 199
    -- asked about the shadow behind COVERS; conflating the two would make the
    -- favourite star's shadow follow a card setting.
    assert(src:match("shadow_hex = is_night"),
        "the glyph shadow is no longer hard-coded")
    assert(src:match("card_shadow%s*="), "the card shadow key is missing")
end)

t.test("both painters keep true colour instead of grey luminance", function()
    -- Blitbuffer's plain paintRoundedRect flattens its colour argument to
    -- luminance, so a red ring would paint grey on a colour device. The
    -- RGB32-aware dispatch is the whole reason these two call sites changed.
    assert(not spine_src:match("bb:paintRoundedRect%(x %- t"),
        "the ring still paints through the grey-flattening call")
    assert(spine_src:match("CoverProgress%.paintRoundedRect%(bb, x %- t"),
        "the ring does not use the RGB32-aware dispatch")
    assert(spine_src:match("CoverProgress%.paintRoundedRect%(bb, x, y, self%.width"),
        "the shadow does not use the RGB32-aware dispatch")
end)

t.test("the corner mask follows the ring's colour", function()
    -- The mask paints the four corner squares INTO the ring. It was hard-coded
    -- black to match a black ring; left that way, a recoloured ring grows four
    -- black teeth.
    assert(not spine_src:match("cover_args%.bg_color = Blitbuffer%.COLOR_BLACK"),
        "the corner mask is still pinned to black while the ring can move")
    assert(spine_src:match("cover_args%.bg_color = _selectionColor%(%)"),
        "the corner mask does not follow the ring")
end)

t.test("both keys are cleared by Reset colours", function()
    -- A row that Reset does not know about leaves a colour stuck until the
    -- user finds the per-row long-press.
    local list = settings_src:match("local keys = {(.-)}")
    assert(list, "the reset list could not be located")
    assert(list:match('"selection_color"'), "Reset skips the selection colour")
    assert(list:match('"card_shadow_color"'), "Reset skips the shadow colour")
end)

t.done()
