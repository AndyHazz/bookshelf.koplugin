-- tests/_test_module_settings_close.lua
-- Module settings dialogs have a close X on their title (Kit.withClose), which
-- closes them the way a tap outside does.
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

t.test("with a title, the X sits on the title line and closes as a tap outside does", function()
    local built
    local function stub(name, t) package.loaded[name] = t end
    stub("ui/widget/buttondialog", { init = function(self)
        local title = { getSize = function() return { w = 400, h = 40 } end }
        self.title_group = { { title } }
        built = self
    end })
    stub("ui/geometry", { new = function(_s, o) return o end })
    local x_widget
    stub("ui/widget/iconbutton", { new = function(_s, o) x_widget = o; return o end })
    stub("ui/widget/overlapgroup", { new = function(_s, o) return o end })
    stub("ui/widget/container/rightcontainer", { new = function(_s, o) return o end })
    local closed = 0
    local spec = { title = "Reading goals", buttons = { { { text = "Daily" } } } }
    spec.onClose = function() closed = closed + 1 end
    withClose(spec)
    eq(#spec.buttons, 1, "a title gets the X, not a row")
    spec:init()
    eq(built, spec)
    eq(x_widget.icon, "close"); eq(x_widget.height, 40, "the X is the title line's height")
    x_widget.callback()
    eq(closed, 1)
end)

t.test("with no title, a Close row at the foot", function()
    local closed = 0
    local spec = { buttons = { { { text = "Daily" } } } }
    spec.onClose = function() closed = closed + 1 end
    withClose(spec)
    eq(spec.buttons[2][1].text, "Close")
    spec.buttons[2][1].callback()
    eq(closed, 1)
end)

t.test("every built-in module's settings dialog has it", function()
    for _i, name in ipairs({ "clock", "last_books", "analogue_clock", "action", "countdown",
            "random_unread", "ornament", "quote_of_day", "weather", "reading_streak", "shelf",
            "trivia", "reading_goal", "daily_fun" }) do
        local m = io.open("micromodules/" .. name .. ".lua"):read("*a")
        assert(m:find('ButtonDialog:new(require("lib/bookshelf_module_kit").withClose{', 1, true),
            name .. "'s settings have no close X")
    end
end)

t.done()
