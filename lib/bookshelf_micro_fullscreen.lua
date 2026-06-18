--[[
Full-screen micro-module overlay (issue #176/#180). Opened by the footer grid
button when Micro-modules placement == "fullscreen". Shows the hero micro-module
grid filling the screen; closes on a tap outside a module (the close-X over the
footer button is the visual cue), or Back.

Mirrors the start menu overlay's pattern: a full-screen InputContainer that
paints an opaque close-X over the launching footer button's region, with the
grid's own cells consuming module taps and a TapDismiss on the rest closing it.

The grid is HeroModules.build, the same renderer the hero uses; in fullscreen
placement the hero behind is the book card, so there's no _hero_cells conflict.
Pagination is the grid's own in-grid chevrons for now; shelf-style footer paging
is a planned refinement.
]]
local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local InputContainer  = require("ui/widget/container/inputcontainer")
local OverlapGroup    = require("ui/widget/overlapgroup")
local Size            = require("ui/size")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Widget          = require("ui/widget/widget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Screen          = Device.screen

-- Paints its single child at a fixed offset within the overlay (no core widget
-- for this -- the start menu defines the same helper).
local OffsetContainer = WidgetContainer:extend{ x_off = 0, y_off = 0 }
function OffsetContainer:getSize() return self[1]:getSize() end
function OffsetContainer:paintTo(bb, x, y)
    local sz = self[1]:getSize()
    self.dimen = Geom:new{ x = x + self.x_off, y = y + self.y_off, w = sz.w, h = sz.h }
    self[1]:paintTo(bb, x + self.x_off, y + self.y_off)
end

local MicroFullscreen = InputContainer:extend{
    name = "micro_modules_fullscreen",
}

-- Paint a custom X (two diagonal strokes) at the launching button's region, so
-- the user sees a clear close target where the grid button was -- identical
-- approach to the start menu's close indicator.
local function _closeGlyph(bw, button_dimen)
    if not (button_dimen and button_dimen.w and button_dimen.w > 0) then return nil end
    local bd       = button_dimen
    -- Centre the X in the VISUAL button height: the footer button's dimen has the
    -- tap hit-extension baked into its height, so centring in the full dimen drops
    -- the X too low. Mirrors the start menu close so the two corners line up.
    local hit_ext  = (bw and bw.FOOTER_HIT_EXTENSION) or Screen:scaleBySize(12)
    local visual_h = math.max(0, bd.h - hit_ext)
    local art    = Screen:scaleBySize(32)
    local stroke = (bw and bw.FOOTER_STROKE_W) or math.max(1, math.floor(art / 14))
    local xspan  = math.floor(art * 0.62)
    local XWidget = Widget:extend{}
    function XWidget:getSize() return Geom:new{ w = xspan, h = xspan } end
    function XWidget:paintTo(b, x, y)
        local last = xspan - stroke
        for t = 0, last do
            b:paintRect(x + t,        y + t, stroke, stroke, Blitbuffer.COLOR_BLACK)
            b:paintRect(x + last - t, y + t, stroke, stroke, Blitbuffer.COLOR_BLACK)
        end
    end
    local frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0, padding = 0, margin = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = bd.w, h = visual_h },
            XWidget:new{},
        },
    }
    return OffsetContainer:new{ x_off = bd.x, y_off = bd.y, frame }
end

function MicroFullscreen.open(bw, button_dimen, footer_h)
    local self = MicroFullscreen:new{
        bw           = bw,
        button_dimen = button_dimen,
        footer_h     = footer_h or Screen:scaleBySize(40),
    }
    UIManager:show(self)
    return self
end

function MicroFullscreen:init()
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    -- Register so a module add/edit/remove rebuilds THIS overlay live: the edit
    -- reload path routes through HeroModules._rebuild, which checks this ref.
    if self.bw then self.bw._micro_fullscreen = self end
    self:_build()  -- sets self.dimen + size-dependent ges_events + content
end

function MicroFullscreen:_build()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    -- Track the built size so paintTo can re-layout on resize / rotation.
    self._built_w, self._built_h = sw, sh
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    if Device:isTouchDevice() then
        -- Whole-screen tap closes; the grid's own cell InputContainers consume
        -- module/chevron taps first via propagation, so only taps on empty space
        -- (or the close-X) fall through to here.
        self.ges_events = {
            TapClose = { GestureRange:new{ ges = "tap", range = self.dimen } },
        }
    end
    local margin = math.min(
        math.floor(Size.padding.fullscreen * 2 * 0.8),
        math.floor(sw * 0.03))
    local PAD       = margin
    local content_w = sw - 2 * margin
    local top       = margin

    local HeroModules = require("lib/bookshelf_hero_modules")
    local HeroModel   = require("lib/bookshelf_hero_modules_model")
    local HeroCard    = require("lib/bookshelf_hero_card")

    -- Full-width status line + hairline at the top, like the in-hero grid.
    local current = (self.bw._currentHeroBook and self.bw:_currentHeroBook()) or nil
    local state   = (self.bw._buildDeviceState and self.bw:_buildDeviceState()) or nil
    local ok_s, status_row = pcall(HeroCard.buildStatusRow, current, state, content_w, true)
    if not ok_s then status_row = nil end
    local status_h = (status_row and status_row:getSize().h) or 0
    local gap      = math.max(1, math.floor(margin / 2))

    -- End the grid at the same Y as the bookshelf's shelf bottom: reserve the
    -- footer band PLUS a bottom margin (the shelves sit a margin above the footer)
    -- so the overlay grid doesn't run lower than the shelf grid did.
    local bottom_reserve = self.footer_h + margin
    local used_top = top + status_h + (status_row and gap or 0)
    local grid_h   = math.max(1, sh - used_top - bottom_reserve)

    -- Reflow ALL modules (not just the hero's current page): pass an explicit
    -- item list so build() bypasses its per-page assignment.
    local ok, grid = pcall(HeroModules.build, self.bw, content_w, grid_h, PAD,
        { items = HeroModel.load() })
    if not ok or not grid then
        grid = Widget:new{}  -- defensive: empty, still closeable
    end

    local col = VerticalGroup:new{ align = "left" }
    if status_row then
        col[#col + 1] = status_row
        col[#col + 1] = VerticalSpan:new{ width = gap }
    end
    col[#col + 1] = grid

    local bg = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0, padding = 0, margin = 0,
        dimen      = Geom:new{ w = sw, h = sh },
        Widget:new{ dimen = Geom:new{ w = sw, h = sh } },
    }
    local children = OverlapGroup:new{
        dimen = self.dimen:copy(),
        allow_mirroring = false,
        bg,
        OffsetContainer:new{ x_off = margin, y_off = top, col },
    }
    -- Read the CURRENT footer button dimen (refreshed when the bookshelf behind
    -- rebuilds on resize), falling back to the open-time value.
    local close_glyph = _closeGlyph(self.bw, (self.bw and self.bw._micromod_dimen) or self.button_dimen)
    if close_glyph then children[#children + 1] = close_glyph end
    self[1] = children
end

-- Re-layout on screen resize / rotation (desktop window resize), the same way
-- the main bookshelf view rebuilds in its paintTo on a size change.
function MicroFullscreen:paintTo(bb, x, y)
    if Screen:getWidth() ~= self._built_w or Screen:getHeight() ~= self._built_h then
        self:_build()
    end
    InputContainer.paintTo(self, bb, x, y)
end

-- Rebuild the overlay's grid in place after a module add/edit/remove, so it
-- updates live like the in-hero grid (no close+reopen needed).
function MicroFullscreen:rebuildGrid()
    self:_build()
    UIManager:setDirty(self, "ui")
end

local function _clearRef(self)
    if self.bw and self.bw._micro_fullscreen == self then
        self.bw._micro_fullscreen = nil
    end
end

function MicroFullscreen:onTapClose()
    _clearRef(self)
    UIManager:close(self)
    if self.bw then UIManager:setDirty(self.bw, "ui") end
    return true
end
MicroFullscreen.onClose = MicroFullscreen.onTapClose
function MicroFullscreen:onCloseWidget() _clearRef(self) end

return MicroFullscreen
