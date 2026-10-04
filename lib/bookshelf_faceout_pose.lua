-- lib/bookshelf_faceout_pose.lua
-- The face-out opening pose: a book "pulled off the shelf" by an invisible
-- hand on its right edge -- tipped forward, turned so the fore-edge shows,
-- lifted and drawn a little toward the viewer (maintainer, 2026-10-04).
--
-- Pure maths, no KOReader: the projection, the fit into the book's own space
-- on the shelf, the inverse of a face (so each screen pixel finds where it is
-- on that face), column spans over a projected quad, and the page stripes.
-- The painter is SpineShelf.paintFaceOutTilt.
--
-- The book, in its own units (pixels): x across the cover (0 at the spine),
-- y up (0 at the foot), z toward the viewer (0 at the front cover, -T at the
-- back). The camera is the shelf's own: orthographic, pitched down VIEW_DEG
-- (the standing page blocks are drawn from it), with a weak perspective so
-- the near edge grows as the book turns toward you.
local M = {}

M.VIEW_DEG  = 12       -- the shelf camera's pitch (SpineLayout.VIEW_SIN)
M.PITCH_DEG = 20       -- tipped forward about the foot
M.YAW_DEG   = 30       -- turned about the spine edge, fore-edge toward you
M.LIFT      = 0.16     -- the lowest point rises this share of the height
M.PULL      = 0.5      -- drawn toward the viewer, as a share of the height
M.Z0        = 4.5      -- the camera distance, as a share of the height

-- pose(W, H, T, opts) -> P, info. P(x, y, z) -> screen x, y. opts:
--   x, base_y  the standing cover's left edge and foot on screen
--   gap        how far past its own width the posed book may reach (the
--              face-out gap either side); it is scaled down only past that
--   pitch, yaw, lift, pull   override the defaults (degrees; shares of H)
-- info: { k = the fit scale, lift = pixels, minx, maxx, miny, maxy }.
function M.pose(W, H, T, opts)
    opts = opts or {}
    local A  = math.rad(M.VIEW_DEG)
    local th = math.rad(opts.pitch or M.PITCH_DEG)
    local ph = math.rad(opts.yaw or M.YAW_DEG)
    local pull = (opts.pull or M.PULL) * H
    local Z0 = M.Z0 * H
    local cA, sA = math.cos(A), math.sin(A)
    local cth, sth, cph, sph = math.cos(th), math.sin(th), math.cos(ph), math.sin(ph)
    local function raw(x, y, z)
        -- tip forward about the bottom-front edge
        local y1 = y * cth - z * sth
        local z1 = y * sth + z * cth
        -- turn about the spine's front edge: the fore-edge comes toward you
        local x2 = x * cph - z1 * sph
        local z2 = x * sph + z1 * cph + pull
        -- the shelf camera (heights normalised so a standing cover keeps its
        -- height) and the weak perspective
        local up  = (y1 * cA - z2 * sA) / cA
        local dep = y1 * sA + z2 * cA
        local s = Z0 / (Z0 - dep)
        return x2 * s, -up * s
    end
    -- the posed box's extent, for the fit
    local minx, maxx, miny, maxy = math.huge, -math.huge, math.huge, -math.huge
    for _i, c in ipairs({ { 0, 0, 0 }, { W, 0, 0 }, { W, H, 0 }, { 0, H, 0 },
                          { 0, 0, -T }, { W, 0, -T }, { W, H, -T }, { 0, H, -T } }) do
        local a, b = raw(c[1], c[2], c[3])
        if a < minx then minx = a end
        if a > maxx then maxx = a end
        if b < miny then miny = b end
        if b > maxy then maxy = b end
    end
    -- Grown by the perspective; scaled down only if it would reach past the
    -- face-out gap either side, so it never covers its neighbours.
    local room = W + 2 * (opts.gap or 0)
    local k = math.min(1, room / math.max(1, maxx - minx))
    local cx = (opts.x or 0) + W / 2
    local lift = math.floor((opts.lift or M.LIFT) * H)
    local base_y = (opts.base_y or 0) - lift
    local mid = (minx + maxx) / 2
    local function P(x, y, z)
        local a, b = raw(x, y, z)
        return cx + k * (a - mid), base_y + k * (b - maxy)
    end
    return P, { k = k, lift = lift,
                minx = cx + k * (minx - mid), maxx = cx + k * (maxx - mid),
                miny = base_y + k * (miny - maxy), maxy = base_y }
end

-- inverse(p0, p1, p2, p3) -> fn(x, y) -> u, v: the screen quad's own
-- coordinates, p0 = (0,0), p1 = (1,0), p2 = (1,1), p3 = (0,1). A projective
-- map (Heckbert's square-to-quad), inverted by its adjugate.
function M.inverse(p0, p1, p2, p3)
    local x0, y0, x1, y1 = p0[1], p0[2], p1[1], p1[2]
    local x2, y2, x3, y3 = p2[1], p2[2], p3[1], p3[2]
    local dx1, dx2, dy1, dy2 = x1 - x2, x3 - x2, y1 - y2, y3 - y2
    local sx, sy = x0 - x1 + x2 - x3, y0 - y1 + y2 - y3
    local den = dx1 * dy2 - dx2 * dy1
    if den == 0 then den = 1e-9 end
    local g = (sx * dy2 - dx2 * sy) / den
    local h = (dx1 * sy - sx * dy1) / den
    local a, b, c = x1 - x0 + g * x1, x3 - x0 + h * x3, x0
    local d, e, f = y1 - y0 + g * y1, y3 - y0 + h * y3, y0
    local A1, B1, C1 = e - f * h, c * h - b, b * f - c * e
    local D1, E1, F1 = f * g - d, a - c * g, c * d - a * f
    local G1, H1, I1 = d * h - e * g, b * g - a * h, a * e - b * d
    return function(x, y)
        local w = G1 * x + H1 * y + I1
        if w == 0 then w = 1e-9 end
        return (A1 * x + B1 * y + C1) / w, (D1 * x + E1 * y + F1) / w
    end
end

-- spansV(quad, fn): fn(x, y0, y1) for each screen column the quad covers,
-- y1 exclusive. Every face goes through this one rasteriser, so faces that
-- share an edge meet on it.
function M.spansV(q, fn)
    local minx, maxx = math.huge, -math.huge
    for _i, p in ipairs(q) do
        if p[1] < minx then minx = p[1] end
        if p[1] > maxx then maxx = p[1] end
    end
    for x = math.floor(minx), math.ceil(maxx) do
        local lo, hi
        for k = 1, 4 do
            local a, b = q[k], q[k % 4 + 1]
            if (a[1] <= x and b[1] >= x) or (b[1] <= x and a[1] >= x) then
                local ys
                if a[1] == b[1] then
                    ys = { a[2], b[2] }
                else
                    ys = { a[2] + (b[2] - a[2]) * (x - a[1]) / (b[1] - a[1]) }
                end
                for _j, y in ipairs(ys) do
                    if not lo or y < lo then lo = y end
                    if not hi or y > hi then hi = y end
                end
            end
        end
        if lo then
            local y0, y1 = math.floor(lo), math.ceil(hi)
            if y1 > y0 then fn(x, y0, y1) end
        end
    end
end

-- stripes(a, b) -> how many page stripes fit across a face whose screen
-- width runs from point a to point b: none finer than ~3px, or they alias
-- into a diagonal moire instead of page lines.
function M.stripes(a, b)
    local dx, dy = b[1] - a[1], b[2] - a[2]
    return math.max(3, math.floor(math.sqrt(dx * dx + dy * dy) / 3))
end

-- page(t, n, board) -> "board", or the stripe's tone (0..255): t runs 0..1
-- across the pages, the boards take `board` of it at each end.
function M.page(t, n, board)
    if t < board or t > 1 - board then return "board" end
    local k = math.floor(t * n)
    return ((k * 73 + 41) % 2 == 0) and 0xA2 or 0xEA
end

return M
