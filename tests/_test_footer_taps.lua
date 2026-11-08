-- tests/_test_footer_taps.lua
-- A page shown from its kept pixels still has a footer that answers taps.
--
-- A turn onto a page built ahead (or kept) copies the page's pixels to the
-- screen and paints no widget; the footer is built new on every turn, and a
-- KOReader Button learns where it is only when painted (its dimen). On a PW5
-- every tap on the footer's arrows after the first turn found nothing
-- (dimen 0,0) until the shelf was painted again.
package.path = "./?.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq
local W = io.open("lib/bookshelf_widget.lua"):read("*a")
local function body(sig)
    return assert(W:match("\nfunction BookshelfWidget:" .. sig .. "\n(.-)\nend\n"), sig .. " moved")
end

local PLACE = body("_placeFooterHitAreas%(d%)")
local freed = 0
local env = setmetatable({
    BookshelfWidget = { _screenLike = function() return { free = function() freed = freed + 1 end } end },
}, { __index = _G })
local src = "local self, d = ...\n" .. PLACE
local place
if setfenv then place = assert(loadstring(src)); setfenv(place, env) else place = assert(load(src, "p", "t", env)) end

t.test("the footer is painted where it stands, off the screen, and the buffer let go", function()
    local painted
    local anchor = { paintTo = function(_self, bb, x, y) painted = { bb = bb, x = x, y = y } end }
    local og = { dimen = { x = 0, y = 20 }, [3] = anchor }
    place({ _overlap_group = og }, { footer_overlap_idx = 3 })
    assert(painted, "the footer was not painted, so its buttons stay at 0,0")
    eq(painted.x, 0); eq(painted.y, 20, "painted somewhere other than where the group stands")
    eq(freed, 1, "the scratch buffer was kept")
end)

t.test("both routes from kept pixels place it", function()
    local show = body("_pageShowOffscreen%(px, shelf_top, d, old_reach, rows,\n        footer_rect, footer_band, mode, keep%)")
    assert(show:find("self:_placeFooterHitAreas(d)", 1, true), "the plain turn from kept pixels leaves the footer dead")
    local swap = body("_swapShelvesInPlace%(%)")
    local wipe = swap:find("local new_bb = px_hit and self:_pagePxToFull(px_hit)", 1, true)
    assert(wipe and swap:find("if px_hit then self:_placeFooterHitAreas(d) end", wipe, true),
        "the wipe from kept pixels leaves the footer dead")
end)

t.done()
