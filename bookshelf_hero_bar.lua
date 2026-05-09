-- bookshelf_hero_bar.lua
-- Progress-bar backend chooser. When bookends is installed we route paint
-- through its OverlayWidget.paintProgressBar primitive (seven styles).
-- Without bookends we fall back to KOReader's stock ProgressWidget
-- (bordered / solid only).
--
-- All callers see a single `:new{ width, height, percentage, style }`
-- constructor and a paintable widget with `getSize / paintTo / free`.
--
-- Earlier version of this module tried to require bookends's BarWidget
-- directly. That doesn't work — BarWidget is `local` inside
-- bookends_overlay_widget.lua and never exported on the OverlayWidget
-- table. paintProgressBar IS exported, so we build our own thin wrapper
-- around it. The pattern matches what bookends's own BarWidget does
-- internally (bookends_overlay_widget.lua:223-227), so any future bar
-- style added to paintProgressBar lights up here automatically.

local Geom   = require("ui/geometry")
local Widget = require("ui/widget/widget")

local HeroBar = {}

-- pcall-load bookends's overlay-widget module. Plugin paths put each
-- koplugin's directory on package.path so the require resolves even
-- though bookends is is_doc_only (its main.lua doesn't run in FM
-- context, but module-level files are still requireable). Returns the
-- paintProgressBar function or nil.
local function loadBookendsPaint()
    local ok, mod = pcall(require, "bookends_overlay_widget")
    if not ok or type(mod) ~= "table" or type(mod.paintProgressBar) ~= "function" then
        return nil
    end
    return mod.paintProgressBar
end

-- Style sets exposed in the line editor's bar-style cycle button. The
-- bookends list is a superset; the fallback keeps it to two real styles.
-- Radial / radial_hollow are deliberately excluded — bookshelf's hero
-- progress bar is a horizontal-strip context where a circle dial reads
-- as out-of-place; bookends still has them for its own status-line use.
HeroBar.BOOKENDS_STYLES = {
    "bordered", "solid", "rounded", "metro", "wavy",
}
HeroBar.FALLBACK_STYLES = { "bordered", "solid" }

-- Returns the cycle-list applicable for the active backend.
function HeroBar.availableStyles()
    if loadBookendsPaint() then return HeroBar.BOOKENDS_STYLES end
    return HeroBar.FALLBACK_STYLES
end

-- Paintable widget that delegates to bookends's paintProgressBar.
-- Extends Widget rather than a bare metatable so KOReader's standard
-- event-propagation walk (WidgetContainer:propagateEvent → child:handleEvent
-- on every descendant) finds a `handleEvent` method on us. The earlier
-- bare-metatable version crashed the first event broadcast (Show /
-- Resume etc) because `bar:handleEvent` was nil.
--
-- Bookends's own BarWidget is similarly bare — but inside bookends it's
-- only ever rendered via manual paintTo calls in OverlayWidget's
-- framework, never as a child of a WidgetContainer that propagates
-- events. Bookshelf places this widget inside a HorizontalGroup, which
-- IS a WidgetContainer.
local BookendsBar = Widget:extend{
    width    = 0,
    height   = 0,
    fraction = 0,
    ticks    = nil,
    style    = "bordered",
    colors   = nil,
    paint    = nil,  -- bookends's paintProgressBar function
}

function BookendsBar:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.ticks = self.ticks or {}
end

function BookendsBar:getSize() return self.dimen end

function BookendsBar:paintTo(bb, x, y)
    -- Stash dimen with screen coords so any parent that walks our dimen
    -- after paint sees the right values.
    self.dimen.x, self.dimen.y = x, y
    self.paint(bb, x, y, self.width, self.height,
        self.fraction, self.ticks, self.style, nil, false, self.colors)
end

function BookendsBar:free() end -- nothing to release; pure painter

-- new{ width, height, percentage, style } -> a paintable widget.
-- `style` is the user's saved choice; we silently downgrade to whatever
-- the active backend supports (paintProgressBar tolerates unknown
-- styles by rendering bordered).
function HeroBar:new(o)
    o = o or {}
    local width      = o.width or 0
    local height     = math.max(1, o.height or 5)
    local percentage = math.max(0, math.min(1, o.percentage or 0))
    local style      = o.style or "bordered"

    local paint = loadBookendsPaint()
    if paint then
        return BookendsBar:new{
            width    = width,
            height   = height,
            fraction = percentage,
            ticks    = {},
            style    = style,
            paint    = paint,
        }
    end

    -- Fallback: KOReader ProgressWidget. Only bordered / solid are
    -- meaningful; saved styles like wavy render as the default look.
    local ProgressWidget = require("ui/widget/progresswidget")
    return ProgressWidget:new{
        width      = width,
        height     = height,
        percentage = percentage,
        margin_h   = 0,
        margin_v   = 0,
    }
end

return HeroBar
