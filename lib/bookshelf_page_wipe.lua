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
local logger
do -- pcall'd: standalone test suites dofile this module without KOReader paths
    local ok, l = pcall(require, "logger")
    logger = ok and l or { info = function() end, dbg = function() end }
end

-- perf-logging branch: per-step wall clock for issue #247 (first wipe after
-- a reader exit / page turn takes seconds on Kobo Clara Colour - theory:
-- the first refreshUI blocks on the EPDC marker of the preceding full
-- refresh). Shares the socket clock with the other perf lines.
local _gettime
do
    local ok, s = pcall(require, "socket")
    _gettime = (ok and s and type(s.gettime) == "function")
        and function() return s.gettime() end
        or  os.clock
end

local PageWipe = {}

-- Mode -> step count. More steps = smoother but slower (each step is a
-- physical e-ink refresh). "off" is handled by the caller (no call).
PageWipe.STEPS = { fast = 5, medium = 8, slow = 12 }

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
function PageWipe.run(screen, old_bb, new_bb, region, forward, steps)
    local rx, ry, rw, rh = region.x, region.y, region.w, region.h
    local prev_dx = 0
    local _t_run0 = _gettime()
    local _step_ms = {}
    local _t_step = _t_run0
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
        local now = _gettime()
        _step_ms[#_step_ms + 1] = string.format("%.0f", (now - _t_step) * 1000)
        _t_step = now
    end
    -- One line per wipe: if the #247 theory holds, the FIRST step will be
    -- hundreds/thousands of ms (blocked on the previous refresh's marker)
    -- and the rest uniform.
    logger.info(string.format(
        "[bookshelf perf] wipe: steps=%d region=%dx%d TOTAL=%.0fms per-step=[%s]",
        steps, rw, rh, (_gettime() - _t_run0) * 1000,
        table.concat(_step_ms, ",")))
end

return PageWipe
