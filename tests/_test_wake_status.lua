-- tests/_test_wake_status.lua
-- On wake the status line shows the time now, not the time the device slept
-- (issue 596). The shelf put back under a closing sleep screen is the shelf
-- as it was (lib/bookshelf_underlay), clock included, and a Resume that came
-- while the sleep screen was still up could not draw over it.
-- BookshelfWidget:_wakeStatusRefresh is driven against its real body.
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq
local src = io.open("lib/bookshelf_widget.lua"):read("*a")

local function bodyOf(sig, name)
    local body = src:match("\nfunction BookshelfWidget:" .. sig .. "\n(.-)\nend\n")
    assert(body, "could not find BookshelfWidget:" .. name .. " - renamed?")
    return body
end

local BODY = bodyOf("_wakeStatusRefresh%(%)", "_wakeStatusRefresh")
local top
local calls
local env = setmetatable({
    UIManager = { getTopmostVisibleWidget = function() return top end },
    require = function(n)
        if n == "lib/bookshelf_hero_regions" then return { read = function() return "regions" end } end
        if n == "lib/bookshelf_hero_modules" then
            return { tickClocks = function() calls[#calls + 1] = "clocks" end }
        end
        error("unexpected require " .. n)
    end,
}, { __index = _G })
local code = "local self = ...\n" .. BODY
local f
if setfenv then f = assert(loadstring(code)); setfenv(f, env)
else f = assert(load(code, "wake", "t", env)) end

local function shelf(o)
    calls = {}
    o._swapHeroRightColumnInPlace = function(_s, r, hint) calls[#calls + 1] = "right:" .. r .. ":" .. hint end
    o._swapHeroStatusStrip = function() calls[#calls + 1] = "strip" end
    top = o
    return o
end

t.test("a book hero redraws its status column", function()
    local w = shelf{ _hero_card = { replaceRightColumn = function() end } }
    f(w)
    eq(calls[1], "right:regions:status")
end)

t.test("a hero with a status strip redraws the strip", function()
    local w = shelf{ _hero_status_strip = {} }
    f(w)
    eq(calls[1], "strip")
end)

t.test("a micro-module hero moves its clocks on, then its header strip", function()
    local w = shelf{ _hero_mode = "micro", _hero_status_strip = {} }
    f(w)
    eq(calls[1], "clocks"); eq(calls[2], "strip")
end)

t.test("nothing while another window is over the shelf, or once closed", function()
    local w = shelf{ _hero_status_strip = {} }
    top = {}
    f(w)
    eq(#calls, 0)
    top = w; w._closed = true
    f(w)
    eq(#calls, 0)
end)

t.test("Resume asks for it too (the sleep screen may already be gone)", function()
    assert(bodyOf("onResume%(%)", "onResume"):find("self:_wakeStatusRefresh()", 1, true),
        "onResume does not redraw the status")
end)

t.done()
