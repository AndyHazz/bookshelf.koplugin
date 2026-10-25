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
    -- The toolbar title's palette icon (bookshelf_module_card_menu.titleRow).
    "ui/widget/button",
    "ui/widget/horizontalgroup",
    "ui/widget/horizontalspan",
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

local zone_calls, forwarded = 0, 0
package.loaded["lib/bookshelf_gesture_zones"] = {
    tryLiveZones = function() zone_calls = zone_calls + 1; return true end,
    forwardToLive = function() forwarded = forwarded + 1; return true end,
}

local Editor = require("lib/bookshelf_module_grid_editor")
local t = dofile("tests/_helpers.lua").runner()
local eq = dofile("tests/_helpers.lua").eq

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

-- A 4x5 grid of 100px cells, 10px gaps, drawn at (0, 0): cell (c, r) spans
-- x = (c-1)*110 .. +100, y = (r-1)*110 .. +100.
local function openOn(boxes)
    local i = info()
    i.boxes = boxes
    i.container = { dimen = { x = 0, y = 0 } }
    local h = host(i)
    local items = {}
    for _k, b in ipairs(boxes) do
        items[#items + 1] = { id = b.id, type = "module", module = "x",
            at = { page = 1, col = b.col, row = b.row, w = b.w, h = b.h } }
    end
    function h:model()
        return { load = function() return items end, save = function() end }
    end
    return Editor.open{ bw = {}, host = h }, h
end

local function pos(x, y) return { x = x, y = y } end

t.test("swiping a module moves it one cell that way", function()
    local ed = openOn({ { id = "a", page = 1, col = 1, row = 1, w = 1, h = 1 } })
    ed:onEdSwipe(nil, { ges = "swipe", direction = "east", pos = pos(50, 50) })
    local b = ed.session:box("a")
    assert(ed.session.selected_id == nil, "a swipe must not open the toolbar")
    assert(b.col == 2 and b.row == 1, "a at " .. b.col .. "," .. b.row)
    ed:onEdSwipe(nil, { ges = "swipe", direction = "south", pos = pos(160, 50) })
    b = ed.session:box("a")
    assert(b.col == 2 and b.row == 2, "a at " .. b.col .. "," .. b.row)
end)

t.test("a swipe that starts outside the grid goes to KOReader's gesture zones", function()
    local ed = openOn({ { id = "a", page = 1, col = 1, row = 1, w = 1, h = 1 } })
    zone_calls = 0
    ed:onEdSwipe(nil, { ges = "swipe", direction = "north", pos = pos(1000, 300) })
    assert(zone_calls == 1, "edge swipe not passed through")
    assert(ed.session:box("a").col == 1, "an edge swipe moved a module")
end)

t.test("a tap outside the grid, toolbar and footer goes to the gesture zones", function()
    local ed = openOn({ { id = "a", page = 1, col = 1, row = 1, w = 1, h = 1 } })
    zone_calls = 0
    ed:onEdTap(nil, { ges = "tap", pos = pos(1000, 5) })
    assert(zone_calls == 1, "top-edge tap not passed through")
end)

t.test("long-pressing an empty cell adds a module there", function()
    local ed = openOn({ { id = "a", page = 1, col = 1, row = 1, w = 1, h = 1 } })
    local got
    function ed.session:add(c, r) got = { c, r } end
    ed:onEdHold(nil, { ges = "hold", pos = pos(250, 360) })
    assert(got and got[1] == 3 and got[2] == 4, "add not called for cell 3,4")
end)

t.test("Dispatcher events from a gesture zone reach KOReader", function()
    local ed = openOn({ { id = "a", page = 1, col = 1, row = 1, w = 1, h = 1 } })
    forwarded = 0
    ed:handleEvent({ handler = "onIncreaseFlIntensity", args = {} })
    assert(forwarded == 1, "brightness action not forwarded")
end)

t.test("swiping one module keeps another one selected", function()
    local ed = openOn({ { id = "a", page = 1, col = 1, row = 1, w = 1, h = 1 },
                        { id = "b", page = 1, col = 3, row = 3, w = 1, h = 1 } })
    ed.session:select("b")
    ed:onEdSwipe(nil, { ges = "swipe", direction = "south", pos = pos(50, 50) })
    assert(ed.session:box("a").row == 2, "a did not move")
    assert(ed.session.selected_id == "b", "the selection changed")
end)

t.test("spread and pinch resize the module under the fingers", function()
    local ed = openOn({ { id = "a", page = 1, col = 1, row = 1, w = 1, h = 1 } })
    ed:onEdSpread(nil, { ges = "spread", direction = "horizontal", pos = pos(50, 50) })
    assert(ed.session:box("a").w == 2, "horizontal spread should widen")
    ed:onEdSpread(nil, { ges = "spread", direction = "vertical", pos = pos(50, 50) })
    assert(ed.session:box("a").h == 2, "vertical spread should make it taller")
    ed:onEdPinch(nil, { ges = "pinch", direction = "diagonal", pos = pos(50, 50) })
    local b = ed.session:box("a")
    assert(b.w == 1 and b.h == 1, "diagonal pinch should shrink both: " .. b.w .. "x" .. b.h)
    assert(ed.session.selected_id == nil, "resizing by gesture must not open the toolbar")
end)

t.test("a pinch off any module does nothing", function()
    local ed = openOn({ { id = "a", page = 1, col = 1, row = 1, w = 1, h = 1 } })
    ed:onEdPinch(nil, { ges = "pinch", direction = "horizontal", pos = pos(300, 300) })
    assert(ed.session:box("a").w == 1)
end)

-- Keys: Enter puts focus on the toolbar on screen (its buttons, the palette
-- icon above them, the footer below), the arrows move along it, Enter presses
-- the focused button and Back goes back to the grid (maintainer: on the
-- desktop emulator keys could not reach the toolbar).
local function btn(name, log, enabled)
    return { name = name, enabled = enabled ~= false,
             onFocus = function(self) log.focus = self.name end,
             onUnfocus = function() end,
             callback = function() log.pressed = name end }
end
local function keyEd()
    local log = {}
    local ed = setmetatable({
        session = { selected_id = "a" },
        _bar_table = { buttons_layout = { { btn("narrower", log), btn("wider", log) },
                                          { btn("settings", log), btn("remove", log) } } },
        _foot_table = { buttons_layout = { { btn("add", log), btn("done", log) } } },
        _palette = btn("palette", log),
    }, { __index = Editor })
    ed._buildBands = function() end
    return ed, log
end

t.test("keys: Enter focuses the toolbar, arrows move along it, Enter presses", function()
    local ed, log = keyEd()
    ed:onEdPress()
    assert(ed._key_focus, "Enter did not move focus onto the toolbar")
    eq(log.focus, "narrower")
    ed:onEdRight(); eq(log.focus, "wider")
    ed:onEdDown();  eq(log.focus, "remove")
    ed:onEdDown();  eq(log.focus, "done", "the footer is below the toolbar")
    ed:onEdUp(); ed:onEdUp(); ed:onEdUp(); eq(log.focus, "palette", "the palette icon is above the toolbar")
    ed:onEdDown(); ed:onEdPress(); eq(log.pressed, "narrower")
end)

t.test("keys: Back leaves the toolbar for the grid, not the editor", function()
    local ed = keyEd()
    ed:onEdPress()
    ed:onDone()
    assert(not ed._key_focus, "Back kept the toolbar focused")
    assert(not ed._closed, "Back closed the editor from the toolbar")
end)

t.test("keys: the footer's Done finishes, even with the toolbar focused", function()
    local src = io.open("lib/bookshelf_module_grid_editor.lua"):read("*a")
    assert(src:find('button("\\xE2\\x9C\\x93 " .. _("Done"), function() self:_finish() end)', 1, true),
        "the Done button only steps out of the toolbar")
    assert(src:find("on_done = function() self:_finish() end", 1, true), "the actions dialog's Done steps out")
end)

t.test("keys: the button tables leave the arrows to the editor", function()
    -- KOReader offers a key to a container's children first, and a
    -- ButtonTable is a FocusManager: the footer's took the arrows, so the
    -- editor never knew its toolbar was focused and Back closed it (rig).
    local src = io.open("lib/bookshelf_module_grid_editor.lua"):read("*a")
    assert(src:find("self._bar_table.key_events = {}", 1, true), "the toolbar's table takes the arrows")
    assert(src:find("self._foot_table.key_events = {}", 1, true), "the footer's table takes the arrows")
end)

t.test("keys: a greyed-out button is passed over by Enter", function()
    local ed, log = keyEd()
    ed._bar_table.buttons_layout[1][1].enabled = false
    ed:onEdPress()
    eq(log.focus, "wider", "focus started on a disabled button")
    ed:onEdLeft(); ed:onEdPress()
    eq(log.pressed, nil, "a disabled button was pressed")
end)

t.done()
