-- tests/_test_ornament_screen_cadence.lua
-- Ornaments are promised per SCREEN, not per gap.
--
-- WHAT WENT WRONG. "I have it set to 'often' on my home shelf, and no
-- ornaments appear on any page."
--
-- Every placement was opportunistic: a piece appeared when a gap happened to
-- be wide enough. Two things then conspire on a plain shelf. A shelf with no
-- groups has no section breaks at all, so that whole channel is empty -- the
-- default Home shelf, flattened folders, is exactly that. And a densely packed
-- row leaves a few dozen pixels at its end, under the minimum gap, so the
-- other channel is empty too. Only the top stop reserved width up front, so
-- every level below it could show nothing at all, for ever, however high the
-- reader set it.
--
-- THE RULE IS NOW A CADENCE. A level says how often a SCREEN is guaranteed a
-- piece -- Always every screen, Often about one in three -- and on a
-- guaranteed screen that has nothing else standing, a piece takes width off a
-- row end and stands there. "They could force their way onto shelf ends...
-- if there are no ornaments between groups on that screen" (maintainer).
--
-- The forcing is the LAST resort, not the first: a screen that already has one
-- between two groups keeps its books.
--
-- Usage (from plugin root): lua tests/_test_ornament_screen_cadence.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq
local orn = io.open("lib/bookshelf_ornaments.lua"):read("*a")

local function bodyOf(name, args)
    local pat = "\nfunction M%." .. name .. "%(" .. (args or "") .. "%)\n(.-)\nend\n"
    local b = orn:match(pat)
    assert(b, "M." .. name .. " missing")
    return b
end

-- Run one of the module's functions with a stubbed frequency.
local function withFreq(freq, name, args, ...)
    local body = bodyOf(name, args)
    local env = { M = { frequency = function() return freq end }, type = type,
                  math = math, tostring = tostring, pairs = pairs }
    env.M.hash = function(s)
        local h = 5381
        for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
        return h
    end
    env.M.SCREEN_PERIOD = load("return " .. (orn:match("M.SCREEN_PERIOD = (%b{})") or "{}"),
                               "p", "t", {})()
    -- screenGuaranteed leans on screenPeriod, so the stub carries the real one.
    env.M.screenPeriod = assert(load(
        "return function()\n" .. bodyOf("screenPeriod") .. "\nend", "sp", "t", env))()
    local fn = assert(load("return function(" .. (args or "") .. ")\n" .. body .. "\nend",
        name, "t", env))
    return fn()(...)
end

t.test("every level has a screen period, and they get rarer in order", function()
    local p = {}
    for _i, lvl in ipairs({ 0, 0.5, 1, 2 }) do
        p[lvl] = withFreq(lvl, "screenPeriod")
        assert(type(p[lvl]) == "number", "no period for level " .. lvl)
    end
    eq(p[0], 0, "None must promise nothing")
    eq(p[2], 1, "Always must mean every screen")
    assert(p[1] > 1 and p[1] <= 3,
        "Often should land about one screen in three, got one in " .. p[1])
    assert(p[0.5] > p[1], "Rarely must be rarer than Often, got " .. p[0.5])
end)

t.test("Always guarantees every screen; None guarantees none", function()
    for i = 1, 8 do
        assert(withFreq(2, "screenGuaranteed", "seed", "page" .. i) == true,
            "Always missed a screen")
        assert(withFreq(0, "screenGuaranteed", "seed", "page" .. i) == false,
            "None promised a screen")
    end
end)

t.test("Often lands often, but not on every screen", function()
    local hits = 0
    for i = 1, 60 do
        if withFreq(1, "screenGuaranteed", "seed", "page" .. i) then hits = hits + 1 end
    end
    assert(hits > 10 and hits < 40,
        "Often guaranteed " .. hits .. " screens in 60; expected roughly a third")
end)

t.test("the same screen always answers the same way", function()
    -- A page that composes differently each time it is shown reads as a bug.
    local a = withFreq(1, "screenGuaranteed", "seed", "page-42")
    for _i = 1, 5 do
        eq(withFreq(1, "screenGuaranteed", "seed", "page-42"), a,
            "the guarantee is not deterministic for a page")
    end
end)

t.test("the shelf reserves width on a guaranteed screen, not only at the top stop", function()
    local shelf = io.open("lib/bookshelf_spine_shelf.lua"):read("*a")
    local block = shelf:match("(Row%-end reservation.-orn.row_end = math.floor)")
    assert(block, "the reservation block moved")
    assert(block:find("screenGuaranteed", 1, true),
        "reservation still keys off the level alone, so Often can never "
        .. "force a piece onto a packed shelf")
    -- A constant seed answers the same for every page: either every screen is
    -- owed one or, far more likely, none ever is -- which is the bug this
    -- whole change exists to fix, reintroduced one layer down.
    assert(block:find("page_id", 1, true),
        "the guarantee is not seeded on the page")
    assert(not block:find('screenGuaranteed(tostring(opts.page_key or "")', 1, true),
        "seeded on a key plan() is never given, so it is constant")
end)

t.test("a screen that already has one keeps its books", function()
    local shelf = io.open("lib/bookshelf_spine_shelf.lua"):read("*a")
    local block = shelf:match("(local row_orn = {}.-\n    end\n)")
    assert(block, "the row-end pick loop moved")
    assert(block:find("screenCount", 1, true),
        "the forced pick must check what is already standing on this screen")
end)

t.done()
