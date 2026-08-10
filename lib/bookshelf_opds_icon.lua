-- lib/bookshelf_opds_icon.lua
-- Decode + scale + cache the tiny inline icons OPDS nav entries carry
-- (Gutenberg attaches little data: URI category glyphs - hearts, stars). The
-- placeholder card renders one where a book placeholder shows its diamond.
-- Cached blitbuffers are CACHE-OWNED and never freed by consumers: hand them
-- to ImageWidget with image_disposable = false only.

local M = {}

-- data:<mime>;base64,<payload> becomes decoded bytes, or nil for anything else.
function M.parse(data_uri)
    if type(data_uri) ~= "string" then return nil end
    local spec, payload = data_uri:match("^data:([^,]*),(.*)$")
    if not spec or not spec:find("base64", 1, true) then return nil end
    local ok, CoverFetch = pcall(require, "lib/bookshelf_cover_fetch")
    if not ok or type(CoverFetch._base64decode) ~= "function" then return nil end
    local ok2, bytes = pcall(CoverFetch._base64decode, payload)
    if not ok2 or type(bytes) ~= "string" or bytes == "" then return nil end
    return bytes
end

-- Integer upscale factor so a 16px feed icon stays legible on a 300dpi
-- panel without smearing: round(target/native), clamped to 1..3. Never
-- downscales (a large icon is left alone; the layout centres it).
function M.scaleFactor(native_h, target_h)
    if type(native_h) ~= "number" or native_h <= 0
            or type(target_h) ~= "number" or target_h <= 0 then
        return 1
    end
    local s = math.floor(target_h / native_h + 0.5)
    if s < 1 then s = 1 elseif s > 3 then s = 3 end
    return s
end

-- Destination-buffer constructor. A seam so the nearest-neighbour copy is
-- unit-testable without ffi; at runtime it is KOReader's Blitbuffer.new.
function M._new_bb(w, h, bbtype)
    local Blitbuffer = require("ffi/blitbuffer")
    return Blitbuffer.new(w, h, bbtype)
end

-- Nearest-neighbour integer upscale into a fresh buffer of the same type.
-- Preserves whatever each pixel carries (including alpha) because pixels are
-- copied verbatim, never resampled. s == 1 hands back the input unchanged.
function M.scaledCopy(bb, s)
    if not bb or type(s) ~= "number" or s <= 1 then return bb end
    local w, h = bb:getWidth(), bb:getHeight()
    local out = M._new_bb(w * s, h * s, bb:getType())
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            local px = bb:getPixel(x, y)
            local by, bx = y * s, x * s
            for dy = 0, s - 1 do
                for dx = 0, s - 1 do
                    out:setPixel(bx + dx, by + dy, px)
                end
            end
        end
    end
    return out
end

-- Memoised decode: data uri > RenderImage > integer upscale. Keyed by
-- uri .. "@" .. target height, so a hit skips the base64 decode AND the
-- render (icons repeat heavily within a catalogue page) and a size change
-- re-renders. FIFO cap keeps a pathological feed from accumulating buffers;
-- 32 icons is several catalogue screens.
local cache, cache_order = {}, {}
local CACHE_CAP = 32

function M.iconFor(data_uri, target_h)
    if type(data_uri) ~= "string" then return nil end
    local key = data_uri .. "@" .. tostring(target_h or 0)
    if cache[key] then return cache[key] end
    local bytes = M.parse(data_uri)
    if not bytes then return nil end
    local ok_r, RenderImage = pcall(require, "ui/renderimage")
    if not ok_r or not RenderImage then return nil end
    local ok_b, bb = pcall(RenderImage.renderImageData, RenderImage, bytes, #bytes)
    if not ok_b or not bb then return nil end
    local s = M.scaleFactor(bb:getHeight(), target_h or 0)
    local ok_s, scaled = pcall(M.scaledCopy, bb, s)
    if not ok_s or not scaled then
        -- Working buffer never left this function, so an explicit free is
        -- safe (the FFI GC finaliser would reclaim it eventually, but why wait).
        if bb.free then pcall(bb.free, bb) end
        return nil
    end
    if scaled ~= bb and bb.free then pcall(bb.free, bb) end
    cache[key] = scaled
    cache_order[#cache_order + 1] = key
    if #cache_order > CACHE_CAP then
        local evict = table.remove(cache_order, 1)
        cache[evict] = nil
        -- Deliberately NOT freed: with 33+ distinct icons on one page the
        -- evictee can still be held by an ImageWidget on screen
        -- (image_disposable = false), and freeing under it would paint from
        -- freed memory. These buffers carry an ffi.gc finaliser (Blitbuffer
        -- setAllocated), so dropping the last Lua reference reclaims them
        -- once no widget holds them.
    end
    return scaled
end

return M
