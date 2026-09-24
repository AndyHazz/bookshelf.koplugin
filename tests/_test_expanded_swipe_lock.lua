-- tests/_test_expanded_swipe_lock.lua
-- Issue 366: "Swipe down leaves full screen shelves". On (the default) a
-- swipe down in full screen brings the top panel back, as it always has; off,
-- full screen stays and the swipe refreshes the library when it starts on the
-- shelf, as it does with the top panel showing.
--
-- onSwipeShelvesDown is extracted from the widget by name; its upvalues
-- become stubbable globals. Run from the plugin root.
package.path = "./?.lua;./?/init.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()
local src = io.open("lib/bookshelf_widget.lua"):read("*a")
local body = assert(src:match("\nfunction BookshelfWidget:onSwipeShelvesDown%(_, ges%)\n(.-)\nend\n"),
    "could not find onSwipeShelvesDown")
local code = "return function(self, _, ges)\n" .. body .. "\nend"

local store = {}
local function handler()
    local env = {
        BookshelfSettings = { nilOrTrue = function(k) local v = store[k]; return v == nil or v == true end },
        _gettime = function() return 0 end,
        UIManager = { setDirty = function() end },
        logger = { dbg = function() end },
        string = string,
        Repo = { buildBook = function() return nil end },
    }
    local f
    if _G.setfenv then f = assert(loadstring(code)); setfenv(f, env)
    else f = assert(load(code, "swipe", "t", env)) end
    return f()
end

local function widget(on_shelf)
    local w = { _expanded = true, calls = {} }
    function w:_selectedFilepath() return nil end
    function w:_setExpanded(v) self._expanded = v; self.calls[#self.calls + 1] = "expanded=" .. tostring(v) end
    function w:_rebuild() end
    function w:_isShelfSwipe() return on_shelf end
    function w:_refreshLibrary() self.calls[#self.calls + 1] = "refresh" end
    return w
end

t.test("by default a swipe down leaves full screen", function()
    store = {}
    local w = widget(true)
    assert(handler()(w, nil, {}) == true)
    assert(w._expanded == false and w.calls[1] == "expanded=false", table.concat(w.calls, ","))
end)

t.test("switched off, full screen stays and a shelf swipe refreshes", function()
    store = { expanded_swipe_back = false }
    local w = widget(true)
    assert(handler()(w, nil, {}) == true)
    assert(w._expanded == true, "left full screen")
    assert(w.calls[1] == "refresh", table.concat(w.calls, ","))
end)

t.test("switched off, a swipe elsewhere passes through", function()
    store = { expanded_swipe_back = false }
    local w = widget(false)
    assert(handler()(w, nil, {}) == false)
    assert(w._expanded == true and #w.calls == 0)
end)

t.done()
