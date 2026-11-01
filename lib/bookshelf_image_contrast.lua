-- lib/bookshelf_image_contrast.lua
--
-- Image contrast (Settings > Image contrast):
--
--   Contrast boost        covers, spines and ornaments (the foreground):
--                         deeper shadows and mid-tones, highlights kept.
--   Wallpaper contrast    the wallpaper around its own median, -100..100
--   Wallpaper brightness  the wallpaper toward white or black, -100..100
--
-- Each is applied ONCE to a picture the shelf already decodes and keeps (a
-- scaled cover entering ScaledCoverCache, an ornament render, the decoded
-- wallpaper), never per paint: blending on a Kindle framebuffer is slow
-- memory (~650 ms full screen on a PW5 against ~23 ms in a copy). The disk
-- copies stay raw, so a change needs no cache rebuild, only the copies in
-- memory dropped (flushForeground; the wallpaper's key changes by itself).
--
-- All values are day-mode pixels: covers and ornaments are inverted for
-- night after this, and the wallpaper's night inversion runs after it too.

local M = {}

M.BOOST_KEY = "image_contrast_boost"         -- 0..100, default 0
M.WP_CONTRAST_KEY = "wallpaper_contrast"     -- -100..100, default 0
M.WP_BRIGHTNESS_KEY = "wallpaper_brightness" -- -100..100, default 0

-- The store is required on use: the wallpaper and ornament modules load
-- this one, and nothing here may cost them a settings read at load.
local function pct(key, lo)
    local ok, S = pcall(require, "lib/bookshelf_settings_store")
    local v = ok and S and S.read and tonumber(S.read(key, 0)) or 0
    return math.max(lo, math.min(100, v)) / 100
end

-- boost() -> 0..1
function M.boost() return pct(M.BOOST_KEY, 0) end

-- wallpaper() -> brightness, contrast (each -1..1)
function M.wallpaper()
    return pct(M.WP_BRIGHTNESS_KEY, -100), pct(M.WP_CONTRAST_KEY, -100)
end

-- wallpaperKey() -> "" when the wallpaper is shown as it is, else a suffix
-- for every cache of the adjusted picture (the decoded copy, its blurs).
function M.wallpaperKey()
    local b, c = M.wallpaper()
    if b == 0 and c == 0 then return "" end
    return string.format("|wb%d,%d", math.floor(b * 100 + 0.5), math.floor(c * 100 + 0.5))
end

-- ── Curves (pure) ─────────────────────────────────────────────────────────

-- boostLUT(lo, med, hi, s) -> lut[0..255] for a picture whose 1st percentile,
-- median and 99th percentile greys are lo, med, hi, at strength s (0..1).
--
-- Contrast around the picture's own median, which stays where it is, so the
-- picture as a whole is no lighter or darker:
--   below it, a gamma curve (1 + 2s) pinned at black and the median: the
--   shadows and mid-tones go deeper;
--   above it, a lift c * (i - med) * (255 - i) / (255 - med), c = s (at
--   most 0.9), pinned at the median and white: the light parts go lighter.
--   Its slope at white is 1 - c, never flat, so the greys nearest white
--   keep a share of their gaps (white lettering on a pale ground merged
--   under a curve that rolled off into white: PW5 trial).
-- Darks only darken and lights only lighten, on any picture. A dark
-- ornament (median ~13 in the Halloween pack) has little to darken: its
-- contrast comes from the lift. The first curve, an S normalised over
-- 0..255, pulled every median toward mid-grey instead: a dark ornament's
-- greys were lifted (40 > 83 at 35%) and a pale one's crushed (150 > 43).
-- lo and hi are kept for callers; the curve needs only the median.
function M.boostLUT(lo, med, hi, s)
    local lut = {}
    if s <= 0 then
        for i = 0, 255 do lut[i] = i end
        return lut
    end
    s = math.min(1, s)
    local g = 1 + 2 * s
    local c = math.min(0.9, s)
    local m = math.max(1, math.min(254, med or 128))
    for i = 0, 255 do
        local v
        if i < m then
            v = m * (i / m) ^ g
        else
            v = i + c * (i - m) * (255 - i) / (255 - m)
        end
        lut[i] = math.max(0, math.min(255, math.floor(v + 0.5)))
    end
    return lut
end

-- wallpaperLUT(med, b, c) -> lut: contrast c scales each grey's distance from
-- the picture's median (c = -1 is one flat grey, so a dark picture stays
-- dark as it goes quiet); brightness b then moves every grey that share of
-- the way to white (b > 0) or black (b < 0).
function M.wallpaperLUT(med, b, c)
    local lut = {}
    local k = 1 + c
    for i = 0, 255 do
        local v = math.max(0, math.min(255, med + (i - med) * k))
        if b > 0 then v = v + (255 - v) * b else v = v * (1 + b) end
        lut[i] = math.floor(v + 0.5)
    end
    return lut
end

-- shiftRGB(r, g, b, lut) -> r, g, b: a colour pixel moved in brightness only.
-- A curve per channel also spreads the channels apart (more saturation) and
-- clips them unevenly (hue shifts): yellows went acid on the colour rig.
local function luma(r, g, b) return math.floor((r * 77 + g * 150 + b * 29) / 256) end
local function clamp(v) return v < 0 and 0 or (v > 255 and 255 or v) end
function M.shiftRGB(r, g, b, lut)
    local y = luma(r, g, b)
    local d = lut[y] - y
    return clamp(r + d), clamp(g + d), clamp(b + d)
end

-- ── Buffers (KOReader's ffi) ──────────────────────────────────────────────

local BPP = { [1] = 1, [2] = 2, [4] = 3, [5] = 4 }   -- BB8, BB8A, RGB24, RGB32
local GREY = { [1] = true, [2] = true }
local function bytes(bb)
    local bpp = BPP[bb:getType()]
    if not bpp then return nil end
    local ffi = require("ffi")
    return ffi.cast("uint8_t *", bb.data), bpp, tonumber(bb.w), tonumber(bb.h), tonumber(bb.stride)
end

-- levels(bb) -> lo, med, hi: the 1st, 50th and 99th percentile greys of a
-- sample, ignoring see-through pixels (an ornament's surround, which is
-- stored black, would read as half the picture).
function M.levels(bb)
    local p, bpp, w, h, stride = bytes(bb)
    if not p then return nil end
    local grey = GREY[bb:getType()]
    local hist, n = {}, 0
    for i = 0, 255 do hist[i] = 0 end
    local step = math.max(1, math.floor(math.sqrt(w * h / 20000)))
    for y = 0, h - 1, step do
        local row = p + y * stride
        for x = 0, w - 1, step do
            local q = row + x * bpp
            if bpp == 1 or bpp == 3 or q[bpp - 1] >= 128 then
                local v = grey and q[0] or luma(q[0], q[1], q[2])
                hist[v] = hist[v] + 1
                n = n + 1
            end
        end
    end
    if n == 0 then return nil end
    local function at(f)
        local target, acc = f * n, 0
        for i = 0, 255 do
            acc = acc + hist[i]
            if acc >= target then return i end
        end
        return 255
    end
    return at(0.01), at(0.5), at(0.99)
end

-- applyLUT(bb, lut): in place; grey values through the table, colour pixels
-- by shiftRGB's rule. Alpha is left alone.
function M.applyLUT(bb, lut)
    local p, bpp, w, h, stride = bytes(bb)
    if not p then return false end
    local L = require("ffi").new("int16_t[256]")
    for i = 0, 255 do L[i] = lut[i] end
    local rshift = require("bit").rshift
    local grey = GREY[bb:getType()]
    for y = 0, h - 1 do
        local row = p + y * stride
        if bpp == 1 then
            for x = 0, w - 1 do row[x] = L[row[x]] end
        elseif grey then
            for x = 0, w - 1 do
                local q = row + x * bpp
                q[0] = L[q[0]]
            end
        else
            for x = 0, w - 1 do
                local q = row + x * bpp
                local r, g, b = q[0], q[1], q[2]
                local y0 = rshift(r * 77 + g * 150 + b * 29, 8)
                local d = L[y0] - y0
                if d ~= 0 then
                    r, g, b = r + d, g + d, b + d
                    q[0] = r < 0 and 0 or (r > 255 and 255 or r)
                    q[1] = g < 0 and 0 or (g > 255 and 255 or g)
                    q[2] = b < 0 and 0 or (b > 255 and 255 or b)
                end
            end
        end
    end
    return true
end

-- ── Foreground ────────────────────────────────────────────────────────────

-- boostImage(bb) -> true when bb was changed. Once per buffer: a cached
-- cover is handed back by put() many times, and is boosted only on the way
-- in. Keyed weakly, so a freed buffer takes its mark with it.
--
-- A COPY of a boosted picture (a cached cover scaled up for a bigger slot, a
-- collage made from cached covers) is boosted already: derive() passes the
-- mark on, so the copy is not boosted a second time, and the cover cache
-- does not write it to disk as if it were raw (isBoosted).
local boosted = setmetatable({}, { __mode = "k" })
function M.isBoosted(bb) return bb ~= nil and boosted[bb] == true end
function M.markBoosted(bb) if bb then boosted[bb] = true end end
function M.derive(src, copy)
    if copy and M.isBoosted(src) then boosted[copy] = true end
    return copy
end
function M.boostImage(bb)
    local s = M.boost()
    if s <= 0 or not bb or boosted[bb] then return false end
    boosted[bb] = true
    local ok, changed = pcall(function()
        local lo, med, hi = M.levels(bb)
        if not lo then return false end
        return M.applyLUT(bb, M.boostLUT(lo, med, hi, s))
    end)
    return ok and changed or false
end

-- spineLook(look, max_luma) -> the spine's fill with the boost applied.
-- Sampled spines sit in a narrow band of dark greys under the ceiling that
-- keeps their light titles legible (about 55..max_luma on real covers), so
-- neighbours look alike on 16 greys. The band is stretched DOWN toward
-- black with the ceiling fixed (spreading it both ways sent the lighter
-- half to the ceiling, all one grey); r, g, b scale together, hue kept.
local spread = setmetatable({}, { __mode = "k" })
function M.spineLook(look, max_luma)
    local s = M.boost()
    if s <= 0 or type(look) ~= "table" or not look.r then return look end
    local hit = spread[look]
    if hit and hit._boost == s then return hit end
    local top, lo, floor = max_luma or 110, 55, 18
    local L = 0.299 * look.r + 0.587 * look.g + 0.114 * look.b
    local stretched = floor + (L - lo) * (top - floor) / math.max(1, top - lo)
    local L2 = math.max(floor, math.min(top, L + (stretched - L) * s))
    local f = (L > 1) and (L2 / L) or 1
    local out = {}
    for k, v in pairs(look) do out[k] = v end
    local function ch(v)
        if L <= 1 then v = L2 else v = v * f end
        return math.floor(math.max(0, math.min(255, v)) + 0.5)
    end
    out.r, out.g, out.b = ch(look.r), ch(look.g), ch(look.b)
    out._boost = s
    spread[look] = out
    return out
end

-- flushForeground(): drop what holds boosted pictures in memory, so the
-- next paint makes them again at the current strength from the raw disk
-- copies. Called when the boost changes.
function M.flushForeground()
    local ok, C = pcall(require, "lib/bookshelf_scaled_cover_cache")
    if ok and C and C.dropMemory then pcall(C.dropMemory, C) end
    -- Custom cover images are boosted in ImageSource's own cache.
    local ok_i, I = pcall(require, "lib/bookshelf_image_source")
    if ok_i and I and I.invalidateCache then pcall(I.invalidateCache) end
    local ok_o, O = pcall(require, "lib/bookshelf_ornaments")
    if ok_o and O and O.dropRenders then pcall(O.dropRenders) end
    -- Spine layouts carry each spine's fill (their renders are keyed on it).
    local ok_s, SpineShelf = pcall(require, "lib/bookshelf_spine_shelf")
    if ok_s and SpineShelf and SpineShelf.dropPlanCache then pcall(SpineShelf.dropPlanCache) end
end

return M
