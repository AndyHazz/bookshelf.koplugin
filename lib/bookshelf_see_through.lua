-- lib/bookshelf_see_through.lua
-- A faded book is see-through: what was behind it is copied before it paints
-- and mixed back over it afterwards.
--
-- The fade used to be a white wash over the cover. On a white page that is
-- the same picture; over a wallpaper, a plank or a dark theme it is a pale
-- tint, not a book you can see the shelf through. Mixing in the pixels that
-- were actually there is right on any ground, and in night mode too (a mix
-- of two pictures inverts to the mix of the two inverted).
--
--   local keep = See.take(bb, x, y, w, h)   -- before the book paints
--   ... paint the book ...
--   See.put(keep, bb, 0.6)                  -- 0.6 of what was behind
--
-- One buffer the book's size in the target's own type and two blits a faded
-- book; nothing for a book that is not faded. Every step is guarded: a
-- target that cannot be read just leaves the book solid.

local M = {}

-- take(bb, x, y, w, h) -> keep | nil. The rect is cut to the target.
function M.take(bb, x, y, w, h)
    if not (type(bb) == "table" or type(bb) == "userdata" or type(bb) == "cdata") then return nil end
    if not (x and y and w and h) then return nil end
    local keep
    local ok = pcall(function()
        if not (bb.blitFrom and bb.getType and bb.getWidth) then return end
        local x0, y0 = math.max(0, x), math.max(0, y)
        local x1 = math.min(bb:getWidth(), x + w)
        local y1 = math.min(bb:getHeight(), y + h)
        local cw, ch = x1 - x0, y1 - y0
        if cw <= 0 or ch <= 0 then return end
        local Blitbuffer = require("ffi/blitbuffer")
        local copy = Blitbuffer.new(cw, ch, bb:getType())
        copy:blitFrom(require("lib/bookshelf_clip_bb").real(bb), 0, 0, x0, y0, cw, ch)
        keep = { bb = copy, x = x0, y = y0, w = cw, h = ch }
    end)
    if not ok then
        if keep and keep.bb and keep.bb.free then pcall(keep.bb.free, keep.bb) end
        return nil
    end
    return keep
end

-- put(keep, bb, strength) -> true when the copy was mixed back. strength is
-- how much of what was behind shows (0..1). The keep is spent either way.
function M.put(keep, bb, strength)
    if not keep then return false end
    local done = false
    if strength and strength > 0 then
        done = pcall(function()
            bb:addblitFrom(keep.bb, keep.x, keep.y, 0, 0, keep.w, keep.h, math.min(1, strength))
        end)
    end
    if keep.bb and keep.bb.free then pcall(keep.bb.free, keep.bb) end
    keep.bb = nil
    return done and true or false
end

return M
