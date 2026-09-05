-- tests/_test_chip_bar_border.lua
-- The chip strip's outline, on a custom selected-chip colour (#294 follow-up).
--
-- Reported from a screenshot with a light mauve chip set: the currently-reading
-- chip's pointer had no border on its sloped edges, and the separator between
-- that chip and Home vanished. Both are the same mistake -- code that assumed
-- the selected fill is BLACK, which it is by default and is not once a custom
-- colour is set.
--
-- Bodies are extracted by name and driven against a recording blitbuffer, as
-- _test_disk_available does: the widget is a file-local and the real one needs
-- a Screen, fonts and a UIManager.
package.path = "./?.lua;./?/init.lua;" .. package.path

local t   = dofile("tests/_helpers.lua").runner()
local src = io.open("lib/bookshelf_chip_bar.lua"):read("*a")

local function compile(code, env, name)
    if _G.setfenv then
        local f = assert(_G.loadstring(code, name))
        _G.setfenv(f, env)
        return f
    end
    return assert(load(code, name, "t", env))
end

local function color8(v)
    local c
    c = { a = v, getColor8 = function() return c end }
    return c
end
local WHITE, BLACK = color8(0xFF), color8(0x00)

-- ── the separator between two filled chips ─────────────────────────────────
local sep_body = src:match("\nlocal function _separatorOnFill%(fill%)\n(.-)\nend\n")
assert(sep_body, "could not find _separatorOnFill - renamed?")

local function separatorOn(fill)
    local env = { type = type, pcall = pcall,
                  Blitbuffer = { COLOR_WHITE = WHITE, COLOR_BLACK = BLACK } }
    local fn = compile("local fill = ...\n" .. sep_body, env, "_separatorOnFill")
    return fn(fill)
end

t.test("no custom colour keeps the historical white", function()
    -- The default selected chip is a black fill, and a black line between two
    -- black chips is invisible -- which is why this was white to begin with.
    assert(separatorOn(nil) == WHITE, "unset must stay white")
    assert(separatorOn(color8(0x00)) == WHITE, "a black fill needs a white line")
end)

t.test("a LIGHT custom fill gets a dark separator", function()
    -- The bug: a white line on a light mauve chip is not there at all.
    assert(separatorOn(color8(0xE0)) == BLACK, "light fill must take a dark line")
    assert(separatorOn(color8(0xD8)) == BLACK, "the reported mauve, roughly")
end)

t.test("a DARK custom fill still gets a white one", function()
    -- Decided on luminance, not on "is a custom colour set" -- getting that
    -- wrong would fix the mauve report and break every dark custom scheme.
    assert(separatorOn(color8(0x20)) == WHITE, "a dark custom fill still needs white")
end)

t.test("a colour that cannot answer falls back rather than erroring", function()
    local ok, res = pcall(separatorOn, { getColor8 = function() error("nope") end })
    assert(ok, "must not propagate")
    assert(res == WHITE, "fall back to the historical white")
    assert(separatorOn({}) == WHITE, "no getColor8 at all")
end)

-- ── the pointer's outline ──────────────────────────────────────────────────
local ptr_body = src:match("\nfunction UpTrianglePointer:paintTo%(bb, x, y%)\n(.-)\nend\n")
assert(ptr_body, "could not find UpTrianglePointer:paintTo - renamed?")

-- Paints into a pixel map so the shape can be read back per row.
local function paint(w, h, fill, outline, border)
    local px = {}
    local bb = {
        paintRect = function(_s, x, y, rw, rh, c)
            for iy = y, y + rh - 1 do
                for ix = x, x + rw - 1 do px[ix .. "," .. iy] = c end
            end
        end,
    }
    local self_ = { width = w, height = h, color = fill,
                    outline = outline, border = border }
    local env = { math = math }
    local fn = compile("local self, bb, x, y = ...\n" .. ptr_body, env, "paintTo")
    fn(self_, bb, 0, 0)
    return px
end

local function rowOf(px, w, dy)
    local out = {}
    for x = 0, w - 1 do out[#out + 1] = px[x .. "," .. dy] end
    return out
end

t.test("with no outline the pointer is the bare taper it always was", function()
    local w, h = 40, 10
    local px = paint(w, h, WHITE, nil, 1)
    local base = rowOf(px, w, h - 1)
    local painted = 0
    for _i, c in ipairs(base) do if c == WHITE then painted = painted + 1 end end
    assert(painted == w, "the base row should be full width, got " .. painted)
end)

t.test("an outlined pointer has the outline on both sloped edges", function()
    -- The defect: the fill ran to the very edge, so on a light chip the
    -- pointer had no border while the rest of the strip did.
    local w, h = 40, 10
    local px = paint(w, h, WHITE, BLACK, 1)
    for dy = 2, h - 2 do
        local row = rowOf(px, w, dy)
        local first, last
        for x = 1, w do
            if row[x] ~= nil then first = first or x; last = x end
        end
        assert(first and last, "row " .. dy .. " painted nothing")
        assert(row[first] == BLACK,
            "row " .. dy .. ": left edge must be the outline, not the fill")
        assert(row[last] == BLACK,
            "row " .. dy .. ": right edge must be the outline, not the fill")
    end
end)

t.test("the fill is still there inside the outline", function()
    -- An outline that swallowed the whole pointer would pass the edge test
    -- above and lose the custom colour the chip is being drawn in.
    local w, h = 40, 10
    local px = paint(w, h, WHITE, BLACK, 1)
    local fill_px = 0
    for dy = 0, h - 1 do
        for _i, c in ipairs(rowOf(px, w, dy)) do
            if c == WHITE then fill_px = fill_px + 1 end
        end
    end
    assert(fill_px > 0, "the pointer lost its fill entirely")
end)

t.test("the apex is outlined too, not left open", function()
    -- The top row is where the two slopes meet; leaving it as fill is the
    -- one-pixel version of the same bug.
    local px = paint(40, 10, WHITE, BLACK, 1)
    local top = rowOf(px, 40, 0)
    -- Count first: skipping nil pixels alone passes against a row that was
    -- never painted at all, which is what dropping the apex from the outline
    -- pass actually produces.
    local painted = 0
    for _i, c in ipairs(top) do
        if c ~= nil then
            painted = painted + 1
            assert(c == BLACK, "the apex row must be outline, not fill")
        end
    end
    assert(painted > 0, "the apex row was not painted at all")
end)

-- ── the pointer JOINS the chip, it does not sit on it ──────────────────────
-- overlap_offset is measured from the chip's CONTENT top, which is inside the
-- frame, so lifting by pointer_h alone leaves the pointer's last rows ON the
-- strip's top border and painting over it. That is deliberate: overpainting
-- the border across the pointer's own width is what merges the two into ONE
-- silhouette, with the outline running up the slopes and continuing along the
-- strip either side.
--
-- Lifting it clear of the border was tried and rejected: it gives the pointer
-- its full-width base back, but leaves a solid line across the join, and the
-- two then read as a triangle stacked on a box rather than one shape. The
-- narrower-looking base is the price of the join.
t.test("the pointer is NOT lifted clear of the frame border", function()
    local lifts = 0
    for expr in src:gmatch("pointer%.overlap_offset = { 0, ([^}]+) }") do
        lifts = lifts + 1
        assert(expr:match("^%-pointer_h$"),
            "a pointer is lifted by " .. expr .. "; clearing the border would "
            .. "leave a line across the join and split the silhouette in two")
    end
    assert(lifts >= 2, "expected both pointer sites, found " .. lifts)
end)

t.done()
