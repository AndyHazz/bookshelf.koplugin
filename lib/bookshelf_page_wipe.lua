--[[--
Software page-turn "wipe" animation for shelf pagination.

Composites two full-screen BlitBuffers (the outgoing page and the incoming
page) strip-by-strip within a region, issuing a grayscale ("ui") refresh per
strip so the reveal plays out as visible motion.

E-INK ONLY. The effect exists because each `refreshUI` triggers a slow,
individually visible EPDC panel update; the `yieldToEPDC` between strips
paces them. On an LCD/OLED those refreshes complete in microseconds and get
coalesced into a single frame, so nothing is seen. Callers MUST gate on
`Device:hasEinkScreen()` and skip this entirely otherwise (it would be pure
wasted work).
]]--

local UIManager = require("ui/uimanager")

local PageWipe = {}

-- Mode -> step count. More steps = smoother but slower (each step is a
-- physical e-ink refresh). "off" is handled by the caller (no call).
PageWipe.STEPS = { fast = 5, medium = 8, slow = 12 }

-- Run the wipe.
--   screen   Device.screen (has .bb, :refreshUI)
--   old_bb   full-screen copy of the outgoing page
--   new_bb   full-screen copy of the incoming page (already painted to screen.bb)
--   region   {x, y, w, h} rectangle to animate; the rest of the screen is
--            left untouched (hero/chips above don't change on pagination)
--   forward  true  = new page reveals from the RIGHT edge (next page)
--            false = new page reveals from the LEFT edge (previous page)
--   steps    number of frames
--
-- Intermediate frames refresh only the newly revealed strip; the final frame
-- refreshes the whole region once (same grayscale mode, so there's no
-- mode-switch flash as the animation lands).
function PageWipe.run(screen, old_bb, new_bb, region, forward, steps)
    local rx, ry, rw, rh = region.x, region.y, region.w, region.h
    local prev_dx = 0
    for i = 1, steps do
        local dx = math.floor(rw * i / steps)
        local strip_w = dx - prev_dx
        if forward then
            -- old page on the left shrinking, new page growing from the right
            screen.bb:blitFrom(old_bb, rx, ry, rx, ry, rw - dx, rh)
            screen.bb:blitFrom(new_bb, rx + rw - dx, ry, rx + rw - dx, ry, dx, rh)
            if i < steps then
                if strip_w > 0 then
                    screen:refreshUI(rx + rw - dx, ry, strip_w, rh)
                    UIManager:yieldToEPDC(20000)
                end
            else
                screen:refreshUI(rx, ry, rw, rh)
            end
        else
            -- new page growing from the left, old page shrinking to the right
            screen.bb:blitFrom(new_bb, rx, ry, rx, ry, dx, rh)
            screen.bb:blitFrom(old_bb, rx + dx, ry, rx + dx, ry, rw - dx, rh)
            if i < steps then
                if strip_w > 0 then
                    screen:refreshUI(rx + prev_dx, ry, strip_w, rh)
                    UIManager:yieldToEPDC(20000)
                end
            else
                screen:refreshUI(rx, ry, rw, rh)
            end
        end
        prev_dx = dx
    end
end

return PageWipe
