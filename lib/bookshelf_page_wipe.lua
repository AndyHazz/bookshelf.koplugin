--[[--
Software page-turn "wipe" animation for shelf pagination.

Reveals an incoming page over the outgoing one strip-by-strip within a region,
issuing a grayscale ("ui") refresh per strip so it plays out as visible motion.

THE SCREEN ITSELF HOLDS THE OUTGOING PAGE. Only the incoming one is passed in,
in the screen's own coordinate space, and each frame blits the next strip of it
over what is already there. There is no copy of the outgoing page at all.

This used to copy BOTH pages out of the framebuffer first, because the caller
painted the new page into the screen and so destroyed the old one. Those copies
were pure loss: framebuffer reads run at ~30MB/s uncached, and they landed
squarely in the gap between the gesture and the first pixel moving. Painting
the new page into an offscreen buffer instead leaves the outgoing one intact on
screen, and is FASTER than painting into the framebuffer besides. Measured on a
PW5: 101ms paint + two 41ms copies = 183ms, against 79ms for the offscreen
paint alone. The offscreen frame was verified byte-identical to the
framebuffer one.

E-INK ONLY. The effect exists because each `refreshUI` triggers a slow,
individually visible EPDC panel update; the `yieldToEPDC` between strips
paces them. On an LCD/OLED those refreshes complete in microseconds and get
coalesced into a single frame, so nothing is seen. Callers MUST gate on
`Device:hasEinkScreen()` and skip this entirely otherwise (it would be pure
wasted work).
]]--

local UIManager = require("ui/uimanager")
local Device = require("device")
local BookshelfSettings = require("lib/bookshelf_settings_store")

local PageWipe = {}

-- Mode -> step count. More steps = smoother but slower (each step is a
-- physical e-ink refresh). "off" is handled by the caller (no call).
PageWipe.STEPS = { fast = 5, medium = 8, slow = 12 }

-- How long to pace between strip refreshes. Measured on a PW5 (1236x882
-- region, 8 steps), sweeping this value and timing the parts separately:
--
--   yield   blit   refresh   yield   total
--    20ms   11ms      41ms   142ms   201ms
--    10ms   18ms      44ms    72ms   138ms
--     5ms   17ms      66ms    38ms   132ms
--     1ms   15ms      96ms    12ms   134ms
--     0ms   10ms     110ms     1ms   137ms
--
-- refreshUI BLOCKS while the EPDC is still busy, so the wait is paid either
-- way: shrink the yield and refresh grows to match. What matters is
-- yield+refresh, which bottoms out at ~102ms for 5ms and below, is 120ms at
-- 10ms, and 186ms at 20ms. So 20ms over-slept by ~80ms per page turn beyond
-- anything the panel asked for, while going below 5ms buys nothing.
--
-- Kaleido caveat: colour panels drain a full refresh far more slowly (#247,
-- which is why the first wipe after one is skipped on colour). That path is
-- unchanged, but this value has only been measured on greyscale.
local EPDC_YIELD_US = 5000

-- Per-surface animation settings (#259) and their defaults. The start menu
-- reveals a taller region than a page wipe, so it defaults one notch
-- snappier. The settings menu rows read the same defaults.
PageWipe.DEFAULTS = {
    shelf_page_animation = "fast",    -- shelf page turns + chip-bar paging
    start_menu_animation = "fast",    -- start menu open/close reveal
}

-- Resolve an animation preference to a step count, or nil when animation
-- should not run (not an e-ink screen, or the setting is "off"). pref_key
-- picks the surface; nil means the base shelf/chip-bar setting. On LCD the
-- per-strip refreshes coalesce so nothing shows -- hence the e-ink gate.
function PageWipe.resolveSteps(pref_key)
    if not (Device.hasEinkScreen and Device:hasEinkScreen()) then return nil end
    local key  = pref_key or "shelf_page_animation"
    local mode = BookshelfSettings.read(key) or PageWipe.DEFAULTS[key] or "medium"
    return PageWipe.STEPS[mode]  -- nil for "off" / unknown
end

-- Run the wipe.
--   screen   Device.screen (has .bb, :refreshUI)
--   new_bb   the incoming page, in the SCREEN's coordinate space -- paint the
--            widget into it at its normal position, so a source coordinate is
--            the destination coordinate. Only `region` is ever read from it.
--   region   {x, y, w, h} rectangle to animate; the rest of the screen is
--            left untouched (hero/chips above don't change on pagination).
--   forward  true  = new page reveals from the RIGHT edge (next page)
--            false = new page reveals from the LEFT edge (previous page)
--   steps    number of frames
--
-- REQUIRED: screen.bb must still hold the OUTGOING page across `region`, which
-- is its natural state -- just do not paint the new page into it first.
--
-- Intermediate frames refresh only the newly revealed strip; the final frame
-- refreshes the whole region once (same grayscale mode, so there's no
-- mode-switch flash as the animation lands).
function PageWipe.run(screen, new_bb, region, forward, steps)
    local rx, ry, rw, rh = region.x, region.y, region.w, region.h
    local prev_dx = 0
    for i = 1, steps do
        local dx = math.floor(rw * i / steps)
        local strip_w = dx - prev_dx
        if strip_w > 0 then
            -- The strip revealed by THIS frame: the incoming page grows in
            -- from the right going forward, from the left going back. Source
            -- and destination coincide, so it lands exactly where a normal
            -- paint would have put it.
            local sx = forward and (rx + rw - dx) or (rx + prev_dx)
            screen.bb:blitFrom(new_bb, sx, ry, sx, ry, strip_w, rh)
            if i < steps then
                screen:refreshUI(sx, ry, strip_w, rh)
                UIManager:yieldToEPDC(EPDC_YIELD_US)
            end
        end
        if i == steps then
            -- Land the whole region in one refresh, even when the last strip
            -- rounds to zero width.
            screen:refreshUI(rx, ry, rw, rh)
        end
        prev_dx = dx
    end
end


return PageWipe
