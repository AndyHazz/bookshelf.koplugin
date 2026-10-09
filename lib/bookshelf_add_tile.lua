-- lib/bookshelf_add_tile.lua
-- The "+ Add shelf" tile on a shelf of shelves (5.4): a button, not a book.
-- Its label inside a dashed outline -- the usual "something can go here"
-- drawing -- with none of the placeholder cover's chrome (no paper card,
-- no divider motif, no shadow; maintainer, 2026-10-05).
--
-- Transparent, with the panel shading behind it when the ground is painted
-- (a wallpaper or a background colour): the same tint, colour and setting
-- as the label plates under covers, so the label stays legible and the
-- outline reads as part of the shelf's chrome. Ink is the theme's, so it
-- holds up on the dark theme too.
--
-- It takes the same slot a card would, and in the cover grid keeps the
-- shadow's reservation (as a flat card does) so its outline lines up with
-- the cards beside it.
local Blitbuffer     = require("ffi/blitbuffer")
local Device         = require("device")
local Font           = require("ui/font")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
-- Composites over the shading: a plain TextBoxWidget paints a white block.
local TextBoxWidget  = require("lib/bookshelf_transparent_text")
local Screen         = Device.screen

local AddTile = InputContainer:extend{
    width          = nil,
    height         = nil,
    label          = "",
    item           = nil,    -- handed back to on_tap / on_hold
    on_tap         = nil,
    on_hold        = nil,
    is_selected    = false,  -- pressed / D-pad focus: a heavier outline
    reserve_shadow = true,   -- keep a card's shadow strip free (cover grid)
}

-- dashes(len, dash, gap) -> list of { offset, length } covering [0, len):
-- whole dashes, spaced so the run starts AND ends on a dash, which keeps
-- every corner drawn. A side too short for two dashes is one solid line.
function AddTile.dashes(len, dash, gap)
    local out = {}
    if len <= 0 then return out end
    if len < dash * 2 + gap then
        out[1] = { 0, len }
        return out
    end
    local n = math.floor((len + gap) / (dash + gap))
    -- Spread the remainder over the gaps so the last dash ends at len.
    local spare = len - n * dash
    local step = spare / (n - 1)
    for i = 0, n - 1 do
        local o = math.floor(i * (dash + step) + 0.5)
        local e = (i == n - 1) and len or math.floor(i * (dash + step) + dash + 0.5)
        out[#out + 1] = { o, e - o }
    end
    return out
end

-- shading() -> fill colour or nil, strength, ink colour or nil: the label
-- plates' rule (bookshelf_shelf_row): a tint only over a painted ground and
-- only while Panel shading is above zero.
function AddTile.shading()
    local fill, strength, ink
    pcall(function()
        local CP = require("lib/bookshelf_cover_progress")
        local colors = CP.resolvedColors and CP.resolvedColors()
        ink = colors and colors.ink or nil
        local Wallpaper = require("lib/bookshelf_wallpaper")
        local painted = (Wallpaper.isShowing and Wallpaper.isShowing())
            or (Wallpaper.ground and type(Wallpaper.ground()) ~= "nil")
        if not painted then return end
        -- The theme on screen's Panel shading (Wallpaper.shading, the seam).
        local v = Wallpaper.shading()
        if v > 0 and colors then fill, strength = colors.panel_bg, v end
    end)
    return fill, strength, ink
end

function AddTile:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self._fill, self._strength, self._ink = AddTile.shading()
    local reserve = self.reserve_shadow
        and require("lib/bookshelf_spine_widget").SHADOW_OFFSET or 0
    self._card_w = math.max(1, self.width - reserve)
    self._card_h = math.max(1, self.height - reserve)
    local pad = Screen:scaleBySize(8)
    -- Sized to the tile: a list row's button is short and wide, a grid
    -- tile tall and narrow; either way the label should read as the title
    -- of a card that size, not a footnote.
    local size = math.floor(math.min(self._card_h * 0.22, self._card_w * 0.13))
    -- Font:getFace scales by the screen itself, so hand it unscaled points.
    local px_per_pt = Screen:scaleBySize(100) / 100
    size = math.max(12, math.min(26, math.floor(size / px_per_pt)))
    self._text = TextBoxWidget:new{
        text      = self.label or "",
        face      = Font:getFace("cfont", size),
        bold      = true,
        fgcolor   = self._ink,
        width     = math.max(1, self._card_w - 2 * pad),
        alignment = "center",
    }
    self.ges_events = {
        Tap  = { GestureRange:new{ ges = "tap",  range = self.dimen } },
        Hold = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
end

function AddTile:getSize() return self.dimen end

function AddTile:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local w, h = self._card_w, self._card_h
    if self._fill then
        pcall(function()
            require("lib/bookshelf_wallpaper").scrim(bb, x, y, w, h,
                self._fill, self._strength, 0)
        end)
    end
    local t = self.is_selected and Screen:scaleBySize(3) or math.max(1, Screen:scaleBySize(1.5))
    local dash, gap = Screen:scaleBySize(9), Screen:scaleBySize(6)
    local ink = self._ink or Blitbuffer.COLOR_DARK_GRAY
    for _i, d in ipairs(AddTile.dashes(w, dash, gap)) do
        bb:paintRect(x + d[1], y, d[2], t, ink)
        bb:paintRect(x + d[1], y + h - t, d[2], t, ink)
    end
    for _i, d in ipairs(AddTile.dashes(h, dash, gap)) do
        bb:paintRect(x, y + d[1], t, d[2], ink)
        bb:paintRect(x + w - t, y + d[1], t, d[2], ink)
    end
    local ts = self._text:getSize()
    self._text:paintTo(bb, x + math.floor((w - ts.w) / 2), y + math.floor((h - ts.h) / 2))
end

function AddTile:onTap()
    if self.on_tap then self.on_tap(self.item) end
    return true
end

function AddTile:onHold()
    if self.on_hold then self.on_hold(self.item) end
    return true
end

function AddTile:free()
    if self._text and self._text.free then self._text:free() end
end

return AddTile
