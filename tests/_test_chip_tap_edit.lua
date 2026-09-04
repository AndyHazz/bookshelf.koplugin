-- tests/_test_chip_tap_edit.lua
-- Which gesture on which chip opens the chip editor.
--
-- Tapping the ALREADY-ACTIVE chip is a deliberate NO-OP. It used to open the
-- editor, and that was removed under #224: a tap meant for switching tabs that
-- landed on the current one opened the editor by accident. Editing is
-- long-press only.
--
-- This is pinned because the reasoning is invisible from the outside -- the
-- branch reads like a gap someone forgot to fill, and "make tapping the
-- current chip open the editor" is a natural-sounding request. Nothing else in
-- the suite covers it, so without this the #224 fix can be undone silently.
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

t.test("#224: tapping the active chip does nothing at all", function()
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

t.test("long-press is the ONLY way to the editor, on any chip", function()
    for _, key in ipairs({ "Home", "Recent" }) do
        local b, seen = bar("Home")
        b:onHoldStrip(nil, at(b, key))
        assert(#seen.hold == 1 and seen.hold[1] == key,
            "long-press should open the editor for " .. key)
    end
end)

t.done()
