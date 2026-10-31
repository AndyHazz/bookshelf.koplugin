-- tests/_test_chip_tap_edit.lua
-- Which gesture on which chip opens the chip editor.
--
-- Tapping the ALREADY-ACTIVE chip opens its editor -- behind a switch,
-- Behavior > Bookshelf gestures > "Tap the current shelf's button to edit
-- the shelf", on by default as every gesture there is (maintainer,
-- 2026-10-31: the editor should be one tap away). It was removed under #224:
-- a tap meant for switching tabs that landed on the current one opened the
-- editor by accident. With the switch off it is the #224 no-op again, and
-- that is pinned here so the switch can't quietly stop working.
--
-- The preamble mirrors _test_chip_bar_pages.lua.
package.path = "./?.lua;./?/init.lua;" .. package.path
-- Minimal class with new()->init() and extend(), for the widget base classes.
local function klass()
    local c = {}; c.__index = c
    function c:extend(t) t = t or {}; setmetatable(t, self); t.__index = t; return t end
    function c:new(o) o = o or {}; setmetatable(o, self); if o.init then o:init() end; return o end
    return c
end

package.loaded["ui/widget/container/inputcontainer"] = klass()
package.loaded["ui/widget/container/framecontainer"]  = klass()
package.loaded["ui/widget/container/centercontainer"] = klass()
package.loaded["ui/widget/overlapgroup"]              = klass()
package.loaded["ui/widget/horizontalgroup"]           = klass()
package.loaded["ui/widget/horizontalspan"]            = klass()
package.loaded["ui/widget/widget"]                    = klass()
package.loaded["ui/widget/linewidget"]                = klass()
package.loaded["ui/widget/iconwidget"]                = klass()
-- TextWidget: width proportional to text length so longer labels measure wider.
local TW = klass()
function TW:getSize() return { w = #(self.text or "") * 9, h = 16 } end
function TW:free() end
package.loaded["ui/widget/textwidget"]    = TW
package.loaded["ui/widget/textboxwidget"] = klass()
package.loaded["ui/geometry"]   = { new = function(_, t) return t or {} end }
package.loaded["ui/gesturerange"] = { new = function(_, t) return t or {} end }
package.loaded["ui/size"] = {
    padding = { default = 4, large = 8, small = 3, fullscreen = 16 },
    border  = { thin = 1, thick = 3 }, line = { medium = 1 },
}
package.loaded["ui/font"] = { getFace = function() return {} end }
package.loaded["ui/uimanager"] = { setDirty = function() end }
package.loaded["ffi/blitbuffer"] = { COLOR_BLACK = 0, COLOR_WHITE = 0xFF, gray = function(v) return v end }
package.loaded["device"] = { screen = { scaleBySize = function(_, n) return n end } }
package.loaded["lib/bookshelf_fonts"] = { getFace = function() return {}, false end }
package.loaded["lib/bookshelf_text_segments"] = {
    upper = function(s) return s end,
    labelSegments = function(s) return { { text = s or "", class = "text" } } end,
}
package.loaded["lib/bookshelf_settings_store"] = {
    read = function(_, default) return default end,   -- chip_font_scale -> nil -> 100
    isTrue = function() return false end,             -- chip_flex_widths off (equal-share)
    -- chip_uppercase_labels defaults ON, so the widths measured here are the
    -- uppercase ones - the same shape the plugin ships with.
    nilOrTrue = function() return true end,
    generation = function() return 0 end,
}

-- Bookshelf gestures: the tap's own switch, flipped per test.
package.loaded["lib/bookshelf_gestures"] = {
    on = function(id)
        if id == "edit_shelf_tap" then return _G.TAP_EDIT ~= false end
        return true
    end,
}
local ChipBar = dofile("lib/bookshelf_chip_bar.lua")
local t = dofile("tests/_helpers.lua").runner()

-- Records which callback a gesture reached, so "opened the editor" and
-- "switched tabs" can never be confused for one another.
local function bar(active)
    local seen = { change = {}, hold = {} }
    local chips = {
        { key = "current", nerd_glyph = "C", action = true },
        { key = "Home",  label = "Home" },
        { key = "Recent", label = "Recent" },
        { key = "search", nerd_glyph = "S", action = true },
    }
    local b = ChipBar:new{
        chips = chips, active = active, selected_key = active,
        width = 2000, height = 40,
        on_change = function(k) seen.change[#seen.change + 1] = k end,
        on_hold   = function(k) seen.hold[#seen.hold + 1] = k end,
    }
    -- onTapStrip works in strip-relative x, which needs a painted dimen.
    b.dimen = { x = 0, y = 0, w = 2000, h = 40 }
    return b, seen
end

local function at(b, key)
    local d = b._chip_dimens[key]
    assert(d, "chip not rendered: " .. key)
    return { pos = { x = d.x + math.floor(d.w / 2) } }
end

t.test("tapping the active chip opens its editor (the switch's default)", function()
    _G.TAP_EDIT = nil
    local b, seen = bar("Home")
    assert(b:onTapStrip(nil, at(b, "Home")) == true, "the tap must be consumed")
    assert(#seen.hold == 1 and seen.hold[1] == "Home", "a tap on the current shelf did not open its editor")
    assert(#seen.change == 0, "and must not re-fire on_change (a needless rebuild)")
end)

t.test("#224: with the switch off, tapping the active chip does nothing at all", function()
    _G.TAP_EDIT = false
    local b, seen = bar("Home")
    assert(b:onTapStrip(nil, at(b, "Home")) == true,
        "the tap must still be CONSUMED -- falling through would hand it to "
        .. "whatever is underneath the strip")
    assert(#seen.hold == 0,
        "tapping the current chip must NOT open the editor: that is the #224 "
        .. "accident, a tab-switch tap landing on the tab it is already on")
    assert(#seen.change == 0,
        "and it must not re-fire on_change either, which would rebuild the "
        .. "shelf for a tab it is already showing")
end)

t.test("tapping a different chip switches to it, and does not open the editor", function()
    local b, seen = bar("Home")
    assert(b:onTapStrip(nil, at(b, "Recent")) == true, "tap should be consumed")
    assert(#seen.change == 1 and seen.change[1] == "Recent", "expected a switch to Recent")
    assert(#seen.hold == 0, "switching tabs must not open the editor")
end)

t.test("action chips fire on_change, never the editor", function()
    -- `current` and `search` carry their own activate semantics and are
    -- handled before the active-chip branch.
    for _, key in ipairs({ "current", "search" }) do
        local b, seen = bar("Home")
        b:onTapStrip(nil, at(b, key))
        assert(#seen.change == 1 and seen.change[1] == key, key .. " should fire on_change")
        assert(#seen.hold == 0, key .. " must not open the editor")
    end
end)

t.test("long-press opens the editor on any chip, either way", function()
    _G.TAP_EDIT = false
    for _, key in ipairs({ "Home", "Recent" }) do
        local b, seen = bar("Home")
        b:onHoldStrip(nil, at(b, key))
        assert(#seen.hold == 1 and seen.hold[1] == key,
            "long-press should open the editor for " .. key)
    end
end)

-- Each switch answers for its own gesture: long-press editing off still
-- leaves the tap (it reaches the shelf's on_hold, which checked only that).
t.test("the tap's way in doesn't hang on the long-press switch", function()
    local cb = io.open("lib/bookshelf_chip_bar.lua"):read("*a")
    assert(cb:find("self.on_hold(chip.key, true)", 1, true), "the tap does not say it is a tap")
    local w = io.open("lib/bookshelf_widget.lua"):read("*a")
    assert(w:find('if not from_tap and not Gestures.on("edit_shelf") then return end', 1, true),
        "long-press editing off blocks the tap too")
end)

t.test("the switch is among Bookshelf's gestures", function()
    local g = io.open("lib/bookshelf_gestures.lua"):read("*a")
    assert(g:find('id = "edit_shelf_tap"', 1, true), "no switch for the tap")
end)

t.done()
