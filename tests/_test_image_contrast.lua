-- tests/_test_image_contrast.lua
-- lib/bookshelf_image_contrast: the curves and their settings. The buffer
-- passes (applyLUT, histogram) need KOReader's ffi and are exercised on the
-- rig; everything here is the arithmetic they apply.
-- Usage: `lua tests/_test_image_contrast.lua` from the plugin dir.

package.path = "./?.lua;" .. package.path

local S = {}
package.preload["lib/bookshelf_settings_store"] = function()
    return { read = function(k, d) if S[k] == nil then return d end return S[k] end }
end

local IC = require("lib/bookshelf_image_contrast")

local pass, fail = 0, 0
local function test(name, fn)
    S = {}
    local ok, err = pcall(fn)
    if ok then pass = pass + 1
    else fail = fail + 1; io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n") end
end

test("everything is off by default", function()
    assert(IC.boost() == 0, "boost")
    local b, c = IC.wallpaper()
    assert(b == 0 and c == 0, "wallpaper")
    assert(IC.wallpaperKey() == "", "no key suffix when off")
end)

test("settings are whole percents, clamped", function()
    S.image_contrast_boost = 35
    assert(math.abs(IC.boost() - 0.35) < 1e-9)
    S.image_contrast_boost = 250
    assert(IC.boost() == 1)
    S.image_contrast_boost = -20
    assert(IC.boost() == 0, "boost never reduces")
    S.wallpaper_contrast, S.wallpaper_brightness = -150, 40
    local b, c = IC.wallpaper()
    assert(c == -1 and math.abs(b - 0.4) < 1e-9)
    assert(IC.wallpaperKey() ~= "", "an adjusted wallpaper is a different picture")
end)

-- A typical cover's levels: 1st percentile, median, 99th percentile.
local LO, MED, HI = 20, 120, 230

test("the boost curve keeps order and both ends", function()
    for _, s in ipairs({ 0.2, 0.35, 0.6, 1 }) do
        local lut = IC.boostLUT(LO, MED, HI, s)
        for i = 1, 255 do assert(lut[i] >= lut[i - 1], "monotonic at " .. i .. " s=" .. s) end
        assert(lut[0] == 0 and lut[255] == 255, "black and white stay put")
    end
end)

test("the boost darkens the darks and leaves near-whites alone", function()
    local lut = IC.boostLUT(LO, MED, HI, 0.5)
    assert(lut[60] < 60, "a dark grey goes darker: " .. lut[60])
    for i = 230, 255 do assert(math.abs(lut[i] - i) <= 3, "near-white " .. i .. " moved to " .. lut[i]) end
    for i = 130, 245 do
        assert(lut[i + 10] - lut[i] >= 9, "highlights bunched at " .. i)
    end
    -- white lettering on a pale ground keeps its gap (the PW5 trial's fault)
    assert(lut[250] - lut[215] >= 30, "pale ground and white lettering merged")
end)

test("a flat picture is not stretched into a poster", function()
    local lut = IC.boostLUT(118, 120, 122, 1)
    assert(math.abs(lut[120] - 120) <= 40, "flat grey moved too far: " .. lut[120])
end)

test("wallpaper at 0/0 is the picture as it is", function()
    local lut = IC.wallpaperLUT(100, 0, 0)
    for i = 0, 255 do assert(lut[i] == i, "moved " .. i) end
end)

test("wallpaper contrast pivots on the picture's median", function()
    local lut = IC.wallpaperLUT(80, 0, -1)
    for i = 0, 255 do assert(lut[i] == 80, "flat at the median") end
    lut = IC.wallpaperLUT(80, 0, -0.5)
    assert(lut[80] == 80 and lut[0] == 40 and lut[255] > 160)
end)

test("wallpaper brightness runs to white and to black", function()
    local up, down = IC.wallpaperLUT(80, 1, 0), IC.wallpaperLUT(80, -1, 0)
    for i = 0, 255 do assert(up[i] == 255 and down[i] == 0) end
end)

test("a colour pixel moves in brightness only, hue kept", function()
    local lut = {}
    for i = 0, 255 do lut[i] = math.max(0, i - 40) end
    local r, g, b = IC.shiftRGB(200, 120, 60, lut)
    assert(r - g == 80 and g - b == 60, "channel gaps kept: " .. r .. "," .. g .. "," .. b)
    assert(r < 200, "darker")
    r, g, b = IC.shiftRGB(30, 10, 5, lut)
    assert(r >= 0 and g >= 0 and b >= 0, "clamped at black")
end)

test("spines spread down under the title ceiling, hue kept", function()
    local look = { r = 100, g = 80, b = 60, sampled = true }
    assert(IC.spineLook(look, 110) == look, "off: the same look")
    S.image_contrast_boost = 60
    local out = IC.spineLook(look, 110)
    assert(out ~= look and out.sampled == true, "a copy with its other fields")
    assert(out.r < look.r, "darker")
    assert(math.abs(out.r / out.g - look.r / look.g) < 0.05, "hue kept")
    local L = 0.299 * out.r + 0.587 * out.g + 0.114 * out.b
    assert(L <= 110.5, "under the ceiling")
    S.image_contrast_boost = 20
    local weaker = IC.spineLook(look, 110)
    assert(weaker.r > out.r, "a changed strength is not served from the memo")
end)

-- ── Wiring: the orders that keep disk copies raw and keys honest ─────────
local function src(path) local f = assert(io.open(path)); local t = f:read("*a"); f:close(); return t end

test("a cover is boosted after its raw disk copy is written", function()
    local f = src("lib/bookshelf_scaled_cover_cache.lua")
    local put = f:match("\nfunction ScaledCoverCache:put%(.-\nend\n")
    assert(put, "put not found")
    local store, boost = put:find("D.store", 1, true), put:find("boostImage", 1, true)
    assert(store and boost and store < boost, "the disk copy would be boosted")
end)

test("the wallpaper's adjustment is in its keys and before the night inversion", function()
    local f = src("lib/bookshelf_wallpaper.lua")
    local bg = f:match("\nfunction M%.bg%(.-\nend\n")
    assert(bg, "M.bg not found")
    assert(bg:find('(night and "|n" or "") .. adjust', 1, true), "picture key")
    assert(bg:find("dkey .. adjust", 1, true), "the blurs' key")
    local lut, inv = bg:find("wallpaperLUT", 1, true), bg:find("invertRect", 1, true)
    assert(lut and inv and lut < inv, "adjusted after the night inversion")
    assert(bg:find("diskCache().store", 1, true) < lut, "the disk copy would be adjusted")
end)

test("an ornament is boosted after its disk copy, before the night pass, keyed", function()
    local f = src("lib/bookshelf_ornaments.lua")
    local r = f:match("\nfunction M%.render%(.-\nend\n")
    assert(r, "render not found")
    assert(r:find('"|b" .. boost', 1, true), "render key")
    local store = r:find("_disk_cache.store", 1, true)
    local boost = r:find("boostImage(bb)", 1, true)
    local inv = r:find("invertRect", 1, true)
    assert(store < boost and boost < inv, "order: store, boost, invert")
end)

test("a spine render is keyed on its fill colour", function()
    local f = src("lib/bookshelf_spine_shelf.lua")
    local k = f:match("\nfunction SpineBookSlot:_renderKey%(.-\nend\n")
    assert(k and k:find("e.look", 1, true), "a changed fill would serve the old render")
end)

test("Image contrast sits below the UI font in Settings", function()
    local f = src("lib/bookshelf_settings.lua")
    local font = f:find('_("Bookshelf UI font: %1")', 1, true)
    local ic = f:find('_("Image contrast")', 1, true)
    assert(font and ic and font < ic)
end)

print(string.format("PASS %d  FAIL %d", pass, fail))
if fail > 0 then os.exit(1) end
