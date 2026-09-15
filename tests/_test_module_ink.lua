-- tests/_test_module_ink.lua
-- Micro-module colour roles actually reach the modules that read them.
--
-- WHAT NEEDS PINNING. The module system publishes its ink under TWO names:
-- SM.COLOR_PRIMARY/COLOR_MUTED, and the same values re-exported as
-- Kit.COLOR_PRIMARY/COLOR_MUTED so a module needs one require. The re-export
-- is a plain assignment taken at load time, so a setter that updated only the
-- first left every Kit-reading module painting the colour that was current
-- when the kit was first required -- black, on a near-black card.
--
-- The failure is invisible in review because both spellings look correct at
-- the call site. Which modules broke depended only on which name their author
-- happened to reach for: the streak card themed, the countdown card did not.
-- setCardBg had already solved this for the card surface; setInk had not.
--
-- Usage (from plugin root): lua tests/_test_module_ink.lua

package.path = "./?.lua;./?/init.lua;" .. package.path
package.loaded["logger"] = { dbg = function() end, info = function() end,
                             warn = function() end, err = function() end }
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local function read(path)
    local f = io.open(path); assert(f, "could not read " .. path)
    local s = f:read("a"); f:close(); return s
end

-- A stand-in kit, installed BEFORE the module system loads so the lazy
-- `require("lib/bookshelf_module_kit")` inside the setters finds it. The real
-- kit drags in fonts and the render stack.
local function freshSystem()
    package.loaded["lib/bookshelf_start_menu_modules"] = nil
    package.loaded["lib/bookshelf_module_kit"] = {
        COLOR_PRIMARY = "kit-stale", COLOR_MUTED = "kit-stale", CARD_BG = "kit-stale",
    }
    local SM = require("lib/bookshelf_start_menu_modules")
    return SM, package.loaded["lib/bookshelf_module_kit"]
end

-- ── the setters reach both names ───────────────────────────────────────────

t.test("setInk reaches the kit's re-exported copies", function()
    local SM, Kit = freshSystem()
    SM.setInk("INK", "MUTED")
    eq(SM.COLOR_PRIMARY, "INK")
    eq(SM.COLOR_MUTED,   "MUTED")
    eq(Kit.COLOR_PRIMARY, "INK",
        "a module reading Kit.COLOR_PRIMARY still paints the load-time black")
    eq(Kit.COLOR_MUTED,   "MUTED",
        "a module reading Kit.COLOR_MUTED still paints the load-time grey")
end)

t.test("setCardBg reaches the kit too, which is the pattern setInk copies", function()
    local SM, Kit = freshSystem()
    SM.setCardBg("CARD")
    eq(SM.CARD_BG, "CARD")
    eq(Kit.CARD_BG, "CARD")
end)

t.test("a nil argument keeps the value it had", function()
    -- The shelf passes whatever the theme resolved; a device with no cover
    -- palette hands back nil for one of them and must not blank the other.
    local SM, Kit = freshSystem()
    SM.setInk("INK", "MUTED")
    SM.setInk(nil, "MUTED2")
    eq(SM.COLOR_PRIMARY, "INK")
    eq(Kit.COLOR_PRIMARY, "INK")
    eq(Kit.COLOR_MUTED, "MUTED2")
end)

-- ── icons: the bitmaps that ignore fgcolor ─────────────────────────────────

local Wallpaper = require("lib/bookshelf_wallpaper")
local function ink(level) return { getColor8 = function() return { a = level } end } end

t.test("tintIcon hands back the original when there is nothing to do", function()
    local icon = { alpha = true }
    eq(Wallpaper.tintIcon(nil, icon), icon, "no ink")
    local not_an_icon = {}   -- no `alpha` field: how an icon widget is recognised
    eq(Wallpaper.tintIcon(ink(0xFF), not_an_icon), not_an_icon,
        "anything without an alpha field is not an icon bitmap")
    eq(Wallpaper.tintIcon(ink(0), icon), icon,
        "black ink on black artwork: a mask render that changes nothing")
end)

t.test("tintIcon leaves a COLOUR icon alone", function()
    -- mask is an alpha stencil with ONE fgcolor, so tinting a colour icon
    -- flattens the artwork to a silhouette. Worse than the problem.
    local icon = { alpha = true, file = "/fake/colour.png" }
    local real = Wallpaper.iconHasColour
    Wallpaper.iconHasColour = function() return true end
    local out = Wallpaper.tintIcon(ink(0xFF), icon)
    Wallpaper.iconHasColour = real
    eq(out, icon)
end)

t.test("tintIcon masks monochrome artwork to the ink it was given", function()
    package.loaded["ffi/blitbuffer"] = package.loaded["ffi/blitbuffer"] or {
        COLOR_BLACK = "black", COLOR_WHITE = "white", TYPE_BB8 = 1,
        new = function() return nil end,
    }
    package.loaded["ui/widget/widget"] = package.loaded["ui/widget/widget"] or {
        extend = function(_self, spec) 
            spec = spec or {}
            spec.extend = function(s, sp) sp = sp or {}; setmetatable(sp, {__index = s}); return sp end
            spec.new = function(s, o) o = o or {}; setmetatable(o, {__index = s})
                if o.init then o:init() end; return o end
            return spec
        end,
    }
    local icon = { alpha = true, dim = true, file = "/fake/mono.png",
                   getSize = function() return { w = 4, h = 4 } end }
    local real = Wallpaper.iconHasColour
    Wallpaper.iconHasColour = function() return false end
    local out = Wallpaper.tintIcon(ink(0xFF), icon)
    Wallpaper.iconHasColour = real
    assert(out ~= icon, "monochrome artwork was not recoloured at all")
    eq(out.inner, icon)
    eq(icon.dim, false, "a dimmed icon masks to a flat grey unless dim is cleared")
end)

-- ── the two call sites that had the bug ────────────────────────────────────

t.test("the full-screen overlay's glyphs ask for an ink", function()
    -- The close X and the hamburger are REPAINTS of the shelf footer's own two
    -- glyphs at the same coordinates, and the shelf asks _chromeInk for those.
    -- While a white backing sat under them a hard-coded black was invisible as
    -- a bug; once the panel went dark the whole footer went missing, which on
    -- a touch-only device is the close button going missing.
    local src = read("lib/bookshelf_micro_fullscreen.lua")
    assert(src:find("_glyphInk", 1, true), "no ink helper in the overlay")
    local bad = {}
    local n = 0
    for line in src:gmatch("[^\n]*") do
        n = n + 1
        local code = line:gsub("%-%-.*$", "")
        if code:find("paintRect") and code:find("COLOR_BLACK") then
            bad[#bad + 1] = "line " .. n .. ": " .. line:gsub("^%s+", "")
        end
    end
    assert(#bad == 0, "overlay glyph painted in a hard-coded black:\n  "
        .. table.concat(bad, "\n  "))
end)

t.test("the action module tints its icon bitmap", function()
    -- Its glyph branch takes fg and honours it; the IconWidget branch cannot,
    -- so the two branches of one function disagreed about the theme.
    local src = read("micromodules/action.lua"):gsub("%-%-[^\n]*", "")
    assert(src:find("tintIcon", 1, true),
        "action.lua returns an IconWidget without tinting it")
end)

t.test("no micromodule composites toward a hard-coded ink level", function()
    -- The analogue clock draws its face by blending over the buffer, so its
    -- colour is a luminance and not a Blitbuffer colour -- which put it outside
    -- every fgcolor sweep. It defaulted to 0 and vanished on the dark card.
    local src = read("micromodules/analogue_clock.lua"):gsub("%-%-[^\n]*", "")
    assert(src:find("face_ink", 1, true),
        "the clock face blends toward a fixed level again")
    assert(not src:find("ink%s*=%s*ink%s+or%s+0"),
        "the clock face still falls back to black")
end)

t.done()
