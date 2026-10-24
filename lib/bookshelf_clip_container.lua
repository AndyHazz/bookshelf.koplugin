--[[
A fixed-size container that centres its single child and bounds it to the
container's w×h. Used so the parent (hero grid) can guarantee a micro-module's
render output is painted within its cell — enforced here, not trusted to the
(often third-party) modules.

Sizing: getSize() always reports the fixed { w, h } (so the cell tiles
predictably regardless of the child's natural size).

Painting: the child is rendered into a REAL offscreen blitbuffer of exactly
w×h, then blitted onto the screen at this container's position. Two reasons to
go via an offscreen buffer rather than `bb:viewport`:

  1. Correctness. A viewport shares the parent's stride/pixel_stride but reports
     a narrower w. A child that does a raw full-width `paintRect(0, .., w, ..)`
     (e.g. reading_goal's progress bar, painted at exactly the cell width) then
     hits blitbuffer's "x == 0 and w == self.w" contiguous-scanline fast path,
     which fills `pixel_stride * h` pixels — the PARENT's width, not the
     viewport's — smearing a full-screen-width band. A real buffer has
     pixel_stride == w, so the fast path is correct. (Standard widgets blit
     rather than paintRect, so they never tripped this; only a raw-paint child
     did.)
  2. Containment. Anything the child draws past w×h lands outside the offscreen
     buffer and is discarded, so the parent's "a module can't overflow its
     cell" guarantee holds for any draw primitive, not just blits.

Placement: a child that fits is centred; a child taller/wider than the cell is
top-/left-aligned (offset clamped to >= 0) so its START is visible and the
overflow is clipped off the bottom/right.

Gestures: the child is painted into the offscreen buffer at buffer-local
coords, so its own tappable widgets know their places relative to this
container, not the screen. With pass_gestures, a gesture inside the container
reaches the child moved into that frame, so a module's own buttons work in a
card as they do in a bare module (painted in place). Taps and double taps
only: long-press and swipes stay the host's. Without it the child gets
no gestures at all (a picker preview: the tap picks the module), rather than
screen positions it would compare against the wrong frame.
]]
local Blitbuffer       = require("ffi/blitbuffer")
local Geom             = require("ui/geometry")
local WidgetContainer  = require("ui/widget/container/widgetcontainer")

local ClipContainer = WidgetContainer:extend{
    w = nil,
    h = nil,
    -- Fill colour for the offscreen buffer, so the centred child's surrounding
    -- margin matches the card it sits on (the parent paints the same colour
    -- behind this container). Defaults to white.
    bg = nil,
    -- Pass gestures to the child, in its painted frame (see the header).
    pass_gestures = nil,
}

function ClipContainer:handleEvent(event)
    if event and event.handler == "onGesture" then
        local ges = event.args and event.args[1]
        local d = self.dimen
        if not (self.pass_gestures and ges and ges.pos and d and d.x and self[1]) then return false end
        -- Taps only: long-press is the grid's (the layout editor) and swipes
        -- turn its pages, whatever a module's widget would make of them.
        if ges.ges ~= "tap" and ges.ges ~= "double_tap" then return false end
        local px, py = ges.pos.x - d.x, ges.pos.y - d.y
        if px < 0 or py < 0 or px >= self.w or py >= self.h then return false end
        local g = {}
        for k, v in pairs(ges) do g[k] = v end
        g.pos = Geom:new{ x = px, y = py, w = 0, h = 0 }
        local moved = {}
        for k, v in pairs(event) do moved[k] = v end
        moved.args = { g }
        return self[1]:handleEvent(moved) and true or false
    end
    return WidgetContainer.handleEvent(self, event)
end

function ClipContainer:getSize()
    return Geom:new{ w = self.w, h = self.h }
end

-- Offscreen scratch buffers, reused across paints. Paint is single-threaded
-- and the buffer's contents never outlive one paintTo (filled, painted into,
-- blitted out), so sharing per size+type is safe. Without this every repaint
-- of every cell allocated and freed a fresh buffer - the minute clock tick
-- repainting a micro grid churned one allocation per cell per minute. Keyed
-- by w:h:type because a grid mixes a few cell sizes (wide/normal); the set is
-- tiny, but cap it and start over if a pathological layout ever grows it.
local _scratch, _scratch_n = {}, 0
local function scratchFor(w, h, bbtype)
    local key = w .. ":" .. h .. ":" .. tostring(bbtype)
    local off = _scratch[key]
    if off then return off end
    if _scratch_n >= 8 then
        for k, b in pairs(_scratch) do
            if b.free then pcall(b.free, b) end
            _scratch[k] = nil
        end
        _scratch_n = 0
    end
    off = Blitbuffer.new(w, h, bbtype)
    _scratch[key] = off
    _scratch_n = _scratch_n + 1
    return off
end

function ClipContainer:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.w, h = self.h }
    local child = self[1]
    if not child then return end
    local cs = child:getSize()
    local cw = (cs and cs.w) or 0
    local ch = (cs and cs.h) or 0
    local dx = math.max(0, math.floor((self.w - cw) / 2))
    local dy = math.max(0, math.floor((self.h - ch) / 2))
    -- Recorded so a host can translate a screen tap into CHILD-local
    -- coordinates (self.dimen + these offsets = the child's painted origin).
    -- This is what makes the module tap-region contract possible despite the
    -- offscreen paint: the host, not the module, owns the geometry.
    self._child_dx, self._child_dy = dx, dy
    -- Render into a real w×h buffer (pixel_stride == w), so any raw paint the
    -- child does is bounded to the cell and the full-width-paintRect fast path
    -- stays correct. Then blit the result onto the screen at this position.
    local off = scratchFor(self.w, self.h, bb:getType())
    -- fill() collapses a colour to its grey (getColor8), so a coloured card
    -- on a colour screen goes through paintRectRGB32, which keeps it.
    -- Asked of Blitbuffer, never by probing `bg.r`: a grey is a Color8
    -- cdata, which RAISES on a field it lacks -- that crashed the start menu
    -- on a greyscale PW5.
    local bg = self.bg or Blitbuffer.COLOR_WHITE
    if off:getType() == Blitbuffer.TYPE_BBRGB32 and off.paintRectRGB32
            and Blitbuffer.isColor8 and not Blitbuffer.isColor8(bg) then
        off:paintRectRGB32(0, 0, self.w, self.h, bg:getColorRGB32())
    else
        off:fill(bg)
    end
    child:paintTo(off, dx, dy)
    bb:blitFrom(off, x, y, 0, 0, self.w, self.h)
end

return ClipContainer
