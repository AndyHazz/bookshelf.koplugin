-- tests/_test_reading_goal_arrangement.lua
-- Reading goals with more than one goal on: how many it shows at once, and
-- in how many columns. As many as the cell has room for: all of them in a
-- row when it is wide enough, four as two rows of two, a stack in a tall
-- one; else two (side by side or stacked) or one, a tap cycling the rest.
--
-- Reddit: "it's only showing my Daily and Weekly goals. I want that part to
-- show all 4 ... I tried expanding the square to cover more space but it
-- just makes the font larger, still only showing two."
package.path = "./?.lua;./?/init.lua;" .. package.path
local t   = dofile("tests/_helpers.lua").runner()
local eq  = dofile("tests/_helpers.lua").eq
local src = io.open("micromodules/reading_goal.lua"):read("*a")
local body = src:match("\nlocal function arrangement%(shape, n_active, block_h, avail_h, room%)\n(.-)\nend\n")

-- room: { width, min_w = a block's least width, gap, hgap }
local function arr(shape, n, block_h, avail_h, room)
    assert(body, "could not find arrangement in reading_goal - renamed?")
    return load("local shape, n_active, block_h, avail_h, room = ...\n" .. body, "arr", "t", { math = math })(
        shape, n, block_h, avail_h, room)
end
-- got: { arr(...) }, both answers (a call followed by more arguments keeps
-- only its first).
local function is(got, want_per, want_cols)
    local per, cols = got[1], got[2]
    assert(per == want_per and cols == want_cols,
        ("%s shown in %s column(s), want %s in %s"):format(tostring(per), tostring(cols), want_per, want_cols))
end
local ROOMY  = { width = 1100, min_w = 240, gap = 12, hgap = 20 }   -- four across fit
local MEDIUM = { width = 700,  min_w = 240, gap = 12, hgap = 20 }   -- two across, not four
local NARROW = { width = 300,  min_w = 240, gap = 12, hgap = 20 }   -- one across

-- ── as before, for two goals and for cells with no room for more ───────────

t.test("a wide cell shows two goals side by side", function()
    is({ arr("wide", 2, 200, 387, MEDIUM) }, 2, 2)
end)
t.test("a tall enough square cell stacks two", function()
    is({ arr("square", 2, 150, 387, NARROW) }, 2, 1)
end)
t.test("a short square cell shows one", function()
    eq((arr("square", 2, 300, 387, NARROW)), 1)
end)
t.test("one goal on: one, whatever the shape", function()
    is({ arr("wide", 1, 100, 387, ROOMY) }, 1, 1)
end)
t.test("no height (start menu): one", function()
    eq((arr("wide", 4, 100, nil, ROOMY)), 1)
end)
t.test("a caller that says nothing of the room gets what it always did", function()
    is({ arr("wide", 4, 200, 387) }, 2, 2)
    is({ arr("square", 4, 150, 387) }, 2, 1)
end)

-- ── all of them, where there is room ───────────────────────────────────────

t.test("wide enough for four across: all four in a row", function()
    is({ arr("wide", 4, 200, 300, ROOMY) }, 4, 4)
end)
t.test("three on, wide enough: three in a row", function()
    is({ arr("wide", 3, 200, 300, ROOMY) }, 3, 3)
end)
t.test("wide, but not for four across: two rows of two when both rows fit", function()
    is({ arr("wide", 4, 150, 400, MEDIUM) }, 4, 2)
end)
t.test("wide, not for four across, and one row high: the pair, as before", function()
    is({ arr("wide", 4, 300, 320, MEDIUM) }, 2, 2)
end)
t.test("a big square cell: two rows of two", function()
    is({ arr("square", 4, 200, 600, MEDIUM) }, 4, 2)
end)
t.test("a tall narrow cell with room for all: a stack of four", function()
    is({ arr("tall", 4, 150, 800, NARROW) }, 4, 1)
end)
t.test("three on in a tall cell: a stack of three", function()
    is({ arr("tall", 3, 150, 600, NARROW) }, 3, 1)
end)
t.test("a tall cell with room for two only: two, the tap cycling the rest", function()
    is({ arr("tall", 4, 200, 500, NARROW) }, 2, 1)
end)
t.test("three on, wide but not for three across: the pair", function()
    is({ arr("wide", 3, 200, 300, MEDIUM) }, 2, 2)
end)

-- ── the module lays out what was decided ───────────────────────────────────

t.test("the module builds rows of that many columns, and steps a tap by what it shows", function()
    local render = src:match("render = function%(ctx%)(.-)\n    on_tap = function")
    assert(render, "render moved")
    assert(render:find("arrangement(Kit.shape(mw, avail_h), #getActiveList(), h1, avail_h, {", 1, true),
        "the cell's room is not handed over: two at most, whatever the size")
    assert(render:find("_last_per_view = per_view", 1, true))
    assert(render:find("for r = 1, math.ceil(#goals / cols) do", 1, true), "no rows of columns")
end)

-- Maintainer, PW5 (a full-screen page, all four goals): two goals where two
-- rows of two had room. The page grows each module's text to fill its cell
-- and keeps the largest scale that fits; the arrangement was decided again at
-- each scale, so it chose two rows of two up to 152% and two stacked from
-- 175% (rig log), and the page kept 175%. The arrangement is decided at the
-- base size, so a bigger scale makes the same goals bigger.
t.test("the arrangement does not follow the host's scale", function()
    local src = io.open("micromodules/reading_goal.lua"):read("*a")
    local render = src:match("render = function%(ctx%)(.-)\n    on_tap = function")
    local pick = render:match("local per_view, cols = 1, 1(.-)_last_per_view = per_view")
    assert(pick, "the arrangement block moved")
    assert(pick:find("buildGoalBlock(getCurrentView(), mw, 100, data, t)", 1, true),
        "the probe is measured at the host's scale")
    assert(pick:find("min_w = Screen:scaleBySize(120)", 1, true), "the least width follows the host's scale")
    assert(not pick:find("scale_pct", 1, true), "the host's scale still decides how many goals show")
end)

-- Side by side, a goal's lines are cut to its column ("2026 challen...",
-- "24 books..." at the page's 175%, rig): the page fits the module by height,
-- and the goals' text cuts itself short rather than overflow. In columns the
-- goals take the largest scale, up to the page's, at which every line fits.
local fit_body = src:match("\nlocal function columnScale%(widest_at, cell_w, scale_pct%)\n(.-)\nend\n")
local function fit(widest_at, cell_w, scale_pct)
    assert(fit_body, "no columnScale in reading_goal")
    return load("local widest_at, cell_w, scale_pct = ...\n" .. fit_body, "fit", "t", { math = math })(
        widest_at, cell_w, scale_pct)
end
-- A line 200 wide at 100%, growing with the scale.
local function lines(base) return function(s) return math.floor(base * s / 100) end end

t.test("columns: the page's scale when every line fits", function()
    eq(fit(lines(200), 400, 150), 150)
end)

t.test("columns: down to the largest scale that fits, never past the page's", function()
    local s = fit(lines(200), 320, 175)
    assert(s <= 160 and s >= 150, "scale " .. tostring(s))
    assert(lines(200)(s) <= 320, "a line still cut")
end)

t.test("columns: a floor, so a very long name does not make it tiny", function()
    eq(fit(lines(2000), 300, 100), 70)
end)

t.test("the columns are built at that scale", function()
    local render = src:match("render = function%(ctx%)(.-)\n    on_tap = function")
    assert(render:find("local col_scale = columnScale(", 1, true), "no fitting for the columns")
    assert(render:find("buildGoalBlock(g, cell_w, col_scale, data, t)", 1, true), "the columns are built at the page's scale")
end)

t.done()
