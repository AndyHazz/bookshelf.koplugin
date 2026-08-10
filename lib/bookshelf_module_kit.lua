--[[
Shared helpers for micro-module authors. The goal: a module never has to
reinvent font scaling, text-fitting, the standard "label + value" card, or
aspect detection — so a naive module looks good at any size, and the layout
rules live in ONE place instead of being copied (differently) into each module.

SIZE is the parent's job. The hero grid (bookshelf_hero_modules._renderFitted)
grows an under-filled card and shrinks an overflowing one by re-rendering the
module at different scale_pct. A module therefore does NOT run its own font
loop — it renders once at the scale_pct it is handed and lets a flexible text
block clamp to avail_h via fitText, which reports its NATURAL height when the
text fits (so the parent's grow can see free space) and ellipsis-clamps only at
the extreme. See micromodules/README.md for the full contract.
]]
local Fonts = require("lib/bookshelf_fonts")
local SM    = require("lib/bookshelf_start_menu_modules")

local Kit = {}

-- Colour roles (re-exported so a module needs one require). COLOR_PRIMARY = the
-- changing/interesting content; COLOR_MUTED = headings, hints, attributions;
-- CARD_BG = the grey card surface a TextBoxWidget must paint on.
Kit.COLOR_PRIMARY = SM.COLOR_PRIMARY
Kit.COLOR_MUTED   = SM.COLOR_MUTED
Kit.CARD_BG       = SM.CARD_BG

-- fmtDuration(secs) -> "3h 05m" / "3h" / "45m", gettext-wrapped so translated
-- unit letters render translated everywhere. Was copied (divergently) into
-- reading_stats and twice into reading_goal - the goal copies had dropped the
-- gettext wrapping, so goal durations rendered untranslated.
function Kit.fmtDuration(secs)
    local _ = require("lib/bookshelf_i18n").gettext
    local T = require("ffi/util").template
    secs = math.max(0, tonumber(secs) or 0)
    local h = math.floor(secs / 3600)
    local m = math.floor((secs % 3600) / 60)
    if h > 0 and m > 0 then return T(_("%1h %2m"), h, string.format("%02d", m)) end
    if h > 0 then return T(_("%1h"), h) end
    return T(_("%1m"), m)
end

-- ─── Tap regions ─────────────────────────────────────────────────────────────
-- Hit-test a module-local point against the regions a module declared via
-- ctx.set_tap_regions during render. Regions are rects in the coordinate
-- space of the widget the module RETURNED (its top-left = 0,0); the host does
-- the screen-to-module translation (cell position, card chrome, clip centring)
-- before calling this - modules never see screen coordinates. First matching
-- region wins (declare overlapping regions most-specific first). Returns the
-- region's id and the region itself, or nil for a miss/malformed input -
-- and on_tap must ALWAYS handle a nil ctx.tapped_region: D-pad activation,
-- whole-cell taps outside every region, and older hosts all produce it.
function Kit.hitRegion(regions, x, y)
    if type(regions) ~= "table" or type(x) ~= "number" or type(y) ~= "number" then
        return nil
    end
    for i = 1, #regions do
        local r = regions[i]
        if type(r) == "table"
                and type(r.x) == "number" and type(r.y) == "number"
                and type(r.w) == "number" and type(r.h) == "number"
                and x >= r.x and x < r.x + r.w
                and y >= r.y and y < r.y + r.h then
            return r.id, r
        end
    end
    return nil
end

-- ─── Settings-dialog helpers ─────────────────────────────────────────────────
-- The standard "a pick landed" triple every module settings dialog performs:
-- close the dialog, reload the menu beneath (so the card re-renders with the
-- new setting), and re-open the dialog so its checkmarks refresh. Was copied
-- verbatim into six modules.
function Kit.settingsReopen(ctx, dialog, show_settings)
    require("ui/uimanager"):close(dialog)
    if ctx and ctx.menu and ctx.menu._reload then ctx.menu:_reload() end
    if show_settings then show_settings(ctx) end
end

-- Kit.radioRow{ label=, active=, on_pick=, toggle= } -> ButtonDialog row.
-- Checkmark-prefixed radio row (U+2713 when active, two-space placeholder
-- otherwise, so labels stay aligned). Tapping the already-active row is a
-- no-op unless toggle = true (a toggle/multi-select row acts on every tap).
function Kit.radioRow(o)
    return {
        text = (o.active and "\xE2\x9C\x93 " or "  ") .. tostring(o.label),
        callback = function()
            if o.active and not o.toggle then return end
            o.on_pick()
        end,
    }
end

-- sc(scale_pct) -> function(n): scaled, rounded pixel size, floored at 1.
function Kit.sc(scale_pct)
    local p = scale_pct or 100
    return function(n) return math.max(1, math.floor(n * p / 100 + 0.5)) end
end

-- face(size, scale_pct, opts) -> a cfont face scaled by scale_pct. opts is the
-- usual {bold=true}/{italic=true}; returns face[, bold] exactly like
-- Fonts:getFace so callers can write `local f, b = Kit.face(...)`.
function Kit.face(size, scale_pct, opts)
    local sc = Kit.sc(scale_pct)
    return Fonts:getFace("cfont", sc(size), opts)
end

-- fitText{...} -> TextBoxWidget. The blessed way to render a flexible text
-- block: wraps to `width`, sizes its font from `size`*scale_pct, and (when
-- `max_h` is given) caps to it with an ellipsis. height_adjust means it reports
-- its NATURAL height when the text fits (so the parent's grow sees free space)
-- and clamps to max_h with an ellipsis only at the extreme. Omit max_h for an
-- uncapped natural block (the parent still clips as a backstop).
function Kit.fitText(o)
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local args = {
        text          = o.text or "",
        face          = Kit.face(o.size or 15, o.scale_pct, o.opts),
        width         = math.max(1, o.width or 50),
        fgcolor       = o.fgcolor or Kit.COLOR_PRIMARY,
        bgcolor       = o.bgcolor or Kit.CARD_BG,
        alignment     = o.align or "left",
        height_adjust = true,
    }
    if o.max_h and o.max_h > 0 then
        args.height = o.max_h
        args.height_overflow_show_ellipsis = true
    end
    return TextBoxWidget:new(args)
end

-- valueCard{...} -> VerticalGroup. The shared "heading + big value + suffix +
-- bar + sub + context" card (reading_goal / reading_stats, and a good default
-- for any stat module). All fields optional except width/scale_pct.
--   heading - small muted bold line               value  - big primary value
--   suffix  - baseline-aligned small primary       bar    - optional full-width widget
--   sub     - optional muted small line            context- optional small primary line
function Kit.valueCard(o)
    local TextWidget      = require("ui/widget/textwidget")
    local VerticalGroup   = require("ui/widget/verticalgroup")
    local VerticalSpan    = require("ui/widget/verticalspan")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local sc = Kit.sc(o.scale_pct)
    local mw = math.max(50, o.width or 50)
    local g = VerticalGroup:new{ align = "left" }
    if o.heading then
        local f, b = Kit.face(15, o.scale_pct, { bold = true })
        g[#g + 1] = TextWidget:new{ text = o.heading, face = f, bold = b,
            fgcolor = Kit.COLOR_MUTED, max_width = mw }
    end
    if o.value then
        local fbig, bbig = Kit.face(20, o.scale_pct, { bold = true })
        local num = TextWidget:new{ text = o.value, face = fbig, bold = bbig,
            fgcolor = Kit.COLOR_PRIMARY, max_width = mw }
        if o.suffix then
            local suf = TextWidget:new{ text = o.suffix, face = Kit.face(14, o.scale_pct),
                fgcolor = Kit.COLOR_PRIMARY, max_width = math.max(10, mw - num:getSize().w) }
            local dy = math.max(0, num:getBaseline() - suf:getBaseline())
            g[#g + 1] = HorizontalGroup:new{ align = "top", num,
                VerticalGroup:new{ align = "left", VerticalSpan:new{ width = dy }, suf } }
        else
            g[#g + 1] = num
        end
    end
    if o.bar then
        g[#g + 1] = VerticalSpan:new{ width = sc(4) }
        g[#g + 1] = o.bar
    end
    if o.sub then
        g[#g + 1] = TextWidget:new{ text = o.sub, face = Kit.face(13, o.scale_pct),
            fgcolor = Kit.COLOR_MUTED, max_width = mw }
    end
    if o.context then
        g[#g + 1] = VerticalSpan:new{ width = sc(3) }
        g[#g + 1] = TextWidget:new{ text = o.context,
            face = Kit.face(13, o.scale_pct, { italic = true }),
            fgcolor = Kit.COLOR_PRIMARY, max_width = mw }
    end
    return g
end

-- The width at which a flexible card can hold TWO comfortable text columns
-- instead of one. Single source for every surface that decides between a
-- one- and two-column layout: the hero/full-screen grid uses it as a flex
-- cell's minimum width (so a third module wraps rather than squeezing three
-- narrow cells onto a row), and the start menu uses it to pick the shape it
-- hands its module cards. Keeping both on one constant is what makes a
-- start-menu card and a grid cell of the same width lay out the same way.
function Kit.twoColMinWidth()
    return require("device").screen:scaleBySize(300)
end

-- shape(width, avail_h) -> "wide" | "square" | "tall". Aspect bands for modules
-- that want different LAYOUTS (not just font sizes) at different cell shapes.
-- ratio = width/avail_h; >= 1.6 wide, <= 0.7 tall, else square.
--
-- nil/zero avail_h means "no height constraint" (the start menu, whose cards
-- take their natural height). There is no aspect to band in that case, so the
-- decision falls back to WIDTH alone via twoColMinWidth() -- a card wide enough
-- for two columns reads "wide", a narrower one reads "square". Callers that
-- know their own shape should pass ctx.shape instead of calling this.
function Kit.shape(width, avail_h)
    if not avail_h or avail_h <= 0 then
        return (width or 0) >= Kit.twoColMinWidth() and "wide" or "square"
    end
    local r = (width or 0) / avail_h
    if r >= 1.6 then return "wide" end
    if r <= 0.7 then return "tall" end
    return "square"
end

-- Per-module SHARED store handle (caches, per-type defaults), backed by the
-- separate bookshelf_micromodules.lua file (not the main bookshelf.lua).
-- Namespaced by module key, so collisions across modules are impossible. Use
-- for data shared by all instances of a module -- NOT per-instance config,
-- which is `ctx.config`.
--   local store = Kit.moduleStore("clock")
--   store:get("format", "follow");  store:set("format", "24")
function Kit.moduleStore(key)
    local MM = require("lib/bookshelf_micromodule_store")
    local prefix = "micromodule_" .. key .. "_"
    local store = {}
    function store:get(name, default) return MM.read(prefix .. name, default) end
    function store:set(name, value) MM.save(prefix .. name, value) end
    function store:delete(name) MM.delete(prefix .. name) end
    return store
end

-- Per-instance config handle for ONE card, backed by fields on its entry +
-- ctx.save (so config travels with the card and is removed with it). The clean
-- replacement for hand-rolling ctx.entry / ctx.save. `save` is nil in render
-- (config is read-only there); :set / :delete persist only when a save is
-- supplied (i.e. in on_tap / show_settings).
--   ctx.config:get("label", "");  ctx.config:set("date", "2026-12-25")
function Kit.entryConfig(entry, save)
    local cfg = {}
    function cfg:get(name, default)
        local v = entry and entry[name]
        if v == nil then return default end
        return v
    end
    function cfg:set(name, value)
        if not entry then return end
        entry[name] = value
        if save then save() end
    end
    function cfg:delete(name)
        if not entry then return end
        entry[name] = nil
        if save then save() end
    end
    return cfg
end

return Kit
