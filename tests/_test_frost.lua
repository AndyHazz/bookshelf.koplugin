-- tests/_test_frost.lua
-- The panel blur's arithmetic (lib/bookshelf_frost): downscale, box blur,
-- bilinear back up, and the cache key. Plain Lua tables stand in for the
-- ffi byte arrays the device passes; the code indexes both the same way.
-- Usage (from plugin root): lua tests/_test_frost.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local H_ = dofile("tests/_helpers.lua")
local t, eq = H_.runner(), H_.eq
local Frost = dofile("lib/bookshelf_frost.lua")

local function alloc(n) local a = {}; for i = 0, n - 1 do a[i] = 0 end; return a end
-- A w x h single-channel image as bytes, from fn(x, y).
local function image(w, h, fn, bpp, nch)
    bpp, nch = bpp or 1, nch or 1
    local a = {}
    for y = 0, h - 1 do for x = 0, w - 1 do
        for c = 0, bpp - 1 do a[(y * w + x) * bpp + c] = (c < nch) and fn(x, y, c) or 0 end
    end end
    return a
end
local function blurInto(src, w, h, bpp, nch, ox, oy, ow, oh, alpha)
    local dst = alloc(ow * oh * bpp)
    Frost.blur(src, w * bpp, bpp, nch, w, h, ox, oy, ow, oh, dst, ow * bpp, alpha, alloc)
    return dst
end

t.test("downsample averages each block, and a partial edge block only what it has", function()
    -- 5x3, f = 2: blocks of 2x2, the last column and row are partial
    local src = image(5, 3, function(x, y) return x * 10 + y end)
    local out = alloc(3 * 2)
    local dw, dh = Frost.downsample(src, 5, 1, 1, 5, 3, 2, out)
    eq(dw, 3); eq(dh, 2)
    eq(out[0], (0 + 10 + 1 + 11) / 4, "first block")
    eq(out[2], (40 + 41) / 2, "right edge: one column, two rows")
    eq(out[5], 42, "bottom-right corner: one pixel")
end)

t.test("a flat picture blurs to exactly itself: no banding introduced", function()
    local src = image(64, 40, function() return 137 end)
    local dst = blurInto(src, 64, 40, 1, 1, 8, 8, 40, 20)
    for i = 0, 40 * 20 - 1 do
        if dst[i] ~= 137 then error("pixel " .. i .. " is " .. tostring(dst[i])) end
    end
end)

t.test("the box blur keeps the total and spreads an impulse evenly both ways", function()
    local w, h = 15, 11
    local buf = alloc(w * h)
    buf[5 * w + 7] = 900
    Frost.boxBlur(buf, w, h, 1, 1, 2, alloc(w * h))
    local sum = 0
    for i = 0, w * h - 1 do sum = sum + buf[i] end
    assert(math.abs(sum - 900) < 1e-6, "the blur gained or lost tone: " .. sum)
    eq(buf[5 * w + 6], buf[5 * w + 8], "not symmetric left/right")
    eq(buf[4 * w + 7], buf[6 * w + 7], "not symmetric up/down")
    assert(buf[5 * w + 7] < 900 and buf[5 * w + 7] > buf[5 * w + 9], "the peak did not spread")
end)

t.test("detail goes, tone stays: a fine stripe pattern becomes its mean", function()
    -- 1px black/white stripes are exactly the detail a panel should hide
    local src = image(96, 64, function(x) return (x % 2 == 0) and 0 or 255 end)
    local dst = blurInto(src, 96, 64, 1, 1, 24, 16, 48, 32)
    for i = 0, 48 * 32 - 1 do
        assert(math.abs(dst[i] - 127.5) <= 1, "a stripe survived at " .. i .. ": " .. dst[i])
    end
end)

t.test("a hard edge comes back as a smooth ramp, not FACTOR-wide steps", function()
    -- left half dark, right half light: across the edge every output pixel
    -- must be no darker than its left neighbour, and no flat runs inside the
    -- ramp (a nearest-neighbour stretch repeats each value FACTOR times)
    local w, h = 128, 48
    local src = image(w, h, function(x) return x < 64 and 40 or 220 end)
    local dst = blurInto(src, w, h, 1, 1, 0, 16, w, 16)
    local row = 8 * w
    local first, last
    for x = 1, w - 1 do
        local d = dst[row + x] - dst[row + x - 1]
        assert(d >= 0, "the ramp went backwards at x=" .. x)
        if d > 0 then first = first or x; last = x end
    end
    assert(first and last - first + 1 >= 2 * Frost.FACTOR, "the edge was not softened")
    for x = first, last do
        assert(dst[row + x] ~= dst[row + x - 1], "a flat step inside the ramp at x=" .. x .. ": blocky")
    end
    eq(dst[row], 40, "the blur reached the far left")
    eq(dst[row + w - 1], 220, "the blur reached the far right")
end)

t.test("soft, not a smear: a small light shape keeps its place and most of its contrast", function()
    -- an 8px light square on a dark ground: the frost should leave it
    -- recognisable -- still clearly lighter at its centre than its ground
    local w, h = 64, 64
    local src = image(w, h, function(x, y)
        return (x >= 28 and x < 36 and y >= 28 and y < 36) and 220 or 40 end)
    local dst = blurInto(src, w, h, 1, 1, 0, 0, w, h)
    local c, ground = dst[32 * w + 32], dst[4 * w + 4]
    eq(ground, 40)
    -- 35%: the ~4px frost (2x, radius 2, two passes; maintainer asked for a
    -- slightly larger blur than ~2px) keeps ~41%; the first ~20px version
    -- (8x, radius 2, three passes), which "left nothing", keeps far less.
    assert(c - ground >= 0.35 * 180, "the shape's centre kept only " .. (c - ground) .. " of 180 levels")
end)

t.test("RGB32: channels blur apart and the alpha byte is written opaque", function()
    local src = image(32, 32, function(_x, _y, c) return ({ 200, 100, 30 })[c + 1] end, 4, 3)
    local dst = blurInto(src, 32, 32, 4, 3, 4, 4, 8, 8, 255)
    eq(dst[0], 200); eq(dst[1], 100); eq(dst[2], 30)
    eq(dst[3], 255, "alpha must be opaque or the blit blends it away")
    eq(dst[(7 * 8 + 7) * 4 + 1], 100, "the last pixel's green")
end)

t.test("region: the panel grown by the margin, clipped to the picture", function()
    local rx, ry, rw, rh = Frost.region(18, 1561, 1200, 67, 48, 1236, 1648)
    eq(rx, 0, "clipped at the left edge"); eq(ry, 1561 - 48)
    eq(rx + rw, 1236, "clipped at the right edge"); eq(ry + rh, 1648, "clipped at the bottom")
    eq(select(1, Frost.region(300, 5, 10, 10, 48, 1000, 100)), 252, "grown by the margin")
end)

t.test("the cache key names the picture (with its night mode) and the rect", function()
    local day = Frost.key("/w.png|1236x1648", 18, 18, 1200, 142)
    local night = Frost.key("/w.png|1236x1648|n", 18, 18, 1200, 142)
    assert(day ~= night, "a night toggle must not reuse the day blur")
    assert(day ~= Frost.key("/w.png|1236x1648", 18, 1561, 1200, 67), "two panels share a key")
    eq(day, Frost.key("/w.png|1236x1648", 18, 18, 1200, 142), "the key is not stable")
    eq(Frost.key(nil, 0, 0, 1, 1), nil, "no picture, no key")
end)

-- ── the dither onto the e-ink panel's 16 greys ────────────────────────────
-- A PW5 shows grey v as level v >> 4 (bands [16n, 16n + 15]); the only bytes
-- that show as exactly what was meant are n * 17, the one byte of level n
-- that every rounding (truncate, nearest) agrees on.

t.test("every dithered byte is an exact device level: (b >> 4) == its level, b == level * 17", function()
    for y = 0, 7 do for x = 0, 7 do for v = 0, 255 do
        local n = Frost.ditherLevel(x, y, v)
        assert(n >= 0 and n <= 15, "level out of range: " .. n)
        local buf = { [0] = v }
        Frost.dither(buf, 1, 1, 1, x, y)
        local b = buf[0]
        eq(b, n * 17, "byte for v=" .. v .. " at " .. x .. "," .. y)
        eq(math.floor(b / 16), n, "the device would show v=" .. v .. " as another level")
    end end end
end)

t.test("each pixel lands on one of the two levels either side of its tone", function()
    for v = 0, 255 do
        local lo = math.floor(v * 15 / 255)
        for p = 0, 63 do
            local n = Frost.ditherLevel(p % 8, math.floor(p / 8), v)
            assert(n == lo or n == lo + 1, "v=" .. v .. " jumped to level " .. n)
        end
    end
end)

t.test("the stipple keeps the tone: an 8x8 tile of any grey averages back to it", function()
    for v = 0, 255 do
        local buf = {}
        for i = 0, 63 do buf[i] = v end
        Frost.dither(buf, 8, 8, 8, 0, 0)
        local s = 0
        for i = 0, 63 do s = s + buf[i] end
        assert(math.abs(s / 64 - v) <= 1, "v=" .. v .. " averages " .. s / 64)
    end
end)

t.test("the pattern is anchored to the screen: a patch matches the panel it is cut from", function()
    -- a 40x24 panel at screen (13, 7), and a 9x5 patch of it at (21, 12)
    local W, Hh, X0, Y0 = 40, 24, 13, 7
    local panel = image(W, Hh, function(x, y) return (x * 5 + y * 9) % 256 end)
    local patch = {}
    for y = 0, 4 do for x = 0, 8 do patch[y * 9 + x] = panel[(y + 5) * W + (x + 8)] end end
    Frost.dither(panel, W, W, Hh, X0, Y0)
    Frost.dither(patch, 9, 9, 5, X0 + 8, Y0 + 5)
    for y = 0, 4 do for x = 0, 8 do
        eq(patch[y * 9 + x], panel[(y + 5) * W + (x + 8)], "seam at " .. x .. "," .. y)
    end end
end)

t.test("KOReader's threshold map: 1..64, each once", function()
    local seen = {}
    for i = 0, 63 do
        local m = Frost.O8X8[i]
        assert(m >= 1 and m <= 64 and not seen[m], "map entry " .. i .. " is " .. tostring(m))
        seen[m] = true
    end
end)

t.done()
