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
    local kit = io.open("lib/bookshelf_popup_kit.lua"):read("*a")
    local fr = kit:match("\n(function Kit%.footerRow%(.-\nend)\n")
    assert(pd:find("footerRow(actions, w,", 1, true) and fr and fr:find("Kit.ringFocus(btn", 1, true),
        "PageDialog footer inverts")
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

t.test("keyFocus: the keys pass over a control that can't act", function()
    local off = { enabled = false }
    local a, b, c = {}, {}, {}
    local f = { layout = { { off }, { a, off, b }, { c } }, selected = { x = 1, y = 1 },
        onFocusMove = function() return true end, moveFocusTo = function() end }
    Kit.keyFocus(f, {}, 2, "p")
    eq(#f.layout, 2, "a row with nothing that can act is still a stop")
    eq(#f.layout[1], 2); assert(f.layout[1][1] == a and f.layout[1][2] == b, "a greyed button is still a stop")
    eq(f.selected.y, 1, "the seed did not follow its row")
end)

-- Review 2026-10-31: the cursor was kept by its index in the row left after
-- the greyed ones went, so -5 greying at the minimum put it on +10 (the row
-- {-10, -5, +5, +10} became {+5, +10}, and x = 2 was +10).
t.test("keyFocus: a rebuild keeps the cursor by place, the nearest live one if it greyed", function()
    local function fm(layout)
        local f = { layout = layout, selected = { x = 1, y = 1 } }
        f.onFocusMove = function(self, args) self.selected.x = self.selected.x + args[1]; return true end
        f.moveFocusTo = function(self, x, y) self.selected = { x = x, y = y } end
        return f
    end
    local m10, m5, p5, p10 = {}, {}, {}, {}
    local state = {}
    local a = fm({ { m10, m5, p5, p10 } })
    Kit.keyFocus(a, state, 1, "p")
    a:onFocusMove({ 0, 0 })                 -- shows it, on -10
    a:onFocusMove({ 1, 0 })                 -- on -5
    eq(a.selected.x, 2)
    local b = fm({ { { enabled = false }, { enabled = false }, p5, p10 } })
    Kit.keyFocus(b, state, 1, "p")
    assert(b.layout[b.selected.y][b.selected.x] == p5, "the cursor jumped past the nearest live button")
    -- Back to live: where it was.
    local c = fm({ { m10, m5, p5, p10 } })
    Kit.keyFocus(c, state, 1, "p")
    assert(c.layout[c.selected.y][c.selected.x] == m5, "the cursor did not keep its place")
end)

t.test("the shelf editor quiets its foot row and seeds on the first card", function()
    local src = io.open("lib/bookshelf_chip_editor.lua"):read("*a")
    assert(src:find("Kit.quietFocus(foot)", 1, true), "the foot row still takes the keys")
    assert(src:find('Kit.keyFocus(button_table, key_state, #strip_focus > 0 and 2 or 1, "main")', 1, true),
        "the cursor does not start on the first card")
    local pd = io.open("lib/bookshelf_page_dialog.lua"):read("*a")
    assert(pd:find("keyFocus(fm, self._key_state, 1, self.pg)", 1, true), "page dialogs have no cursor seed")
end)

-- The book popup and the shelf footer (maintainer, desktop): a tab's focus
-- is the inset ring, not the cell inverted; the description's source
-- switch takes the keys; stars and pills ring rather than invert; the
-- footer's ring is round the icon, in the footer's own ink.
t.test("book popup and footer: rings, not inversions; every control keyed", function()
    local rm = io.open("lib/bookshelf_reviews_modal.lua"):read("*a")
    assert(rm:find("Kit.invertRing(bb,\n            x + self._tab_x[self._focused_idx] + inset,", 1, true),
        "a focused tab is not ringed")
    assert(rm:find("strip.seg_rows = seg_rows", 1, true)
           and rm:find("local focus = body.seg_rows and { layout = { body.seg_rows[1] },", 1, true),
        "the source switch is not keyed")
    local w = io.open("lib/bookshelf_widget.lua"):read("*a")
    assert(w:find('ringFocus(pill, 0, Space.radius.button)', 1, true), "a focused pill is inverted")
    assert(w:find('ringFocus(star, 0, Space.px(4))', 1, true), "a focused star is inverted")
    assert(not w:find("star.onFocus = function() frame.invert = true", 1, true), "a star still inverts")
    local fr = w:match("\nfunction BookshelfWidget%._footerFocusRing%(widget, content_size, below, ink%)(.-)\nend\n")
    assert(fr and fr:find("Color.paintBorder(", 1, true) and fr:find("ink or Blitbuffer.COLOR_BLACK", 1, true),
        "the footer ring is not in the footer's ink")
    assert(w:find("hit_extension, self:_chromeInk())", 1, true), "the footer ring does not take the chrome ink")
end)

-- The shelf menu bar and the shelf (maintainer, desktop): a chip's focus is
-- a ring inside it in its own text colour, over its look (the selected chip
-- stays black); crumbs ring too; the cover's ring goes when the keys leave
-- the grid.
t.test("shelf menu bar and shelf: chip and crumb rings; the cover's ring follows the keys", function()
    local cb = io.open("lib/bookshelf_chip_bar.lua"):read("*a")
    assert(not cb:find("is_cursor", 1, true) and cb:find("if is_active then fill_c, ink_c = _activeChipColors() end", 1, true),
        "the cursor still clears the selected chip's fill")
    assert(cb:find("if is_active and has_custom then ring_c = ink_c", 1, true)
           and cb:find("elseif is_active then ring_c = ink:invert()", 1, true),
        "the chip ring is not in the chip's own ink")
    assert(not cb:find("bordersize = pb,\n                    color      = Blitbuffer.COLOR_BLACK", 1, true),
        "the crumb ring is still a black box")
    local w = io.open("lib/bookshelf_widget.lua"):read("*a")
    assert(w:find('local on_grid = self._focus_zone == nil or self._focus_zone == "grid"', 1, true),
        "the cover keeps its ring off the grid")
    assert(w:find('for _i, name in ipairs({ "onBSFocusUp", "onBSFocusDown", "onBSFocusLeft", "onBSFocusRight" }) do', 1, true),
        "a zone change does not repaint the ring")
end)

t.done()
