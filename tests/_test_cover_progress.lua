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

print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
