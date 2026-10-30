-- tests/_test_module_refresh_closed.lua
-- A module keeps ctx.refresh to call when its data changes, and that can be
-- after the shelf has closed: a pack's own plugin calling it when a game
-- closes or a reading session ends, with the reader open by then. A refresh
-- then re-rendered the card on the closed shelf and asked the panel to
-- repaint where it used to be (on a shelf module, it rebuilt the rows). Pack
-- authors guarded it with Bookshelf's private fields, which can change in any
-- release. ctx.refresh is now safe to call at any time: on a closed shelf it
-- does nothing.
-- Run from the plugin root: lua tests/_test_module_refresh_closed.lua
package.path = "./?.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()
local hm = io.open("lib/bookshelf_hero_modules.lua"):read("*a")

local function compile(code, env, name)
    if _G.setfenv then
        local f = assert(_G.loadstring(code, name)); _G.setfenv(f, env); return f
    end
    return assert(load(code, name, "t", env))
end

local RELOAD = hm:match("\nfunction HeroModules%._reloadCellById%(bw, id%)\n(.-)\nend\n")
assert(RELOAD, "could not find HeroModules._reloadCellById - renamed?")
-- The refresh handle each cell hands its module (ctx.refresh), in _makeCell.
local REFRESH = hm:match("\n    local function refresh%(%)\n(.-)\n    end\n")
assert(REFRESH, "could not find the cell's refresh handle - renamed?")

local function world(closed)
    local seen = { swaps = 0, dirty = 0, host = 0 }
    local bw = { _closed = closed or nil, _hero_cells = { c1 = { entry = { id = "c1" } } } }
    local HM = {}
    HM._swapCell = function() seen.swaps = seen.swaps + 1; return nil end
    local env = setmetatable({
        HeroModules = HM,
        UIManager = { setDirty = function() seen.dirty = seen.dirty + 1 end },
    }, { __index = _G })
    HM._reloadCellById = compile("local bw, id = ...\n" .. RELOAD, env, "reload")
    return bw, HM, seen, env
end

t.test("refreshing a card on an open shelf repaints it", function()
    local bw, HM, seen = world(false)
    HM._reloadCellById(bw, "c1")
    assert(seen.swaps == 1 and seen.dirty == 1, "swaps " .. seen.swaps .. ", dirty " .. seen.dirty)
end)

t.test("refreshing a card on a closed shelf does nothing", function()
    local bw, HM, seen = world(true)
    HM._reloadCellById(bw, "c1")
    assert(seen.swaps == 0 and seen.dirty == 0, "swaps " .. seen.swaps .. ", dirty " .. seen.dirty)
end)

t.test("a shelf module's refresh does nothing once the shelf has closed", function()
    for _, closed in ipairs({ false, true }) do
        local bw, HM, seen, env = world(closed)
        local host = { refresh = function() seen.host = seen.host + 1 end }
        env.bw, env.host, env.entry = bw, host, { id = "c1" }
        compile(REFRESH, env, "refresh")()
        local want = closed and 0 or 1
        assert(seen.host == want, string.format("closed=%s: host refreshed %d times",
            tostring(closed), seen.host))
    end
end)

t.done()
