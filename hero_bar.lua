-- hero_bar.lua
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

local Geom = require("ui/geometry")

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
HeroBar.BOOKENDS_STYLES = {
    "bordered", "solid", "rounded", "metro", "wavy", "radial", "radial_hollow",
}
HeroBar.FALLBACK_STYLES = { "bordered", "solid" }

-- Returns the cycle-list applicable for the active backend.
function HeroBar.availableStyles()
    if loadBookendsPaint() then return HeroBar.BOOKENDS_STYLES end
    return HeroBar.FALLBACK_STYLES
end

-- Minimal paintable widget that delegates to bookends's paintProgressBar.
-- Exposes the contract KOReader's HorizontalGroup expects from a child:
-- `getSize() → { w, h }`, `paintTo(bb, x, y)`, optional `free()`.
local BookendsBar = {}
BookendsBar.__index = BookendsBar

function BookendsBar.new(o, paint)
    o.paint = paint
    o.dimen = Geom:new{ x = 0, y = 0, w = o.width, h = o.height }
    return setmetatable(o, BookendsBar)
end

function BookendsBar:getSize() return self.dimen end

function BookendsBar:paintTo(bb, x, y)
    -- Stash dimen with screen coords so getStatusStripDimen-style
    -- post-paint reads (anywhere a parent walks our dimen) work.
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
        return BookendsBar.new({
            width    = width,
            height   = height,
            fraction = percentage,
            ticks    = {},
            style    = style,
        }, paint)
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
