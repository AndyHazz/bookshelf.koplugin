-- tests/_test_faceout_pose.lua
-- The face-out "pulled off the shelf" pose (lib/bookshelf_faceout_pose).
-- Usage (from plugin root): lua tests/_test_faceout_pose.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local H_ = dofile("tests/_helpers.lua")
local t, eq = H_.runner(), H_.eq
local Pose = dofile("lib/bookshelf_faceout_pose.lua")

local function near(a, b, tol, msg)
    assert(math.abs(a - b) <= (tol or 0.5), (msg or "") .. string.format(" got %.3f want %.3f", a, b))
end

t.test("no pose is the standing book: the front cover lands on its own rectangle", function()
    local P = Pose.pose(200, 300, 30, { x = 100, base_y = 900, gap = 0,
                                        pitch = 0, yaw = 0, lift = 0, pull = 0 })
    local function at(x, y, z) return { P(x, y, z) } end
    -- with no turn the box's widest extent is the cover, so the fit is 1
    local a, b = at(0, 0, 0), at(200, 300, 0)
    near(a[1], 100, 1, "left edge"); near(a[2], 900, 1, "foot")
    near(b[1], 300, 1, "right edge"); near(b[2], 600, 1, "head")
end)

t.test("the default pose lifts its lowest point and stays inside its gaps", function()
    local P, info = Pose.pose(200, 300, 30, { x = 100, base_y = 900, gap = 12 })
    eq(info.maxy, 900 - math.floor(Pose.LIFT * 300), "the lowest point is not lifted by LIFT")
    assert(info.minx >= 100 - 12 - 0.5 and info.maxx <= 300 + 12 + 0.5,
        string.format("the pose reaches past its gaps: %.1f..%.1f", info.minx, info.maxx))
end)

t.test("pulled toward the viewer it grows: the near edge is taller than the standing cover", function()
    local P = Pose.pose(200, 300, 30, { x = 100, base_y = 900, gap = 200 })   -- room to grow
    local _, top = P(200, 300, 0)
    local _, foot = P(200, 0, 0)
    assert(foot - top > 300 * 0.9, string.format("the near edge is %.1f tall", foot - top))
    local _, ltop = P(0, 300, 0); local _, lfoot = P(0, 0, 0)
    assert(foot - top > lfoot - ltop, "the near (fore-edge) side is not taller than the spine side")
end)

t.test("the fore-edge faces the viewer: it shows to the right of the cover", function()
    -- turned toward you, the fore-edge's back edge projects right of its
    -- front edge (W cos(yaw) + T cos(pitch) sin(yaw) > W cos(yaw))
    local P = Pose.pose(200, 300, 30, { x = 100, base_y = 900, gap = 12 })
    local fx = P(200, 150, 0)
    local bx = P(200, 150, -30)
    assert(bx > fx, "the turn shows the spine side, not the fore-edge")
end)

t.test("inverse maps a quad's corners and edges back to the unit square", function()
    local inv = Pose.inverse({ 100, 400 }, { 80, 390 }, { 70, 100 }, { 92, 110 })
    local u, v = inv(100, 400); near(u, 0, 1e-6); near(v, 0, 1e-6)
    u, v = inv(80, 390); near(u, 1, 1e-6); near(v, 0, 1e-6)
    u, v = inv(70, 100); near(u, 1, 1e-6); near(v, 1, 1e-6)
    u, v = inv(92, 110); near(u, 0, 1e-6); near(v, 1, 1e-6)
end)

t.test("spansV covers a quad column by column, inside its edges", function()
    local cols = {}
    Pose.spansV({ { 10, 20 }, { 20, 20 }, { 20, 40 }, { 10, 40 } }, function(x, y0, y1)
        cols[#cols + 1] = { x, y0, y1 }
    end)
    eq(#cols, 11)
    eq(cols[1][2], 20); eq(cols[1][3], 40)
end)

t.test("stripes are never finer than about 3px; the boards end the pages", function()
    eq(Pose.stripes({ 0, 0 }, { 6, 0 }), 3)
    eq(Pose.stripes({ 0, 0 }, { 30, 0 }), 10)
    eq(Pose.page(0.01, 10, 0.08), "board")
    eq(Pose.page(0.99, 10, 0.08), "board")
    assert(type(Pose.page(0.5, 10, 0.08)) == "number")
end)

t.done()
