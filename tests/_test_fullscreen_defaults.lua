-- tests/_test_fullscreen_defaults.lua
-- What the full-screen micro-module surface ships with, and who gets it.
--
-- THE ARRANGEMENT is the maintainer's own, captured from their device:
-- analogue clock, reading stats, quote of day (spanning), library count,
-- reading goal. Adopted as the default for the same reason Home ships as
-- spines -- a first launch should show what the surface is for, and the old
-- fallback was a single clock.
--
-- THE SUBTLETY is who gets it. Seeding served one reader and now serves two:
--
--   * someone who already had hero modules when this surface arrived should
--     find THEIR set behind the full-screen button. That is what seeding
--     from the hero list has always done and it is still right.
--   * on a fresh install the hero list is just the pair we ship, so copying
--     it made the full-screen view a bigger copy of the hero grid.
--
-- So the copy happens only when the reader has actually arranged their hero
-- modules. "Untouched" is compared by module key in order: that is what a
-- reader changes, while ids and per-entry config are ours to vary.
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

t.test("a customised hero list is still copied, an untouched one is not", function()
    -- Both halves matter. Losing the first silently overrides modules an
    -- upgrader had already arranged; losing the second is the original bug.
    local body = fs_src:match("local function heroIsUntouched.-\nend")
    assert(body, "heroIsUntouched moved or was renamed")
    assert(body:find("HeroModel.DEFAULTS()", 1, true),
        "untouched must be judged against the hero defaults")
    assert(body:find("hero[i].module ~= defaults[i].module", 1, true),
        "compare by module key in order -- ids and config are ours to vary")

    local seed = fs_src:match("local function seedFromHero.-\nend")
    assert(seed, "seedFromHero moved or was renamed")
    assert(seed:find("heroIsUntouched(out)", 1, true),
        "the seed must consult it")
    assert(seed:find("#out == 0 or heroIsUntouched(out)", 1, true),
        "an empty hero list must still fall back to our defaults")
end)

t.done()
