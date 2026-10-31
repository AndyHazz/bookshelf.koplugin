-- tests/_test_tap_feedback_ornament.lua
-- A tap on an ornament module on a covers shelf (maintainer, PW5,
-- 2026-10-31): the pressed flash refreshed the whole cell with the fast
-- waveform, 1-bit on the panel, so the picture was smeared, and with no tap
-- action set nothing repainted it after. The flash refreshes the border's
-- ring alone; and no flash for a tap that does nothing.
--
-- Usage (from plugin root): lua tests/_test_tap_feedback_ornament.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq
local hm = io.open("lib/bookshelf_hero_modules.lua"):read("*a")
local orn = io.open("micromodules/ornament.lua"):read("*a")

local function fn(name)
    local body = assert(hm:match("\nfunction HeroModules%." .. name .. "%((.-)\nend\n"), name)
    return assert(load("local HeroModules = {}\nfunction HeroModules." .. name .. "(" .. body
        .. "\nend\nreturn HeroModules." .. name))()
end

t.test("an ornament flashes only with a tap action set", function()
    assert(orn:find('tap_feedback = function(ctx)', 1, true), "an ornament with no tap still flashes")
    assert(hm:find('if type(feedback) == "function" then', 1, true), "tap_feedback as a function is not asked")
end)

t.test("the flash refreshes the border's ring, not the picture inside it", function()
    local ring = fn("_ringRects")
    local r = ring({ x = 100, y = 200, w = 50, h = 80 }, 2, 6)
    eq(#r, 4)
    -- Top and bottom across, the sides between them: no two overlap or
    -- share an edge, so the refreshes are not merged into the whole cell.
    eq(r[1].x, 102); eq(r[1].y, 202); eq(r[1].w, 46); eq(r[1].h, 6)
    eq(r[2].y, 200 + 80 - 2 - 6); eq(r[2].h, 6)
    eq(r[3].x, 102); eq(r[3].y, 209); eq(r[3].w, 6); eq(r[3].h, 80 - 4 - 12 - 2)
    eq(r[4].x, 100 + 50 - 2 - 6)
    -- UIManager's own test (Geom:notOpenIntersectWith): every pair apart.
    local function apart(a, b)
        return a.x > b.x + b.w or a.y > b.y + b.h or b.x > a.x + a.w or b.y > a.y + a.h
    end
    for i = 1, 4 do
        for j = i + 1, 4 do assert(apart(r[i], r[j]), "bands " .. i .. " and " .. j .. " would merge") end
    end
    -- Too small for a ring: the cell.
    local s = ring({ x = 0, y = 0, w = 10, h = 10 }, 0, 6)
    eq(#s, 1); eq(s[1].w, 10)
    assert(hm:find("for i, rr in ipairs(HeroModules._ringRects(", 1, true), "the flash still refreshes the whole cell")
end)

t.done()
