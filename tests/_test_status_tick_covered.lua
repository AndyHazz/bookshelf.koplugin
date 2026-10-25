-- tests/_test_status_tick_covered.lua
-- Issue 549: under a full-screen window that is not marked covers_fullscreen
-- (Storefront's Updates list and its overlays), the minute tick swapped the
-- hero's status line and asked for a panel refresh of it. KOReader repaints
-- the window over it, so nothing wrong was drawn, but the e-ink panel flashed
-- that rectangle and left a ghost of its edge, every minute.
--
-- A tick or device-state event applied while another window is on top keeps
-- the tree current and asks for no refresh; it drops the underlay's copy so
-- the window's close repaints the shelf as it is now. A live preview from a
-- dialog over the shelf (the line editor) still repaints: that is not a tick.
-- Run from the plugin root: lua tests/_test_status_tick_covered.lua
package.path = "./?.lua;" .. package.path
local t  = dofile("tests/_helpers.lua").runner()
local eq = dofile("tests/_helpers.lua").eq

local w  = io.open("lib/bookshelf_widget.lua"):read("*a")
local hm = io.open("lib/bookshelf_hero_modules.lua"):read("*a")

local function compile(code, env, name)
    if _G.setfenv then
        local f = assert(_G.loadstring(code, name)); _G.setfenv(f, env); return f
    end
    return assert(load(code, name, "t", env))
end

local function method(src, pat, name)
    local body = src:match(pat)
    assert(body, "could not find " .. name .. " - renamed?")
    return body
end

local HOLD   = method(w, "\nfunction BookshelfWidget:_holdTickRefresh%(target%)\n(.-)\nend\n", "_holdTickRefresh")
local RIGHT  = method(w, "\nfunction BookshelfWidget:_swapHeroRightColumnInPlace%(regions, region_hint%)\n(.-)\nend\n",
                      "_swapHeroRightColumnInPlace")
local STRIP  = method(w, "\nfunction BookshelfWidget:_swapHeroStatusStrip%(%)\n(.-)\nend\n", "_swapHeroStatusStrip")
local CLOCKS = method(hm, "\nfunction HeroModules%.tickClocks%(bw%)\n(.-)\nend\n", "tickClocks")

-- A world with a shelf, maybe a window over it, and a record of what was asked.
local function world(top_is_shelf)
    local W = { dirty = {}, invalidated = 0 }
    local shelf = {}
    local overlay = { name = "storefront updates" }
    W.shelf, W.overlay = shelf, overlay
    local env = setmetatable({}, { __index = _G })
    env.UIManager = {
        getTopmostVisibleWidget = function() return top_is_shelf and shelf or overlay end,
        setDirty = function(_um, widget, mode, region) W.dirty[#W.dirty + 1] = { widget, mode, region } end,
        nextTick = function() end,
    }
    env.require = function(name)
        if name == "lib/bookshelf_underlay" then
            return { invalidate = function() W.invalidated = W.invalidated + 1 end }
        end
        return require(name)
    end
    env.Repo = {}
    env._device_state_expires_at = 0
    env.HeroCard = { buildStatusRow = function() return { dimen = nil } end }
    env.HeroModules = { _tickMinuteHooks = function() end,
                        _swapCell = function() return { x = 0, y = 0, w = 10, h = 10 } end }
    local hold = compile("local self, target = ... ; " .. HOLD, env, "hold")
    shelf._holdTickRefresh = function(s, target) return hold(s, target) end
    shelf._buildDeviceState = function() return {} end
    shelf._currentHeroBook = function() return nil end
    local hero = { replaceRightColumn = function() return true, { x = 391, y = 37, w = 808, h = 30 } end }
    shelf._hero_card, shelf._hero_parent = hero, { hero }
    shelf._hero_status_strip = { group = { { dimen = nil } }, idx = 1, content_w = 100 }
    shelf._hero_clock_cells = { {} }
    local right = compile("local self, regions, region_hint = ... ; " .. RIGHT, env, "right")
    local strip = compile("local self = ... ; " .. STRIP, env, "strip")
    local clocks = compile("local bw = ... ; " .. CLOCKS, env, "clocks")
    W.right  = function() return right(shelf, {}, "status") end
    W.strip  = function() return strip(shelf) end
    W.clocks = function() return clocks(shelf) end
    return W
end

t.test("a tick under another window swaps the status line but asks for no refresh", function()
    for _i, which in ipairs({ "right", "strip", "clocks" }) do
        local W = world(false)
        W.shelf._in_status_tick = true
        W[which]()
        eq(#W.dirty, 0, which .. ": a refresh was asked for under the window")
        eq(W.invalidated, 1, which .. ": the underlay's copy was kept, so the close restores the old clock")
    end
end)

t.test("a tick with the shelf on top still refreshes", function()
    for _i, which in ipairs({ "right", "strip", "clocks" }) do
        local W = world(true)
        W.shelf._in_status_tick = true
        W[which]()
        eq(#W.dirty, 1, which .. ": no refresh with the shelf on top")
        eq(W.invalidated, 0, which)
    end
end)

t.test("a live preview from a dialog over the shelf still refreshes", function()
    -- The line editor and the size dialogs sit over the shelf and swap the
    -- column to preview each change: not a tick, so they are not held.
    local W = world(false)
    W.right()
    eq(#W.dirty, 1, "the editor's preview was held")
end)

t.test("the minute tick and the device-state repaint mark themselves", function()
    local tick = w:match("self%._status_timer_func = function%(%).-Re%-arm at the next minute boundary")
    assert(tick and tick:find("self._in_status_tick = true", 1, true), "the minute tick is not marked")
    local gated = w:match("\nfunction BookshelfWidget:_gatedRepaint%(tokens, debounce%)\n.-\nend\n")
    assert(gated and gated:find("self._in_status_tick = true", 1, true), "_gatedRepaint is not marked")
end)

t.done()
