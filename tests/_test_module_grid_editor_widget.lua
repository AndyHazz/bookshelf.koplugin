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
    -- Buttons in the toolbar (stock Button stubs).
    "ui/widget/button",
    "ui/widget/horizontalgroup",
    "ui/widget/horizontalspan",
}) do
    package.preload[name] = function() return make_widget_base() end
end
-- combine(): the union _dirty() builds its refresh region from.
local GeomMT = {}
GeomMT.__index = GeomMT
function GeomMT:combine(o)
    local x, y = math.min(self.x, o.x), math.min(self.y, o.y)
    return setmetatable({ x = x, y = y, w = math.max(self.x + self.w, o.x + o.w) - x,
        h = math.max(self.y + self.h, o.y + o.h) - y }, GeomMT)
end
package.preload["ui/geometry"] = function()
    return { new = function(_, t) return setmetatable(t or {}, GeomMT) end }
end
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
        hasKeys = function() return _G.TEST_DPAD == true end,
        hasDPad = function() return _G.TEST_DPAD == true end,
        isTouchDevice = function() return true end,
    }
end

for _, name in ipairs({ "ui/widget/iconbutton", "ui/widget/container/leftcontainer",
                        "ui/widget/buttondialog",
                        "ui/widget/notification", "ui/widget/textwidget",
                        "ui/widget/linewidget" }) do
    package.preload[name] = function() return make_widget_base() end
end
package.preload["lib/bookshelf_colour_text"] = function() return make_widget_base() end
-- The kit's buttons: a widget the keys can focus and press.
package.preload["lib/bookshelf_popup_kit"] = function()
    local W = make_widget_base()
    return {
        button = function(o) local b = W:new{}; b.on_tap = o.on_tap; return b end,
        hintText = function() return W:new{} end,
        cardify = function(f) return f end,
    }
end
package.preload["ui/gesturerange"] = function() return { new = function(_, t) return t end } end
package.preload["ui/font"] = function() return { getFace = function() return {} end } end
package.preload["lib/bookshelf_fonts"] = function() return { getFace = function() return {}, true end } end
local shown, closed = {}, {}
local dirty_fns = {}
package.preload["ui/uimanager"] = function()
    return { show = function(_, w) shown[#shown + 1] = w end,
             close = function(_, w) closed[#closed + 1] = w end,
             setDirty = function(_, _w, fn)
                 if type(fn) == "function" then dirty_fns[#dirty_fns + 1] = fn end
             end,
             nextTick = function(_, fn) fn() end }
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

-- Opened on a piece from a menu (the shelf editor's add, a module's Edit)
-- with the keys: nothing was focused, the arrows moved the grid's selection
-- and only Enter reached the toolbar, which nothing said (maintainer,
-- desktop). Focus goes straight onto the toolbar's first button.
t.test("keys: opened on a piece, focus is on its toolbar", function()
    _G.TEST_DPAD = true
    local ok, err = pcall(function()
        local h = host(info())
        local ed = Editor.open{ bw = {}, host = h, select_id = "a" }
        assert(ed._key_focus, "the toolbar has no focus")
        ed:onDone()
        assert(not ed._closed, "Back from the toolbar closed the editor")
        -- Nothing selected: no toolbar, nothing to focus.
        ed:onDone()
        local ed2 = Editor.open{ bw = {}, host = host(info()) }
        assert(not ed2._key_focus, "focus with no piece selected")
        -- Just added (the shelf editor's add opens the editor, then adds):
        -- selected after the open, focus on its toolbar all the same.
        ed2.session:select("a")
        assert(ed2._key_focus, "the piece just added has no focus on its toolbar")
        ed2:onDone()
        ed2:onDone()
        -- The grid's own arrows select without taking the toolbar.
        local ed4 = Editor.open{ bw = {}, host = host(info()) }
        package.loaded["lib/bookshelf_hero_modules"].navMove = function() return "a" end
        ed4:onEdRight()
        package.loaded["lib/bookshelf_hero_modules"].navMove = function() return nil end
        eq(ed4.session.selected_id, "a")
        assert(not ed4._key_focus, "an arrow on the grid moved focus onto the toolbar")
        ed4:onDone()
    end)
    _G.TEST_DPAD = nil
    assert(ok, err)
    -- A touch screen with no keys: no ring.
    local ed3 = Editor.open{ bw = {}, host = host(info()), select_id = "a" }
    assert(not ed3._key_focus, "a ring on a touch screen")
    ed3:onDone()
end)

-- A fake screen of grey values.
local function fakeBB(W, H, v)
    local px = {}
    local b = { getWidth = function() return W end, getHeight = function() return H end }
    function b:getPixel(x, y)
        local g = px[y * W + x] or v
        return { getColor8 = function() return { a = g } end }
    end
    function b:set(x, y, g) px[y * W + x] = g end
    return b
end

t.test("a repaint of the editor alone does not fade the faded screen again", function()
    local orig, faded = fakeBB(120, 120, 100), fakeBB(120, 120, 200)
    local keep = { { x = 0, y = 0, w = 60, h = 120 } }
    local marks = Editor._fadeMarks(orig, faded, keep)
    assert(#marks > 0)
    for _i, m in ipairs(marks) do assert(m.x >= 60, "a mark inside a kept rect") end
    -- The screen as the fade left it: still faded.
    eq(Editor._stillFaded(faded, marks), true)
    -- The shelf painted again under it: fade afresh.
    eq(Editor._stillFaded(orig, marks), false)
    -- The toolbar painted over a few marks: still faded.
    faded:set(marks[1].x, marks[1].y, 0)
    eq(Editor._stillFaded(faded, marks), true)
    -- A fade that changed nothing leaves nothing to go on: fade (a no-op).
    eq(#Editor._fadeMarks(orig, orig, keep), 0)
    eq(Editor._stillFaded(orig, {}), false)
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

-- Keys: Enter puts focus on the toolbar on screen (its buttons, the X
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
        -- The title's row (its X), then the toolbar's own rows.
        _bar_rows = { { btn("close", log) },
                      { btn("narrower", log), btn("wider", log) },
                      { btn("settings", log), btn("remove", log) } },
        _foot_rows = { { btn("add", log), btn("done", log) } },
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
    ed:onEdUp(); ed:onEdUp(); ed:onEdUp(); eq(log.focus, "close", "the title's X is above the toolbar")
    ed:onEdDown(); ed:onEdPress(); eq(log.pressed, "narrower")
end)

-- The toolbar's d-pad: the arrows move by where the buttons are on screen,
-- so Left from Right reaches Left over the empty middle, and Down from Up
-- reaches Down, not the next button in the row's list.
t.test("keys: the arrows walk the d-pad as it looks", function()
    -- Where the rig's portrait toolbar puts them.
    local log = {}
    local function at(name, x, y, w)
        local b = btn(name, log)
        b.dimen = { x = x, y = y, w = w or 92, h = 83 }
        return b
    end
    local ed = setmetatable({
        session = { selected_id = "a" },
        _bar_rows = { { at("close", 1068, 1122, 63) },
                      { at("up", 233, 1236), at("wminus", 589, 1236), at("wplus", 761, 1236),
                        at("settings", 906, 1236, 196) },
                      { at("left", 134, 1326), at("right", 332, 1326),
                        at("hminus", 589, 1326), at("hplus", 761, 1326),
                        at("style", 906, 1326, 196) },
                      { at("down", 233, 1416), at("prev", 589, 1416), at("next", 761, 1416),
                        at("remove", 906, 1416, 196) } },
        _foot_rows = { { at("add", 27, 1563, 139), at("newpage", 512, 1563, 187),
                         at("done", 1046, 1563, 163) } },
    }, { __index = Editor })
    ed._buildBands = function() end
    ed:onEdPress();  eq(log.focus, "up")
    ed:onEdDown();   eq(log.focus, "down", "Down from Up skipped the d-pad's middle")
    ed:onEdRight();  eq(log.focus, "prev", "Right from Down left its line")
    ed:onEdLeft();   eq(log.focus, "down")
    ed:onEdUp();     ed:onEdLeft(); eq(log.focus, "left", "Left from Up is the d-pad's Left")
    ed:onEdDown();   eq(log.focus, "down", "Down from Left went past the d-pad")
    ed:onEdUp();     ed:onEdLeft(); ed:onEdRight()
    eq(log.focus, "right", "Right from Left crossed the middle")
    ed:onEdRight();  eq(log.focus, "hminus", "Right from the d-pad reached Height")
    ed:onEdRight(); ed:onEdRight(); eq(log.focus, "style", "Style is level with Height")
    ed:onEdDown();   eq(log.focus, "remove", "Remove is under Style")
    ed:onEdUp(); ed:onEdUp(); eq(log.focus, "settings", "Settings is over Style")
    ed:onEdLeft();   eq(log.focus, "wplus")
    ed:onEdDown(); ed:onEdDown(); eq(log.focus, "next", "Page is below Height")
    ed:onEdRight();  eq(log.focus, "remove", "Remove is level with Page")
    ed:onEdLeft(); ed:onEdLeft(); eq(log.focus, "prev")
    ed:onEdDown();   eq(log.focus, "newpage", "the footer is below the toolbar")
    ed:onEdUp(); ed:onEdUp(); ed:onEdUp(); ed:onEdUp()
    eq(log.focus, "close", "the title's X is above the toolbar")
    ed:onEdRight();  eq(log.focus, "close", "Right from the X went to another line")
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
    assert(src:find('square_bottom = true, on_tap = function() self:_finish() end }', 1, true),
        "the Done button only steps out of the toolbar")
    assert(src:find("on_done = function() self:_finish() end", 1, true), "the actions dialog's Done steps out")
end)

t.test("keys: a greyed-out button is passed over by Enter", function()
    local ed, log = keyEd()
    ed._bar_rows[2][1].enabled = false
    ed:onEdPress()
    eq(log.focus, "wider", "focus started on a disabled button")
    ed:onEdLeft(); ed:onEdPress()
    eq(log.pressed, nil, "a disabled button was pressed")
end)

-- Closing the toolbar (its X): the refresh must cover where the toolbar
-- was. The rects were a table literal starting with the toolbar's rect, nil
-- once it had gone, and # of a table with a hole at 1 can be 0, so the old
-- toolbar's place was left out and it stayed on screen (rig).
t.test("closing the toolbar refreshes where it was", function()
    local inf = info()
    inf.container = { dimen = { x = 0, y = 0, w = 400, h = 300 } }
    local ed = Editor.open{ bw = {}, host = host(inf), select_id = "a" }
    ed._bar_rect = { x = 12, y = 1100, w = 1240, h = 400 }
    ed._footer_rect = { x = 0, y = 1600, w = 1264, h = 80 }
    for i = #dirty_fns, 1, -1 do dirty_fns[i] = nil end
    ed:_dirty()
    ed._bar_rect = nil   -- painted without a toolbar
    local _mode, r = dirty_fns[#dirty_fns]()
    assert(r and r.y <= 1100 and r.y + r.h >= 1500, "the old toolbar's place is not refreshed")
end)

t.done()
