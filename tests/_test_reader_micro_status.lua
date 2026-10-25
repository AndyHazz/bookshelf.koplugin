-- tests/_test_reader_micro_status.lua
-- The full-screen micro-modules view opened from inside a book shows the
-- shelf's status line, and keeps it (and its clock cells) current with its
-- own minute tick: the shelf's tick does not run in the reader.
--
-- Usage (from plugin root): lua tests/_test_reader_micro_status.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local t  = dofile("tests/_helpers.lua").runner()
local eq = dofile("tests/_helpers.lua").eq

local src = io.open("main.lua"):read("*a")
local body = src:match("\n(function Bookshelf:_openReaderMicroModules%(.-\nend)\n")
assert(body, "_openReaderMicroModules moved")

local function setup()
    local env = {}
    local scheduled = {}
    local shown = {}
    local UM = {}
    function UM:scheduleIn(s, fn) scheduled[#scheduled + 1] = { s = s, fn = fn } end
    function UM:unschedule(fn)
        for i = #scheduled, 1, -1 do if scheduled[i].fn == fn then table.remove(scheduled, i) end end
    end
    function UM:isWidgetShown(w) return shown[w] or false end
    local opened
    local view = { refreshed = 0 }
    function view:refreshStatus() self.refreshed = self.refreshed + 1 end
    local ticks = 0
    local BW = { invalidated = 0 }
    function BW._currentHeroBook(self) self._asked = true; return { title = "Reading" } end
    function BW._buildDeviceState() return { battery = 80 } end
    function BW.invalidateDeviceState() BW.invalidated = BW.invalidated + 1 end
    local loaded = {
        ["lib/bookshelf_micro_fullscreen"] = { open = function(shim)
            opened = shim; shim._micro_fullscreen = view; shown[view] = true; return view end },
        ["device"] = { screen = { scaleBySize = function(_s, v) return v end } },
        ["lib/bookshelf_footer_geom"] = { hitExtension = function() return 0 end,
                                          barMetrics = function() return { bar_t = 1 } end },
        ["lib/bookshelf_reader_buttons"] = { side = function() return "right" end,
            gridOverlayRect = function() return { x = 0, y = 0, w = 10, h = 10 } end,
            overlayRect = function() return { x = 0, y = 0, w = 10, h = 10 } end,
            showMenu = function() return true end },
        ["lib/bookshelf_widget"] = BW,
        ["lib/bookshelf_hero_modules"] = { tickClocks = function(bw) ticks = ticks + 1; return bw end },
    }
    setmetatable(env, { __index = _G })
    env.UIManager = UM
    env.require = function(name)
        local m = loaded[name]
        if m == nil then error("unexpected require " .. name) end
        return m
    end
    env.Bookshelf = {}
    assert(load(body, "_openReaderMicroModules", "t", env))()
    env.Bookshelf._openReaderMicroModules({})
    return {
        shim = function() return opened end, view = view, shown = shown, BW = BW,
        scheduled = scheduled, ticks = function() return ticks end,
    }
end

t.test("the view gets the book being read and the device state for its status line", function()
    local s = setup()
    local shim = s.shim()
    assert(shim, "the view did not open")
    assert(shim._currentHeroBook, "no current book: the status line is dropped")
    eq(shim:_currentHeroBook().title, "Reading")
    eq(shim:_buildDeviceState().battery, 80)
end)

t.test("a minute tick refreshes the status line and clocks while the view is up", function()
    local s = setup()
    eq(#s.scheduled, 1, "no minute tick armed")
    assert(s.scheduled[1].s > 0 and s.scheduled[1].s <= 60)
    local tick = table.remove(s.scheduled, 1).fn
    tick()
    eq(s.view.refreshed, 1); eq(s.ticks(), 1)
    eq(s.BW.invalidated, 1, "the battery and wifi read stayed cached")
    eq(#s.scheduled, 1, "the tick did not re-arm")
    -- Closed: the next tick does nothing and stops.
    s.shown[s.view] = nil
    table.remove(s.scheduled, 1).fn()
    eq(s.view.refreshed, 1); eq(#s.scheduled, 0, "kept ticking after the view closed")
end)

t.done()
