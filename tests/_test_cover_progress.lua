-- tests/_test_cover_progress.lua
-- Pure-Lua unit tests for bookshelf_cover_progress.decide(book).
-- Usage: cd into the plugin dir, then `lua tests/_test_cover_progress.lua`.
--
-- decide() is pure decision logic, but the module pulls in KOReader widget +
-- ffi requires at load time (the glyph/bar builders live in the same file).
-- Everything decide() needs is stubbed below; the widget builders only need
-- to *load*, not run.

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
}) do
    package.preload[name] = function() return make_widget_base() end
end
package.preload["ui/widget/textwidget"] = function() return { new = function(_, t) return t end } end
package.preload["ui/font"] = function() return { getFace = function() return {} end } end
package.preload["ui/geometry"] = function()
    return { new = function(_, t) return setmetatable(t or {}, { __index = {} }) end }
end
package.preload["ffi/blitbuffer"] = function()
    return {
        Color8     = function(n) return { v = n } end,
        ColorRGB32 = function(r,g,b,a) return { r=r, g=g, b=b, a=a } end,
        COLOR_WHITE = {}, COLOR_BLACK = {},
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
package.preload["device"] = function()
    return {
        screen = {
            isColorEnabled = function() return false end,
            scaleBySize    = function(_, n) return n end,
        },
    }
end
package.preload["lib/bookshelf_color"] = function()
    return { parseColorValue = function(v) return v end }
end

-- Settings stub: decide() reads RAW keys (no prefix). Per-test settable.
local S = {}
package.preload["lib/bookshelf_settings_store"] = function()
    return {
        read       = function(k) return S[k] end,
        save       = function(k, v) S[k] = v end,
        isTrue     = function(k) return S[k] == true end,
        nilOrTrue  = function(k) return S[k] == nil or S[k] == true end,
        generation = function() return 1 end,
    }
end

local CP = require("lib/bookshelf_cover_progress")

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1
    else fail = fail + 1; io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n") end
end
local function eq(a, e, msg)
    if a ~= e then error((msg or "") .. " expected=" .. tostring(e) .. " got=" .. tostring(a), 2) end
end

local function book(status, pct) return { status = status, book_pct = pct } end
local function setAll(v)
    S.progress_bar_enabled      = v
    S.progress_bookmark_enabled = v
    S.progress_badge_style      = v and "bookmark" or "none"
    S.on_hold_badge_enabled     = v
    S.on_hold_display           = nil  -- fall back to the legacy boolean
end

-- Reading --------------------------------------------------------------------
test("reading + pct shows bar + in_progress glyph", function()
    setAll(true)
    local r = CP.decide(book("reading", 0.5))
    eq(r.bar, true); eq(r.bar_pct, 0.5); eq(r.glyph, "in_progress")
end)
test("all toggles off → no indicators", function()
    setAll(false)
    local r = CP.decide(book("reading", 0.5))
    eq(r.bar, false); eq(r.glyph, nil)
end)

-- Complete -------------------------------------------------------------------
test("complete → complete_bookmark glyph by default, no bar", function()
    setAll(true)
    local r = CP.decide(book("complete", 0.42))
    eq(r.bar, false); eq(r.glyph, "complete_bookmark")
end)
test("complete with tickbox style → complete_tickbox", function()
    setAll(true); S.progress_badge_style = "tickbox"
    local r = CP.decide(book("complete", 1.0))
    eq(r.glyph, "complete_tickbox")
end)
test("complete does not fade by default (#138 opt-in)", function()
    setAll(true); S.finished_fade_enabled = nil
    local r = CP.decide(book("complete", 1.0))
    eq(r.on_hold_fade, nil, "fade")
end)
test("finished_fade_enabled → fade, badge kept (independent cues)", function()
    setAll(true); S.finished_fade_enabled = true
    local r = CP.decide(book("finished", 1.0))
    eq(r.on_hold_fade, true, "fade")
    eq(r.glyph, "complete_bookmark", "badge unaffected by fade")
    S.finished_fade_enabled = nil
end)
test("finished fade does not leak to reading/on-hold decisions", function()
    setAll(true); S.finished_fade_enabled = true; S.on_hold_display = "pause"
    eq(CP.decide(book("reading", 0.5)).on_hold_fade, nil, "reading")
    eq(CP.decide(book("on_hold", 0.5)).on_hold_fade, nil, "on-hold pause-only")
    S.finished_fade_enabled = nil; S.on_hold_display = nil
end)

-- On hold --------------------------------------------------------------------
test("on-hold badge ON → on_hold=true, corner glyph suppressed", function()
    setAll(true)
    local r = CP.decide(book("abandoned", 0.3))
    eq(r.on_hold, true, "on_hold flag")
    eq(r.glyph, nil, "corner glyph should be suppressed")
end)
test("on-hold badge ON still shows the progress bar when enabled", function()
    setAll(true)
    local r = CP.decide(book("on_hold", 0.3))
    eq(r.bar, true); eq(r.bar_pct, 0.3)
end)
test("on-hold badge OFF → falls back to in_progress bookmark", function()
    setAll(true); S.on_hold_badge_enabled = false
    local r = CP.decide(book("abandoned", 0.3))
    eq(r.on_hold, nil, "on_hold flag should be unset")
    eq(r.glyph, "in_progress", "should fall back to in_progress")
end)
test("on-hold badge defaults ON when key unset", function()
    setAll(true); S.on_hold_badge_enabled = nil
    local r = CP.decide(book("abandoned", 0.3))
    eq(r.on_hold, true)
end)

-- On hold, four-state on_hold_display (issue #121) --------------------------
test("on_hold_display=both → badge + fade, corner glyph suppressed", function()
    setAll(true); S.on_hold_display = "both"
    local r = CP.decide(book("on_hold", 0.3))
    eq(r.on_hold, true, "badge"); eq(r.on_hold_fade, true, "fade")
    eq(r.glyph, nil, "corner glyph")
end)
test("on_hold_display=pause → badge only", function()
    setAll(true); S.on_hold_display = "pause"
    local r = CP.decide(book("on_hold", 0.3))
    eq(r.on_hold, true, "badge"); eq(r.on_hold_fade, nil, "fade")
    eq(r.glyph, nil, "corner glyph")
end)
test("on_hold_display=fade → fade only", function()
    setAll(true); S.on_hold_display = "fade"
    local r = CP.decide(book("abandoned", 0.3))
    eq(r.on_hold, nil, "badge"); eq(r.on_hold_fade, true, "fade")
    eq(r.glyph, nil, "corner glyph")
end)
test("on_hold_display=none → no cues, falls back to in_progress bookmark", function()
    setAll(true); S.on_hold_display = "none"
    local r = CP.decide(book("on_hold", 0.3))
    eq(r.on_hold, nil, "badge"); eq(r.on_hold_fade, nil, "fade")
    eq(r.glyph, "in_progress", "bookmark fallback")
end)
test("on_hold_display wins over legacy boolean when both set", function()
    setAll(true); S.on_hold_badge_enabled = false; S.on_hold_display = "fade"
    local r = CP.decide(book("on_hold", 0.3))
    eq(r.on_hold, nil, "badge"); eq(r.on_hold_fade, true, "fade")
end)
test("legacy ON maps to both cues (fade flag set too)", function()
    setAll(true)  -- on_hold_badge_enabled=true, on_hold_display unset
    local r = CP.decide(book("on_hold", 0.3))
    eq(r.on_hold, true, "badge"); eq(r.on_hold_fade, true, "fade")
end)

-- New / nil ------------------------------------------------------------------
test("status=new shows nothing", function()
    setAll(true); eq(CP.decide(book("new", nil)).glyph, nil)
end)
test("nil status shows nothing", function()
    setAll(true); eq(CP.decide(book(nil, nil)).glyph, nil)
end)
test("nil book is defensive", function()
    setAll(true); local r = CP.decide(nil); eq(r.bar, false); eq(r.glyph, nil)
end)

-- Downloaded tick ------------------------------------------------------------
-- The OPDS "you already have this file" mark. Two properties are load-bearing.
--
-- 1. PRIVATE USE AREA ONLY. The glyph renders through the bundled nerd-font
--    "symbols" face, which covers U+E000..U+F8FF and nothing else; a non-PUA
--    codepoint has segfaulted this plugin before. U+F058 is nf-fa-check_circle
--    and maps to the `ok_sign` glyph in the bundled symbols.ttf cmap (the same
--    cmap lib/bookshelf_nerdfont_names.lua was generated from).
-- 2. decide() must NOT learn about it. decide()'s vocabulary is READ status
--    (in progress / finished / on hold), driven by status + percent and gated
--    behind the three status toggles. "I have this file" is not a read status
--    and has no inputs there, so the glyph is a constant the renderer reaches
--    for directly.
test("GLYPH_DOWNLOADED is a single Private-Use-Area codepoint", function()
    local g = CP.GLYPH_DOWNLOADED
    eq(type(g), "string", "constant must exist")
    -- UTF-8 decode of the one codepoint it must hold.
    local b1, b2, b3, b4 = g:byte(1, 4)
    eq(b4, nil, "must be exactly one 3-byte codepoint")
    local cp = (b1 - 0xE0) * 0x1000 + (b2 - 0x80) * 0x40 + (b3 - 0x80)
    eq(cp, 0xF058, "U+F058 (nf-fa-check_circle), verified present in symbols.ttf")
    eq(cp >= 0xE000 and cp <= 0xF8FF, true, "must be inside the Private Use Area")
end)

test("decide() does not surface the downloaded flag", function()
    setAll(true)
    local b = book(nil, nil); b.downloaded = true
    local r = CP.decide(b)
    eq(r.glyph, nil, "downloaded is not a read status")
    eq(r.downloaded, nil, "decide() must not grow a field for it")
end)

-- ── Chrome: the shelf menu and footer ground ───────────────────────────────
--
-- Its own key rather than reusing badge_bg. They start identical, but sharing
-- the key would mean recolouring your badges silently restyled the menu bar
-- and footer, and you could never have dark chrome with light badges.
--
-- The default is 0xFF in BOTH modes, which is not a mistake: night mode
-- inverts the frame, so one painted value gives white chrome in day and black
-- chrome at night, which is what it should be. Badge background does the
-- opposite (0xFF day, 0x00 night) precisely because a badge must stay white on
-- screen in both.

test("chrome background defaults to white in day", function()
    local prev = _G.G_reader_settings
    _G.G_reader_settings = {
        isTrue = function() return false end, readSetting = function() return nil end,
    }
    local ok, c = pcall(CP.resolvedColors)
    _G.G_reader_settings = prev
    assert(ok, "resolvedColors failed: " .. tostring(c))
    assert(c.chrome_bg, "no chrome background resolved")
    assert(c.chrome_bg.grey == 0xFF,
        "expected 0xFF, got " .. tostring(c.chrome_bg.grey))
end)

test("chrome background paints the SAME value at night, so it shows black", function()
    -- Painting 0x00 here would display white and put a bright bar across a
    -- night shelf, which is the mistake the drop shadow made.
    -- The shared resolvedInNight helper is defined further down this file, so
    -- the stub is inlined rather than moving these tests away from the rest of
    -- the chrome ones.
    local prev = _G.G_reader_settings
    _G.G_reader_settings = {
        isTrue = function(_s, k) return k == "night_mode" end,
        readSetting = function() return nil end,
    }
    local ok, c = pcall(CP.resolvedColors)
    _G.G_reader_settings = prev
    assert(ok, "resolvedColors failed in night mode: " .. tostring(c))
    assert(c.chrome_bg and c.chrome_bg.grey == 0xFF,
        "night chrome should paint 0xFF and display black, got "
        .. tostring(c.chrome_bg and c.chrome_bg.grey))
end)

test("chrome background is not the badge background", function()
    -- Same starting value, separate keys. If these ever become one field the
    -- decoupling has been undone by accident.
    local src = io.open("lib/bookshelf_cover_progress.lua"):read("a")
    assert(src:find('_readModeColor("chrome_bg"', 1, true),
        "chrome_bg does not read its own setting key")
end)

-- ── Night-mode defaults ────────────────────────────────────────────────────

-- These constants are in PAINT space: KOReader inverts the whole frame at
-- refresh, so a night default of 0xE5 DISPLAYS as 0xFF - 0xE5 = 0x1A. Getting
-- that backwards is the standing trap in this file, and it is invisible in a
-- day-mode screenshot.
local function resolvedInNight()
    local prev = _G.G_reader_settings
    _G.G_reader_settings = {
        isTrue      = function(_s, k) return k == "night_mode" end,
        readSetting = function() return nil end,
    }
    local ok, c = pcall(CP.resolvedColors)
    _G.G_reader_settings = prev
    assert(ok, "resolvedColors failed in night mode: " .. tostring(c))
    return c
end

test("night: the RIBBON and shelf badges get the 90%-black band", function()
    -- They had no night default at all, so they fell through to plain black --
    -- which in night mode paints white and DISPLAYS black, leaving the band
    -- invisible against the black page (maintainer report).
    local c = resolvedInNight()
    assert(c.ribbon_bg, "no night default: the ribbon falls through to pure black")
    assert(c.ribbon_bg.grey == 0xE5,
        "expected paint 0xE5 so it displays 0x1A (90% black), got "
        .. tostring(c.ribbon_bg.grey))
end)

test("night: the DIVIDER CARD keeps its own manilla default", function()
    -- The bug this pair exists for. v5.0.1 put the night default on folder_bg,
    -- which the divider card reads too:
    --
    --     local fill_color = indicator_colors.folder_bg
    --                        or constantInNight(CARDBOARD)
    --
    -- so the card's manilla turned near-black while its label kept its own
    -- default of constantInNight(BLACK) -- author and folder names went dark
    -- on dark (issue 395, reported with a photo).
    --
    -- folder_bg must stay nil when unset so the card reaches its own
    -- fallback. One setting key, two resolutions: raw here, night-defaulted
    -- as ribbon_bg for the surfaces that asked for a dark band.
    local c = resolvedInNight()
    assert(c.folder_bg == nil,
        "a night default on folder_bg darkens the divider card: issue 395 again")
end)

-- ── Re-colouring live indicators without a rebuild ─────────────────────────

test("a composed glyph re-colours by ROLE, not by child position", function()
    -- The dangling bookmarks and completed icons are a stack of halo copies
    -- under a centre fill. Tagging each child means this survives a change to
    -- the build order, which indexing "last child is the centre" would not.
    local g = CP.buildOutlinedGlyphWidget("X", 10, 1, "DAY_HALO", "DAY_CENTRE")
    local seen_halo, seen_centre = 0, 0
    for i = 1, #g do
        local role = g[i][1] and g[i][1]._bs_role
        if role == "halo" then seen_halo = seen_halo + 1 end
        if role == "centre" then seen_centre = seen_centre + 1 end
    end
    assert(seen_halo == 8, "expected 8 halo copies, got " .. seen_halo)
    assert(seen_centre == 1, "expected exactly one centre, got " .. seen_centre)

    g:_bs_recolour{ halo = "NIGHT_HALO", centre = "NIGHT_CENTRE" }
    for i = 1, #g do
        local glyph = g[i][1]
        if glyph._bs_role == "halo" then
            assert(glyph.fgcolor == "NIGHT_HALO", "a halo copy was missed")
        elseif glyph._bs_role == "centre" then
            assert(glyph.fgcolor == "NIGHT_CENTRE", "the centre fill was missed")
        end
    end
end)

test("a shadowed glyph keeps its shadow role distinct from the halo", function()
    -- Same colour family, different job: the shadow must not take the halo's
    -- colour or the glyph loses the raised look it dangles off the cover with.
    local g = CP.buildHaloShadowedGlyphWidget("X", 10, 1, 2, 2,
                                              "HALO", "CENTRE", "SHADOW")
    g:_bs_recolour{ halo = "NH", centre = "NC", shadow = "NS" }
    local found = {}
    for i = 1, #g do
        local glyph = g[i][1]
        if glyph and glyph._bs_role then found[glyph._bs_role] = glyph.fgcolor end
    end
    assert(found.shadow == "NS", "the shadow was not re-coloured")
    assert(found.halo   == "NH", "the halo was not re-coloured")
    assert(found.centre == "NC", "the centre was not re-coloured")
end)

test("refreshColors re-reads the palette for everything registered", function()
    -- The pick closure must re-derive from the CURRENT palette rather than
    -- capture the colours this build happened to use, or a flip would re-apply
    -- the day values it was created with.
    local g = CP.buildOutlinedGlyphWidget("X", 10, 1, "OLD_HALO", "OLD_CENTRE")
    CP.registerRecolour(g, function(c)
        return { halo = c.border, centre = c.bookmark }
    end)
    local prev = _G.G_reader_settings
    _G.G_reader_settings = {
        isTrue      = function() return false end,
        readSetting = function() return nil end,
    }
    local ok, n = pcall(CP.refreshColors)
    _G.G_reader_settings = prev
    assert(ok, "refreshColors errored: " .. tostring(n))
    assert(n >= 1, "nothing was refreshed")
    local centre
    for i = 1, #g do
        local glyph = g[i][1]
        if glyph and glyph._bs_role == "centre" then centre = glyph.fgcolor end
    end
    assert(centre ~= "OLD_CENTRE", "the centre kept its build-time colour")
end)

test("night: the card DROP SHADOW paints light so it displays dark", function()
    -- KOReader's Blitbuffer.gray is INVERTED. From ffi/blitbuffer.lua:
    --
    --     -- 0 is white, 1.0 is black
    --     function BB.gray(level)
    --         return Color8(bxor(floor(0xFF * level), 0xFF))
    --     end
    --
    -- so gray(0.15) is 0xD9, NOT 0x26. bookshelf_spine_widget's fallback has
    -- this right (SHADOW_GRAY_NIGHT = gray(0.15), painting 0xD9 so it displays
    -- 0x26, a dark grey). The settable default introduced with issue 199 was
    -- written as the colour it wanted to LOOK, 0x26, so it painted 0x26 and
    -- DISPLAYED 0xD9: a bright halo instead of a shadow, on every card and on
    -- the stack folder style (maintainer report).
    --
    -- The day default hides the same slip, which is why it went unnoticed:
    -- gray(0.5) is 0x80, and 0x80 is its own inverse.
    local c = resolvedInNight()
    assert(c.card_shadow, "the card shadow lost its night default")
    assert(c.card_shadow.hex == "#D9D9D9",
        "a shadow must PAINT light to DISPLAY dark under night inversion; "
        .. "expected #D9D9D9 (displays 0x26), got " .. tostring(c.card_shadow.hex))
end)

test("day: the card shadow stays mid-grey", function()
    -- The day value is not pre-inverted and must not be touched by the fix.
    local prev = _G.G_reader_settings
    _G.G_reader_settings = {
        isTrue      = function() return false end,
        readSetting = function() return nil end,
    }
    local ok, c = pcall(CP.resolvedColors)
    _G.G_reader_settings = prev
    assert(ok, "resolvedColors failed in day mode")
    assert(c.card_shadow and c.card_shadow.hex == "#808080",
        "expected the unchanged mid-grey, got "
        .. tostring(c.card_shadow and c.card_shadow.hex))
end)

test("night: the overlay foreground is left alone", function()
    -- No default is needed on either surface, once the background default is
    -- scoped correctly. The card wants black on manilla; the ribbon wants the
    -- constantInNight WHITE that ribbonColors already supplies. Adding one was
    -- the first attempted fix for 395 and it treated the symptom.
    local c = resolvedInNight()
    assert(c.folder_fg == nil, "the foreground gained a default nobody asked for")
end)

-- ── Shelf theme ────────────────────────────────────────────────────
--
-- "night" meant two things at once: the reader wants a dark shelf, and the
-- panel will flip the frame. They were always equal, so nothing had to tell
-- them apart -- and the shelf theme is exactly the case where they differ.

test("the two axes are separate, and the flip is their disagreement", function()
    local src = io.open("lib/bookshelf_cover_progress.lua"):read("a")
    local body = src:match("function M%.resolvedColors%(%).-\nend\n")
    assert(body, "resolvedColors could not be located")
    assert(body:match("dark ~= inverting"),
        "the flip is no longer the disagreement between look and frame")
    -- The flip's cache slot has to be declared with the other slots. Left
    -- off that line it becomes a GLOBAL: an _ENV hash lookup on the hot
    -- path and a name any other module can trample.
    local decl = src:match("local _resolved_cache[^\n]*")
    assert(decl and decl:find("_resolved_flip", 1, true),
        "_resolved_flip is not declared local with the other cache slots")
    -- The suffix picks the LOOK's stored colours; the flip corrects for the
    -- frame. Keyed on the device flag, a pinned theme reads the wrong half of
    -- the palette entirely.
    local suffix = src:match("local function _modeSuffix%(%).-\nend")
    assert(suffix:match("M%.theme%(%)"),
        "the palette suffix still follows the device instead of the look")
end)

test("the resolved cache knows about both axes", function()
    -- Keyed on the look alone, toggling night mode under a pinned theme would
    -- serve a palette built for the other frame state -- every colour wrong.
    local src = io.open("lib/bookshelf_cover_progress.lua"):read("a")
    assert(src:match("_resolved_flip == flip"),
        "the palette cache ignores the frame state")
    assert(src:match("_resolved_flip  = flip"),
        "the palette cache never records the frame state")
end)

test("every palette colour goes through the flip", function()
    -- One missed parse is one colour left inverted against all the others.
    local src = io.open("lib/bookshelf_cover_progress.lua"):read("a")
    local body = src:match("function M%.resolvedColors%(%).-_resolved_flip  = flip")
    assert(body, "resolvedColors could not be located")
    local raw = select(2, body:gsub("Color%.parseColorValue%(", ""))
    eq(raw, 1, "expected only _paint's own parse to remain")
end)

test("inverting a stored value keeps its shape", function()
    -- The flip works on the STORED shape, before parsing, so the parse cache
    -- and the greyscale luminance path never learn a theme exists.
    local Color = dofile("lib/bookshelf_color.lua")
    eq(Color.invertValue({ grey = 0xFF }).grey, 0x00)
    eq(Color.invertValue({ grey = 0xEE }).grey, 0x11)
    eq(Color.invertValue({ hex = "#000000" }).hex, "#FFFFFF")
    eq(Color.invertValue({ hex = "#FFD700" }).hex, "#0028FF")
    -- false is "none" -- an absence. Inverting it would turn "no ribbon" into
    -- a black one.
    eq(Color.invertValue(false), false)
    eq(Color.invertValue(nil), nil)
end)

print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
