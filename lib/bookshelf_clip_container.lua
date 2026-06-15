--[[
A fixed-size container that centres its single child and CLIPS it to the
container's bounds. Used so the parent (hero grid / start menu) can guarantee a
micro-module's render output never paints outside its cell — enforced here, not
trusted to the (often third-party) modules.

Sizing: getSize() always reports the fixed { w, h } (so the cell tiles
predictably regardless of the child's natural size). paintTo() paints the child
into a blitbuffer viewport bounded to w×h, so anything the child draws past the
edge is simply outside the viewport and discarded — the same crop mechanism
ScrollableContainer uses.

Placement: a child that fits is centred; a child taller/wider than the cell is
top-/left-aligned (offset clamped to >= 0) so its START is visible and the
overflow is clipped off the bottom/right, rather than centring and losing both
ends.

Gesture note: the child is painted into the viewport at viewport-local coords,
so a child with its OWN tappable sub-widgets would get the wrong gesture rects.
Micro-modules are display-only internally (their tap is handled at the cell
level by the parent's InputContainer), so this is fine for that use.
]]
local Geom            = require("ui/geometry")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local ClipContainer = WidgetContainer:extend{
    w = nil,
    h = nil,
}

function ClipContainer:getSize()
    return Geom:new{ w = self.w, h = self.h }
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
    -- Paint the child into a viewport clamped to this container; the viewport
    -- is only w×h, so anything beyond it is clipped.
    local vp = bb:viewport(x, y, self.w, self.h)
    child:paintTo(vp, dx, dy)
end

return ClipContainer
