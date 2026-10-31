-- tests/_test_chip_button_align.lua
-- A kit button with an icon and a label has them at its left, so buttons of
-- one width stacked in a column (the layout editor's Settings, Style and
-- Remove) line up (maintainer); a label or an icon alone stays centred.
--
-- Usage (from plugin root): lua tests/_test_chip_button_align.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq
unpack = unpack or table.unpack   -- KOReader's LuaJIT has it

local function widget(kind)
    local C = { kind = kind }
    function C:new(o)
        o = o or {}
        o.kind = kind
        o.getSize = o.getSize or function(self)
            if self.dimen and self.dimen.w then return { w = self.dimen.w, h = self.dimen.h or 10 } end
            local w = 0
            for _i, c in ipairs(self) do w = w + c:getSize().w end
            return { w = math.max(w, self.width or 10), h = 10 }
        end
        return o
    end
    function C:extend(o) o = o or {}; for k, v in pairs(self) do if o[k] == nil then o[k] = v end end; return o end
    return C
end
for _i, name in ipairs({ "ui/widget/container/centercontainer", "ui/widget/container/leftcontainer",
        "ui/widget/container/framecontainer", "ui/widget/container/inputcontainer",
        "ui/widget/horizontalgroup", "ui/widget/horizontalspan", "ui/widget/iconwidget",
        "lib/bookshelf_colour_text" }) do
    package.loaded[name] = widget(name)
end
package.loaded["ffi/blitbuffer"] = { COLOR_BLACK = 0, COLOR_WHITE = 1, COLOR_DARK_GRAY = 2,
    COLOR_GRAY = 3, COLOR_LIGHT_GRAY = 4 }
package.loaded["ui/geometry"] = { new = function(_s, o) return o end }
package.loaded["ui/gesturerange"] = { new = function(_s, o) return o end }
package.loaded["ui/size"] = { border = { default = 1 }, radius = { default = 4 } }
package.loaded["device"] = { screen = { scaleBySize = function(_s, v) return v end } }
package.loaded["lib/bookshelf_space"] = { px = function(v) return v end, radius = { default = 4 } }
package.loaded["lib/bookshelf_cap_centre"] = { centre = function(w) return w end }

local Chip = require("lib/bookshelf_chip_button")
local function content(o)
    local btn = Chip.build(o)
    return btn[1][1].kind
end

t.test("an icon and a label start at the left", function()
    eq(content{ text = "Settings", icon_glyph = "G", height = 40, width = 200 },
        "ui/widget/container/leftcontainer")
end)

t.test("a label or an icon alone is centred", function()
    eq(content{ text = "Done", height = 40, width = 200 }, "ui/widget/container/centercontainer")
    eq(content{ icon_glyph = "G", height = 40, width = 200 }, "ui/widget/container/centercontainer")
end)

-- A greyed label alone was too easy to miss: a button that can't act has a
-- grey border too, everywhere a kit button is used (maintainer).
t.test("a disabled button's border is grey, an enabled one's is not", function()
    eq(Chip.build{ text = "+", height = 40, enabled = false }[1].color, 4)
    eq(Chip.build{ text = "+", height = 40 }[1].color, nil)
end)

-- The layout editor's footer buttons sit flush on the screen's bottom edge.
t.test("square_bottom reaches the frame", function()
    eq(Chip.build{ text = "Add", height = 40, square_bottom = true }[1].square_bottom, true)
    eq(Chip.build{ text = "Add", height = 40 }[1].square_bottom, nil)
end)

-- And open at the bottom: no line along the screen's edge, the sides run
-- down off it, so they read as standing on the edge on purpose, not cut
-- off by it (maintainer, 2026-10-31).
t.test("a square-bottomed button has no bottom border", function()
    local src = io.open("lib/bookshelf_chip_button.lua"):read("*a")
    local block = assert(src:match("if self%.square_bottom and r > 0 and self%.dimen then(.-)\n    end\n    if %(self%.inverted"))
    assert(not block:find("y + h - b, w, b", 1, true), "it still draws a bottom border")
    assert(block:find("Color.paintRect(bb, x, y + h - r, b, r, ink)", 1, true), "its sides stop short")
    local kit = io.open("lib/bookshelf_popup_kit.lua"):read("*a")
    assert(kit:find("h - (square_bottom and t or 2 * t)", 1, true), "the keys' ring closes the bottom")
end)

t.done()
