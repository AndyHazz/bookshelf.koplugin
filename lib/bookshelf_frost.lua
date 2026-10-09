-- lib/bookshelf_frost.lua
-- The blur behind a panel (Theme > Wallpaper > Blur wallpaper behind panels):
-- frosted glass over the wallpaper, under the panel's tint.
--
-- PURE ARITHMETIC over 0-indexed arrays, so the same code runs on an ffi
-- pointer into a Blitbuffer on the device and on a plain Lua table in the
-- tests (lua 5.4 has no ffi). Nothing here knows about Blitbuffer;
-- bookshelf_wallpaper copies the picture out, calls these, and owns the cache.
--
-- Cheap on purpose (a PW5 is a 1 GHz Cortex-A7): never a real Gaussian at
-- full resolution. The region is averaged down FACTOR times in each axis,
-- box-blurred there PASSES times (repeated box passes approach a Gaussian),
-- and stretched back with a bilinear filter, which keeps the result smooth
-- rather than the blocks a nearest-neighbour stretch (bb:scale) leaves.
-- Every pass touches each source pixel once, in a running sum, so the cost is
-- linear in the panel's area and does not grow with the blur's radius.
--
-- The result is cached by the caller and rebuilt only when what is behind the
-- panel changes (the picture, its night pre-inversion, the panel's rect), so
-- this runs once per picture, not per paint.

local M = {}

-- Downscale factor, box radius (in downscaled pixels) and passes. Together
-- about a 4px Gaussian: a soft frost that takes a print's fine lines away
-- while its shapes stay recognisable. History (maintainer): ~20px (8x,
-- radius 2, three passes) left "nothing of the background"; ~2px (2x,
-- radius 1) read well once dithered, and a "slightly larger blur" was asked
-- for. FACTOR stays even: an odd one leaves 1px stripes unevenly averaged.
M.FACTOR = 2
M.RADIUS = 2
M.PASSES = 2

-- margin(f, r, p) -> px of picture beyond the panel's edge the blur reads,
-- so the panel's edges blend with what lies outside rather than smearing
-- their own last row.
function M.margin(f, r, p)
    f, r, p = f or M.FACTOR, r or M.RADIUS, p or M.PASSES
    return f * r * p
end

-- region(x, y, w, h, margin, sw, sh) -> rx, ry, rw, rh: the panel's rect
-- grown by margin and clipped to the picture (sw x sh).
function M.region(x, y, w, h, margin, sw, sh)
    local rx = math.max(0, x - margin)
    local ry = math.max(0, y - margin)
    local rx1 = math.min(sw, x + w + margin)
    local ry1 = math.min(sh, y + h + margin)
    return rx, ry, math.max(0, rx1 - rx), math.max(0, ry1 - ry)
end

-- key(bg_key, x, y, w, h) -> the cache key: what is behind the panel.
-- bg_key already names the picture, the screen size and the night
-- pre-inversion (Wallpaper.bg's key), so those need no field of their own.
function M.key(bg_key, x, y, w, h)
    if not bg_key then return nil end
    return table.concat({ bg_key, x, y, w, h,
                          M.FACTOR, M.RADIUS, M.PASSES }, "|")
end

-- downsample(src, stride, bpp, nch, w, h, f, out) -> dw, dh
-- Box average of each f x f block of a w x h image into out (nch channels
-- interleaved, 0-indexed). src is bytes: pixel (x, y) channel c is at
-- y * stride + x * bpp + c. Blocks at the right and bottom edges average
-- only the pixels they have.
function M.downsample(src, stride, bpp, nch, w, h, f, out)
    local dw, dh = math.ceil(w / f), math.ceil(h / f)
    for dy = 0, dh - 1 do
        local y0 = dy * f
        local y1 = y0 + f; if y1 > h then y1 = h end
        for dx = 0, dw - 1 do
            local x0 = dx * f
            local x1 = x0 + f; if x1 > w then x1 = w end
            local n = (y1 - y0) * (x1 - x0)
            local o = (dy * dw + dx) * nch
            for c = 0, nch - 1 do
                local s = 0
                for y = y0, y1 - 1 do
                    local p = y * stride + x0 * bpp + c
                    for _x = x0, x1 - 1 do
                        s = s + src[p]
                        p = p + bpp
                    end
                end
                out[o + c] = s / n
            end
        end
    end
    return dw, dh
end

-- boxBlur(buf, w, h, nch, r, passes, tmp) -> buf, blurred in place.
-- Separable running-sum box of radius r, horizontal then vertical, passes
-- times; the edges clamp (the edge value repeats). tmp must hold w*h*nch.
function M.boxBlur(buf, w, h, nch, r, passes, tmp)
    if r <= 0 or passes <= 0 or w <= 0 or h <= 0 then return buf end
    local win = 2 * r + 1
    local wl, hl = w - 1, h - 1
    for _p = 1, passes do
        -- rows: buf -> tmp
        for y = 0, hl do
            local base = y * w
            for c = 0, nch - 1 do
                local s = 0
                for k = -r, r do
                    local xx = k; if xx < 0 then xx = 0 elseif xx > wl then xx = wl end
                    s = s + buf[(base + xx) * nch + c]
                end
                for x = 0, wl do
                    tmp[(base + x) * nch + c] = s / win
                    local xo = x - r; if xo < 0 then xo = 0 end
                    local xi = x + r + 1; if xi > wl then xi = wl end
                    s = s + buf[(base + xi) * nch + c] - buf[(base + xo) * nch + c]
                end
            end
        end
        -- columns: tmp -> buf
        for x = 0, wl do
            for c = 0, nch - 1 do
                local s = 0
                for k = -r, r do
                    local yy = k; if yy < 0 then yy = 0 elseif yy > hl then yy = hl end
                    s = s + tmp[(yy * w + x) * nch + c]
                end
                for y = 0, hl do
                    buf[(y * w + x) * nch + c] = s / win
                    local yo = y - r; if yo < 0 then yo = 0 end
                    local yi = y + r + 1; if yi > hl then yi = hl end
                    s = s + tmp[(yi * w + x) * nch + c] - tmp[(yo * w + x) * nch + c]
                end
            end
        end
    end
    return buf
end

-- upscale(small, sw, sh, nch, f, ox, oy, dst, dstride, bpp, w, h, alpha, rows)
-- Bilinear stretch of the small grid back to a w x h rect into dst (bytes,
-- dstride per row, bpp per pixel). (ox, oy) is where the rect starts inside
-- the region the grid was taken from: output pixel (x, y) samples the grid at
-- the centre of region pixel (x + ox, y + oy). alpha, when given, is written
-- to byte nch of every pixel (an RGB32 target's alpha). rows is scratch of
-- sh * w * nch: each grid row stretched across once, so the per-pixel work is
-- one vertical blend per channel.
function M.upscale(small, sw, sh, nch, f, ox, oy, dst, dstride, bpp, w, h, alpha, rows, cols)
    -- Horizontal pass: every grid row across the output width.
    cols = cols or {}
    for x = 0, w - 1 do
        local u = (x + ox + 0.5) / f - 0.5
        if u < 0 then u = 0 elseif u > sw - 1 then u = sw - 1 end
        local i0 = math.floor(u)
        local i1 = i0 + 1; if i1 > sw - 1 then i1 = sw - 1 end
        cols[x * 3], cols[x * 3 + 1], cols[x * 3 + 2] = i0, i1, u - i0
    end
    for j = 0, sh - 1 do
        local gbase = j * sw
        local rbase = j * w
        for x = 0, w - 1 do
            local i0, i1, t = cols[x * 3], cols[x * 3 + 1], cols[x * 3 + 2]
            local a0, a1 = (gbase + i0) * nch, (gbase + i1) * nch
            local o = (rbase + x) * nch
            for c = 0, nch - 1 do
                local a = small[a0 + c]
                rows[o + c] = a + (small[a1 + c] - a) * t
            end
        end
    end
    -- Vertical pass, straight into the target bytes.
    for y = 0, h - 1 do
        local v = (y + oy + 0.5) / f - 0.5
        if v < 0 then v = 0 elseif v > sh - 1 then v = sh - 1 end
        local j0 = math.floor(v)
        local j1 = j0 + 1; if j1 > sh - 1 then j1 = sh - 1 end
        local t = v - j0
        local r0, r1 = j0 * w * nch, j1 * w * nch
        local p = y * dstride
        for x = 0, w - 1 do
            local o = x * nch
            for c = 0, nch - 1 do
                local a = rows[r0 + o + c]
                local val = math.floor(a + (rows[r1 + o + c] - a) * t + 0.5)
                if val < 0 then val = 0 elseif val > 255 then val = 255 end
                dst[p + c] = val
            end
            if alpha then dst[p + nch] = alpha end
            p = p + bpp
        end
    end
end

-- ── Onto the panel's own greys (greyscale e-ink) ───────────────────────
--
-- A blur is a smooth field of in-between greys, and a 16-grey e-ink panel
-- has none of them: a PW5 shows grey v as level v >> 4, so a gentle ramp
-- comes out as two or three flat greys with hard edges between them, a
-- pattern rather than a blur (maintainer, photo of the PW5). Dithered onto
-- exact levels first, each pixel shows exactly as painted and the ramp
-- survives as a fine stipple whose average is the tone the blur asked for.
--
-- KOReader's own ordered 8x8 dither (base ffi/blitbuffer.lua dither_o8x8,
-- itself ImageMagick's o8x8 at 16 levels), the same threshold map and the
-- same integer arithmetic, so the result is byte for byte what its
-- ditherblitFrom would give. Ported rather than called so it runs on the
-- same byte arrays as the rest of this file and the tests can check what
-- the device runs; it costs one table read per pixel, once per build.
M.O8X8 = { [0] = 1, 49, 13, 61, 4, 52, 16, 64, 33, 17, 45, 29, 36, 20, 48, 32,
                 9, 57, 5, 53, 12, 60, 8, 56, 41, 25, 37, 21, 44, 28, 40, 24,
                 3, 51, 15, 63, 2, 50, 14, 62, 35, 19, 47, 31, 34, 18, 46, 30,
                 11, 59, 7, 55, 10, 58, 6, 54, 43, 27, 39, 23, 42, 26, 38, 22 }

-- ditherLevel(x, y, v) -> n, 0..15: the level grey v lands on at pixel
-- (x, y). The byte written is n * 17, and (n * 17) >> 4 == n, so the panel
-- shows exactly level n: no band edge for it to fall across.
function M.ditherLevel(x, y, v)
    -- div255(v * (15 * 64 + 1)), as KOReader does it
    local u = v * 961 + 128
    local t = math.floor((u + math.floor(u / 256)) / 256)
    local l = math.floor(t / 64)
    t = t - l * 64
    if t >= M.O8X8[(x % 8) + 8 * (y % 8)] then l = l + 1 end
    if l > 15 then l = 15 end
    return l
end

-- One table, built on first use: the byte for every (phase, v), 1-based
-- (phase * 256 + v + 1) so it is all array part.
local _lut = nil
local function ditherLut()
    if _lut then return _lut end
    local lut = {}
    for phase = 0, 63 do
        local px, py = phase % 8, math.floor(phase / 8)
        for v = 0, 255 do
            lut[phase * 256 + v + 1] = M.ditherLevel(px, py, v) * 17
        end
    end
    _lut = lut
    return lut
end

-- dither(buf, stride, w, h, x0, y0) -> buf, every byte of a w x h grey image
-- (one byte per pixel, stride per row) put on its level, in place. (x0, y0)
-- is where the image sits on the screen, so the pattern is anchored to the
-- screen and every patch cut from it lines up with the panel around it.
function M.dither(buf, stride, w, h, x0, y0)
    local lut = ditherLut()
    x0, y0 = x0 or 0, y0 or 0
    for y = 0, h - 1 do
        local row = ((y0 + y) % 8) * 8
        local p = y * stride
        for x = 0, w - 1 do
            local base = (row + (x0 + x) % 8) * 256 + 1
            buf[p + x] = lut[base + buf[p + x]]
        end
    end
    return buf
end

-- blur(src, sstride, bpp, nch, rw, rh, ox, oy, w, h, dst, dstride, alpha, alloc)
-- The whole pipeline: a rw x rh region of src down, blurred, and back up
-- into the w x h rect that starts (ox, oy) inside it. alloc(n) returns a
-- zeroed 0-indexed array of n numbers (an ffi double array on the device).
function M.blur(src, sstride, bpp, nch, rw, rh, ox, oy, w, h, dst, dstride, alpha, alloc)
    local f = M.FACTOR
    local dw, dh = math.ceil(rw / f), math.ceil(rh / f)
    local small = alloc(dw * dh * nch)
    M.downsample(src, sstride, bpp, nch, rw, rh, f, small)
    M.boxBlur(small, dw, dh, nch, M.RADIUS, M.PASSES, alloc(dw * dh * nch))
    M.upscale(small, dw, dh, nch, f, ox, oy, dst, dstride, bpp, w, h, alpha,
              alloc(dh * w * nch), alloc(w * 3))
    return dw, dh
end

return M
