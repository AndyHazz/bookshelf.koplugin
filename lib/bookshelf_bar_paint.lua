-- bookshelf_bar_paint.lua
-- The progress-bar painter, copied from bookends (bookends_overlay_widget.lua)
-- so every bar style draws the same whether or not bookends is installed.
--
-- Everything between the two "copied from bookends" markers below is
-- BYTE-IDENTICAL to bookends' source, and tools/check_bar_parity.sh (run by
-- tests/run.sh) fails when either side drifts. To take a bookends change:
-- copy the region over, then run both test suites. Only the requires above
-- the first marker are bookshelf's own:
--
--   * bookends_colour        -> lib/bookshelf_color (same parseColorValue;
--                               bound to the name `Colour` the copy uses)
--   * bookends_pacman_sprite -> lib/bookshelf_pacman_sprite (a whole-file
--                               byte-identical copy, also parity-checked)
--
-- The module table keeps bookends' local name, OverlayWidget, because the
-- copied function headers name it; it is still just a table of painters:
--   OverlayWidget.paintProgressBar(bb, x, y, w, h, fraction, ticks, style,
--       orientation, reverse, colors, markers)
--   OverlayWidget.BAR_STYLES   -- every style paintProgressBar dispatches on
--   OverlayWidget.bbPaintRect  -- colour-safe paintRect

local ffi = require("ffi")
local Blitbuffer = require("ffi/blitbuffer")
local Colour = require("lib/bookshelf_color")
local Device = require("device")
local Font = require("ui/font")
local PacmanSprite = require("lib/bookshelf_pacman_sprite")
local Screen = Device.screen

-- ===== copied from bookends: bookends_overlay_widget.lua, painter state + colour-safe helpers =====
-- Per-pacman animation frame counters keyed by screen position. Each
-- distinct pacman on screen has its own counter, incremented once per
-- paintProgressBar call (so the bar animates on every repaint regardless
-- of who's driving the paint — bookends overlay, bookshelf's hero bar,
-- or any future consumer). Different pacmans first appearing in the same
-- paint get sequential starting phases via _pacman_seq, so two pacmans
-- side-by-side animate in opposite phase rather than locked together.
-- Resets on plugin reload; no persistence needed. Table growth is
-- bounded by the number of distinct screen positions ever painted —
-- negligible in practice.
local _pacman_frames = {}
local _pacman_seq = 0

local ColorRGB32_t = ffi.typeof("ColorRGB32")

-- Helper: resolve a text/symbol colour table ({grey=N} or {hex=H}) to a
-- Blitbuffer colour object on the current screen. Returns nil when v is
-- nil/false. Uses `not v` rather than `v == nil` because under LuaJIT an
-- ffi.metatype equality check routes through __eq, and Blitbuffer's __eq
-- indexes the other operand unconditionally — so `bb_color == nil` would
-- crash. `not v` never calls __eq.
local function resolveTextColor(v)
    if not v then return nil end
    return Colour.parseColorValue(v, Screen:isColorEnabled())
end

-- Blitbuffer's plain paintRect / paintRoundedRect / paintBorder always flatten
-- their colour argument to luminance via getColor8(), so painting a ColorRGB32
-- through them renders as grey on a colour buffer. KOReader exposes parallel
-- *RGB32 variants for true-colour fills; these wrappers dispatch by colour
-- type so all the call-sites in paintProgressBar can stay shape-agnostic.
-- bbPaintRect is declared as OverlayWidget.bbPaintRect (module export) below
-- and then aliased to a local for in-file call sites.

local function bbPaintRoundedRect(bb, x, y, w, h, c, r)
    if not c then return end
    if ffi.istype(ColorRGB32_t, c) then
        bb:paintRoundedRectRGB32(x, y, w, h, c, r)
    else
        bb:paintRoundedRect(x, y, w, h, c, r)
    end
end

local function bbPaintBorder(bb, x, y, w, h, bw, c, r)
    if not c then return end
    if ffi.istype(ColorRGB32_t, c) then
        bb:paintBorderRGB32(x, y, w, h, bw, c, r)
    else
        bb:paintBorder(x, y, w, h, bw, c, r)
    end
end

local OverlayWidget = {}

--- Dispatch a filled rectangle paint to the correct Blitbuffer variant.
--- Blitbuffer's plain paintRect flattens its colour to luminance via
--- getColor8(), so a ColorRGB32 painted through it renders as grey on a
--- colour buffer. KOReader's *RGB32 variants preserve true colour; this
--- wrapper dispatches by colour type so callers stay shape-agnostic.
--- Exported as OverlayWidget.bbPaintRect so main.lua can call it directly.

function OverlayWidget.bbPaintRect(bb, x, y, w, h, c)
    if not c then return end
    if ffi.istype(ColorRGB32_t, c) then
        bb:paintRectRGB32(x, y, w, h, c)
    else
        bb:paintRect(x, y, w, h, c)
    end
end
local bbPaintRect = OverlayWidget.bbPaintRect
-- ===== end copied region =====

-- ===== copied from bookends: bookends_overlay_widget.lua, BAR_STYLES + paintProgressBar =====
-- Canonical list of styles paintProgressBar dispatches on. Exported so
-- downstream consumers (bookshelf's hero bar picker, third-party themes,
-- etc.) can enumerate the available styles without grepping the
-- if/elseif chain inside paintProgressBar. Order = the order the styles
-- were introduced; readers that want a stable cycle should follow this
-- ordering. Add new entries here when paintProgressBar gains a new
-- branch — the source of truth for "does bookends support style X?".
OverlayWidget.BAR_STYLES = {
    "bordered", "solid", "rounded", "metro", "wavy",
    "radial", "radial_hollow", "pacman",
}

--- Paint a progress bar directly to a blitbuffer.
-- @param orientation "horizontal" (default) or "vertical"
-- @param reverse boolean: flip fill direction
-- @param colors table or nil: { fill = Blitbuffer color, bg = Blitbuffer color }
function OverlayWidget.paintProgressBar(bb, x, y, w, h, fraction, ticks, style, orientation, reverse, colors, markers)
    if w < 1 or h < 1 then return end
    fraction = math.max(0, math.min(1, fraction or 0))
    local vertical = orientation == "vertical"
    -- Custom colors: nil = not set (use default), false = transparent (skip paint)
    local custom_fill = colors and colors.fill
    local custom_bg = colors and colors.bg
    local custom_tick = colors and colors.tick
    local invert_read_ticks = colors and colors.invert_read_ticks
    local tick_height_pct = colors and colors.tick_height_pct or 100
    local custom_border = colors and colors.border
    local custom_invert = colors and colors.invert

    -- Resolve custom color: false → nil (transparent/skip), nil → default, else custom.
    -- Must use type() checks to avoid triggering Blitbuffer's __eq metamethod.
    local function resolveColor(custom, default)
        local t = type(custom)
        if t == "nil" then return default end      -- not set: use default
        if t == "boolean" then return nil end      -- false = transparent
        return custom                               -- Color8 value
    end

    -- Helper: paint a rect, swapping axes for vertical.
    -- Skips painting if color is nil (transparent).
    local function pr(rx, ry, rw, rh, color)
        if not color then return end
        if vertical then
            bbPaintRect(bb, ry, rx, rh, rw, color)
        else
            bbPaintRect(bb, rx, ry, rw, rh, color)
        end
    end

    -- Work in abstract coordinates: length = progress axis, thickness = cross axis
    local length = vertical and h or w
    local thickness = vertical and w or h
    local ox = vertical and y or x  -- origin along progress axis
    local oy = vertical and x or y  -- origin along cross axis

    -- Asymmetric thickness: read side = full `thickness`, unread side = a
    -- separate value (centred on the same midline). nil/equal = symmetric,
    -- and the per-style code paths collapse back to the existing render.
    -- Resolution order for unread thickness:
    --   1. colors.unread_height (per-bar absolute px) — wins if set
    --   2. colors.unread_height_pct (global %)        — fallback
    --   3. read_thick                                 — symmetric default
    local read_thick = thickness
    local unread_thick
    if colors and colors.unread_height then
        unread_thick = colors.unread_height
    elseif colors and colors.unread_height_pct then
        unread_thick = math.floor(read_thick * colors.unread_height_pct / 100)
    else
        unread_thick = read_thick
    end
    if unread_thick < 0 then unread_thick = 0 end
    if unread_thick > read_thick then unread_thick = read_thick end
    local unread_oy = oy + math.floor((read_thick - unread_thick) / 2)

    if style == "metro" then
        -- Metro style: start ring, trunk line, position dot, ticks above/below
        local line_thick = math.max(3, math.floor(thickness * 0.2))
        local start_r = math.floor(thickness / 2)  -- full height circle
        local dot_r = math.max(4, math.floor(thickness * 0.35))
        local line_y = oy + math.floor((thickness - line_thick) / 2)
        local unread_line_thick = unread_thick == read_thick and line_thick
            or math.max(1, math.floor(line_thick * unread_thick / read_thick))
        local unread_line_y = oy + math.floor((thickness - unread_line_thick) / 2)
        -- Metro ticks default shorter — the thin trunk looks better with
        -- compact ticks.  Scale the user's tick_height_pct relative to 60%
        -- so 100% (default) → 60%, 200% → 120%, etc.
        tick_height_pct = math.floor(tick_height_pct * 0.35)

        -- Inset the line so start/end circles don't clip
        local inset = start_r
        local line_ox = ox + inset
        local line_len = length - 2 * inset  -- room for start + end circles
        if line_len < 1 then line_len = length; line_ox = ox; inset = 0 end

        local line_fill = math.floor(line_len * fraction)
        local line_fill_start = reverse and (line_len - line_fill) or 0

        -- Metro reads fill/bg like every other style now. Defaults match the
        -- previous all-dark-grey trunk so an unconfigured metro bar is
        -- visually unchanged. The legacy track/metro_fill fields are aliased
        -- to bg/fill upstream by Colour.resolveBarColors (back-compat shim).
        local metro_read   = resolveColor(custom_fill, Blitbuffer.COLOR_DARK_GRAY)
        local metro_unread = resolveColor(custom_bg,   Blitbuffer.COLOR_DARK_GRAY)
        -- Trunk: read portion at full line_thick, unread portion at unread_line_thick.
        -- Both centred on the bar's cross-axis. When symmetric they coincide.
        local read_trunk_start = reverse and (line_len - line_fill) or 0
        local unread_trunk_start = reverse and 0 or line_fill
        local unread_trunk_len = line_len - line_fill
        if line_fill > 0 then
            pr(line_ox + read_trunk_start, line_y, line_fill, line_thick, metro_read)
        end
        if unread_trunk_len > 0 and unread_line_thick > 0 and unread_thick > 0 then
            pr(line_ox + unread_trunk_start, unread_line_y, unread_trunk_len, unread_line_thick, metro_unread)
        end

        -- Chapter ticks: depth 1 above line (connected to trunk), depth 2 below.
        -- When reversed, flip tick sides so the visual hierarchy mirrors the direction.
        -- Tick height is uniform across both halves — derived from the read
        -- thickness so unread-half ticks don't shrink with the trunk.
        local metro_tick_h = math.max(1, math.floor(thickness * tick_height_pct / 100))
        for _i, tick in ipairs(ticks or {}) do
            local tick_frac = type(tick) == "table" and tick[1] or tick
            local tick_w = type(tick) == "table" and tick[2] or 1
            local tick_depth = type(tick) == "table" and tick[3] or 1
            if reverse then tick_frac = 1 - tick_frac end
            local tick_pos = math.floor(line_len * tick_frac)
            if tick_pos > 0 and tick_pos < line_len then
                local tick_above
                if reverse then
                    tick_above = tick_depth > 1
                else
                    tick_above = tick_depth <= 1
                end
                -- Vertical (side-anchored) bars: flip tick sides
                if vertical then tick_above = not tick_above end
                -- Tick recolouring: ticks within the read portion paint in metro_read
                local is_read
                if reverse then
                    is_read = tick_pos >= line_len - line_fill
                else
                    is_read = tick_pos <= line_fill
                end
                local tick_color = is_read and metro_read or metro_unread
                -- Anchor ticks at the bar's vertical centre so they always cross
                -- the trunk regardless of read/unread thickness asymmetry.
                local centre_y = oy + math.floor(thickness / 2)
                if tick_above then
                    pr(line_ox + tick_pos, centre_y - metro_tick_h, line_thick, metro_tick_h, tick_color)
                else
                    pr(line_ox + tick_pos, centre_y, line_thick, metro_tick_h, tick_color)
                end
            end
        end

        -- Helper for circles
        local function paintCircle(cx, cy, r, color)
            if not color then return end
            if vertical then
                bbPaintRoundedRect(bb, cy, cx, r * 2, r * 2, color, r)
            else
                bbPaintRoundedRect(bb, cx, cy, r * 2, r * 2, color, r)
            end
        end

        -- Start circle (empty ring; read colour when set, else trunk colour)
        local start_cx = reverse and (line_ox + line_len - start_r) or (line_ox - start_r)
        paintCircle(start_cx, oy, start_r, metro_read or metro_unread)
        local ring_border = line_thick
        local inner_r = start_r - ring_border
        if inner_r > 0 then
            -- Inner ring is paper-coloured. KOReader's night-mode framebuffer
            -- inversion maps COLOR_WHITE → COLOR_BLACK at refresh time, so the
            -- ring stays visually correct on inverted reads. Previously this
            -- read colors.invert, overloading that field (also used for tick
            -- inversion). Decoupled here so "Tick inversion colour" in the
            -- menu only describes tick behaviour.
            paintCircle(start_cx + ring_border, oy + ring_border, inner_r,
                Blitbuffer.COLOR_WHITE)
        end

        -- End circle (filled, trunk colour, same size as start)
        local end_cx = reverse and (line_ox - start_r) or (line_ox + line_len - start_r)
        paintCircle(end_cx, oy, start_r, metro_unread)

        -- Current position dot (uses tick colour, default black)
        local pos_on_line = reverse and (line_len - line_fill) or line_fill
        local dot_cx = line_ox + pos_on_line - dot_r
        local dot_cy = oy + math.floor((thickness - dot_r * 2) / 2)
        paintCircle(dot_cx, dot_cy, dot_r, resolveColor(custom_tick, Blitbuffer.COLOR_BLACK))

    elseif style == "wavy" then
        -- Wavy ribbon: the entire bar follows a sine wave path.
        -- Two-toned fill with a position dot riding the curve.
        local wave_fill  = resolveColor(custom_fill, Blitbuffer.COLOR_DARK_GRAY)
        local wave_track = resolveColor(custom_bg,   Blitbuffer.COLOR_GRAY)
        local wave_dot = resolveColor(custom_tick, Blitbuffer.COLOR_BLACK)

        local amplitude = math.floor(thickness * 0.35)
        local ribbon_h = math.max(3, math.floor(thickness * 0.4))
        local half_ribbon = math.floor(ribbon_h / 2)
        local unread_ribbon_h = unread_thick == read_thick and ribbon_h
            or math.max(1, math.floor(ribbon_h * unread_thick / read_thick))
        local unread_half_ribbon = math.floor(unread_ribbon_h / 2)
        local mid = oy + math.floor(thickness / 2)
        local two_pi = 2 * math.pi

        -- Phase-lock: adjust wavelength so both ends land on zero crossings.
        -- Force odd half-cycles so the wave starts going one way and ends
        -- going the other ('W' shape). Reversed bars negate the sine ('M').
        local target_wl = math.max(20, math.floor(thickness * 2.5))
        local half_cycles = math.max(1, math.floor((length - 1) / (target_wl / 2) + 0.5))
        if half_cycles % 2 == 0 then half_cycles = half_cycles + 1 end
        local wavelength = 2 * (length - 1) / half_cycles
        local wave_sign = reverse and 1 or -1

        local fill_len = math.floor(length * fraction)
        local fill_start = reverse and (length - fill_len) or 0
        local fill_end = fill_start + fill_len

        -- Helper: wave center y at position i
        local function wave_y(i)
            return mid + math.floor(amplitude * wave_sign * math.sin(two_pi * i / wavelength))
        end

        -- End cap circles (behind the ribbon, same size and color as the wave)
        local cap_r = half_ribbon
        local start_color = (0 >= fill_start and 0 < fill_end) and wave_fill or wave_track
        local end_color = ((length - 1) >= fill_start and (length - 1) < fill_end) and wave_fill or wave_track
        local function paintCap(cx, cy, color)
            if not color then return end
            local rx, ry = cx - cap_r, cy - cap_r
            local d = cap_r * 2
            if vertical then
                bbPaintRoundedRect(bb, ry, rx, d, d, color, cap_r)
            else
                bbPaintRoundedRect(bb, rx, ry, d, d, color, cap_r)
            end
        end
        paintCap(ox, wave_y(0), start_color)
        paintCap(ox + length - 1, wave_y(length - 1), end_color)

        -- Paint ribbon column by column. Read columns use full ribbon_h;
        -- unread columns use the (possibly thinner) unread_ribbon_h, centred
        -- on the same wave path. Symmetric configs collapse to the prior render.
        for i = 0, length - 1 do
            local cy = wave_y(i)
            local in_fill = i >= fill_start and i < fill_end
            local color = in_fill and wave_fill or wave_track
            if not in_fill and unread_thick == 0 then color = nil end
            local h_local = in_fill and ribbon_h or unread_ribbon_h
            local half_local = in_fill and half_ribbon or unread_half_ribbon
            local ry = cy - half_local
            if color then
                if vertical then
                    bbPaintRect(bb, ry, ox + i, h_local, 1, color)
                else
                    bbPaintRect(bb, ox + i, ry, 1, h_local, color)
                end
            end
        end

        -- Chapter ticks — vertical lines through the ribbon at each chapter boundary
        for _, tick in ipairs(ticks or {}) do
            local tick_frac = type(tick) == "table" and tick[1] or tick
            local tick_w = type(tick) == "table" and tick[2] or 1
            if reverse then tick_frac = 1 - tick_frac end
            local tick_pos = math.floor(length * tick_frac)
            if tick_pos > 0 and tick_pos < length then
                local cy = wave_y(tick_pos)
                local in_fill = tick_pos >= fill_start and tick_pos < fill_end
                -- Tick height scales to local ribbon thickness (read or unread).
                local local_ribbon_h = in_fill and ribbon_h or unread_ribbon_h
                local th = math.max(1, math.floor(local_ribbon_h * tick_height_pct / 100))
                local ty = cy - math.floor(th / 2)
                local base_tick = wave_dot
                if base_tick then
                    local tick_color
                    if invert_read_ticks ~= false and in_fill then
                        tick_color = resolveColor(custom_invert, Blitbuffer.COLOR_WHITE)
                    else
                        tick_color = base_tick
                    end
                    if vertical then
                        bbPaintRect(bb, ty, ox + tick_pos, th, tick_w, tick_color)
                    else
                        bbPaintRect(bb, ox + tick_pos, ty, tick_w, th, tick_color)
                    end
                end
            end
        end

        -- Position dot riding the wave
        if wave_dot then
            local dot_r = math.max(4, math.floor(thickness * 0.35))
            local pos_i = reverse and (length - fill_len) or fill_len
            pos_i = math.max(0, math.min(length - 1, pos_i))
            local dot_cy = wave_y(pos_i)
            local dot_cx = ox + pos_i - dot_r
            local dot_dy = dot_cy - dot_r
            if vertical then
                bbPaintRoundedRect(bb, dot_dy, dot_cx, dot_r * 2, dot_r * 2, wave_dot, dot_r)
            else
                bbPaintRoundedRect(bb, dot_cx, dot_dy, dot_r * 2, dot_r * 2, wave_dot, dot_r)
            end
        end

    elseif style == "pacman" then
        -- Pacman bar: read portion is empty, pacman sprite at the read
        -- fraction, dot strip and power pellet in the unread region.
        --
        -- Mouth animation: each pacman is keyed by its top-left screen
        -- position. First sighting at a position seeds its counter from
        -- a monotonic sequence (so two pacmans appearing side-by-side in
        -- the same paint start in opposite mouth phase). Every subsequent
        -- paintProgressBar call increments that pacman's own counter, so
        -- the animation advances on each repaint regardless of how many
        -- pacmans are on screen or who is driving the paint (bookends
        -- overlay, bookshelf, etc.).
        local pacman_key = math.floor(x) .. "_" .. math.floor(y)
        local frame = _pacman_frames[pacman_key]
        if frame == nil then
            _pacman_seq = _pacman_seq + 1
            frame = _pacman_seq
        end
        _pacman_frames[pacman_key] = frame + 1
        local mouth_open = (frame % 2) == 1

        -- Resolve colours. Authentic arcade hex on colour-enabled devices;
        -- strong greyscale defaults on B&W. Custom overrides via the existing
        -- per-bar colors table flow through resolveColor as elsewhere.
        local is_colour = Screen and Screen.isColorEnabled and Screen:isColorEnabled()
        local default_fill, default_dot
        if is_colour then
            default_fill = Colour.parseColorValue({ hex = "#FFCC00" }, true)
            default_dot  = Colour.parseColorValue({ hex = "#FFB897" }, true)
        else
            -- On greyscale screens, lean into "softer than black" — a hard
            -- black silhouette reads harsh next to text. Pacman sits a
            -- couple of shades darker than the dots so it still leads
            -- visually. Explicit Color8 bytes so the values don't drift
            -- if Blitbuffer renames its named constants.
            default_fill = Blitbuffer.Color8(0x22)
            default_dot  = Blitbuffer.COLOR_DARK_GRAY
        end
        local pac_fill = resolveColor(custom_fill, default_fill)
        local pac_dot  = resolveColor(custom_bg, default_dot)

        -- Pick frame + rotation. Direction "ltr"/"rtl" map to right/left;
        -- "ttb"/"btt" map to down/up.
        local dir_map = { ltr = "right", rtl = "left", ttb = "down", btt = "up" }
        local facing = dir_map[orientation == "vertical"
            and (reverse and "btt" or "ttb")
            or (reverse and "rtl" or "ltr")] or "right"
        local frame_name = mouth_open and "open" or "closed"
        local sprite = PacmanSprite.rotate(
            PacmanSprite.getFrame(frame_name),
            PacmanSprite.directionToSteps(facing))

        -- Block scale: minimum 2 device px per arcade pixel so the sprite
        -- stays legible — at thickness=14 (typical inline) a block=1 sprite
        -- is only 13 px, which is too small to read. Block=2 gives 26 px,
        -- which slightly overflows the bar in both directions (see
        -- `feedback_tick_overflow_intentional`) but is the right minimum.
        local block = math.max(2, math.floor(thickness / 10))
        local sprite_px = 13 * block

        -- `length` and `thickness` are already in scope from the function preamble.
        local fraction_px = math.floor(fraction * length)

        -- We track two positions on the fill axis:
        --   * `pacman_canonical_start` — canonical (un-mirrored) leading-edge
        --     of pacman. Grows from 0 to length-sprite_px regardless of
        --     direction. Used to decide which dots are still ahead of the
        --     reader.
        --   * `sprite_start` — the actual paint coordinate. Same as the
        --     canonical position for forward bars; mirrored about the bar's
        --     centre for reversed bars.
        local pacman_canonical_start = math.floor(fraction_px - sprite_px / 2)
        pacman_canonical_start = math.max(0, math.min(length - sprite_px, pacman_canonical_start))
        local pacman_canonical_lead = pacman_canonical_start + sprite_px
        local sprite_start = reverse
            and (length - sprite_px - pacman_canonical_start)
            or pacman_canonical_start

        -- Perpendicular axis: centre the sprite on the bar midline.
        local cross_offset = math.floor((thickness - sprite_px) / 2)

        -- Paint sprite. For each "on" cell in the 13x13 grid, draw a
        -- block-sized rect.
        --
        -- Horizontal bars: sprite col maps to the bar's progress axis
        --   (the wedge sits on the right edge of the right-facing base sprite).
        -- Vertical bars: the sprite is rotated so its wedge ends up on the
        --   row axis (top or bottom of the grid), so row maps to the bar's
        --   progress axis instead.
        if pac_fill then
            for row = 0, 12 do
                for col = 0, 12 do
                    local mask = 2 ^ col
                    if (math.floor(sprite[row + 1] / mask) % 2) == 1 then
                        local axis_off, cross_off
                        if vertical then
                            axis_off = sprite_start + row * block
                            cross_off = cross_offset + col * block
                        else
                            axis_off = sprite_start + col * block
                            cross_off = cross_offset + row * block
                        end
                        -- `ox` is the progress-axis origin, `oy` the cross-axis
                        -- origin: in vertical mode `ox` == screen y and `oy` ==
                        -- screen x, so `rect_x` gets `oy` and `rect_y` gets `ox`.
                        local rect_x, rect_y
                        if vertical then
                            rect_x = oy + cross_off
                            rect_y = ox + axis_off
                        else
                            rect_x = ox + axis_off
                            rect_y = oy + cross_off
                        end
                        bbPaintRect(bb, rect_x, rect_y, block, block, pac_fill)
                    end
                end
            end
        end

        -- Dot strip + pellet. Dots sit at FIXED canonical positions on
        -- the bar (independent of pacman). On each paint we filter to the
        -- dots still ahead of pacman's leading edge — the rest are
        -- "eaten". This keeps dots anchored to the bar instead of
        -- shifting around as pacman moves.
        local dot_block = math.max(3, math.floor(thickness / 6))
        local pellet_block = dot_block * 2

        if pac_dot then
            local layout = PacmanSprite.layoutDots(length, dot_block, pellet_block)
            local dot_cross = math.floor((thickness - dot_block) / 2)
            local pellet_cross = math.floor((thickness - pellet_block) / 2)

            -- Map a canonical bar position (0..length) to its actual
            -- paint coord. For reversed bars, mirror about the bar centre
            -- so the pellet lands at the far end (opposite pacman's start).
            local function toActual(canonical_pos, element_block)
                if reverse then
                    return length - canonical_pos - element_block
                else
                    return canonical_pos
                end
            end

            -- Paint each marker until the leading edge has crossed its
            -- entire footprint. Vanishing the marker the moment the
            -- leading edge first reaches it goes by too fast to read at
            -- typical page-turn cadence; holding it through dot_block
            -- pixels of overlap gives a couple of frames where the
            -- contact is visible before it disappears.
            for _idx, canonical_dot in ipairs(layout.dots) do
                if canonical_dot + dot_block > pacman_canonical_lead then
                    local axis = toActual(canonical_dot, dot_block)
                    local rect_x, rect_y
                    if vertical then
                        rect_x = oy + dot_cross
                        rect_y = ox + axis
                    else
                        rect_x = ox + axis
                        rect_y = oy + dot_cross
                    end
                    bbPaintRect(bb, rect_x, rect_y, dot_block, dot_block, pac_dot)
                end
            end

            -- Pellet at the far canonical end of the bar; paint until
            -- pacman has reached it.
            if layout.pellet and layout.pellet >= pacman_canonical_lead then
                local axis = toActual(layout.pellet, pellet_block)
                local rect_x, rect_y
                if vertical then
                    rect_x = oy + pellet_cross
                    rect_y = ox + axis
                else
                    rect_x = ox + axis
                    rect_y = oy + pellet_cross
                end
                bbPaintRect(bb, rect_x, rect_y, pellet_block, pellet_block, pac_dot)
            end
        end

        -- Chapter ticks intentionally not rendered for pacman (the strip is
        -- already dot-dense and tick markers don't read at this density).

    elseif style == "radial" or style == "radial_hollow" then
        -- Radial (pie-chart) style: a circle filled clockwise from 12 o'clock.
        -- Two distinct asymmetric models:
        --   solid:  unread arc draws as a smaller pie wedge (scaled diameter),
        --           with radial connector lines at the angular boundaries.
        --   hollow: unread arc keeps the read band's diameter but uses a
        --           thinner ring centred on the read band's midline.
        local diameter = math.min(vertical and h or w, vertical and w or h)
        local radius = math.floor(diameter / 2)
        if radius < 2 then radius = 2 end
        -- Center the circle in the allocated rectangle
        local cx = x + math.floor(w / 2)
        local cy = y + math.floor(h / 2)

        local radial_bg = resolveColor(custom_bg, Blitbuffer.COLOR_GRAY)
        -- Match solid bar's GRAY_5 (0x55) read default. DARK_GRAY (0x88) was
        -- only 0x22 darker than the GRAY (0xAA) unread bg — too washed-out
        -- on e-ink to read as a clear progress indicator.
        local radial_fill = resolveColor(custom_fill, Blitbuffer.COLOR_GRAY_5)
        local radial_tick = resolveColor(custom_tick, Blitbuffer.COLOR_BLACK)
        local radial_border_color = resolveColor(custom_border, Blitbuffer.COLOR_BLACK)

        local hollow = style == "radial_hollow"
        local inner_radius = hollow and math.floor(radius * 0.55) or 0

        local r2 = radius * radius
        local inner_r2 = inner_radius * inner_radius
        local two_pi = 2 * math.pi

        -- Asymmetric geometry differs by style.
        -- For solid: unread radii scale down (smaller pie wedge).
        -- For hollow: unread band is thinner, centred on read band's midline.
        local unread_radius, unread_inner_radius, unread_r2, unread_inner_r2
        local mid_r, band_half, unread_band_half, unread_outer_band_r, unread_inner_band_r
        if hollow then
            mid_r = (radius + inner_radius) / 2
            band_half = (radius - inner_radius) / 2
            unread_band_half = unread_thick == read_thick and band_half
                or band_half * unread_thick / read_thick
            unread_outer_band_r = mid_r + unread_band_half
            unread_inner_band_r = mid_r - unread_band_half
            unread_radius = unread_outer_band_r
            unread_inner_radius = unread_inner_band_r
            unread_r2 = unread_outer_band_r * unread_outer_band_r
            unread_inner_r2 = unread_inner_band_r * unread_inner_band_r
        else
            -- Solid: scale full radius
            unread_radius = unread_thick == read_thick and radius
                or math.floor(radius * unread_thick / read_thick)
            unread_inner_radius = 0
            unread_r2 = unread_radius * unread_radius
            unread_inner_r2 = 0
        end

        -- Paint the pie/donut pixel by pixel.
        for py = -radius, radius - 1 do
            for px = -radius, radius - 1 do
                local dx = px + 0.5
                local dy = py + 0.5
                local d2 = dx * dx + dy * dy
                local angle = math.atan2(dx, -dy)
                if angle < 0 then angle = angle + two_pi end
                local pixel_frac = angle / two_pi
                local in_fill = pixel_frac <= fraction
                if in_fill then
                    if d2 <= r2 and d2 > inner_r2 then
                        if radial_fill then
                            bbPaintRect(bb, cx + px, cy + py, 1, 1, radial_fill)
                        end
                    end
                else
                    if d2 <= unread_r2 and d2 > unread_inner_r2 then
                        if radial_bg then
                            bbPaintRect(bb, cx + px, cy + py, 1, 1, radial_bg)
                        end
                    end
                end
            end
        end

        -- Chapter tick marks: radial lines at each chapter boundary.
        -- Per-half: read ticks span the read band; unread ticks span the unread band
        -- (which for solid is a smaller-radius pie, for hollow is a thinner ring).
        for _, tick in ipairs(ticks or {}) do
            local tick_frac = type(tick) == "table" and tick[1] or tick
            local tick_w = type(tick) == "table" and tick[2] or 1
            local tick_angle = tick_frac * two_pi
            local cos_a = math.cos(tick_angle - math.pi / 2)
            local sin_a = math.sin(tick_angle - math.pi / 2)
            local in_fill = tick_frac <= fraction
            local local_outer = in_fill and radius or unread_radius
            local local_inner = in_fill and inner_radius or unread_inner_radius
            if local_outer > 0 and local_outer > local_inner then
                local span = local_outer - local_inner
                local inner_r_for_tick = math.floor(local_outer - span * tick_height_pct / 100)
                if inner_r_for_tick < local_inner then inner_r_for_tick = local_inner end
                for t = inner_r_for_tick, local_outer do
                    local lx = cx + math.floor(t * cos_a)
                    local ly = cy + math.floor(t * sin_a)
                    local pix_angle = math.atan2(t * cos_a, -(t * sin_a))
                    if pix_angle < 0 then pix_angle = pix_angle + two_pi end
                    local pix_frac = pix_angle / two_pi
                    local pix_in_fill = pix_frac <= fraction
                    local tick_color
                    if invert_read_ticks ~= false and pix_in_fill then
                        tick_color = resolveColor(custom_invert, Blitbuffer.COLOR_WHITE)
                    else
                        tick_color = radial_tick
                    end
                    if tick_color then
                        bbPaintRect(bb, lx, ly, tick_w, tick_w, tick_color)
                    end
                end
            end
        end

        -- Border ring(s). Read arc uses full radii; unread arc uses style-specific
        -- radii (smaller pie for solid, thinner band for hollow).
        if radial_border_color then
            local border = (colors and colors.border_thickness) or 1
            if border < 0 then border = 0 end
            if border > 0 then
                local read_b = math.min(border, radius)
                local r_outer_r2 = radius * radius
                local r_inner_r2 = (radius - read_b) * (radius - read_b)
                -- Unread border bounds: outer ring at unread_radius, with thickness
                -- min(border, band_width). For hollow, "band_width" is the unread
                -- ring band; for solid, it's just the unread radius (so border eats
                -- inward from the smaller circle's edge).
                local unread_b_outer = math.min(border, unread_radius)
                local u_outer_outer_r2 = unread_radius * unread_radius
                local u_outer_inner_r2 = (unread_radius - unread_b_outer) * (unread_radius - unread_b_outer)
                for py = -radius, radius - 1 do
                    for px = -radius, radius - 1 do
                        local dx = px + 0.5
                        local dy = py + 0.5
                        local d2 = dx * dx + dy * dy
                        local angle = math.atan2(dx, -dy)
                        if angle < 0 then angle = angle + two_pi end
                        local pixel_frac = angle / two_pi
                        local in_fill = pixel_frac <= fraction
                        if in_fill then
                            if read_b > 0 and d2 <= r_outer_r2 and d2 > r_inner_r2 then
                                bbPaintRect(bb, cx + px, cy + py, 1, 1, radial_border_color)
                            end
                        else
                            if unread_b_outer > 0 and unread_radius > 0 and d2 <= u_outer_outer_r2 and d2 > u_outer_inner_r2 then
                                bbPaintRect(bb, cx + px, cy + py, 1, 1, radial_border_color)
                            end
                        end
                    end
                end
                -- Inner border ring(s): for hollow only.
                if hollow then
                    local read_ib = math.min(border, inner_radius)
                    local rib_outer_r2 = inner_radius * inner_radius
                    local rib_inner_r2 = (inner_radius - read_ib) * (inner_radius - read_ib)
                    -- Unread inner band edge for hollow uses unread_inner_radius
                    -- (= mid_r - unread_band_half). Border inset goes outward from
                    -- there toward mid_r.
                    local unread_b_inner = math.min(border, unread_inner_radius)
                    local uib_outer_r2 = unread_inner_radius * unread_inner_radius
                    local uib_inner_r2 = (unread_inner_radius - unread_b_inner) * (unread_inner_radius - unread_b_inner)
                    -- Loop must cover both read inner_radius AND unread_inner_radius
                    -- (which can be larger when the unread band is centred on the
                    -- read midline and shrinks toward it). Use ceil to avoid
                    -- truncating the unread band's outermost pixels.
                    local loop_r = math.max(inner_radius, math.ceil(unread_inner_radius))
                    for py = -loop_r, loop_r - 1 do
                        for px = -loop_r, loop_r - 1 do
                            local dx = px + 0.5
                            local dy = py + 0.5
                            local d2 = dx * dx + dy * dy
                            local angle = math.atan2(dx, -dy)
                            if angle < 0 then angle = angle + two_pi end
                            local pixel_frac = angle / two_pi
                            local in_fill = pixel_frac <= fraction
                            if in_fill then
                                if read_ib > 0 and d2 <= rib_outer_r2 and d2 > rib_inner_r2 then
                                    bbPaintRect(bb, cx + px, cy + py, 1, 1, radial_border_color)
                                end
                            else
                                if unread_b_inner > 0 and unread_inner_radius > 0 and d2 <= uib_outer_r2 and d2 > uib_inner_r2 then
                                    bbPaintRect(bb, cx + px, cy + py, 1, 1, radial_border_color)
                                end
                            end
                        end
                    end
                end
                -- Connector radial lines at the angular boundaries. For solid:
                -- bridge the read disk's outer edge to the unread (smaller) disk's
                -- outer edge. For hollow: bridge the band's outer edges AND the
                -- band's inner edges (read band extends from inner_radius to
                -- radius; unread band extends from unread_inner_band_r to
                -- unread_outer_band_r — both shorter than the read band).
                if read_thick ~= unread_thick and fraction > 0 and fraction < 1 then
                    local function paintRadialConnector(angle_at, r_a, r_b)
                        -- Paint border-thickness radial line from r_a to r_b at the
                        -- given angle. Caller passes any pair; ordering doesn't matter.
                        if r_a == r_b then return end
                        local cos_a = math.cos(angle_at - math.pi / 2)
                        local sin_a = math.sin(angle_at - math.pi / 2)
                        local r_lo = math.min(r_a, r_b)
                        local r_hi = math.max(r_a, r_b)
                        local half_b = math.floor(border / 2)
                        for t = r_lo, r_hi do
                            local lx = cx + math.floor(t * cos_a)
                            local ly = cy + math.floor(t * sin_a)
                            bbPaintRect(bb, lx - half_b, ly - half_b,
                                math.max(1, border), math.max(1, border),
                                radial_border_color)
                        end
                    end
                    if hollow then
                        -- Bridge outer band edges (radius vs unread_outer_band_r)
                        paintRadialConnector(0, radius, unread_outer_band_r)
                        paintRadialConnector(fraction * two_pi, radius, unread_outer_band_r)
                        -- Bridge inner band edges (inner_radius vs unread_inner_band_r)
                        paintRadialConnector(0, inner_radius, unread_inner_band_r)
                        paintRadialConnector(fraction * two_pi, inner_radius, unread_inner_band_r)
                    else
                        -- Solid: just one connector per boundary, from outer disk
                        -- (radius) down to unread disk (unread_radius).
                        paintRadialConnector(0, unread_radius, radius)
                        paintRadialConnector(fraction * two_pi, unread_radius, radius)
                    end
                end
            end
        end

    elseif style == "solid" then
        local solid_fill = resolveColor(custom_fill, Blitbuffer.COLOR_GRAY_5)
        local solid_bg = resolveColor(custom_bg, Blitbuffer.COLOR_GRAY)
        if unread_thick > 0 then
            pr(ox, unread_oy, length, unread_thick, solid_bg)
        end
        local fill_len = math.floor(length * fraction)
        local fill_start = reverse and (length - fill_len) or 0
        if fill_len > 0 then
            pr(ox + fill_start, oy, fill_len, thickness, solid_fill)
        end
        for _, tick in ipairs(ticks or {}) do
            local tick_frac = type(tick) == "table" and tick[1] or tick
            local tick_w = type(tick) == "table" and tick[2] or 1
            if reverse then tick_frac = 1 - tick_frac end
            local tick_pos = math.floor(length * tick_frac)
            if tick_pos > 0 and tick_pos < length then
                local in_fill = tick_pos >= fill_start and tick_pos < fill_start + fill_len
                local base_tick = resolveColor(custom_tick, Blitbuffer.COLOR_BLACK)
                if base_tick then
                    local tick_color
                    if invert_read_ticks ~= false and in_fill then
                        tick_color = resolveColor(custom_invert, Blitbuffer.COLOR_WHITE)
                    else
                        tick_color = base_tick
                    end
                    -- Tick height scales to the local thickness (read or unread half).
                    local local_thick = in_fill and read_thick or unread_thick
                    local th = math.max(1, math.floor(local_thick * tick_height_pct / 100))
                    local t_oy = oy + math.floor((thickness - th) / 2)
                    pr(ox + tick_pos, t_oy, tick_w, th, tick_color)
                end
            end
        end
    else
        local border_fill = resolveColor(custom_fill, Blitbuffer.COLOR_DARK_GRAY)
        local border_bg = resolveColor(custom_bg, Blitbuffer.COLOR_WHITE)
        local border = (colors and colors.border_thickness) or 1
        if border < 0 then border = 0 end
        if border > math.floor(thickness / 2) then border = math.floor(thickness / 2) end
        local min_dim = vertical and w or h
        local radius = style == "rounded" and math.floor(min_dim / 2) or 0
        -- Asymmetric path: paint two adjacent segments (read at read_thick,
        -- unread at unread_thick centred on the same midline). Each segment
        -- is fully bordered. Symmetric configs fall through to the legacy
        -- single-rect render below to keep that pixel output unchanged.
        if unread_thick ~= read_thick then
            local read_len = math.floor(length * fraction)
            local unread_len = length - read_len
            local read_seg_ox = reverse and (length - read_len) or 0
            local unread_seg_ox = reverse and 0 or read_len

            -- Paints one segment: outer bg + optional inner fill + border outline
            -- with one inner-facing edge optionally skipped (for stepped boundary).
            -- skip_side: "left" omits the rect's left edge in abstract coords (the
            -- progress-axis low end), "right" omits the high end. nil = paint all.
            local function paintSeg(seg_ox, seg_oy, seg_len, seg_thick, outer_color, inner_color, skip_side)
                if seg_len <= 0 or seg_thick <= 0 then return end
                local rx = vertical and seg_oy or seg_ox
                local ry = vertical and seg_ox or seg_oy
                local rw = vertical and seg_thick or seg_len
                local rh = vertical and seg_len or seg_thick
                local seg_radius = radius
                if seg_radius > math.floor(math.min(rw, rh) / 2) then
                    seg_radius = math.floor(math.min(rw, rh) / 2)
                end
                -- Outer bg fill
                if outer_color then
                    if seg_radius > 0 then
                        bbPaintRoundedRect(bb, rx, ry, rw, rh, outer_color, seg_radius)
                    else
                        bbPaintRect(bb, rx, ry, rw, rh, outer_color)
                    end
                end
                -- Inner fill, inset by border + padding
                if inner_color then
                    local padding = math.max(1, math.floor(seg_thick * 0.1))
                    local inset = border + padding
                    local inner_rx = rx + inset
                    local inner_ry = ry + inset
                    local inner_rw = rw - 2 * inset
                    local inner_rh = rh - 2 * inset
                    if inner_rw > 0 and inner_rh > 0 then
                        if seg_radius > 0 then
                            local inner_r = math.max(0, seg_radius - inset)
                            bbPaintRoundedRect(bb, inner_rx, inner_ry, inner_rw, inner_rh, inner_color, inner_r)
                        else
                            bbPaintRect(bb, inner_rx, inner_ry, inner_rw, inner_rh, inner_color)
                        end
                    end
                end
                -- Border. For rounded, bbPaintBorder traces all four sides; we
                -- can't selectively skip a single curved edge from that helper,
                -- so for rounded we still paint the full bordered outline (the
                -- connectors will overpaint the boundary area). For square
                -- (non-rounded) borders we paint as four explicit rects and
                -- omit the side specified by skip_side.
                local seg_border_color = resolveColor(custom_border, Blitbuffer.COLOR_BLACK)
                if seg_border_color and border > 0 then
                    if seg_radius > 0 then
                        bbPaintBorder(bb, rx, ry, rw, rh, border, seg_border_color, seg_radius)
                    else
                        local seg_b = border
                        if seg_b > math.floor(seg_thick / 2) then seg_b = math.floor(seg_thick / 2) end
                        if seg_b < 0 then seg_b = 0 end
                        if seg_b > 0 then
                            -- Map abstract skip_side to the rect's actual edge.
                            -- For horizontal bars: "left" = small-x edge, "right" = large-x edge.
                            -- For vertical bars: "left" (small progress-axis) = small-y edge,
                            --                    "right" (large progress-axis) = large-y edge.
                            local skip_low_x = (not vertical) and skip_side == "left"
                            local skip_high_x = (not vertical) and skip_side == "right"
                            -- Top edge
                            bbPaintRect(bb, rx, ry, rw, seg_b, seg_border_color)
                            -- Bottom edge
                            bbPaintRect(bb, rx, ry + rh - seg_b, rw, seg_b, seg_border_color)
                            -- Left edge (small-x)
                            if not skip_low_x then
                                bbPaintRect(bb, rx, ry, seg_b, rh, seg_border_color)
                            end
                            -- Right edge (large-x)
                            if not skip_high_x then
                                bbPaintRect(bb, rx + rw - seg_b, ry, seg_b, rh, seg_border_color)
                            end
                            -- For vertical bars the top/bottom paints above already
                            -- cover the cross-axis edges. The progress-axis-low/high
                            -- edges are handled by the small-x/large-x overpaint
                            -- the "Top" and "Bottom" lines do (since axes were
                            -- swapped via rx/ry/rw/rh). The skip_low_y/skip_high_y
                            -- decisions therefore translate as: if true, undo the
                            -- corresponding top/bottom paint by overpainting bg.
                            -- We don't undo here; vertical bars use horizontal-style
                            -- skip_side semantics in the call sites and the swap
                            -- below makes it work out: the call sites pass skip_side
                            -- referring to abstract progress-axis low/high, and for
                            -- vertical bars that maps to the screen-y top/bottom of
                            -- the segment — already handled by skipping the right
                            -- "corner" via the unread top/bottom not existing, but
                            -- ASCII border still paints. Since vertical asymmetric
                            -- bars are uncommon and this comment is already too long,
                            -- skip vertical-axis skip handling for now.
                        end
                    end
                end
            end

            -- Read segment: skip the inner-facing border edge (boundary side).
            -- Unread segment: same. Connectors below bridge the step in the outline.
            local read_skip = reverse and "left" or "right"
            local unread_skip = reverse and "right" or "left"
            paintSeg(ox + read_seg_ox, oy, read_len, read_thick, border_bg, border_fill, read_skip)
            paintSeg(ox + unread_seg_ox, unread_oy, unread_len, unread_thick, border_bg, nil, unread_skip)

            -- Rounded asymmetric: paintSeg painted both segments as fully-rounded
            -- pills. The inner-facing rounded corners create a "two separate pills"
            -- look that breaks the stepped flow. Overpaint each segment's inner
            -- side: erase the inner-facing border, fill the corner indents with bg
            -- to square them, then re-paint straight top/bottom borders extending
            -- to the boundary.
            if radius > 0 and read_thick ~= unread_thick then
                local seg_border_color = resolveColor(custom_border, Blitbuffer.COLOR_BLACK)

                -- Per-segment inner radius (clamped to half the segment thickness,
                -- matching paintSeg's clamp).
                local read_r = radius
                if read_r > math.floor(read_thick / 2) then read_r = math.floor(read_thick / 2) end
                local unread_r = radius
                if unread_r > math.floor(unread_thick / 2) then unread_r = math.floor(unread_thick / 2) end

                local function squareInnerSide(seg_ox, seg_oy, seg_len, seg_thick, seg_r, side)
                    -- side: "right" (square the right end) or "left" (square left end)
                    if seg_len <= 0 or seg_thick <= 0 then return end
                    local inner_x  -- abstract x of the inner-facing edge (boundary side)
                    if side == "right" then
                        inner_x = seg_ox + seg_len - seg_r
                    else
                        inner_x = seg_ox
                    end
                    -- Erase inner-facing border: full segment height, border-thick.
                    if border > 0 then
                        local erase_ox = (side == "right")
                            and (seg_ox + seg_len - border)
                            or seg_ox
                        pr(erase_ox, seg_oy, border, seg_thick, border_bg)
                    end
                    -- Fill the two inner-side corner indents (square them).
                    pr(inner_x, seg_oy, seg_r, seg_r, border_bg)
                    pr(inner_x, seg_oy + seg_thick - seg_r, seg_r, seg_r, border_bg)
                    -- Re-paint top and bottom borders straight across the squared
                    -- corner area so the segment outline is continuous along the
                    -- top and bottom edges.
                    if seg_border_color and border > 0 then
                        pr(inner_x, seg_oy, seg_r, border, seg_border_color)
                        pr(inner_x, seg_oy + seg_thick - border, seg_r, border, seg_border_color)
                    end
                end

                -- Only square the unread segment's inner end. Read keeps its
                -- rounded inner end so the read pill ends with a clean rounded
                -- "tip" at the boundary.
                squareInnerSide(ox + unread_seg_ox, unread_oy, unread_len, unread_thick, unread_r,
                    reverse and "right" or "left")
            end

            -- Boundary connectors: bridge between read and unread heights so the
            -- bordered outline is closed and "flows" from thick to thin. Only paint
            -- for bordered (radius == 0); rounded keeps its rounded inner end on the
            -- read pill and a vertical connector here would clash with that look.
            if border > 0 and read_thick ~= unread_thick and radius == 0 then
                local boundary_x = ox + (reverse and unread_seg_ox + unread_len or read_seg_ox + read_len)
                local b_x = boundary_x - math.floor(border / 2)
                -- Top connector: from read top (oy) down to unread top (unread_oy),
                -- inclusive of corner overlap on the unread side.
                local top_y = oy
                local top_h = unread_oy - oy + border
                if top_h > 0 then
                    pr(b_x, top_y, border, top_h, resolveColor(custom_border, Blitbuffer.COLOR_BLACK))
                end
                -- Bottom connector: from unread bottom up to read bottom.
                local bot_y = unread_oy + unread_thick - border
                local bot_h = (oy + read_thick) - bot_y
                if bot_h > 0 then
                    pr(b_x, bot_y, border, bot_h, resolveColor(custom_border, Blitbuffer.COLOR_BLACK))
                end
            end

            -- Ticks (read-thickness, centred on read midline). Mirrors the
            -- symmetric tick logic below, simplified — the asymmetric segments
            -- already carry their own borders, so no inner-rect inset is needed.
            local tick_ox = ox
            local tick_len = length
            local tick_thick = read_thick
            local fill_len_for_ticks = read_len
            local fill_start_for_ticks = read_seg_ox
            for _, tick in ipairs(ticks or {}) do
                local tick_frac = type(tick) == "table" and tick[1] or tick
                local tick_w = type(tick) == "table" and tick[2] or 1
                if reverse then tick_frac = 1 - tick_frac end
                local tick_pos = math.floor(tick_len * tick_frac)
                if tick_pos > 0 and tick_pos < tick_len then
                    local base_tick = resolveColor(custom_tick, Blitbuffer.COLOR_BLACK)
                    if base_tick then
                        local in_fill = tick_pos >= fill_start_for_ticks
                            and tick_pos < fill_start_for_ticks + fill_len_for_ticks
                        local tick_color
                        if invert_read_ticks ~= false and in_fill then
                            tick_color = resolveColor(custom_invert, border_bg)
                        else
                            tick_color = base_tick
                        end
                        -- Tick height scales to local thickness (read or unread).
                        local local_thick = in_fill and read_thick or unread_thick
                        local th = math.max(1, math.floor(local_thick * tick_height_pct / 100))
                        local t_oy = oy + math.floor((tick_thick - th) / 2)
                        pr(tick_ox + tick_pos, t_oy, tick_w, th, tick_color)
                    end
                end
            end
            return
        end
        -- Background (use real coordinates for rounded rect API)
        if radius > 0 then
            if border_bg then
                bbPaintRoundedRect(bb, x, y, w, h, border_bg, radius)
            end
        else
            if border_bg then
                bbPaintRect(bb, x, y, w, h, border_bg)
            end
        end
        local padding = math.max(1, math.floor(thickness * 0.1))
        local h_inset = border + padding
        local v_inset = border + padding
        if radius > 0 then
            -- Rounded: paint fill as a rounded rect, then overpaint the unfilled
            -- portion with a background rounded rect so both ends keep curved edges.
            local inset = h_inset
            local inner_r = math.max(0, radius - inset)
            local inner_x = x + inset
            local inner_y = y + inset
            local inner_w = w - 2 * inset
            local inner_h = h - 2 * inset
            if inner_w > 0 and inner_h > 0 then
                local inner_len = vertical and inner_h or inner_w
                local fill_len = math.floor(inner_len * fraction)
                -- Background (unfilled) first as full rounded rect
                if border_bg then
                    bbPaintRoundedRect(bb, inner_x, inner_y, inner_w, inner_h, border_bg, inner_r)
                end
                -- Fill (read portion) on top — its rounded corners overlay the background
                if fill_len > 0 and border_fill then
                    if vertical then
                        if reverse then
                            bbPaintRoundedRect(bb, inner_x, inner_y + inner_h - fill_len, inner_w, fill_len, border_fill, inner_r)
                        else
                            bbPaintRoundedRect(bb, inner_x, inner_y, inner_w, fill_len, border_fill, inner_r)
                        end
                    else
                        if reverse then
                            bbPaintRoundedRect(bb, inner_x + inner_w - fill_len, inner_y, fill_len, inner_h, border_fill, inner_r)
                        else
                            bbPaintRoundedRect(bb, inner_x, inner_y, fill_len, inner_h, border_fill, inner_r)
                        end
                    end
                end
            end
        end
        local inner_ox = ox + h_inset
        local inner_oy = oy + v_inset
        local inner_len = length - 2 * h_inset
        local inner_thick = thickness - 2 * v_inset
        if inner_len > 0 and inner_thick > 0 and radius == 0 then
            -- Bordered (non-rounded): rectangular fill
            local fill_len = math.floor(inner_len * fraction)
            if fill_len > 0 then
                if reverse then
                    pr(inner_ox + inner_len - fill_len, inner_oy, fill_len, inner_thick, border_fill)
                else
                    pr(inner_ox, inner_oy, fill_len, inner_thick, border_fill)
                end
            end
        end
        -- Border on top
        local border_color = resolveColor(custom_border, Blitbuffer.COLOR_BLACK)
        if radius > 0 then
            if border_color then
                bbPaintBorder(bb, x, y, w, h, border, border_color, radius)
            end
        else
            if border_color then
                bbPaintRect(bb, x, y, w, border, border_color)
                bbPaintRect(bb, x, y + h - border, w, border, border_color)
                bbPaintRect(bb, x, y, border, h, border_color)
                bbPaintRect(bb, x + w - border, y, border, h, border_color)
            end
        end
        -- Chapter ticks
        if inner_len > 0 and inner_thick > 0 then
            local fill_len = math.floor(inner_len * fraction)
            local fill_start = reverse and (inner_len - fill_len) or 0
            -- For rounded bars, compute the inner radius for tick clipping
            local clip_r = radius > 0 and math.max(0, radius - h_inset) or 0
            for _, tick in ipairs(ticks or {}) do
                local tick_frac = type(tick) == "table" and tick[1] or tick
                local tick_w = type(tick) == "table" and tick[2] or 1
                if reverse then tick_frac = 1 - tick_frac end
                local tick_pos = math.floor(inner_len * tick_frac)
                if tick_pos > 0 and tick_pos < inner_len then
                    local base_tick = resolveColor(custom_tick, Blitbuffer.COLOR_BLACK)
                    if base_tick then
                        local tick_color
                        local in_fill = tick_pos >= fill_start and tick_pos < fill_start + fill_len
                        if invert_read_ticks ~= false and in_fill then
                            -- Use `invert` if set, otherwise fall back to `bg`
                            -- (the legacy bordered behaviour — preserves pre-v4.3 presets).
                            tick_color = resolveColor(custom_invert, border_bg)
                        else
                            tick_color = base_tick
                        end
                        local th = math.max(1, math.floor(inner_thick * tick_height_pct / 100))
                        -- Clip tick height near rounded ends so ticks don't exceed the curve
                        if clip_r > 0 then
                            local dist_from_left = tick_pos
                            local dist_from_right = inner_len - tick_pos
                            local dist_from_edge = math.min(dist_from_left, dist_from_right)
                            if dist_from_edge < clip_r then
                                local avail = 2 * math.floor(math.sqrt(math.max(0, clip_r * clip_r - (clip_r - dist_from_edge) * (clip_r - dist_from_edge))))
                                th = math.min(th, avail)
                            end
                        end
                        if th > 0 then
                            local t_oy = inner_oy + math.floor((inner_thick - th) / 2)
                            pr(inner_ox + tick_pos, t_oy, tick_w, th, tick_color)
                        end
                    end
                end
            end
        end
    end

    -- Session / book-open markers (#77): style-agnostic triangle overlays drawn
    -- on top of the bar with NO layout reservation (approach 3). The top marker
    -- points down at the bar from above; the bottom marker points up from below.
    -- Each carries its own fraction, size (% of a fixed screen-scaled base), pixel offset from
    -- the bar edge, and colour. Drawn in abstract coords via pr(), so vertical
    -- bars and reverse fill are handled for free. Rows outside the buffer are
    -- skipped; bbPaintRect clips the horizontal span of the rest.
    if markers and (markers.top or markers.bottom) then
        local cross_limit = vertical and bb:getWidth() or bb:getHeight()
        local default_marker = resolveColor(custom_tick, Blitbuffer.COLOR_BLACK)
        -- Marker size is relative to a FIXED screen-scaled base, NOT the bar
        -- thickness — otherwise a thin bar (e.g. 4px) yields invisible markers.
        -- 100% ≈ a clearly visible caret on any bar; Size% scales from there.
        local marker_base = Screen:scaleBySize(20)
        local RenderText = require("ui/rendertext")
        local function drawMarker(m, is_top)
            if not m then return end
            local fracs = m.fracs or (m.frac and { m.frac })
            if not fracs or #fracs == 0 then return end
            local color = m.color or default_marker
            if not color then return end
            local mh = math.max(2, math.floor(marker_base * (m.size or 50) / 100))
            local offset = m.offset or 0
            local style = m.style or "chevron"
            for _, raw_frac in ipairs(fracs) do
                local frac = math.max(0, math.min(1, raw_frac))
                if reverse then frac = 1 - frac end
                local pos = math.floor(length * frac)
                if style ~= "solid" then
                    local cp
                    if vertical then cp = is_top and 0xE841 or 0xE840
                    else cp = is_top and 0xE83F or 0xE842 end
                    local g = RenderText:getGlyph(Font:getFace("symbols", math.max(8, mh)), cp)
                    if g and g.bb then
                        local gw, gh = g.bb:getWidth(), g.bb:getHeight()
                        local ink_x, ink_y
                        if vertical then
                            ink_y = ox + pos - math.floor(gh / 2)
                            ink_x = is_top and (oy - offset - gw) or (oy + thickness + offset)
                        else
                            ink_x = ox + pos - math.floor(gw / 2)
                            ink_y = is_top and (oy - offset - gh) or (oy + thickness + offset)
                        end
                        if ffi.istype(ColorRGB32_t, color) and bb.colorblitFromRGB32 then
                            bb:colorblitFromRGB32(g.bb, ink_x, ink_y, 0, 0, gw, gh, color)
                        else
                            bb:colorblitFrom(g.bb, ink_x, ink_y, 0, 0, gw, gh, color)
                        end
                    end
                else
                    local denom = (mh > 1) and (mh - 1) or 1
                    for r = 0, mh - 1 do
                        local taper = is_top and ((mh - 1 - r) / denom) or (r / denom)
                        local half = math.floor(mh / 2 * taper)
                        local cross_y = is_top
                            and (oy - offset - mh + r)
                            or  (oy + thickness + offset + r)
                        if cross_y >= 0 and cross_y < cross_limit then
                            pr(ox + pos - half, cross_y, half * 2 + 1, 1, color)
                        end
                    end
                end
            end
        end
        drawMarker(markers.top, true)
        drawMarker(markers.bottom, false)
    end
end
-- ===== end copied region =====

return OverlayWidget
