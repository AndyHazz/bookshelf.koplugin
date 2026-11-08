-- lib/bookshelf_scale.lua
-- Scale.cover(src, w, h) -> a new w x h copy of a cover; src is untouched.
--
-- Two scalers, each cheaper for a different job. Blitbuffer:scale is a
-- per-pixel Lua loop: its cost follows the OUTPUT (on a PW5 ~0.4 us a pixel,
-- 40 ms for a 259x390 shelf cover). MuPDF's follows the SOURCE (10-14 ms for
-- a 597x901 cover, whatever the target). So MuPDF for a downscale to more
-- than a twentieth of the source, the Lua loop for a small thumbnail -- and
-- for every upscale, the direction MuPDF is documented to corrupt on Kindle.
local M = {}

-- MuPDF once the output is more than 1/RATIO of the source (the measured
-- crossover: a 597x901 cover breaks even near a 130x195 target).
local RATIO = 20

local Mupdf -- nil = not tried, false = unavailable

function M.cover(src, w, h)
    w, h = math.floor(w), math.floor(h)
    local sw, sh = src:getWidth(), src:getHeight()
    if w <= sw and h <= sh and w * h * RATIO > sw * sh then
        if Mupdf == nil then
            local ok, m = pcall(require, "ffi/mupdf")
            Mupdf = ok and m or false
        end
        if Mupdf then
            local ok, out = pcall(Mupdf.scaleBlitBuffer, src, w, h)
            if ok and out then return out end
        end
    end
    return src:scale(w, h)
end

return M
