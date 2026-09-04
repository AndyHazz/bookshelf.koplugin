-- tests/_test_hero_flex_width.lua
-- HeroModules._flexMinWidth: the minimum width a flex micro-module needs
-- before it will share a row with another.
--
-- Issue #359: every flex module got a full-width row of its own, however little
-- content it had, so two could never sit side by side. The cause is that
-- twoColMinWidth() is scaleBySize(300), which scales with the screen -- and so
-- does the hero -- so it lands at ~53% of the row at EVERY size. Measured in
-- the emulator: 412 of 776 at 824px wide, 618 of 1162 at 1236px. Just over
-- half, every time, so the two-column path the constant is named for was
-- unreachable.
--
-- What matters here is the PAIRING ARITHMETIC, not the number: two cells plus a
-- gap must fit the row, and -- WHERE THE CAP BINDS -- three must not, since a
-- cap that let three in would cram the row, which is what the 300dp floor was
-- there to prevent. Where the cap does not bind the old behaviour stands
-- unchanged, three fitting included.
--
-- Driven against the real function body, extracted by name, as
-- _test_disk_available does.
package.path = "./?.lua;./?/init.lua;" .. package.path

local t   = dofile("tests/_helpers.lua").runner()
local src = io.open("lib/bookshelf_hero_modules.lua"):read("*a")

local body = src:match("\nfunction HeroModules%._flexMinWidth%(content_w, gap%)\n(.-)\nend\n")
assert(body, "could not find HeroModules._flexMinWidth - renamed?")

local function compile(code, env, name)
    if _G.setfenv then
        local f = assert(_G.loadstring(code, name))
        _G.setfenv(f, env)
        return f
    end
    return assert(load(code, name, "t", env))
end

-- floor_w stands in for twoColMinWidth() = Screen:scaleBySize(300).
local function flexMin(content_w, gap, floor_w)
    local env = {
        math = math,
        require = function(name)
            assert(name == "lib/bookshelf_module_kit", "unexpected require: " .. tostring(name))
            return { twoColMinWidth = function() return floor_w end }
        end,
    }
    local fn = compile("local content_w, gap = ...\n" .. body, env, "_flexMinWidth")
    return fn(content_w, gap)
end

-- Does the packer's row test admit n cells of this width?
local function fits(n, w, gap, content_w)
    return n * w + (n - 1) * gap <= content_w
end

t.test("#359: two flex cells pair at the real measured geometries", function()
    -- The two sizes captured from the emulator, where the shipped constant
    -- stacked them.
    local cases = {
        { content_w = 776,  gap = 24, floor_w = 412 },   -- 824px wide screen
        { content_w = 1162, gap = 37, floor_w = 618 },   -- 1236px wide screen
    }
    for _, c in ipairs(cases) do
        assert(not fits(2, c.floor_w, c.gap, c.content_w),
            ("precondition: the raw %dpx floor should NOT fit twice in %dpx")
                :format(c.floor_w, c.content_w))
        local w = flexMin(c.content_w, c.gap, c.floor_w)
        assert(fits(2, w, c.gap, c.content_w),
            ("two %dpx cells must fit %dpx with a %dpx gap"):format(w, c.content_w, c.gap))
    end
end)

t.test("WHEN THE CAP BINDS, three never fit: a row gains a column, not a crush", function()
    -- Only where the cap actually applies. Where the floor is already below
    -- half the row (a wide screen), how many cells fit is pre-existing
    -- behaviour that this change does not touch -- and three genuinely can,
    -- which an earlier version of this test wrongly asserted against.
    -- The zero-gap case is the one that pins HALF specifically. With a
    -- realistic gap almost any fraction keeps three out, because the two gaps
    -- alone push it over; with no gap only a cap of half or more does. Without
    -- it, capping at a THIRD passes every other assertion here while quietly
    -- allowing a three-across row.
    for _, c in ipairs({ { 776, 24, 412 }, { 1162, 37, 618 }, { 776, 0, 412 } }) do
        local content_w, gap, floor_w = c[1], c[2], c[3]
        local w = flexMin(content_w, gap, floor_w)
        assert(w < floor_w, "precondition: the cap should bind here")
        assert(fits(2, w, gap, content_w),
            ("two %dpx cells must still fit %dpx"):format(w, content_w))
        assert(not fits(3, w, gap, content_w),
            ("three %dpx cells must NOT fit %dpx (gap=%d)"):format(w, content_w, gap))
    end
end)

t.test("where the cap does not bind, how many fit is left exactly as it was", function()
    local content_w, gap, floor_w = 2000, 20, 300
    local w = flexMin(content_w, gap, floor_w)
    assert(w == floor_w, "the cap must not bind here")
    assert(fits(3, w, gap, content_w),
        "a wide row fitting three 300px cells is pre-existing behaviour and must be preserved")
end)

t.test("a floor narrower than half the row is left alone", function()
    -- Only the cap is new behaviour. Where the constant already allowed two
    -- columns, it must still decide the width, or a wide screen would start
    -- pairing modules that were deliberately given room.
    local w = flexMin(2000, 20, 300)
    assert(w == 300, "expected the 300px floor to stand, got " .. tostring(w))
end)

t.test("the cap accounts for the gap, not just half the width", function()
    -- Ignoring the gap gives exactly half, and two of those plus a gap
    -- overflow the row by exactly the gap -- the off-by-one that would leave
    -- the bug in place while looking fixed.
    local content_w, gap, floor_w = 776, 24, 412
    local w = flexMin(content_w, gap, floor_w)
    assert(w <= math.floor((content_w - gap) / 2),
        ("cap must subtract the gap: got %d, half of %d is %d")
            :format(w, content_w, math.floor(content_w / 2)))
end)

t.test("a degenerate row falls back to the floor instead of returning nonsense", function()
    -- content_w smaller than the gap yields a negative half. Returning that
    -- would make every cell 1px wide via the packer's max(1, ...) floors.
    for _, c in ipairs({ { 0, 24 }, { 10, 24 }, { nil, nil } }) do
        local w = flexMin(c[1], c[2], 412)
        assert(w == 412, ("degenerate geometry should fall back to the floor, got %s")
            :format(tostring(w)))
    end
end)

t.done()
