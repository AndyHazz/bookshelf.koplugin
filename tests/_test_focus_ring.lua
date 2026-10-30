-- tests/_test_focus_ring.lua
-- The keys' focus ring on a segmented control's cell sat on the cell's
-- edge, square: at the control's rounded ends its corners stuck out past
-- the outline, and it ran over the outline and dividers ("[" shapes,
-- maintainer: the focus highlight should look cleaner). A segment's ring is
-- set in from the cell's edge, its corners rounded, so it never touches
-- the control's outline.
--
-- Usage (from plugin root): lua tests/_test_focus_ring.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq

local stack, dirty = {}, {}
package.loaded["ui/uimanager"] = {
    widgetRepaint = function() end,
    forceRePaint = function() end,
    yieldToEPDC = function() end,
    setDirty = function(_s, w, mode, box) dirty[#dirty + 1] = { w = w, mode = mode, box = box } end,
    getTopmostVisibleWidget = function() return stack[#stack] end,
    isWidgetShown = function(_s, w)
        for _i, s in ipairs(stack) do if s == w then return true end end
        return false
    end,
    tickAfterNext = function(_s, f) f() end,
}
local function widget()
    local C = {}
    function C:new(o) return o or {} end
    function C:extend(o) o = o or {}; return setmetatable(o, { __index = self }) end
    return C
end
for _i, name in ipairs({ "ui/widget/container/centercontainer", "ui/widget/container/framecontainer",
        "ui/widget/horizontalgroup", "ui/widget/horizontalspan", "ui/widget/container/inputcontainer",
        "ui/widget/container/widgetcontainer" }) do
    package.loaded[name] = widget()
end
package.loaded["ffi/blitbuffer"] = { COLOR_BLACK = 0, COLOR_WHITE = 1, COLOR_DARK_GRAY = 2,
    COLOR_LIGHT_GRAY = 3, gray = function(v) return v end, Color8 = function(v) return v end }
package.loaded["ui/geometry"] = { new = function(_s, o) return o end }
package.loaded["ui/gesturerange"] = { new = function(_s, o) return o end }
package.loaded["ui/size"] = setmetatable({}, { __index = function() return setmetatable({}, { __index = function() return 1 end }) end })
package.loaded["device"] = { screen = { scaleBySize = function(_s, v) return v end } }
package.loaded["lib/bookshelf_space"] = setmetatable({ px = function(v) return v end },
    { __index = function() return setmetatable({}, { __index = function() return 1 end }) end })
package.loaded["lib/bookshelf_colour_text"] = { new = function(_s, o)
    o.getSize = function() return { w = 60, h = 30 } end
    return o
end }
package.loaded["ui/widget/container/inputcontainer"].paintTo = function() end
local Kit = require("lib/bookshelf_popup_kit")


local function paintRecorder()
    local rects = {}
    return { invertRect = function(_s, x, y, w, h) rects[#rects + 1] = { x, y, w, h } end }, rects
end

t.test("a cell's ring keeps inside its focus inset", function()
    local cell = Kit.tapCell({}, 200, 60, function() end)
    cell.focus_inset, cell.focus_radius = 6, 8
    cell._focused = true
    local bb, rects = paintRecorder()
    cell:paintTo(bb, 100, 50)
    assert(#rects > 0, "no ring painted")
    for _i, r in ipairs(rects) do
        assert(r[1] >= 106 and r[2] >= 56 and r[1] + r[3] <= 294 and r[2] + r[4] <= 104,
            "the ring reaches the cell's edge")
    end
end)

t.test("a segmented control's cells get a set-in, rounded ring", function()
    local _seg, focus = Kit.segmented{ items = { { key = "a", label = "A" }, { key = "b", label = "B" } },
        active = "a", face = {} }
    for _i, cell in ipairs(focus[1]) do
        assert((cell.focus_inset or 0) > Kit.BORDER, "the ring sits on the outline")
        assert((cell.focus_radius or 0) > 0, "the ring is square")
    end
end)

-- KOReader's own Button shows focus by inverting the whole button: in our
-- footers a focused Cancel looked like one that is on (black means "on").
t.test("a stock button given the ring is not inverted, and rings inside its inset", function()
    local frame = { invert = false }
    local btn = { frame = frame, getSize = function() return { w = 300, h = 80 } end,
                  paintTo = function() end }
    Kit.ringFocus(btn, 5, 8)
    btn:onFocus()
    eq(frame.invert, false)
    local bb, rects = paintRecorder()
    btn:paintTo(bb, 0, 0)
    assert(#rects > 0, "no ring painted")
    for _i, r in ipairs(rects) do
        assert(r[1] >= 5 and r[2] >= 5 and r[1] + r[3] <= 295 and r[2] + r[4] <= 75, "the ring leaves the inset")
    end
    btn:onUnfocus()
    bb, rects = paintRecorder()
    btn:paintTo(bb, 0, 0)
    eq(#rects, 0)
end)

t.test("the page dialog's and the book popup's footers ring their buttons", function()
    local pd = io.open("lib/bookshelf_page_dialog.lua"):read("*a")
    assert(pd:find("Kit.ringFocus(btn", 1, true) or pd:find("ringFocus(btn", 1, true), "PageDialog footer inverts")
    local rm = io.open("lib/bookshelf_reviews_modal.lua"):read("*a")
    assert(rm:find("ringFocusTable(bt", 1, true), "the book popup's footer inverts")
end)

-- Keys in our popups (maintainer, desktop: the shelf editor took no keys).
package.loaded["ui/widget/focusmanager"] = { FORCED_FOCUS = 4 }

t.test("quietFocus: an inner FocusManager lets the outer one have the keys", function()
    local inner = { key_events = { FocusDown = {} } }
    Kit.quietFocus(inner)
    eq(next(inner.key_events), nil)
    for _i, h in ipairs({ "onFocusMove", "onFocusHalfMove", "onFocusNext", "onFocusPrevious", "onPress", "onHold" }) do
        eq(inner[h](inner, { 0, 1 }), false, h .. " still takes the key")
    end
end)

t.test("keyFocus: seeded on its row, shown at the first key, kept across a rebuild", function()
    local moves, focused = 0, {}
    local function fm()
        local f = { layout = { { "a" }, { "b", "c" }, { "d" } }, selected = { x = 1, y = 1 } }
        f.onFocusMove = function(self, args) moves = moves + 1; self.selected.y = self.selected.y + args[2]; return true end
        f.moveFocusTo = function(self, x, y) focused[#focused + 1] = x .. "," .. y; self.selected = { x = x, y = y } end
        return f
    end
    local state = {}
    local a = fm()
    Kit.keyFocus(a, state, 2, "main")
    eq(a.selected.y, 2, "not seeded on its row")
    eq(#focused, 0, "the ring shows before a key")
    a:onFocusMove({ 0, 1 })
    eq(moves, 0, "the first key moved the cursor")
    eq(focused[1], "1,2", "the first key did not show it where it was seeded")
    a:onFocusMove({ 0, 1 })
    eq(a.selected.y, 3)
    -- Rebuilt (every change rebuilds): where it was, and showing.
    local b = fm()
    Kit.keyFocus(b, state, 2, "main")
    eq(b.selected.y, 3); eq(focused[#focused], "1,3")
    -- Another page seeds afresh.
    local c = fm()
    Kit.keyFocus(c, state, 1, "page")
    eq(c.selected.y, 1)
end)

t.test("the shelf editor quiets its foot row and seeds on the first card", function()
    local src = io.open("lib/bookshelf_chip_editor.lua"):read("*a")
    assert(src:find("Kit.quietFocus(foot)", 1, true), "the foot row still takes the keys")
    assert(src:find('Kit.keyFocus(button_table, key_state, #strip_focus > 0 and 2 or 1, "main")', 1, true),
        "the cursor does not start on the first card")
    local pd = io.open("lib/bookshelf_page_dialog.lua"):read("*a")
    assert(pd:find("keyFocus(fm, self._key_state, 1, self.pg)", 1, true), "page dialogs have no cursor seed")
end)

t.done()
