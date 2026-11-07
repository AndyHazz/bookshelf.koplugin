-- tests/_test_breadcrumb_edit.lua
-- Inside a shelf of shelves, a tap on the crumb of the shelf on screen opens
-- that shelf's settings, as a tap on the current shelf's button does at the
-- top level (behind the same switch, edit_shelf_tap). Any other crumb still
-- climbs to its level, and a crumb with folders open below it still closes
-- them first.
-- Run from the plugin root: lua tests/_test_breadcrumb_edit.lua
package.path = "./?.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq

local src = io.open("lib/bookshelf_widget.lua"):read("*a")
local body = src:match("\nfunction BookshelfWidget:_onBreadcrumb%(depth, in_search%)\n(.-)\nend\n")

local switch_on = true
local edited
local function method()
    assert(body, "BookshelfWidget:_onBreadcrumb(depth, in_search) is missing")
    local env = setmetatable({
        Gestures = { on = function(id) return id == "edit_shelf_tap" and switch_on end },
        require = function(name)
            if name == "lib/bookshelf_chip_editor" then
                return { editTab = function(_e, id, opts) edited = { id = id, opts = opts } end }
            end
            return require(name)
        end,
    }, { __index = _G })
    return assert(load("return function(self, depth, in_search)\n" .. body .. "\nend", "crumb", "t", env))()
end

local function shelf(depth_chain, drills)
    local s = { chip = "sub", _drilldown_path = drills or {}, went = nil, dialog = nil }
    s._shelfCrumbCount = function() return depth_chain end
    s._navBackTo = function(self, d) self.went = d end
    s._drillBackTo = function(self, d) self.went = "drill" .. d end
    s._openSearchDialog = function(self, q) self.dialog = q end
    s._afterChipEdit = function() end
    return s
end

t.test("the crumb of the shelf on screen opens its settings", function()
    edited = nil; switch_on = true
    local s = shelf(1)          -- one shelf below the top: crumb 1 is this one
    method()(s, 1, false)
    assert(edited, "the shelf's settings did not open")
    eq(edited.id, "sub"); eq(edited.opts.bw, s)
    eq(s.went, nil, "it also navigated")
end)

t.test("other crumbs still climb, and folders open below close first", function()
    edited = nil; switch_on = true
    local s = shelf(2)
    method()(s, 1, false)       -- the parent shelf's crumb
    eq(s.went, 1); eq(edited, nil)
    method()(s, 0, false)       -- the top shelf's pill
    eq(s.went, 0); eq(edited, nil)
    local d = shelf(1, { { kind = "series" } })
    method()(d, 1, false)       -- this shelf's crumb, a stack open below it
    eq(d.went, 1, "the open stack was not closed"); eq(edited, nil)
end)

t.test("with the switch off it does nothing, as the shelf button does", function()
    edited = nil; switch_on = false
    local s = shelf(1)
    method()(s, 1, false)
    eq(edited, nil, "edit_shelf_tap off, the settings opened anyway")
    switch_on = true
end)

t.test("search keeps its own crumbs, and a top-level shelf is unaffected", function()
    edited = nil
    local s = shelf(0, { { kind = "search", payload = { query = "x" } } })
    method()(s, 1, true)
    eq(s.dialog, "x"); eq(edited, nil)
    method()(s, -1, true)
    eq(s.went, "drill0")
    local top = shelf(0)
    method()(top, 0, false)
    eq(top.went, 0); eq(edited, nil)
end)

t.done()
