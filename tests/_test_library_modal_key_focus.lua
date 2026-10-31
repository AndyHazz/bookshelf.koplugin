-- tests/_test_library_modal_key_focus.lua
-- config.focus_on_key: the keys' focus ring stays hidden until the first key
-- press, which shows it (on the caller's cell when that is on the page shown,
-- else on the page's first) instead of moving it. The Theme library marks its
-- choice with a frame of its own, and a ring seeded on the first card while
-- the choice was on another page read as that mark (review, 2026-10-09).
package.path = "./?.lua;" .. package.path
-- The strip's Press sends a gesture: an event and a point.
package.loaded["ui/event"] = { new = function(_s, name, ...) return { name = name, args = { ... } } end }
package.loaded["ui/geometry"] = { new = function(_s, t) return t end }
package.loaded["ui/time"] = { now = function() return 0 end }
local t  = dofile("tests/_helpers.lua").runner()
local eq = dofile("tests/_helpers.lua").eq
local src = io.open("lib/bookshelf_library_modal.lua"):read("*a")
local LibraryModal = {}
local function method(name)
    local body = src:match("(function LibraryModal:" .. name .. "%(.-\nend)\n")
    assert(body, "LibraryModal:" .. name .. " not found")
    assert(load("local LibraryModal = ...\n" .. body))(LibraryModal)
end
for _i, n in ipairs({ "_revealFocus", "_cellsPerPage", "_gridNav", "_gridCols", "onGridFocusDown", "onGridFocusRight", "onGridPress",
                      "onGridFocusUp", "onGridFocusLeft", "_stripPos", "refreshCell" }) do
    method(n)
end

local function modal(focus, page, idx)
    local tapped = {}
    local m = setmetatable({
        page = page or 1, _dpad_idx = idx, _focus_zone = "grid", refreshes = 0, tapped = tapped,
        config = {
            item_count = function() return 10 end,
            cells_per_page = function() return 4 end,
            grid_cols = function() return 1 end,
            item_at = function(i) return i end,
            on_cell_tap = function(i) tapped[#tapped + 1] = i end,
            focus_on_key = focus,
        },
    }, { __index = LibraryModal })
    function m:refresh() self.refreshes = self.refreshes + 1 end
    return m
end

t.test("init leaves the ring hidden on every picker, until the first key", function()
    -- Seeded on the first card, it read as that card chosen (the outline that
    -- marks the one in use).
    assert(not src:find("self._dpad_idx = 1", 1, true), "the focus is seeded at open")
end)

t.test("with no focus_on_key the first key shows the ring on the page's first card", function()
    local m = modal(nil)
    m:onGridFocusDown()
    eq(m._dpad_idx, 1)
end)

t.test("the first key press shows the focus on the caller's cell, without moving", function()
    local m = modal(function() return 3 end)
    m:onGridFocusDown()
    eq(m._dpad_idx, 3, "the first press moved the focus or showed it elsewhere")
    eq(m.page, 1)
    m:onGridFocusDown()
    eq(m._dpad_idx, 4, "the second press did not move")
end)

t.test("a cell on another page: the page's first cell, and Press does not choose", function()
    local m = modal(function() return 7 end)
    m:onGridPress()
    eq(m._dpad_idx, 1); eq(#m.tapped, 0, "the press that showed the focus chose a card")
    m:onGridPress()
    eq(m.tapped[1], 1)
    local m2 = modal(function() return 7 end, 2)
    m2:onGridFocusRight()
    eq(m2._dpad_idx, 7, "the focus did not show on the caller's cell on the page shown")
end)

t.test("without focus_on_key nothing changes: a press moves at once", function()
    local m = modal(nil, 1, 1)
    m:onGridFocusDown()
    eq(m._dpad_idx, 2)
end)

-- STYLE.md: every popup takes the keys. The strip (its chips, a sort switch,
-- header buttons) could not be reached: Up at the grid's top row now goes
-- there, Down from its last row back to the grid, and Press taps it.
t.test("Up from the grid's top row reaches the strip; Down goes back; Press taps", function()
    local m = modal(nil, 1, 1)
    local pressed = {}
    local function w(name) return { name = name, dimen = { x = 0, y = 0, w = 10, h = 10 },
        handleEvent = function(_s, ev) if ev.args and ev.args[1] and ev.args[1].ges == "tap" then pressed[#pressed + 1] = name end; return true end } end
    m._strip_layout = { { w("A-Z"), w("Most") }, { w("Add") } }
    m:onGridFocusUp()
    eq(m._focus_zone, "strip"); eq(m._strip_row, 2)
    m:onGridFocusUp()
    eq(m._strip_row, 1)
    m:onGridFocusRight()
    eq(m._strip_col, 2)
    m:onGridPress()
    eq(pressed[1], "Most")
    m:onGridFocusDown(); m:onGridFocusDown()
    eq(m._focus_zone, "grid"); eq(m._dpad_idx, 1)
end)

t.test("the grid's ring shows only while the keys are on the grid", function()
    assert(src:find('local focused = modal._focus_zone == "grid" and modal._dpad_idx ~= nil and idx == modal._dpad_idx', 1, true),
        "the grid keeps its ring while the footer or strip has the keys")
end)

-- Perf review 2026-10-31: a tick in a multi-select picker built the whole
-- picker again and refreshed all of it, for one card.
t.test("refreshCell draws one card again and refreshes its box; off the page, all", function()
    local dirty = {}
    package.loaded["ui/uimanager"] = { setDirty = function(_s, _w, f) dirty[#dirty + 1] = { f() } end }
    -- the method was loaded before the stub: give it one through its globals
    UIManager = package.loaded["ui/uimanager"]
    local m = modal(nil, 1, nil)
    local item = { value = "Crime" }
    local ic = { dimen = { x = 10, y = 20, w = 100, h = 50 } }
    m._cell_slots = { [item] = { ic = ic, idx = 3 } }
    m._build_cell = function(idx, it) return { built = idx, item = it } end
    m:refreshCell(item)
    eq(ic[1].built, 3)
    eq(#dirty, 1); eq(dirty[1][1], "ui"); eq(dirty[1][2].w, 100)
    eq(m.refreshes, 0, "the whole picker was built again")
    m:refreshCell({ value = "elsewhere" })
    eq(m.refreshes, 1, "a card off the page did not fall back to a full refresh")
    local ed = io.open("lib/bookshelf_chip_editor.lua"):read("*a")
    assert(ed:find("modal:refreshCell(item)", 1, true), "the filter picker's tick refreshes the whole picker")
end)

t.done()
