-- tests/_test_hero_status_rect.lua
-- The refresh a status-line swap asks for: just the status strip, never the
-- whole screen. The rect used to come from the widgets' PAINTED dimens, so a
-- strip whose widgets never record one (or a column not yet painted: a swap
-- held under another window, issue 549) fell back to the whole right column,
-- or to no rect at all -- a full-screen refresh. Now the strip is measured:
-- the column's origin from its last paint (a swapped slot does not move),
-- the strip's height from its rows' sizes (it is the column's first rows).
-- Run from the plugin root: lua tests/_test_hero_status_rect.lua
package.path = "./?.lua;" .. package.path
local t  = dofile("tests/_helpers.lua").runner()
local eq = dofile("tests/_helpers.lua").eq

local src = io.open("lib/bookshelf_hero_card.lua"):read("*a")

local function compile(code, env, name)
    if _G.setfenv then
        local f = assert(_G.loadstring(code, name)); _G.setfenv(f, env); return f
    end
    return assert(load(code, name, "t", env))
end

local STRIP = src:match("\nfunction HeroCard:getStatusStripDimen%(%)\n(.-)\nend\n")
assert(STRIP, "getStatusStripDimen moved")
local SWAP = src:match("\nfunction HeroCard:replaceRightColumn%(regions, book, state, region_hint%)\n(.-)\nend\n")
assert(SWAP, "replaceRightColumn moved")

local Geom = { new = function(_c, o) return o end }
local function env()
    local e = setmetatable({}, { __index = _G })
    e.Geom = Geom
    e.require = function(name)
        if name == "ui/uimanager" then return { nextTick = function() end } end
        return require(name)
    end
    return e
end

local function row(h) return { getSize = function() return { w = 800, h = h } end } end

local function card()
    local c = { _right_dimen = { w = 808, h = 486 }, _right_slot = 1 }
    local e = env()
    local strip = compile("local self = ... ; " .. STRIP, e, "strip")
    c.getStatusStripDimen = function(s) return strip(s) end
    local swap = compile("local self, regions, book, state, region_hint = ... ; " .. SWAP, e, "swap")
    c.replaceRightColumn = function(s, ...) return swap(s, ...) end
    c._buildRightColumn = function(s)
        s._status_strip_widgets = { row(30), row(2), row(8) }   -- unpainted: no dimen
        return {}
    end
    c._right_holder = { {} }
    return c
end

t.test("the status strip is measured, not read from a paint", function()
    local c = card()
    c._right_origin = { x = 391, y = 37 }
    c._status_strip_widgets = { row(30), row(2), row(8) }
    local r = c:getStatusStripDimen()
    assert(r, "no rect for an unpainted strip")
    eq(r.x, 391); eq(r.y, 37); eq(r.w, 808); eq(r.h, 40)
end)

t.test("a status swap asks for the strip, painted or not", function()
    local c = card()
    c._right_holder[1] = { dimen = { x = 391, y = 37, w = 808, h = 486 } }  -- painted column
    c._status_strip_widgets = { row(30), row(2), row(8) }
    local ok, r = c:replaceRightColumn({}, nil, nil, "status")
    assert(ok and r, "no rect")
    eq(r.h, 40, "refreshed more than the status strip")
    -- The new column was never painted (held under a window); the next tick:
    ok, r = c:replaceRightColumn({}, nil, nil, "status")
    assert(ok and r, "an unpainted column gave no rect: a full-screen refresh")
    eq(r.x, 391); eq(r.y, 37); eq(r.h, 40)
end)

t.test("a whole-column swap of an unpainted column still names the column", function()
    local c = card()
    c._right_holder[1] = { dimen = { x = 391, y = 37, w = 808, h = 486 } }
    c:replaceRightColumn({}, nil, nil, nil)
    local ok, r = c:replaceRightColumn({}, nil, nil, nil)
    assert(ok and r, "no rect: a full-screen refresh")
    eq(r.x, 391); eq(r.y, 37); eq(r.w, 808); eq(r.h, 486)
end)

t.done()
