-- tests/_test_chip_switch_refresh_band.lua
-- A chip switch refreshes every row the hero used to occupy (issue 423).
--
-- WHAT NEEDS PINNING. Switching chips scopes its refresh to the band BELOW the
-- hero, so the hero does not re-flash on e-ink for a book that has not changed
-- (issue 124). The band's top edge came from the hero's painted rect captured
-- BEFORE the rebuild, on the stated reasoning that "switching chips never
-- changes the hero ... so it rebuilds pixel-identical".
--
-- It does change it. The hero's height follows the shelf's own layout, so two
-- shelves with different styles (spines against covers), different row counts,
-- or one of them empty, give heroes of different heights. Going from a taller
-- hero to a shorter one, the band started at the OLD bottom -- below the new
-- one -- so the rows between them were never refreshed and the panel kept the
-- previous shelf's pixels there. The framebuffer was correct throughout, which
-- is why it survived a screenshot and only showed up in a photograph of the
-- screen.
--
-- Reporter's own trace, Kobo Clara BW (1072x1448), switching back and forth:
--     ui update for region 0 596 1072 852
--     ui update for region 0 650 1072 798
-- Two hero heights, 54px apart, and each refresh starts below its own hero.
--
-- The band therefore starts at whichever bottom is higher, so it covers both
-- layouts. When the two agree -- the case the optimisation was written for --
-- nothing changes, down to the shadow nudge.
--
-- Usage (from plugin root): lua tests/_test_chip_switch_refresh_band.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local src = io.open("lib/bookshelf_widget.lua"):read("*a")
local body = src:match("\nfunction BookshelfWidget:_rebuildRefreshBelowHero%(%)\n(.-)\nend\n")
assert(body, "BookshelfWidget:_rebuildRefreshBelowHero moved or was renamed")

local NUDGE = 4

-- old_bottom: where the hero the user is looking at ends.
-- new_bottom: where the hero the rebuild produces ends (nil = no dims).
local function run(old_bottom, new_bottom)
    local captured = {}
    local env = {
        math = math, pairs = pairs, ipairs = ipairs, type = type,
        Screen = { scaleBySize = function(_, n) return n end },
        Geom = { new = function(_, tt) return tt end },
        UIManager = {
            setDirty = function(_self, _w, arg)
                if type(arg) == "function" then
                    local kind, region, dith = arg()
                    captured.kind, captured.region, captured.dithered = kind, region, dith
                else
                    captured.kind, captured.region = arg, "whole widget"
                end
            end,
        },
    }
    local fn = assert(load("return function(self)\n" .. body .. "\nend",
        "_rebuildRefreshBelowHero", "t", env))()
    local self_ = {
        width = 1072, height = 1448, dithered = nil,
        _hero_parent = { { dimen = old_bottom and { x = 0, y = 0, h = old_bottom } or nil } },
        _hero_dims   = nil,
        _rebuild = function(s)
            -- the rebuild is what changes the hero's height
            s._hero_dims = new_bottom and { PAD = 0, hero_h = new_bottom } or nil
        end,
    }
    fn(self_)
    return captured
end

t.test("hero unchanged: the band is unchanged, nudge and all", function()
    local c = run(600, 600)
    eq(c.kind, "ui")
    eq(c.region.y, 600 + NUDGE, "the shadow nudge belongs to the unchanged case")
    eq(c.region.h, 1448 - (600 + NUDGE))
end)

t.test("the new hero is SHORTER: the band starts at the new bottom", function()
    -- The reporter's case. Starting at the old bottom left the rows between
    -- 596 and 650 showing the previous shelf.
    local c = run(650, 596)
    eq(c.region.y, 596, "the vacated rows were left out of the refresh")
    eq(c.region.h, 1448 - 596)
end)

t.test("the new hero is TALLER: the band still starts at the old bottom", function()
    -- Nothing is stale here, but the band has to reach up to where the old
    -- hero ended or the newly covered rows go unrefreshed on the way back.
    local c = run(596, 650)
    eq(c.region.y, 596)
    eq(c.region.h, 1448 - 596)
end)

t.test("no painted hero yet: fall back to the new layout's own figure", function()
    local c = run(nil, 620)
    eq(c.region.y, 620 + NUDGE, "with only one figure it is the unchanged case")
end)

t.test("nothing to measure at all: refresh the whole widget", function()
    local c = run(nil, nil)
    eq(c.kind, "ui")
    eq(c.region, "whole widget", "a scoped band cannot be guessed; refresh everything")
end)

t.done()
