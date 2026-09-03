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

-- ── the tab must not show a line where it joins the body ────────────────────
-- The body is drawn as a rounded rect WITH a full border, then its top rows
-- are overpainted so the body meets the tab on a straight line. That overpaint
-- used to be gated on the radius, so with square corners it never ran and the
-- body's top border was left drawn straight across the join -- the tab read as
-- a separate box sitting on the card instead of one piece of cardboard.
--
-- Replays the real paint into a tiny raster and reads the pixel back, because
-- the bug is an ordering question: the border IS drawn, and what matters is
-- whether the fill lands on top of it afterwards.

local function renderPixels(square)
    __settings["cover_square_corners"] = square or nil
    local px = {}
    local function put(x, y, w, h, tag)
        for iy = y, y + h - 1 do
            for ix = x, x + w - 1 do px[ix .. "," .. iy] = tag end
        end
    end
    local fake = {
        paintRectRGB32        = function(_s, x, y, w, h, c) put(x, y, w, h, c.tag or "?") end,
        paintRoundedRectRGB32 = function(_s, x, y, w, h, c) put(x, y, w, h, c.tag or "?") end,
        paintBorderRGB32      = function(_s, x, y, w, h, t, c)
            put(x, y, w, t, c.tag or "?")                 -- top
            put(x, y + h - t, w, t, c.tag or "?")         -- bottom
            put(x, y, t, h, c.tag or "?")                 -- left
            put(x + w - t, y, t, h, c.tag or "?")         -- right
        end,
        getInverse = function() return 0 end,
        setInverse = function() end,
    }
    local folder = FolderCard.build{ width = 300, height = 200, label = "Discworld" }
    local poly = folder[1]
    poly.fill_color = { tag = "fill", getColorRGB32 = function(s) return s end }
    poly.edge_color = { tag = "edge", getColorRGB32 = function(s) return s end }
    poly:paintTo(fake, 0, 0)
    __settings["cover_square_corners"] = nil
    return px, poly
end

test("square corners leave no border across the tab join", function()
    local px, poly = renderPixels(true)
    -- A column in the middle of the tab, at the row where tab meets body.
    local mid_x = math.floor(poly.tab_w / 2)
    local join  = poly.tab_h
    eq(px[mid_x .. "," .. join], "fill",
        "a border line was left across the tab/body join")
end)

test("the folder still has a top edge to the RIGHT of the tab", function()
    -- The overpaint must not take the real top edge with it: right of the tab
    -- that line is the folder's own top.
    local px, poly = renderPixels(true)
    local right_x = poly.tab_w + math.floor((300 - poly.tab_w) / 2)
    eq(px[right_x .. "," .. poly.tab_h], "edge",
        "the folder lost the top edge beside its tab")
end)

test("rounded corners still clear the join too", function()
    local px, poly = renderPixels(false)
    local mid_x = math.floor(poly.tab_w / 2)
    eq(px[mid_x .. "," .. poly.tab_h], "fill",
        "the rounded-corner path regressed at the join")
end)

test("the tab's corner outline has no holes", function()
    -- The tab's corners are now drawn by KOReader's own paintBorderRGB32, the
    -- same primitive the covers use, so their SMOOTHNESS is not ours to test
    -- and the fake below models that border as four straight rects. What this
    -- still guards is a return to a hand-rolled arc: the previous one stepped
    -- its inset by more than a pixel between rows (at the default radius the
    -- rows sat at 0, 0, 1 and 4), so a dot per row left the outline open and
    -- the page showed through. Checks CONNECTIVITY, not particular pixels.
    local px, poly = renderPixels(true)
    local tr = poly.tab_radius
    assert(tr and tr > 0, "the tab has no rounded corner to test")
    local function edgesInRow(row)
        local cols = {}
        for c = 0, poly.tab_w do
            if px[c .. "," .. row] == "edge" then cols[#cols + 1] = c end
        end
        return cols
    end
    for row = 1, tr - 1 do
        local here, below = edgesInRow(row), edgesInRow(row - 1)
        assert(#here > 0, "arc row " .. row .. " painted no outline at all")
        for _i, c in ipairs(here) do
            local touching = false
            for _j, c2 in ipairs(below) do
                if math.abs(c - c2) <= 1 then touching = true break end
            end
            -- A pixel with no neighbour on the row above/below is a hole in
            -- the outline, which is exactly what showed through on device.
            if not touching and #below > 0 then
                error("arc pixel at (" .. c .. "," .. row .. ") is disconnected", 2)
            end
        end
    end
end)

print(string.format("\n%d pass, %d fail", pass, fail))
os.exit(fail == 0 and 0 or 1)
