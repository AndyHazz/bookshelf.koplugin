-- bookshelf_space.lua
-- Spacing (padding, margins, gaps, insets) that does not grow with a DPI
-- override.
--
-- KOReader's Screen:scaleBySize(px) is px * (panel + dpi) / 2, where panel is
-- the screen's short edge / 600 and dpi is the DPI override / 160 (panel again
-- without an override). So raising the DPI setting -- which readers do to get
-- bigger text -- grows every gap with the text: on a PW5 (1236x1648, panel
-- 2.06) a unit of padding is 1.65px at DPI 200 and 2.53px at 480, 53% more,
-- exactly when space is shortest (maintainer: "at large dpis when space is at
-- a premium, we end up with even less space because all the padding increases
-- with the text size").
--
-- The rule: spacing never grows past the panel's own scale.
--
--   Space.px(v) = min(Screen:scaleBySize(v), ceil(v * panel))
--
-- Below the panel's natural scale -- no override, or an override at or under
-- it, which is most readers (DPI 200 and 300 on a PW5) -- that IS
-- scaleBySize(v), to the pixel, so nothing moves. Above it, text still grows
-- and the gaps stay where the panel would put them.
--
-- For TEXT-derived and physical sizes keep Screen:scaleBySize and KOReader's
-- Size: font sizes, icons and glyphs, row heights that hold text, borders,
-- lines and radii. And keep KOReader's Size.padding.* where a number has to
-- match what a KOReader widget uses inside itself.
--
-- Space.padding / Space.margin / Space.span / Space.radius mirror KOReader's
-- Size groups of the same names (its base values), computed on access so a
-- rotation or DPI change is followed. Drop shadows and rounded corners use
-- Space too: they are shape, and should not grow with a DPI override.

local Device = require("device")

local Space = {}

local function screen() return Device.screen end

-- panelScale() -> the screen's short edge / 600, or nil where the screen
-- cannot say (a test stub, a screen not yet set up): Space.px is then plain
-- scaleBySize, which is what it equals at ordinary settings anyway.
local function panelScale()
    local s = screen()
    if not (s and s.getWidth and s.getHeight) then return nil end
    local ok, w, h = pcall(function() return s:getWidth(), s:getHeight() end)
    if not ok or type(w) ~= "number" or type(h) ~= "number" then return nil end
    return math.min(w, h) / 600
end

function Space.px(v)
    if type(v) ~= "number" then return v end
    local s = screen()
    local by_size = s:scaleBySize(v)
    if v <= 0 then return by_size end
    local panel = panelScale()
    if not panel then return by_size end
    local by_panel = math.ceil(v * panel)
    return by_size < by_panel and by_size or by_panel
end

-- KOReader's frontend/ui/size.lua base values, before scaleBySize.
local BASE = {
    padding = { default = 5, tiny = 1, small = 2, large = 10, button = 2,
                buttontable = 4, fullscreen = 15 },
    margin  = { default = 5, tiny = 1, small = 2, title = 2, fine_tune = 3,
                fullscreen_popout = 3 },
    span    = { horizontal_default = 10, horizontal_small = 5,
                vertical_default = 2, vertical_large = 5 },
    -- Rounded corners are shape, not text: they keep their size whatever
    -- the DPI override (maintainer).
    radius  = { default = 2, window = 7, button = 7 },
}
Space.BASE = BASE

for group, values in pairs(BASE) do
    Space[group] = setmetatable({}, {
        __index = function(_t, k)
            local v = values[k]
            if v == nil then return nil end
            return Space.px(v)
        end,
    })
end

return Space
