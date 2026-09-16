-- tests/_test_spine_selection_repaint.lua
-- The first tap on a spine shelf must lift the book.
--
-- WHAT NEEDS PINNING. _repaintSpineSelection(old_fp, new_fp) is asked with
-- old_fp = nil on the first tap after a shelf is built. It walked
-- `ipairs({ old_fp, new_fp })`, and ipairs stops at the first nil: with a nil
-- old key the loop never ran for the NEW one, so the slot was found in the
-- registry (the diagnostic printed it) and never flipped. Every later tap
-- has a non-nil old key and works, which is how this hid behind "the first
-- tap after a restart never lifts" through two rounds of fixes, one of which
-- papered over it with a full rebuild.
--
-- Usage (from plugin root): lua tests/_test_spine_selection_repaint.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

-- Pull the method out of the widget by name and run it against a fake self;
-- its upvalues become globals we stub (see reference_widget_body_extraction).
local src = io.open("lib/bookshelf_widget.lua"):read("a")
local body = src:match("\nfunction BookshelfWidget:_repaintSpineSelection%(old_fp, new_fp%)\n.-\nend\n")
assert(body, "could not locate _repaintSpineSelection")
local chunk = body:gsub("^\nfunction BookshelfWidget:_repaintSpineSelection%(", "return function(self, ")
local dirty = {}
local env = setmetatable({
    _gettime = function() return 0 end,
    logger   = { dbg = function() end, info = function() end, warn = function() end },
    Screen   = { scaleBySize = function(_s, n) return n end },
    UIManager = { setDirty = function(_u, _w, how) dirty[#dirty + 1] = how end },
    BookshelfWidget = {},
}, { __index = _G })
local fn = assert(load(chunk, "repaint", "t", env))()

local function geom(x, y, w, h)
    local g = { x = x, y = y, w = w, h = h }
    g.copy = function(s) return geom(s.x, s.y, s.w, s.h) end
    return g
end
local function shelf(slots_per_row)
    -- Two rows, each an OverlapGroup{ plank, recess, HorizontalGroup } with
    -- the slot registry rowWidget attaches.
    local vg = { [1] = "hero", [2] = "chips" }
    local self = { _shelf_dims = { n_shelves = 2, shelf_top_idx = 3 }, _inner_vgroup = vg,
                   _swapShelvesInPlace = function(s) s._swapped = true end }
    for r = 1, 2 do
        local row = { "plank", "recess", {} }
        row._slots_by_fp = {}
        for _, fp in ipairs(slots_per_row[r] or {}) do
            row._slots_by_fp[fp] = { entry = {}, book = { filepath = fp },
                                     dimen = geom(10 * r, 100 * r, 30, 300), is_selected = false }
        end
        vg[3 + 2 * (r - 1)] = row
    end
    return self
end

t.test("first tap: a nil old key still flips the new slot", function()
    local self = shelf{ { "/a.epub", "/b.epub" }, { "/c.epub" } }
    dirty = {}
    fn(self, nil, "/b.epub")
    eq(self._inner_vgroup[3]._slots_by_fp["/b.epub"].is_selected, true,
        "the tapped book was not lifted")
    eq(#dirty, 1, "exactly one repaint")
    assert(type(dirty[1]) == "function", "the repaint should be scoped to the slot, not the widget")
end)

t.test("later tap: the old slot drops and the new one lifts", function()
    local self = shelf{ { "/a.epub", "/b.epub" }, { "/c.epub" } }
    self._inner_vgroup[3]._slots_by_fp["/b.epub"].is_selected = true
    dirty = {}
    fn(self, "/b.epub", "/c.epub")
    eq(self._inner_vgroup[3]._slots_by_fp["/b.epub"].is_selected, false)
    eq(self._inner_vgroup[5]._slots_by_fp["/c.epub"].is_selected, true)
    eq(#dirty, 1)
end)

t.test("a book that is not on the page flips nothing and repaints nothing", function()
    local self = shelf{ { "/a.epub" }, {} }
    dirty = {}
    fn(self, nil, "/zzz.epub")
    eq(#dirty, 0)
end)

t.test("a face-out on the page rebuilds the rows instead", function()
    local self = shelf{ { "/a.epub" }, {} }
    self._inner_vgroup[3]._slots_by_fp["/a.epub"].entry = nil   -- a face-out wrapper
    fn(self, nil, "/a.epub")
    eq(self._swapped, true)
end)

t.done()
