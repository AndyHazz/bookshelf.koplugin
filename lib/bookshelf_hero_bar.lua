-- bookshelf_hero_bar.lua
-- The progress bar every %bar paints with: the hero lines, the list-view
-- lines. One painter for everyone, lib/bookshelf_bar_paint.lua, which is a
-- byte-identical copy of bookends' paintProgressBar (parity-checked by
-- tools/check_bar_parity.sh), so a bar looks the same with or without
-- bookends installed.
--
-- Bookshelf used to borrow bookends' painter when it was installed and fall
-- back to KOReader's ProgressWidget (bordered / solid only) when it was not,
-- so most readers never saw the fresh-install default, "rounded", and two
-- renderers drifted apart (the same lesson as the token picker, see
-- lib/bookshelf_settings.lua).
--
-- All callers see a single `:new{ width, height, percentage, style, colors }`
-- constructor and a paintable widget with `getSize / paintTo / free`.

local Geom   = require("ui/geometry")
local Widget = require("ui/widget/widget")

local HeroBar = {}

-- Loaded on first use rather than at require time: the painter pulls in ffi
-- and the blitbuffer, which a caller that only builds a bar widget (a layout
-- test) has no need of until a bar is actually drawn.
local _painter
local function painter()
    if not _painter then _painter = require("lib/bookshelf_bar_paint") end
    return _painter
end

-- Styles the painter has that a text line does not offer. Radial /
-- radial_hollow are circular dials and look out of place in a horizontal
-- line. Anything not listed here is offered as the painter gains it.
HeroBar.EXCLUDED_STYLES = {
    radial        = true,
    radial_hollow = true,
}

-- The cycle the line editors' Bar style button walks: every painter style
-- minus EXCLUDED_STYLES, in the painter's order. Built once; the editors
-- only read it.
local _styles
function HeroBar.availableStyles()
    if not _styles then
        local out = {}
        for _i, s in ipairs(painter().BAR_STYLES) do
            if not HeroBar.EXCLUDED_STYLES[s] then
                out[#out + 1] = s
            end
        end
        _styles = out
    end
    return _styles
end

-- Paintable widget around the painter. Extends Widget rather than a bare
-- metatable so KOReader's standard event-propagation walk
-- (WidgetContainer:propagateEvent > child:handleEvent on every descendant)
-- finds a `handleEvent` method on us: a bare-metatable version crashed the
-- first event broadcast (Show / Resume etc) because `bar:handleEvent` was
-- nil. The bar sits inside a HorizontalGroup, which IS a WidgetContainer.
local BarWidget = Widget:extend{
    width    = 0,
    height   = 0,
    fraction = 0,
    ticks    = nil,
    style    = "bordered",
    colors   = nil,
}

-- One shared empty ticks table: the hero and list lines draw no chapter
-- ticks, and the painter only reads it.
local NO_TICKS = {}

function BarWidget:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.ticks = self.ticks or NO_TICKS
end

function BarWidget:getSize() return self.dimen end

function BarWidget:paintTo(bb, x, y)
    -- Stash dimen with screen coords so any parent that walks our dimen
    -- after paint sees the right values.
    self.dimen.x, self.dimen.y = x, y
    painter().paintProgressBar(bb, x, y, self.width, self.height,
        self.fraction, self.ticks, self.style, nil, false, self.colors)
end

function BarWidget:free() end -- nothing to release; pure painter

-- new{ width, height, percentage, style, colors } -> a paintable widget.
-- `style` is the user's saved choice; the painter renders an unknown style
-- as bordered. `colors` is the painter's colour table ({ fill = , bg = ,
-- border = }, any of them nil = the style's own default, false =
-- see-through); nil leaves every style its own look.
function HeroBar:new(o)
    o = o or {}
    return BarWidget:new{
        width    = o.width or 0,
        height   = math.max(1, o.height or 5),
        fraction = math.max(0, math.min(1, o.percentage or 0)),
        style    = o.style or "bordered",
        colors   = o.colors,
    }
end

return HeroBar
