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
package.loaded["ffi/blitbuffer"] = { COLOR_BLACK = 0, COLOR_WHITE = 1, COLOR_DARK_GRAY = 2 }
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

t.done()
