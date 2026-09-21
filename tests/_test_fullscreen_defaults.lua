-- tests/_test_fullscreen_defaults.lua
-- What the full-screen micro-module surface ships with, and who gets it.
--
-- THE ARRANGEMENT is the maintainer's own, captured from their device:
-- analogue clock, reading stats, quote of day (spanning), library count,
-- reading goal. Adopted as the default for the same reason Home ships as
-- spines -- a first launch should show what the surface is for, and the old
-- fallback was a single clock.
--
-- SEEDING IS FROM OUR OWN DEFAULTS, full stop. It used to copy the hero list
-- so that turning the surface on carried an existing reader's modules over.
-- That was a migration aid when the surface was new and stopped earning its
-- weight: the two lists are independent stores that diverge the moment either
-- is edited, and the copy made a fresh install's full-screen view a bigger
-- duplicate of the hero grid.
--
-- Usage (from plugin root): lua tests/_test_fullscreen_defaults.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local fs_src   = io.open("lib/bookshelf_fullscreen_modules_model.lua"):read("*a")
local hero_src = io.open("lib/bookshelf_hero_modules_model.lua"):read("*a")

local function defaultsOf(src, label)
    local body = src:match("(function M.DEFAULTS%(%).-\n    }\nend)")
             or src:match("(function M.DEFAULTS%(%).-\nend)")
    assert(body, label .. " DEFAULTS() moved or was renamed")
    local env = { ipairs = ipairs, pairs = pairs }
    env.M = {}
    assert(load(body, label, "t", env))()
    return env.M.DEFAULTS()
end

local FS   = defaultsOf(fs_src, "fullscreen")
local HERO = defaultsOf(hero_src, "hero")

t.test("the full-screen surface ships the maintainer's arrangement", function()
    local got = {}
    for _, it in ipairs(FS) do got[#got + 1] = it.module end
    eq(table.concat(got, ","),
       "analogue_clock,stats,quote_of_day,shelf_size,reading_goal")
end)

t.test("the quote spans, because it is the one that is mostly text", function()
    for _, it in ipairs(FS) do
        if it.module == "quote_of_day" then eq(it.size, 1, "quote should span") end
    end
end)

t.test("every entry is a well-formed module row", function()
    for i, it in ipairs(FS) do
        eq(it.type, "module", "entry " .. i .. " type")
        assert(type(it.module) == "string" and it.module ~= "", "entry " .. i .. " module")
        assert(type(it.id) == "string" and it.id ~= "", "entry " .. i .. " id")
        -- No page field: the full-screen view reflows everything, it does
        -- not paginate, and a stray page would be carried around for ever.
        eq(it.page, nil, "entry " .. i .. " must carry no page")
    end
end)

t.test("ids are unique, or entries collide when edited", function()
    local seen = {}
    for _, it in ipairs(FS) do
        assert(not seen[it.id], "duplicate id " .. tostring(it.id))
        seen[it.id] = true
    end
end)

t.test("it is NOT simply the hero pair, which is the bug being fixed", function()
    assert(#FS > #HERO,
        "seeding used to copy the hero list, making this a bigger copy of the hero grid")
end)

t.test("seeding does not consult the hero list at all", function()
    -- The carry-over is gone by choice, not by accident. The two surfaces are
    -- independent stores that diverge the moment either is edited, and the
    -- rule for deciding which readers got a copy was more machinery than the
    -- behaviour deserved. Anyone who had already opened the full-screen view
    -- is unaffected either way: the seed runs once, behind the seeded flag.
    assert(not fs_src:find("seedFromHero", 1, true),
        "the hero carry-over is back")
    assert(not fs_src:find("HeroModel", 1, true),
        "the full-screen model should not depend on the hero model at all")
    assert(fs_src:find("local seed = M.DEFAULTS()", 1, true),
        "the seed must come from this module's own defaults")
end)

t.done()
