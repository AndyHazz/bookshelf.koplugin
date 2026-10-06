-- lib/bookshelf_frost.lua
-- The blur behind a panel (Panel shading > Blur the picture behind panels):
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
-- about a 2-3px Gaussian (sigma ~2.3px, a fifth of a millimetre at 300 dpi):
-- a soft frost that takes the edge off a print's fine lines while its shapes
-- stay recognisable. The first version (8x, radius 2, three passes, ~20px)
-- left "nothing of the background" at Low shading (maintainer).
M.FACTOR = 2
M.RADIUS = 1
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
