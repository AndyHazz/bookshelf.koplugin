-- tests/_test_module_grid_editor_widget.lua
-- The layout editor widget's lifecycle: it reads the grid from its HOST (not
-- the shared bw field the other surface can overwrite), an open that fails
-- leaves nothing behind, and however it closes it saves and takes the host
-- out of edit mode.
--
-- Usage: cd into the plugin dir, then `lua tests/_test_module_grid_editor_widget.lua`

package.path = "./?.lua;./?/init.lua;" .. package.path

local function make_widget_base()
    local W = {}
    W.__index = W
    function W:extend(o) o = o or {}; setmetatable(o, self); self.__index = self; return o end
    function W:new(o)
        o = o or {}; setmetatable(o, self); self.__index = self
        if self.init then o:init() end
        return o
    end
    function W:init() end
    function W:getSize() return { w = 0, h = 0 } end
    function W:paintTo() end
    function W:handleEvent() return false end
    return W
end

for _, name in ipairs({
    "ui/widget/widget",
    "ui/widget/overlapgroup",
    "ui/widget/verticalgroup",
    "ui/widget/verticalspan",
    "ui/widget/container/framecontainer",
    "ui/widget/container/centercontainer",
    "ui/widget/container/widgetcontainer",
    "ui/widget/container/inputcontainer",
}) do
    package.preload[name] = function() return make_widget_base() end
end
package.preload["ui/geometry"] = function() return { new = function(_, t) return t or {} end } end
package.preload["ui/size"] = function()
    return { padding = { fullscreen = 10, default = 5 }, border = { default = 1, window = 2 },
             radius = { window = 4 },
             line = { thin = 1, medium = 2, thick = 3 } }
end
package.preload["ffi/blitbuffer"] = function()
    return { COLOR_WHITE = "white", COLOR_BLACK = "black",
             Color8 = function(n) return { v = n } end,
             gray = function(f) return { gray = f } end }
end
package.preload["device"] = function()
    return {
        screen = { getWidth = function() return 1264 end,
                   getHeight = function() return 1680 end,
                   scaleBySize = function(_, n) return n end },
        input = { group = { Back = "Back" } },
        hasKeys = function() return false end,
        hasDPad = function() return false end,
        isTouchDevice = function() return true end,
    }
end

for _, name in ipairs({ "ui/widget/buttontable", "ui/widget/buttondialog",
                        "ui/widget/notification", "ui/widget/textwidget" }) do
    package.preload[name] = function() return make_widget_base() end
end
package.preload["lib/bookshelf_colour_text"] = function() return make_widget_base() end
package.preload["ui/gesturerange"] = function() return { new = function(_, t) return t end } end
package.preload["ui/font"] = function() return { getFace = function() return {} end } end
local shown, closed = {}, {}
package.preload["ui/uimanager"] = function()
    return { show = function(_, w) shown[#shown + 1] = w end,
             close = function(_, w) closed[#closed + 1] = w end,
             setDirty = function() end, nextTick = function(_, fn) fn() end }
end
package.preload["lib/bookshelf_settings_store"] = function()
    return { read = function(_k, d) return d end, flush = function() end }
end
package.preload["lib/bookshelf_start_menu_modules"] = function()
    return { get = function() return { title = "Mod" } end }
end
package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }
package.loaded["ffi/util"] = { template = function(s, ...) return s end }
package.loaded["logger"] = { dbg = function() end, info = function() end,
    warn = function() end, err = function() end }
package.loaded["lib/bookshelf_hero_modules"] = {
    _sizeFor = function() return 1, 1 end, _ctx = function() return {} end,
    navMove = function() return nil end,
}

local Editor = require("lib/bookshelf_module_grid_editor")
local t = dofile("tests/_helpers.lua").runner()

local D = { cols = 4, rows = 5, cell_w = 100, cell_h = 100, gap = 10 }

local function host(info)
    local h = { renders = {}, saves = 0, info = info }
    local items = { { id = "a", type = "module", module = "x",
                      at = { page = 1, col = 1, row = 1, w = 1, h = 1 } } }
    function h:model()
        return { load = function() return items end,
                 save = function() h.saves = h.saves + 1 end }
    end
    function h:render(edit) self.renders[#self.renders + 1] = edit or "store" end
    function h:footerRect() return nil end
    function h:gridInfo() return self.info end
    return h
end

local function info()
    return { surface = "hero", dims = D, key = "at", page = 1, ox = 0, oy = 0,
             boxes = { { id = "a", page = 1, col = 1, row = 1, w = 1, h = 1 } },
             container = { dimen = {} } }
end

t.test("the editor edits the host's own grid, not the shared field", function()
    local bw = { _module_grid = { surface = "fullscreen", dims = D, key = "at", page = 1,
                                  boxes = {} } }
    local h = host(info())
    local ed = Editor.open{ bw = bw, host = h, select_id = "a" }
    assert(ed and ed.session:box("a"), "editor took its boxes from bw._module_grid")
    ed:onDone()
end)

t.test("closing without Done still saves and leaves edit mode", function()
    local bw = {}
    local h = host(info())
    local ed = Editor.open{ bw = bw, host = h, select_id = "a" }
    ed:onCloseWidget()
    assert(h.saves == 1, "saves " .. h.saves)
    assert(h.renders[#h.renders] == "store", "host still in edit mode")
    assert(bw._module_editor == nil)
end)

t.test("an open that fails leaves nothing behind", function()
    local bw = {}
    local h = host(info())
    function h:render() error("boom") end
    local ok = pcall(Editor.open, { bw = bw, host = h, select_id = "a" })
    assert(not ok, "expected the failure to surface to the caller")
    assert(bw._module_editor == nil, "a dead editor would block every later long-press")
end)

t.test("no grid on the host means no editor", function()
    local bw = {}
    local h = host(nil)
    assert(Editor.open{ bw = bw, host = h } == nil)
end)

t.done()
