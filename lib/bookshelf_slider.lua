-- bookshelf_slider.lua (see STYLE.md)
-- A value on a track: a size nudge, an ornament's size or lift. A tap
-- anywhere on the track sets it there; a drag moves the knob and sets it
-- when the finger lifts (each change redraws a preview behind, which on
-- e-ink is no thing to do on every move). - and + step it finely. Ticks
-- under the track mark the range's ends and Default.
--   Slider.new{ width, value, min, max, step, default, format(v) -> text,
--               on_change(v), face, small, step_label, big, big_label }
--               -> widget, keys_row
-- Grey cards either side step it: "-5" "+5" by o.step beside the track and,
-- with o.big, "-10" "+10" outside them (maintainer: keep both nudges).
-- step_label / big_label: the number a card shows, when the value's own
-- units are not the reader's (an ornament's 0.05 reads 5).
-- The maths is kept apart (snap, valueAt, xOf, ticks) so the tests reach it
-- without widgets.

local Slider = {}

-- snap(v, o) -> v on o.step's grid from o.min, kept in [o.min, o.max]. Rounded
-- through the step count, so 0.05 steps come out as 1.25, not 1.2500000001.
function Slider.snap(v, o)
    local step = o.step or 1
    local n = math.floor((v - o.min) / step + 0.5)
    local out = o.min + n * step
    -- Two places past the step's own, enough for any step we use.
    out = math.floor(out * 10000 + 0.5) / 10000
    return math.max(o.min, math.min(o.max, out))
end

-- valueAt(x, w, o) -> the value at x along a track w wide (snapped).
function Slider.valueAt(x, w, o)
    local f = math.max(0, math.min(1, w > 0 and x / w or 0))
    return Slider.snap(o.min + f * (o.max - o.min), o)
end

-- xOf(v, w, o) -> where v sits along a track w wide.
function Slider.xOf(v, w, o)
    if o.max <= o.min then return 0 end
    local f = (math.max(o.min, math.min(o.max, v)) - o.min) / (o.max - o.min)
    return math.floor(f * w + 0.5)
end

-- ticks(o) -> the values marked under the track: the ends and Default.
function Slider.ticks(o)
    local out, seen = {}, {}
    -- Not ipairs: with no default it stopped at the hole and dropped the max.
    for _i, v in pairs({ o.min, o.default, o.max }) do
        if v and not seen[v] then seen[v] = true; out[#out + 1] = v end
    end
    table.sort(out)
    return out
end

-- colors(picked, defaults) -> fill, track: the reader's own progress bar
-- colours (Colors > Progress bar; cover_progress.pickedBarColors, nil when
-- none is picked), each falling back to the slider's own.
function Slider.colors(picked, defaults)
    picked = picked or {}
    return picked.fill or defaults.fill, picked.bg or defaults.track
end

function Slider.new(o)
    local Blitbuffer      = require("ffi/blitbuffer")
    local Geom            = require("ui/geometry")
    local GestureRange    = require("ui/gesturerange")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan  = require("ui/widget/horizontalspan")
    local InputContainer  = require("ui/widget/container/inputcontainer")
    local UIManager       = require("ui/uimanager")
    local VerticalGroup   = require("ui/widget/verticalgroup")
    local TextWidget      = require("lib/bookshelf_colour_text")
    local Kit             = require("lib/bookshelf_popup_kit")
    local Space           = require("lib/bookshelf_space")
    local _ = require("lib/bookshelf_i18n").gettext

    local fmt = o.format or tostring
    local value = Slider.snap(o.value, o)
    local function commit(v)
        v = Slider.snap(v, o)
        if v ~= value and o.on_change then o.on_change(v) end
    end

    local btn_h = TextWidget:new{ text = "Hg", face = o.face }:getSize().h + Space.px(12)
    -- stepButton(d, by): a grey card stepping by d * by, labelled with the
    -- step ("-10", "+5"): the fine step beside the track, the big one
    -- outside it (maintainer: keep both nudges).
    -- The kit's minus and plus before the number.
    local MINUS, PLUS = Kit.MINUS, Kit.PLUS
    local glyph_face = require("ui/font"):getFace("symbols", math.max(10, (o.face and o.face.orig_size or 18) - 4))
    local function stepButton(d, by, label)
        local enabled = (d < 0 and value > o.min) or (d > 0 and value < o.max)
        return Kit.button{ text = label, face = o.face, icon_glyph = d < 0 and MINUS or PLUS,
            icon_face = glyph_face, gap = Space.px(2), pad_h = Space.px(8), card = true,
            height = btn_h, enabled = enabled, instant = true,
            on_tap = function() commit(value + d * by) end }
    end
    local step = o.step or 1
    local fine_label = o.step_label or tostring(step)
    local minus = stepButton(-1, step, fine_label)
    local plus  = stepButton(1, step, fine_label)
    local big_minus, big_plus
    if o.big then
        local big_label = o.big_label or tostring(o.big)
        big_minus = stepButton(-1, o.big, big_label)
        big_plus  = stepButton(1, o.big, big_label)
    end
    local gap = Space.px(10)
    local side = minus:getSize().w + gap
    if big_minus then side = side + big_minus:getSize().w + gap end
    local track_w = math.max(Space.px(60), o.width - 2 * side)

    -- The track: a bar in the reader's progress bar colours, the fill up to
    -- the knob (the value is what is "on"), ticks under it, the knob a ring
    -- in the fill colour (maintainer: hollow, and a thicker track). Its
    -- touch area is the buttons' height, so it is as easy to hit as they are.
    local CP = require("lib/bookshelf_cover_progress")
    local fill, track_c = Slider.colors(CP.pickedBarColors(),
        { fill = Blitbuffer.COLOR_BLACK, track = Blitbuffer.COLOR_LIGHT_GRAY })
    local bar_h = math.max(4, Space.px(12))
    local r = math.max(math.floor(btn_h / 4), bar_h)   -- the knob's radius
    local ring = math.max(2, Space.px(3))
    local inner = track_w - 2 * r            -- where the knob's centre runs
    -- knob(bb, cx, cy, rad, c): a disc, through the colour-safe paint.
    local function knob(bb, cx, cy, rad, c)
        CP.paintRoundedRect(bb, cx - rad, cy - rad, 2 * rad, 2 * rad, c, rad)
    end
    local Track = InputContainer:extend{}
    local track = Track:new{ dimen = Geom:new{ w = track_w, h = btn_h } }
    track.shown = value
    function track:paintTo(bb, x, y)
        self.dimen.x, self.dimen.y = x, y
        local cy = y + math.floor(btn_h / 2)
        local x0 = x + r
        local kx = x0 + Slider.xOf(self.shown, inner, o)
        CP.paintRoundedRect(bb, x0, cy - math.floor(bar_h / 2), inner, bar_h,
            track_c, math.floor(bar_h / 2))
        if kx > x0 then
            CP.paintRoundedRect(bb, x0, cy - math.floor(bar_h / 2), kx - x0, bar_h,
                fill, math.floor(bar_h / 2))
        end
        for _i, tv in ipairs(Slider.ticks(o)) do
            local tx = x0 + Slider.xOf(tv, inner, o)
            bb:paintRect(tx - 1, cy + math.floor(bar_h / 2) + Space.px(3), 2, Space.px(6),
                Blitbuffer.COLOR_DARK_GRAY)
        end
        knob(bb, kx, cy, r, fill)
        knob(bb, kx, cy, r - ring, Blitbuffer.COLOR_WHITE)
    end
    local function at(pos)
        return Slider.valueAt(pos.x - track.dimen.x - r, inner, o)
    end
    local function show(v)
        if v == track.shown then return end
        track.shown = v
        local top = UIManager.getTopmostVisibleWidget and UIManager:getTopmostVisibleWidget()
        -- "ui", not "fast": fast is black and white only, and broke up the
        -- grey track behind the knob (maintainer, PW5).
        UIManager:setDirty(top, function() return "ui", track.dimen end)
    end
    track.ges_events = {
        Tap        = { GestureRange:new{ ges = "tap",         range = function() return track.dimen end } },
        Pan        = { GestureRange:new{ ges = "pan",         range = function() return track.dimen end } },
        PanRelease = { GestureRange:new{ ges = "pan_release", range = function() return track.dimen end } },
        Swipe      = { GestureRange:new{ ges = "swipe",       range = function() return track.dimen end } },
    }
    function track:onTap(_a, ges) commit(at(ges.pos)); return true end
    function track:onPan(_a, ges) show(at(ges.pos)); return true end
    function track:onPanRelease(_a, ges) commit(at(ges.pos)); return true end
    -- A quick drag arrives as a swipe: its pos is where it began, so the end
    -- is that plus its distance, along the track.
    function track:onSwipe(_a, ges)
        local dx = (ges.direction == "east" and 1 or ges.direction == "west" and -1 or 0)
            * (ges.distance or 0)
        commit(at({ x = ges.pos.x + dx }))
        return true
    end

    -- Under the track: each tick's label, Default by name, left out where it
    -- would run into the one before.
    -- The track, its ticks and knob are painted by their own offsets, left
    -- to right; the rows round them are not mirrored in a right-to-left UI,
    -- or Default sat under another tick and + on the low end.
    local labels = HorizontalGroup:new{ align = "top", allow_mirroring = false }
    local used = 0
    for _i, tv in ipairs(Slider.ticks(o)) do
        local text = (tv == o.default) and _("Default") or fmt(tv)
        local lw = TextWidget:new{ text = text, face = o.small,
            fgcolor = Blitbuffer.COLOR_DARK_GRAY }
        local w = lw:getSize().w
        local cx = r + Slider.xOf(tv, inner, o)
        local lx = math.max(0, math.min(track_w - w, cx - math.floor(w / 2)))
        if lx >= used then
            labels[#labels + 1] = HorizontalSpan:new{ width = lx - used }
            labels[#labels + 1] = lw
            used = lx + w + Space.px(6)
        end
    end

    local row = HorizontalGroup:new{ align = "center", allow_mirroring = false }
    local keys = {}
    local function add(w)
        if #row > 0 then row[#row + 1] = HorizontalSpan:new{ width = gap } end
        row[#row + 1] = w
    end
    local parts = { minus, track, plus }
    if big_minus then parts = { big_minus, minus, track, plus, big_plus } end
    for _i, w in ipairs(parts) do
        add(w)
        if w ~= track then keys[#keys + 1] = w end
    end
    local vg = VerticalGroup:new{ align = "left",
        row,
        HorizontalGroup:new{ align = "top", allow_mirroring = false,
            HorizontalSpan:new{ width = side }, labels },
    }
    return vg, keys, fmt(value)
end

return Slider
