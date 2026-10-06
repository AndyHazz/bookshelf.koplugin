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

t.test("a hard edge comes back as a smooth ramp, not 8px steps", function()
    -- left half dark, right half light: across the edge every output pixel
    -- must be no darker than its left neighbour, and the steps small
    local w, h = 128, 48
    local src = image(w, h, function(x) return x < 64 and 40 or 220 end)
    local dst = blurInto(src, w, h, 1, 1, 0, 16, w, 16)
    local row = 8 * w
    local worst = 0
    for x = 1, w - 1 do
        local d = dst[row + x] - dst[row + x - 1]
        assert(d >= 0, "the ramp went backwards at x=" .. x)
        if d > worst then worst = d end
    end
    assert(worst <= 12, "a step of " .. worst .. " levels: blocky, not bilinear")
    assert(dst[row] < 60 and dst[row + w - 1] > 200, "the blur reached the far ends")
end)

t.test("RGB32: channels blur apart and the alpha byte is written opaque", function()
    local src = image(32, 32, function(_x, _y, c) return ({ 200, 100, 30 })[c + 1] end, 4, 3)
    local dst = blurInto(src, 32, 32, 4, 3, 4, 4, 8, 8, 255)
    eq(dst[0], 200); eq(dst[1], 100); eq(dst[2], 30)
    eq(dst[3], 255, "alpha must be opaque or the blit blends it away")
    eq(dst[(7 * 8 + 7) * 4 + 1], 100, "the last pixel's green")
end)

t.test("region: the panel grown by the margin, clipped to the picture", function()
    local rx, ry, rw, rh = Frost.region(18, 1561, 1200, 67, Frost.margin(), 1236, 1648)
    eq(rx, 0, "clipped at the left edge"); eq(ry, 1561 - Frost.margin())
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

t.done()
