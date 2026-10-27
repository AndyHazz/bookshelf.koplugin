-- tests/_test_module_settings_close.lua
-- Module settings dialogs end in a Close row (Kit.withClose), which closes
-- them the way a tap outside does.
--
-- Usage (from plugin root): lua tests/_test_module_settings_close.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local src = io.open("lib/bookshelf_module_kit.lua"):read("*a")
local body = src:match("\nfunction Kit%.withClose%(spec%)\n(.-)\nend\n")
assert(body, "Kit.withClose is gone")
local withClose = assert(load("local spec = ...\n" .. body))

t.test("Close is the last row and closes as a tap outside does", function()
    local closed = 0
    local spec = { buttons = { { { text = "Daily" } } } }
    spec.onClose = function() closed = closed + 1 end
    eq(withClose(spec), spec)
    local last = spec.buttons[#spec.buttons]
    eq(#spec.buttons, 2); eq(last[1].text, "Close")
    last[1].callback()
    eq(closed, 1)
end)

t.test("every built-in module's settings dialog has it", function()
    for _i, name in ipairs({ "clock", "last_books", "analogue_clock", "action", "countdown",
            "random_unread", "ornament", "quote_of_day", "weather", "reading_streak", "shelf",
            "trivia", "reading_goal" }) do
        local m = io.open("micromodules/" .. name .. ".lua"):read("*a")
        assert(m:find('ButtonDialog:new(require("lib/bookshelf_module_kit").withClose{', 1, true),
            name .. "'s settings have no Close row")
    end
end)

t.done()
