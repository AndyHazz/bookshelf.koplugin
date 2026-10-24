-- tests/_test_drop_lift.lua
-- A tap on empty space drops the lifted book back onto the shelf (maintainer:
-- "tapping anywhere off the book in empty space should drop the book back").
-- _dropLift is pulled out of the widget by name and run against a stub, and
-- handleEvent is checked to offer it a tap only after our own widgets and
-- KOReader's touch zones have passed on it.
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq
local src = io.open("lib/bookshelf_widget.lua"):read("*a")
local body = src:match("\n(function BookshelfWidget:_dropLift%(.-\nend)\n")
local shown_body = src:match("\n(function BookshelfWidget:_liftShown%(.-\nend)\n")
local dirty_body = src:match("\n(function BookshelfWidget:_dirtyDroppedBook%(.-\nend)\n")

local dirty = {}
local function load_drop()
    assert(body, "no BookshelfWidget:_dropLift")
    local env = setmetatable({
        BookshelfWidget = {},
        Screen = { scaleBySize = function(_s, v) return v end },
        UIManager = { setDirty = function(_u, w, f) dirty[#dirty + 1] = { w, f } end },
    }, { __index = _G })
    assert(shown_body, "no BookshelfWidget:_liftShown")
    assert(dirty_body, "no BookshelfWidget:_dirtyDroppedBook")
    local chunk = assert((loadstring or load)(shown_body .. "\n" .. dirty_body .. "\n" .. body, "=_dropLift", "t", env))
    if setfenv then setfenv(chunk, env) end
    chunk()
    return function(w)
        w._liftShown = env.BookshelfWidget._liftShown
        w._dirtyDroppedBook = env.BookshelfWidget._dirtyDroppedBook
        return env.BookshelfWidget._dropLift(w)
    end
end

local function widget(o)
    local w = { calls = {}, _spine_lift_headroom = 8 }
    for k, v in pairs(o) do w[k] = v end
    function w:_selectedFilepath()
        if self._cursor_idx then return "cursor.epub" end
        return self._tap_selected_fp or (self._preview_book and self._preview_book.filepath)
    end
    function w:_shelfSlotRect(fp)
        if fp == self.visible then return { x = 10, y = 100, w = 20, h = 80, copy = function(r) return r end } end
    end
    function w:_repaintSelectionHighlight(a, b) self.calls[#self.calls + 1] = { "repaint", a, b } end
    function w:_rebuildRefreshHeroAndChips() self.calls[#self.calls + 1] = { "hero" } end
    return w
end

t.test("a tap-twice lift drops, and only its slot repaints", function()
    local drop = load_drop()
    local w = widget{ _tap_selected_fp = "a.epub", visible = "a.epub" }
    eq(drop(w), true)
    eq(w._tap_selected_fp, nil)
    eq(w.calls[1], { "repaint", "a.epub", nil })
end)

t.test("a previewed book drops: the hero goes back to the book being read", function()
    local drop = load_drop()
    dirty = {}
    local w = widget{ _preview_book = { filepath = "b.epub" }, _hero_mode = "preview", visible = "b.epub" }
    eq(drop(w), true)
    eq(w._preview_book, nil); eq(w._hero_mode, "current")
    eq(w.calls[1], { "hero" })
    eq(#dirty, 1, "the row the book stood out of is refreshed too")
    local _mode, r = dirty[1][2]()
    -- The book's rect was y=100 h=80 (lifted); it lands lower, so the
    -- refresh reaches below it as well as above (a face-out's foot and the
    -- lift shadow it leaves). pad = max(12, headroom 8) = 12 here.
    assert(r.y < 100 and r.y + r.h >= 100 + 80 + 12, "the refresh does not reach where the book lands")
end)

t.test("nothing lifted on this page: the tap is left alone", function()
    local drop = load_drop()
    local w = widget{ _preview_book = { filepath = "b.epub" }, visible = "other.epub" }
    eq(drop(w), false); eq(w._preview_book.filepath, "b.epub")
    eq(drop(widget{}), false)
end)

t.test("a d-pad cursor, or bulk selection, is not a lift to drop", function()
    local drop = load_drop()
    eq(drop(widget{ _cursor_idx = 3, visible = "cursor.epub" }), false)
    local w = widget{ _tap_selected_fp = "a.epub", visible = "a.epub",
                      _selection = { isActive = function() return true end } }
    eq(drop(w), false); eq(w._tap_selected_fp, "a.epub")
end)

t.test("handleEvent offers a tap to _dropLift after our widgets and KOReader's zones", function()
    local he = src:match("function BookshelfWidget:handleEvent%(event%)(.-)\nend\n")
    assert(he, "handleEvent moved")
    local kids = he:find("InputContainer.handleEvent(self, event)", 1, true)
    local fmz = he:find("GestureZones.tryLiveZones(ev)", 1, true)
    local drop = he:find("self:_dropLiftOnTap(ev)", 1, true)
    assert(kids and fmz and drop and kids < fmz and fmz < drop, "the drop runs before something that should come first")
    local tap = src:match("function BookshelfWidget:_dropLiftOnTap%(ev%)(.-)\nend\n")
    assert(tap and tap:find('ev.ges ~= "tap"', 1, true), "the drop is not limited to a plain tap")
end)

-- The slot's tap range is its whole column, so the wall above a short book
-- is that book's. While another book is lifted, a tap there must fall
-- through to _dropLift instead of lifting the short book.
local sss = io.open("lib/bookshelf_spine_shelf.lua"):read("*a")
local ontap = sss:match("\n(function SpineBookSlot:onTap%(.-\nend)\n")
local function load_ontap(tapped)
    assert(ontap, "no SpineBookSlot:onTap")
    local env = setmetatable({
        SpineBookSlot = {},
        SpineShelf = {},
        Screen = { scaleBySize = function(_s, v) return v end },
        _itemCallback = function(cbs, book, kind) return function(b) tapped[#tapped + 1] = b end end,
    }, { __index = _G })
    local chunk = assert((loadstring or load)(ontap, "=onTap", "t", env))
    if setfenv then setfenv(chunk, env) end
    chunk()
    return env.SpineBookSlot.onTap
end
local function slot(lift_shown, selected)
    return { is_selected = selected, height = 300, entry = { h = 200 }, book = { filepath = "short.epub" },
             dimen = { x = 0, y = 1000, w = 30, h = 300 },
             callbacks = { lift_shown = function() return lift_shown end } }
end
local function at(y) return { pos = { x = 10, y = y } } end

t.test("the wall above a short spine drops another lifted book, and does not lift this one", function()
    local tapped = {}
    local tap = load_ontap(tapped)
    eq(tap(slot(true, false), nil, at(1020)), false, "a tap above the book falls through")
    eq(#tapped, 0)
    eq(tap(slot(true, false), nil, at(1200)), true, "a tap on the book itself still picks it")
    eq(#tapped, 1)
end)

t.test("with nothing lifted, the whole column still picks the book", function()
    local tapped = {}
    local tap = load_ontap(tapped)
    eq(tap(slot(false, false), nil, at(1020)), true)
    eq(tap(slot(true, true), nil, at(1020)), true, "the lifted book's own column is its own")
end)

t.test("a tap on the hero's blank area leaves the previewed book as it is", function()
    local b = src:match("\n(function BookshelfWidget:_dropLiftOnTap%(.-\nend)\n")
    assert(b, "no _dropLiftOnTap")
    local env = setmetatable({ BookshelfWidget = {} }, { __index = _G })
    local chunk = assert((loadstring or load)(b, "=_dropLiftOnTap", "t", env))
    if setfenv then setfenv(chunk, env) end
    chunk()
    local dropped = 0
    local w = { _hero_card = { dimen = { x = 0, y = 0, w = 1236, h = 480 } },
                _dropLift = function() dropped = dropped + 1; return true end }
    eq(env.BookshelfWidget._dropLiftOnTap(w, { ges = "tap", pos = { x = 600, y = 300 } }), false)
    eq(dropped, 0)
    eq(env.BookshelfWidget._dropLiftOnTap(w, { ges = "tap", pos = { x = 600, y = 900 } }), true)
end)

t.done()
