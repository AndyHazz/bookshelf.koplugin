-- tests/_test_folder_card.lua
-- Pure-Lua tests for FolderCard.build's cover_floor return value: the
-- slot-local y where FULL-WIDTH cardboard coverage begins. FolderStack /
-- SeriesStack use this as the floor a true-aspect cover must not shrink
-- past, so the cover (and its right-edge drop shadow) always reaches under
-- the cardboard with no gap.
--
-- This is deliberately NOT where the tab starts (v_offset): the tab only
-- spans the left TAB_WIDTH_FRAC of the width, so a cover image that reaches
-- only that far still leaves blank background visible (on the right,
-- outside the tab) down to where the full-width body actually begins --
-- the exact gap a user spotted on-device (Culture/Old Man's War stacks)
-- when this floor was v_offset alone.
--
-- Note this floor is now purely cosmetic (how far the cover IMAGE reaches),
-- not a shadow/corner-safety margin: the book card's own footprint (shadow,
-- border, rounded corners) stays at the slot's full height regardless (see
-- SpineWidget.cover_align_top) -- an earlier version shrunk the whole card
-- to this floor instead, which broke the shadow's alignment with the
-- folder and needed an extra CARD_RADIUS margin to hide the card's own
-- rounded corner. Neither applies now.
--
-- FolderCard pulls in KOReader widget/font modules at load time; none of it
-- runs real font metrics, so TextBoxWidget is stubbed to a fixed line
-- height, making the cardboard's geometry fully predictable:
--   line_h = 20 (both the "Mg" probe and any label probe, same stub)
--   tab_h  = floor(line_h / 2) = 10
--   label_h = 20 (single line always fits under the stub)
--   label_pad = Size.padding.large = 10
--   card_h = tab_h + label_pad + label_h + label_pad = 50
--   SHADOW_OFFSET = Screen:scaleBySize(4) = 4 (stub is the identity)
--   v_offset (tab top)  = clamp(height - card_h - SHADOW_OFFSET, min 0) = clamp(height - 54, 0)
--   cover_floor (body top, full width) = v_offset + tab_h

package.path = "./?.lua;" .. package.path

local function make_widget_base()
    local W = {}
    W.__index = W
    function W:extend(o) o = o or {}; setmetatable(o, self); self.__index = self; return o end
    function W:new(o) o = o or {}; setmetatable(o, self); self.__index = self; if self.init then self:init() end; return o end
    function W:init() end
    return W
end

package.preload["ui/widget/widget"] = function() return make_widget_base() end
package.preload["ui/widget/container/framecontainer"] = function() return make_widget_base() end
package.preload["ui/font"] = function() return {} end
package.preload["ui/geometry"] = function()
    return { new = function(_, t) return setmetatable(t or {}, { __index = {} }) end }
end
package.preload["ui/size"] = function()
    return { padding = { small = 3, default = 5, large = 10, fullscreen = 15 } }
end
package.preload["ffi/blitbuffer"] = function()
    return {
        colorFromString = function() return {} end,
        gray            = function(n) return { gray = n } end,
        COLOR_BLACK     = {}, COLOR_WHITE = {},
    }
end
package.preload["device"] = function()
    return {
        isAndroid = function() return false end,
        screen = {
            isColorEnabled = function() return false end,
            scaleBySize    = function(_, n) return n end,
        },
    }
end
-- TextBoxWidget: fixed 20px line height regardless of text/width, so the
-- cardboard's tab/body geometry is fully predictable (see header comment).
-- Needs :extend too -- folder_card.lua subclasses it (CardboardTextBox).
package.preload["ui/widget/textboxwidget"] = function()
    local TextBoxWidget = {}
    TextBoxWidget.__index = TextBoxWidget
    function TextBoxWidget:extend(o)
        o = o or {}
        setmetatable(o, self)
        self.__index = self
        return o
    end
    function TextBoxWidget:new(o)
        o = o or {}
        setmetatable(o, self)
        self.__index = self
        o.getSize = function(self) return { h = 20, w = self.width or 0 } end
        o.free = function() end
        return o
    end
    return TextBoxWidget
end
package.preload["lib/bookshelf_fonts"] = function()
    return { getFace = function() return {}, {} end }
end
package.preload["lib/bookshelf_cover_progress"] = function()
    return { resolvedColors = function() return {} end }
end
-- Table-driven so a test can flip a preference; unset keys still fall through
-- to the caller's default, which is what every existing test here relies on.
_G.__settings = {}
package.preload["lib/bookshelf_settings_store"] = function()
    return { read = function(key, default)
        local v = _G.__settings[key]
        if v == nil then return default end
        return v
    end }
end

_G.G_reader_settings = { isTrue = function() return false end }

local FolderCard = require("lib/bookshelf_folder_card")

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1
    else fail = fail + 1; io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n") end
end
local function eq(a, e, msg)
    if a ~= e then error((msg or "") .. " expected=" .. tostring(e) .. " got=" .. tostring(a), 2) end
end

test("smoke: build returns a third value (cover_floor)", function()
    local folder, label, cover_floor = FolderCard.build{ width = 300, height = 200, label = "Discworld" }
    assert(folder ~= nil)
    assert(label ~= nil)
    eq(type(cover_floor), "number")
end)

-- Regression guard: this is height - card_h - SHADOW_OFFSET (146) PLUS
-- tab_h (10). Returning the bare 146 (the tab's own top) reproduces the
-- on-device bug where a short cover's image left blank background visible
-- between the tab and the body.
test("cover_floor: generous height -- includes tab_h on top of the tab's own offset", function()
    local _, _, cover_floor = FolderCard.build{ width = 300, height = 200, label = "Discworld" }
    eq(cover_floor, 156)
end)

test("cover_floor: shifts 1:1 with height (card geometry is height-independent)", function()
    local _, _, f1 = FolderCard.build{ width = 300, height = 200, label = "Discworld" }
    local _, _, f2 = FolderCard.build{ width = 300, height = 300, label = "Discworld" }
    eq(f2 - f1, 100)
end)

test("cover_floor: flatlines at tab_h when the slot is too short for the cardboard", function()
    local _, _, cover_floor = FolderCard.build{ width = 300, height = 40, label = "Discworld" }
    eq(cover_floor, 10)
end)

test("cover_floor: flatlines at tab_h exactly at the v_offset boundary height", function()
    local _, _, cover_floor = FolderCard.build{ width = 300, height = 54, label = "Discworld" }
    eq(cover_floor, 10)
end)

test("cover_floor: one pixel above the v_offset boundary is tab_h + 1", function()
    local _, _, cover_floor = FolderCard.build{ width = 300, height = 55, label = "Discworld" }
    eq(cover_floor, 11)
end)


-- ── Square corners and the shadow reservation ───────────────────────────────
-- The cardboard shares the cover's right and bottom edges -- that shared edge
-- is what gives the folder its drop shadow (see the book-layer comment in
-- bookshelf_folder_stack). So it has to reserve exactly what the cover
-- reserved, and round its bottom corners exactly as the cover rounds its own.
-- SpineWidget stopped reserving unconditionally when "No cover drop shadow"
-- arrived, and the cardboard kept subtracting, which left it inset over the
-- cover it is supposed to line up with.

test("the cardboard drops its reservation when the cover does", function()
    local _, _, floor_reserved = FolderCard.build{
        width = 300, height = 200, label = "Discworld" }
    local _, _, floor_flush = FolderCard.build{
        width = 300, height = 200, label = "Discworld", shadow_reserve = 0 }
    -- No reservation puts the card SHADOW_OFFSET lower, so it reaches the
    -- cover's bottom edge instead of stopping short of it.
    eq(floor_flush - floor_reserved, 4, "cardboard did not move down by the reservation")
end)

test("omitting the reservation keeps the shipped geometry", function()
    local _, _, a = FolderCard.build{ width = 300, height = 200, label = "Discworld" }
    local _, _, b = FolderCard.build{
        width = 300, height = 200, label = "Discworld", shadow_reserve = 4 }
    eq(a, b, "the default stopped matching an explicit full reservation")
end)

test("the card is as wide as the cover when neither reserves", function()
    local folder = FolderCard.build{
        width = 300, height = 200, label = "Discworld", shadow_reserve = 0 }
    eq(folder[1].width, 300, "card narrower than the cover it sits on")
end)

test("bottom corners follow the square-corners preference", function()
    _G.__settings["cover_square_corners"] = true
    local folder = FolderCard.build{ width = 300, height = 200, label = "Discworld" }
    _G.__settings["cover_square_corners"] = nil
    eq(folder[1].radius, 0, "cardboard kept rounded bottom corners under a square cover")
end)

test("bottom corners stay rounded by default", function()
    local folder = FolderCard.build{ width = 300, height = 200, label = "Discworld" }
    eq(folder[1].radius, 4, "the default rounding changed")
end)

test("the tab keeps its own rounding", function()
    -- Deliberate: the tab is the cardboard's own shape and sits nowhere near
    -- the cover's outline, so it is not part of the corner match.
    _G.__settings["cover_square_corners"] = true
    local folder = FolderCard.build{ width = 300, height = 200, label = "Discworld" }
    _G.__settings["cover_square_corners"] = nil
    eq(folder[1].tab_radius, 4, "the tab lost its rounding")
end)

print(string.format("\n%d pass, %d fail", pass, fail))
os.exit(fail == 0 and 0 or 1)
