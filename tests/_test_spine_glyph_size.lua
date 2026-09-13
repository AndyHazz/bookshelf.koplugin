-- tests/_test_spine_glyph_size.lua
-- How big the status / favourite glyphs on a spine are allowed to get.
--
-- ── WHY THIS EXISTS ─────────────────────────────────────────────────────────
--
-- On a thin spine the status glyph and the favourite star crowded the title
-- out, so their caps came down (17 -> 12 and 14 -> 10). PR #393 made that
-- change by deriving the size from `spine_w`, which is PIXELS:
--
--     local gsize = math.max(8, math.min(12, math.floor(spine_w * 0.34)))
--
-- but the number handed to BFont:getFace is scaled by getFace itself
-- (frontend/ui/font.lua: `size = Screen:scaleBySize(size)`), so it has to be
-- in DP. Feeding it a pixel width scales twice, and since scaleBySize is
-- `min(w, h) / 600`, the glyph's share of the spine then depends on how big
-- the screen is: on a 600x800 panel a 22dp spine dropped 13 -> 8, while on a
-- Sage a 16dp spine went the wrong way entirely, 9 -> 11.
--
-- The caps were the intended change; the unit was not. On the PW3 the author
-- tested, factor 1.787 x 0.34 = 0.608, so the pixel ratio was standing in for
-- the 0.6 the code already used -- the two agree there at every spine width
-- but one.
--
-- ── THE SHELF, NOT THE BOOK ────────────────────────────────────────────────
--
-- The size is capped the way the TITLE face is (and the bulk badge is sized):
-- at what an average book on this shelf gets, via e.ref_w_dp. A 1000-page
-- spine otherwise wears badges that tower over its neighbours', which is the
-- same complaint the title cap was added for.
--
-- Usage (from plugin root): lua tests/_test_spine_glyph_size.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

local H = dofile("tests/_helpers.lua")
local t = H.runner()
local eq = H.eq

local src = assert(io.open("lib/bookshelf_spine_shelf.lua")):read("*a")
local block = src:match("\n(local function _glyphSizeDp%(.-\nend)\n")
assert(block, "the glyph-size helper moved or was renamed")

local env = { math = math }
local function compile(code)
    if _G.setfenv then
        local f = assert(_G.loadstring(code, "glyph"))
        _G.setfenv(f, env)
        return f
    end
    return assert(load(code, "glyph", "t", env))
end
compile(block .. "\nEXPORT = _glyphSizeDp")()
local size = assert(env.EXPORT, "the helper block exported nothing")

-- The two call sites, so the numbers below read like the real thing. The
-- default shelf reference is 22dp, the width an unknown page count gets.
local function status(w_dp, ref) return size(w_dp, ref, 0.6, 8, 12) end
local function favourite(w_dp, ref) return size(w_dp, ref, 0.5, 7, 10) end

-- ── the caps, which are the point of the change ────────────────────────────

t.test("a wide spine no longer gets a 17dp status glyph", function()
    eq(status(30), 12, "0.6 of 30 is 18, so a cap is what answers")
    eq(status(60), 12, "and it stays there however thick the spine")
end)

t.test("the favourite star is capped below the status glyph", function()
    eq(favourite(30), 10)
    assert(favourite(60) < status(60), "the star is the quieter of the two")
end)

t.test("a thin spine still gets a legible glyph", function()
    eq(status(8), 8, "0.6 of 8 is 4, so the floor answers")
    eq(favourite(8), 7)
end)

t.test("in between, the size follows the spine", function()
    eq(status(16), 9)
    eq(favourite(16), 8)
end)

t.test("size never shrinks as the spine widens", function()
    local prev = 0
    for w_dp = 8, 80 do
        local s = status(w_dp)
        assert(s >= prev, "w_dp=" .. w_dp .. " went backwards: " .. s .. " < " .. prev)
        prev = s
    end
end)

t.test("a missing width falls back rather than erroring", function()
    eq(status(nil, nil), 12, "the entry's 20dp default, under the 22dp shelf reference")
end)

-- ── capped by the SHELF, the way the title face is ─────────────────────────

t.test("a fat spine does not tower over its neighbours", function()
    -- A 1000-page outlier on a shelf of ordinary paperbacks: it may not wear
    -- a bigger glyph than the shelf's average book earns.
    local avg = status(12, 12)
    eq(status(60, 12), avg, "the outlier is held to the shelf's size")
end)

t.test("a shelf of thick books earns bigger glyphs than a shelf of thin ones", function()
    assert(status(30, 40) > status(30, 10),
        "the reference is what separates the two shelves")
end)

t.test("a thin spine is still smaller than its neighbours on the same shelf", function()
    -- The cap is a ceiling, not a fixed size: below it, each spine keeps
    -- scaling with its own width, exactly as the title face does.
    assert(status(10, 40) < status(30, 40))
end)

t.test("the shelf reference cannot push the glyph past its own cap", function()
    eq(status(60, 400), 12, "an absurd reference still stops at 12dp")
    eq(favourite(60, 400), 10)
end)

-- ── the unit, which is the part that must not drift back ───────────────────

t.test("the glyph size is DP: the call sites pass the spine's DP width", function()
    -- The regression guard. `spine_w` is in scope at both call sites and is
    -- the tempting thing to reach for; it is also already scaled, and
    -- BFont:getFace scales again.
    -- Scanned with the declaration removed, so its own parameter list is
    -- not mistaken for a third call site.
    local rest = (src:gsub("local function _glyphSizeDp%(.-\nend\n", "", 1))
    local calls = {}
    for args in rest:gmatch("_glyphSizeDp%((.-)%)") do calls[#calls + 1] = args end
    eq(#calls, 2, "expected the status glyph and the favourite star")
    for _i, args in ipairs(calls) do
        local first = args:match("^%s*([%w_%.]+)")
        eq(first, "w_dp", "a glyph size must come from the DP width, got: " .. args)
        assert(args:find("ref_w_dp", 1, true),
            "and must be capped by the shelf reference, got: " .. args)
    end
end)

t.test("the same spine gets the same glyph on every screen", function()
    -- Restating the above as the property it buys: nothing screen-derived can
    -- reach the helper, so a 22dp spine looks the same on a Basic and a Sage.
    assert(not block:find("Screen"), "the helper must not consult the screen")
    assert(not block:find("spine_w"), "nor any pixel width")
end)

t.done()
