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
package.preload["lib/bookshelf_book_repository"] = function()
    return {
        readProgress = function(fp)
            _G._test_read_progress_calls = (_G._test_read_progress_calls or 0) + 1
            return nil, nil, nil, _G._test_progress_pages and _G._test_progress_pages[fp]
        end,
        prefersDocSettingsPageCount = function(book)
            return book and book.format == "EPUB"
        end,
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

-- Page count -----------------------------------------------------------------
test("EPUB page-count badge prefers DocSettings pages over BIM estimate", function()
    setAll(true)
    S.progress_page_count_enabled = true
    _G._test_read_progress_calls = 0
    _G._test_progress_pages = { ["/books/three-apples.epub"] = 370 }
    local b = {
        filepath = "/books/three-apples.epub",
        format = "EPUB",
        status = "new",
        page_count = 222,
    }
    local r = CP.decide(b)
    eq(r.page_count, true)
    eq(b.page_count, 370)
    eq(_G._test_read_progress_calls, 1)
end)

test("fixed-layout page-count badge keeps existing BIM pages", function()
    setAll(true)
    S.progress_page_count_enabled = true
    _G._test_read_progress_calls = 0
    _G._test_progress_pages = { ["/books/fixed.pdf"] = 370 }
    local b = {
        filepath = "/books/fixed.pdf",
        format = "PDF",
        status = "new",
        page_count = 271,
    }
    local r = CP.decide(b)
    eq(r.page_count, true)
    eq(b.page_count, 271)
    eq(_G._test_read_progress_calls, 0)
end)

print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
