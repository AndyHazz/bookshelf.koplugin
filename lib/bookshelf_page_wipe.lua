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
    shelf_page_animation = "medium",  -- shelf page turns + chip-bar paging
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
--
-- REQUIRED: screen.bb must already hold the INCOMING page across `region`
-- when this is called. Both callers get that for free by painting the new
-- content into screen.bb and copying it into new_bb, in that order. The
-- composite is built incrementally off that starting state -- frame 1 lays
-- old_bb back over the not-yet-revealed part, later frames only advance the
-- boundary by one strip -- which is what keeps the blit volume at ~2 region
-- fills instead of one per step. Hand it a screen.bb holding something else
-- and the reveal will show stale pixels.
function PageWipe.run(screen, old_bb, new_bb, region, forward, steps)
    local rx, ry, rw, rh = region.x, region.y, region.w, region.h
    local prev_dx = 0
    for i = 1, steps do
        local dx = math.floor(rw * i / steps)
        local strip_w = dx - prev_dx
        if forward then
            -- old page on the left shrinking, new page growing from the right.
            -- screen.bb starts out holding the new page in full, so frame 1
            -- restores the old page over the not-yet-revealed left part and
            -- every later frame just advances the boundary by one strip.
            if i == 1 then
                screen.bb:blitFrom(old_bb, rx, ry, rx, ry, rw - dx, rh)
            elseif strip_w > 0 then
                screen.bb:blitFrom(new_bb, rx + rw - dx, ry,
                                   rx + rw - dx, ry, strip_w, rh)
            end
            if i < steps then
                if strip_w > 0 then
                    screen:refreshUI(rx + rw - dx, ry, strip_w, rh)
                    UIManager:yieldToEPDC(EPDC_YIELD_US)
                end
            else
                screen:refreshUI(rx, ry, rw, rh)
            end
        else
            -- new page growing from the left, old page shrinking to the right
            -- (same incremental composite as the forward branch above).
            if i == 1 then
                screen.bb:blitFrom(old_bb, rx + dx, ry, rx + dx, ry, rw - dx, rh)
            elseif strip_w > 0 then
                screen.bb:blitFrom(new_bb, rx + prev_dx, ry,
                                   rx + prev_dx, ry, strip_w, rh)
            end
            if i < steps then
                if strip_w > 0 then
                    screen:refreshUI(rx + prev_dx, ry, strip_w, rh)
                    UIManager:yieldToEPDC(EPDC_YIELD_US)
                end
            else
                screen:refreshUI(rx, ry, rw, rh)
            end
        end
        prev_dx = dx
    end
end

return PageWipe
