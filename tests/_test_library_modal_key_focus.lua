-- tests/_test_library_modal_key_focus.lua
-- config.focus_on_key: the keys' focus ring stays hidden until the first key
-- press, which shows it (on the caller's cell when that is on the page shown,
-- else on the page's first) instead of moving it. The Theme library marks its
-- choice with a frame of its own, and a ring seeded on the first card while
-- the choice was on another page read as that mark (review, 2026-10-09).
package.path = "./?.lua;" .. package.path
local t  = dofile("tests/_helpers.lua").runner()
local eq = dofile("tests/_helpers.lua").eq
local src = io.open("lib/bookshelf_library_modal.lua"):read("*a")
local LibraryModal = {}
local function method(name)
    local body = src:match("(function LibraryModal:" .. name .. "%(.-\nend)\n")
    assert(body, "LibraryModal:" .. name .. " not found")
    assert(load("local LibraryModal = ...\n" .. body))(LibraryModal)
end
for _i, n in ipairs({ "_revealFocus", "_gridNav", "_gridCols", "onGridFocusDown", "onGridFocusRight", "onGridPress" }) do
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

t.test("init leaves the ring hidden when the caller asks for focus on the first key", function()
    assert(src:find("if total > 0 and not self.config.focus_on_key then self._dpad_idx = 1 end", 1, true),
        "the focus is seeded at open even with focus_on_key")
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

t.done()
