-- tests/_test_plank_design.lua
package.path = "./?.lua;" .. package.path
local t  = dofile("tests/_helpers.lua").runner()
local eq = dofile("tests/_helpers.lua").eq
local src = io.open("lib/bookshelf_spine_shelf.lua"):read("*a")
local body = src:match("(function SpineShelf%.plankDesignLayout%(.-\nend)\n")
assert(body, "plankDesignLayout not found")
local SpineShelf = { PLANK_SURFACE_SHARE = 0.8 }
assert(load("local SpineShelf = ...\n" .. body))(SpineShelf)
local L = SpineShelf.plankDesignLayout

-- The layout: plank.middle.png covers the ORIGINAL plank exactly; the ends
-- are anchored to the screen edges, or placed by their plank_end marker.
local function args(o)
    local a = { screen_w = 1236, row_x = 37, row_w = 1162, surf_h = 48, face_h = 9,
                mid = { w = 960, h = 360 }, left = nil, right = nil }
    for k, v in pairs(o or {}) do a[k] = v end
    return a
end

t.test("vertical: the middle band splits 80/20 into surface and face, each fitted", function()
    local l = L(args())
    eq(l.surf0, 96); eq(l.face0, 24)            -- native: band 120 -> 96 + 24
    eq(l.top_h, math.floor(120 * 57 / 120 + 0.5), "outer bands scale with the plank")
    eq(l.bot_h, l.top_h)
    eq(l.surf_h, 48); eq(l.face_h, 9)
end)

t.test("the middle tiles cover the original plank, no more, no less", function()
    local l = L(args())
    eq(l.tiles[1], 37, "starts at the plank's left end")
    eq(l.clip_x0, 37); eq(l.clip_x1, 37 + 1162, "clipped at its right end")
    eq(l.tiles[#l.tiles] < 37 + 1162, true)
    eq(l.tiles[#l.tiles] + l.mid_w >= 37 + 1162, true, "and reaches it")
end)

t.test("ends without a marker sit flush with the screen edges", function()
    local l = L(args{ left = { w = 200, h = 360 }, right = { w = 200, h = 360 } })
    eq(l.left_x, 0); eq(l.right_x + l.right_w, 1236)
    eq(l.left_w, math.floor(200 * 57 / 120 + 0.5))
end)

t.test("an end's plank_end marker lands on the real plank end", function()
    local l = L(args{ left = { w = 200, h = 360, edge = 60 }, right = { w = 200, h = 360, edge = 60 } })
    local e = math.floor(60 * 57 / 120 + 0.5)
    eq(l.left_x + e, 37, "left marker on the plank's left end")
    eq(l.right_x + l.right_w - e, 37 + 1162, "right marker on its right end")
end)

t.test("narrow screen: ends never exceed half the screen", function()
    local l = L(args{ screen_w = 100, row_x = 5, row_w = 90,
                      left = { w = 900, h = 360 }, right = { w = 900, h = 360 } })
    eq(l.left_w <= 50, true); eq(l.right_w <= 50, true)
end)

t.test("a solid end (plank_solid) is carried by the layout; plain ends are not", function()
    local l = L(args{ left = { w = 200, h = 360, edge = 60, solid = true }, right = { w = 200, h = 360, edge = 60 } })
    eq(l.left_solid, true); eq(l.right_solid, false)
    eq(L(args()).left_solid, false, "no end image, no solid end")
end)

t.test("a solid end replaces the middle under it: no fade there, the middle cut to its inner edge", function()
    -- Maintainer: the middle's fade under a fading end overlapped awkwardly.
    assert(src:find('text:find("bookshelf:plank_solid", 1, true)', 1, true), "plank_solid not read from the PNG")
    local taper = src:match("local function _taperBands%(.-\nend")
    assert(taper and taper:find("l.left_solid", 1, true) and taper:find("l.right_solid", 1, true),
        "the fade still runs under a solid end")
    local strip = src:match("local function _designStrip%(.-\nend")
    assert(strip and strip:find("cut(l.clip_x0, l.left_x + l.left_w)", 1, true)
        and strip:find("cut(l.right_x, l.clip_x1)", 1, true), "the middle is not cut under a solid end")
end)

t.test("an end image is composited OVER the strip, alpha included", function()
    -- alphablitFrom keeps the target's alpha, so an end's part-transparent
    -- shadow or soft edge over a cut or blank part of the strip vanished.
    local strip = src:match("local function _designStrip%(.-\nend\n")
    assert(strip and not strip:find("strip:alphablitFrom(e,", 1, true), "ends still alphablit (target alpha kept)")
    assert(strip:find("d.alpha = math.floor(oa + 0.5)", 1, true), "the end's alpha is not combined into the strip")
end)

t.test("slots render see-through over a plank design, and repainters redraw it", function()
    assert(src:find("function SpineShelf.seeThrough()", 1, true), "no seeThrough")
    local slot = src:match("function SpineBookSlot:paintTo%(.-\nend")
    assert(slot and not slot:find("SpineShelf.has_wallpaper", 1, true),
        "slot paint still keys transparency on the wallpaper alone")
    local key = src:match("function SpineBookSlot:_renderKey%(.-\nend")
    assert(key and key:find("seeThrough()", 1, true), "render key ignores the design")
    -- fillLiftGap and nickFromBelow copy neighbouring SCREEN pixels, which
    -- already carry the design. The two that paint computed plank colour
    -- must, over a design, DARKEN it instead: the shadow is kept, and the
    -- design is not painted out.
    for _i, fn in ipairs({ "LiftShadow:paintTo", "FaceOutFeet:paintTo" }) do
        local b = src:match("function " .. fn:gsub("%.", "%%."):gsub(":", "%%:") .. "%(.-\nend")
        assert(b and b:find("activePlankDesign()", 1, true) and b:find("shadeDesign(", 1, true),
            fn .. " must shade a plank design, not paint over it")
        assert(not b:find("redrawDesign(", 1, true), fn .. " still paints the shadow out")
    end
end)



t.test("the plank design goes UNDER the recess, so the books' shadows fall on it", function()
    local rw = src:match("function SpineShelf%.rowWidget%(.-\nend\n")
    local d  = rw:find("children[#children + 1] = design", 1, true)
    local r  = rw:find("children[#children + 1] = recess", 1, true)
    local g  = rw:find("children[#children + 1] = group", 1, true)
    assert(d and r and g and d < r and r < g, "order must be plank, design, recess, books")
end)


t.test("the plank design runs edge to edge of its target, not just the row", function()
    -- Across the TARGET's width whenever it is wider than the row: the screen,
    -- and the page wipe's screen-sized offscreen buffer, which a test of
    -- bb == Screen.bb missed, so every wiped page turn cut off the end art
    -- drawn beyond the plank ends (Night Sky's knobs, Cats' arms).
    local pd = src:match("function PlankDesign:paintTo%(.-\nend")
    assert(pd and pd:find("bb:getWidth()", 1, true), "design is clipped to the row's margins")
    assert(not pd:find("bb == Screen.bb", 1, true),
        "only the framebuffer gets the full-width strip; the page wipe's buffer crops the ends")
end)


t.test("the middle's above/below bands fade out at the plank ends (no hard shadow edge)", function()
    local ds = src:match("local function _designStrip%(.-\nend\n")
    assert(ds and ds:find("_taperBands(", 1, true), "the middle's outer bands are cut square at the plank ends")
end)


t.test("footer page buttons drop their white fill over a plank design, not only over a wallpaper", function()
    local w = io.open("lib/bookshelf_widget.lua"):read("*a")
    local i = w:find('require("lib/bookshelf_wallpaper").unfill(', 1, true)
    local before = i and w:sub(math.max(1, i - 700), i) or ""
    assert(before:find("activePlankDesign", 1, true),
        "unfill is gated on the painted ground alone: white boxes show over a design's lower band")
end)


t.test("plank art is unpremultiplied once when loaded (MuPDF decodes it premultiplied)", function()
    -- A premultiplied bitmap blended as straight alpha darkens every
    -- half-transparent pixel twice: a dark band where each end fades into the
    -- middle. Converting at load keeps every blit and the night inversion on
    -- the straight-alpha path, which the night frame handles correctly.
    local bi = src:match("local function _bandImage%(.-\nend\n")
    assert(bi and bi:find("_unpremultiply(", 1, true), "decoded plank art is used premultiplied")
    assert(src:find("local function _unpremultiply(", 1, true))
end)

-- alphaRegions: the design strip painted as few alpha blends as it can
-- (PW5 profile: the whole strip alpha-blended on every row, every paint, was
-- ~20% of a spine tap). Empty rows skipped, opaque spans copied, only the
-- rest blended.
local rbody = src:match("(function SpineShelf%.alphaRegions%(.-\nend)\n")
assert(rbody, "alphaRegions not found")
local R = { MAX_ALPHA_REGIONS = 64 }
assert(load("local SpineShelf = ...\n" .. rbody))(R)

local function grid(rows)   -- rows of strings: . = 0, # = 255, + = partial
    local h, w = #rows, #rows[1]
    local map = { ["."] = 0, ["#"] = 255, ["+"] = 128 }
    return w, h, function(x, y) return map[rows[y + 1]:sub(x + 1, x + 1)] end
end
local function covers(rects, w, h, alphaAt)
    -- every pixel with alpha > 0 in exactly one rect, of the right kind
    local hit = {}
    for _i, r in ipairs(rects) do
        for y = r.y, r.y + r.h - 1 do for x = r.x, r.x + r.w - 1 do
            local k = y * w + x
            assert(not hit[k], "pixel " .. x .. "," .. y .. " painted twice")
            hit[k] = true
            local a = alphaAt(x, y)
            assert(a > 0, "a transparent pixel is painted")
            if r.solid then assert(a == 255, "a partial pixel copied without blending") end
        end end
    end
    for y = 0, h - 1 do for x = 0, w - 1 do
        if alphaAt(x, y) > 0 then assert(hit[y * w + x], "pixel " .. x .. "," .. y .. " left out") end
    end end
end

t.test("alphaRegions: transparent rows skipped, solid copied, edges blended, rows merged", function()
    local w, h, a = grid({
        "..........",
        "..........",
        "+########+",
        "+########+",
        "+########+",
        "++++++++++",
        "..++++++..",
    })
    local rects = R.alphaRegions(w, h, a)
    covers(rects, w, h, a)
    -- the three solid middle rows are ONE copy
    local solid = 0
    for _i, r in ipairs(rects) do if r.solid then solid = solid + 1; eq(r.h, 3, "solid rows not merged") end end
    eq(solid, 1)
    eq(#rects, 5, "3 regions for the middle band, 1 per shadow row")
end)

t.test("alphaRegions: an all-transparent strip paints nothing; noise falls back to one blend", function()
    local w, h, a = grid({ "....", "...." })
    eq(#R.alphaRegions(w, h, a), 0)
    -- A strip too fragmented to be worth it (every pixel changes class): one blend.
    local rows = {}
    for y = 1, 30 do
        local r = {}
        for x = 1, 40 do r[x] = ((x + y) % 2 == 0) and "#" or "+" end
        rows[y] = table.concat(r)
    end
    local w2, h2, a2 = grid(rows)
    local rects = R.alphaRegions(w2, h2, a2)
    eq(#rects, 1, "fragmented: fall back to one blend")
    eq(rects[1].solid, false)
    eq(rects[1].w, w2); eq(rects[1].h, h2)
end)

t.done()
