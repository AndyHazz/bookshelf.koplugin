-- tests/_test_ornament_hanging.lua
-- A piece that hangs from the shelf above (maintainer, 5.3 review): the
-- height nudge still moves it, so a piece whose image has room above its
-- drawing can connect to the shelf; and it is painted BEHIND the shelf above
-- and its shadow, which means the row above paints it, before its plank.
-- Usage (from plugin root): lua tests/_test_ornament_hanging.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t, eq = helpers.runner(), helpers.eq
local widget = io.open("lib/bookshelf_widget.lua"):read("*a")
local shelf = io.open("lib/bookshelf_spine_shelf.lua"):read("*a")
local orn = io.open("lib/bookshelf_ornaments.lua"):read("*a")

local function extract(src, name)
    local pat = "\nfunction " .. name:gsub("[%.%(%)]", "%%%0") .. "\n(.-)\nend\n"
    local body = src:match(pat)
    assert(body, name .. " not found")
    return body
end

t.test("a hanging piece moves to the row above, first, one row pitch down", function()
    local hang = load("return function(self, rows, pitch, top_gap)\n"
        .. extract(widget, "BookshelfWidget:_hangUnder(rows, pitch, top_gap)") .. "\nend",
        "hang", "t", { ipairs = ipairs, table = table })()
    local plank1, plank2 = { name = "plank1" }, { name = "plank2" }
    local bat = { name = "bat", overlap_offset = { 900, -40 } }
    local rows = { { plank1 }, { plank2, _hanging = { bat } } }
    hang({}, rows, 300)
    eq(rows[1][1], bat, "not painted first by the row above (so before its plank)")
    eq(rows[1][2], plank1)
    eq(bat.overlap_offset[1], 900); eq(bat.overlap_offset[2], 260, "not moved down by the pitch")
    eq(#rows[2]._hanging, 0, "left behind in its own row too: painted twice")
    for _i, w in ipairs(rows[2]) do assert(w ~= bat, "still a child of its own row") end
end)

t.test("both ways a page is built hand them over", function()
    local n = select(2, widget:gsub("self:_hangUnder%(rows, ", ""))
    eq(n, 2, "the rebuild and the swap in place must both move hanging pieces")
    assert(widget:find("row_pitch            = shelf_h + grid_between", 1, true), "the swap has no pitch to use")
    assert(widget:find("self:_hangUnder(rows, shelf_h + grid_between, hang_top_gap)", 1, true), "the rebuild does not say where row 1 hangs from")
    assert(widget:find("self:_hangUnder(rows, d.row_pitch, d.hang_top_gap)", 1, true), "the swap does not say where row 1 hangs from")
    assert(widget:find("hang_top_gap         = hang_top_gap", 1, true), "the swap has no top gap to use")
end)

t.test("the row keeps hanging pieces out of its own children, in all three slots", function()
    -- In rowWidget itself: the pack editor's ornamentRow has its own.
    local row_body = shelf:match("function SpineShelf%.rowWidget.-\nend\n")
    local n = select(2, row_body:gsub("hanging%[#hanging %+ 1%] = w_", ""))
    eq(n, 3, "row end, section gap and a lead piece at a row's start")
    assert(shelf:find("if ornament and SpineShelf.behindAbove(ornament.placement, ornament.overlap_offset[2], opts) then", 1, true), "bare plank")
    assert(shelf:find("row_group._hanging, row_group._orn_list = hanging, orn_list", 1, true))
end)

t.test("a piece that rises above its row goes behind the shelf above, like a hanging one", function()
    -- Maintainer: large pieces rose over the row above; like hanging pieces
    -- they should go behind the shelf above. Not on a page's first row: there
    -- is no shelf above to go behind.
    local body = shelf:match("\n(function SpineShelf%.behindAbove%(pl, y, opts%)\n.-\nend)\n")
    assert(body, "no SpineShelf.behindAbove")
    local env = setmetatable({ SpineShelf = {} }, { __index = _G })
    local f
    if _G.setfenv then f = assert(loadstring(body)); setfenv(f, env) else f = assert(load(body, "b", "t", env)) end
    f()
    local ba = env.SpineShelf.behindAbove
    eq(ba({}, -5, { row_index = 2 }), true, "a piece rising above its row")
    eq(ba({}, 0, { row_index = 2 }), false, "a piece within its row")
    eq(ba({}, -5, { row_index = 1 }), false, "the first row has no shelf above")
    local rw = shelf:match("\nfunction SpineShelf%.rowWidget%(opts%)\n(.-)\nfunction SpineShelf%.")
    local n = select(2, rw:gsub("SpineShelf%.behindAbove%(", ""))
    eq(n, 4, "the row end, the section gap, the lead piece and the bare plank must all decide this way")
end)

t.test("negative padding may take a piece behind the books beside it", function()
    -- Maintainer: tightening should be able to go behind the adjacent books.
    -- So the pieces paint before the books (after the plank and the recess),
    -- and the padding may go past the drawing's edge, down to half the piece.
    local rw = shelf:match("\nfunction SpineShelf%.rowWidget%(opts%)\n(.-)\nfunction SpineShelf%.")
    local g = rw:find("children[#children + 1] = group", 1, true)
    local o = rw:find("children[#children + 1] = ornament end", 1, true)
    local gp = rw:find("children[#children + 1] = gap_ornaments[_i]", 1, true)
    assert(g and o and gp and o < g and gp < g, "pieces are painted over the books")
    local rec = rw:find("if recess then children[#children + 1] = recess end", 1, true)
    assert(rec and rec < gp, "pieces are painted under the recess shading")
    local body = shelf:match("\n(function SpineShelf%.ornPad%(base, pl%)\n.-\nend)\n")
    local env = setmetatable({ SpineShelf = {} }, { __index = _G })
    local f
    if _G.setfenv then f = assert(loadstring(body)); setfenv(f, env) else f = assert(load(body, "p", "t", env)) end
    f()
    eq(env.SpineShelf.ornPad(10, { w = 100, pad_px = -30 }), -20, "tightening stopped short of the books")
    eq(env.SpineShelf.ornPad(10, { w = 100, pad_px = -500 }), -50, "a piece may not tighten past half its width")
    eq(env.SpineShelf.ornPad(10, { w = 100, pad_px = 5 }), 15)
end)

t.test("a tall standing piece stays in front of its own shelf while its top goes behind the one above", function()
    -- Device: growing a piece until it rose above its row made it pop behind
    -- its OWN shelf too: handed wholly to the row above, it was painted
    -- before its own plank. Now the row above paints it whole (behind that
    -- shelf) and its own row paints it again, cropped to the row, in front.
    local body = shelf:match("\n(function SpineShelf%.ownRowPart%(w_, Orn%)\n.-\nend)\n")
    assert(body, "no SpineShelf.ownRowPart")
    local env = setmetatable({ SpineShelf = {} }, { __index = _G })
    local f
    if _G.setfenv then f = assert(loadstring(body)); setfenv(f, env) else f = assert(load(body, "o", "t", env)) end
    f()
    local made
    local Orn = { Ornament = { new = function(_self, t) made = t; return t end } }
    local pl = { w = 100, h = 300, entry = {} }
    local part = env.SpineShelf.ownRowPart({ placement = pl, night = false, overlap_offset = { 40, -120 } }, Orn)
    eq(part.overlap_offset[1], 40); eq(part.overlap_offset[2], 0, "the own-row copy does not start at the row's top")
    eq(part.placement.crop.y, 120, "the risen part is not cropped away")
    eq(part.placement.crop.h, 180)
    eq(part.placement.w, 100, "the copy lost the placement")
    assert(pl.crop == nil, "the shared placement was changed")
    eq(env.SpineShelf.ownRowPart({ placement = { w = 10, h = 10 }, overlap_offset = { 0, 5 } }, Orn), nil,
       "a piece within its row got an own-row copy")
    local rw = shelf:match("\nfunction SpineShelf%.rowWidget%(opts%)\n(.-)\nfunction SpineShelf%.")
    eq(select(2, rw:gsub("SpineShelf%.ownRowPart%(", "")), 4, "every slot must keep its own-row part")
end)

t.test("height: an anchor (bottom on the plank, top under the shelf above) and an offset in shelf heights", function()
    -- Maintainer: "for a tall ornament, if you increase size so it's nearly
    -- full height of the shelf, the % height doesn't act usefully". Height was
    -- a fraction of the space left ABOVE the piece, so a piece filling the
    -- shelf moved a few px for 10%. Now the anchor pins a piece to its plank
    -- (bottom) or under the shelf above (top, the drawing's top against the
    -- underside, whatever the sizes), and height moves it from there by a
    -- share of the shelf's stand height, the same for every piece.
    local body = shelf:match("\n(function SpineShelf%.ornamentY%(pl, stand_h, opts%)\n.-\nend)\n")
    assert(body, "ornamentY not found")
    local env = setmetatable({ SpineShelf = {}, Screen = { scaleBySize = function(_s, v) return v end } },
                             { __index = _G })
    local f
    if _G.setfenv then f = assert(loadstring(body)); setfenv(f, env) else f = assert(load(body, "y", "t", env)) end
    f()
    local Y = env.SpineShelf.ornamentY
    for _i, g in ipairs({ { stand = 280, head = 40 }, { stand = 190, head = 30 }, { stand = 400, head = 60 } }) do
        local pl = { above = 200, h = 200, anchor = "top", offset = 0, content_top = 25 }
        local top = Y(pl, g.stand, { lift_headroom = g.head })
        eq(top + pl.content_top, -(g.head + 2), "top does not meet the shelf above at stand " .. g.stand)
        pl.offset = -0.1
        eq(Y(pl, g.stand, { lift_headroom = g.head }), top + math.floor(0.1 * g.stand + 0.5), "-10% from the top is not a tenth of the shelf lower")
        pl.anchor, pl.offset = "bottom", 0
        eq(Y(pl, g.stand, { lift_headroom = g.head }), g.stand - 200, "bottom at 0% is not standing")
    end
    -- The same step moves a small piece and one filling the shelf alike.
    local small = { above = 60,  h = 60,  anchor = "bottom", offset = 0.1 }
    local tall  = { above = 270, h = 270, anchor = "bottom", offset = 0.1 }
    eq((280 - 60) - Y(small, 280, {}), 28)
    eq((280 - 270) - Y(tall, 280, {}), 28, "a tall piece moves less than a small one for the same step")
    local dangle = { above = 200, h = 200, anchor = "bottom", offset = -0.2 }
    assert(Y(dangle, 280, {}) > 80, "below 0% does not dangle")
    assert(not shelf:find("hang_lift", 1, true), "the old hang offset is still read")
end)

t.test("a hanging piece meets the shelf above as the plank design draws it, not the nominal plank", function()
    -- Device: a scroll's top was hidden behind the Cinnabar plank's carved
    -- apron, which hangs a band below the nominal plank. Below row 1 the top
    -- drops by designDrop at the row's height; row 1 hangs from the top panel.
    local body = shelf:match("\n(function SpineShelf%.ornamentY%(pl, stand_h, opts%)\n.-\nend)\n")
    local asked
    local env = setmetatable({ SpineShelf = { designDrop = function(h) asked = h; return 37 end },
                               Screen = { scaleBySize = function(_s, v) return v end } },
                             { __index = _G })
    local f
    if _G.setfenv then f = assert(loadstring(body)); setfenv(f, env) else f = assert(load(body, "y", "t", env)) end
    f()
    local Y = env.SpineShelf.ornamentY
    local pl = { above = 200, h = 200, anchor = "top", offset = 0, content_top = 25 }
    eq(Y(pl, 280, { lift_headroom = 35, row_index = 2, height = 423 }) + 25, -37 + 37, "not under the drawn shelf")
    eq(asked, 423, "measured at another row height")
    asked = nil
    eq(Y(pl, 280, { lift_headroom = 35, row_index = 1, height = 423 }) + 25, -37, "row 1 moved off the top panel")
    eq(asked, nil, "row 1 asked for the design's drop")
    pl.anchor = "bottom"
    eq(Y(pl, 280, { lift_headroom = 35, row_index = 2, height = 423 }), 80, "a standing piece moved")
end)

t.test("a height is corrected to the real gap between rows before anything is handed up", function()
    -- Rig: a piece at 100% stopped short of the shelf above by the screen
    -- slack GridMargins spreads between rows, which is only known after the
    -- rows are built. Each row notes its pieces off 0% with the gap they
    -- were built against; _hangUnder moves them by height x the difference.
    local hang = load("return function(self, rows, pitch, top_gap)\n"
        .. extract(widget, "BookshelfWidget:_hangUnder(rows, pitch, top_gap)") .. "\nend",
        "hang", "t", { ipairs = ipairs, table = table, math = math })()
    local up = { name = "up", overlap_offset = { 10, 50 } }
    local half = { name = "half", overlap_offset = { 20, 100 } }
    local crop = { x = 0, y = 30, w = 50, h = 170 }
    local risen = { name = "risen", overlap_offset = { 30, -30 } }
    local part = { name = "part", overlap_offset = { 30, 0 }, placement = { h = 200, crop = crop } }
    local row2 = { { name = "plank2" }, up, half, part, _hanging = { risen },
                   _orn_list = { { w = up, t = 1, gap = 40, rh = 280 },
                                 { w = half, t = 0.5, gap = 40, rh = 280 },
                                 { w = risen, t = 1.2, gap = 40, rh = 280, part = part } } }
    local rows = { { { name = "plank1" } }, row2 }
    hang({}, rows, 280 + 60)                -- the real gap is 60, built against 40
    eq(up.overlap_offset[2], 30, "100% did not move up by the whole slack")
    eq(half.overlap_offset[2], 90, "50% did not move up by half of it")
    eq(risen.overlap_offset[2], -54 + 340, "a risen piece was not corrected before it was handed up")
    eq(crop.y, 54, "its own-row copy's crop did not follow"); eq(crop.h, 146)
end)

t.test("a piece dangling into the row below is painted in front of that row's books", function()
    -- Device: glasses on row 1 lowered to -10% hung behind the books of row
    -- 2, which paints later. The row below now paints the part below its own
    -- top AFTER its books; the piece's own row keeps the rest (cropped, so
    -- no part is painted twice).
    local made = {}
    local Orn = { Ornament = { new = function(_s, t) made[#made + 1] = t; return t end } }
    local hang = load("return function(self, rows, pitch, top_gap)\n"
        .. extract(widget, "BookshelfWidget:_hangUnder(rows, pitch, top_gap)") .. "\nend",
        "hang", "t", { ipairs = ipairs, table = table, math = math, setmetatable = setmetatable,
                       require = function(m) if m == "lib/bookshelf_ornaments" then return Orn end return require(m) end })()
    local pl = { w = 300, h = 120, entry = {} }
    local glasses = { name = "glasses", placement = pl, overlap_offset = { 50, 300 } }
    local books2 = { name = "books2" }
    local rows = { { { name = "plank1" }, glasses, _orn_list = { { w = glasses, t = 0, dangle = true, gap = 40, rh = 340 } } },
                   { { name = "plank2" }, books2 } }
    hang({}, rows, 380)                      -- row 2 starts 380 below row 1's top
    local below = rows[2][#rows[2]]
    assert(below ~= books2 and below.placement, "the row below does not paint the dangling part after its books")
    eq(below.overlap_offset[1], 50); eq(below.overlap_offset[2], 0)
    eq(below.placement.crop.y, 80, "the part below row 2's top does not start there")
    eq(below.placement.crop.h, 40)
    eq(glasses.placement.crop.h, 80, "the own row still paints the part the row below does")
    assert(pl.crop == nil, "the shared placement was changed")
    local within = { name = "w", placement = { w = 10, h = 10 }, overlap_offset = { 0, 100 } }
    local rows2 = { { within, _orn_list = { { w = within, t = -0.1, gap = 40, rh = 340 } } }, { { name = "p" } } }
    hang({}, rows2, 380)
    eq(#rows2[2], 1, "a piece that stays in its row was copied into the row below")
end)

t.test("a page's first row hangs its pieces from the bottom of the top panel", function()
    -- Maintainer: a top shelf takes hanging pieces, anchored to the bottom
    -- of the top panel instead of a shelf above. Built against the nominal
    -- row gap (40), the piece moves up to the visible gap under the panel
    -- (70): its drawing's top meets the panel's bottom.
    local made = {}
    local Orn = { Ornament = { new = function(_s, o) made[#made + 1] = o; return o end } }
    local hang = load("return function(self, rows, pitch, top_gap)\n"
        .. extract(widget, "BookshelfWidget:_hangUnder(rows, pitch, top_gap)") .. "\nend",
        "hang", "t", { ipairs = ipairs, table = table, math = math, setmetatable = setmetatable,
                       require = function(m) if m == "lib/bookshelf_ornaments" then return Orn end return require(m) end })()
    local pl = { w = 100, h = 200 }
    local frame = { name = "frame", placement = pl, overlap_offset = { 10, -40 } }
    local cup = { name = "cup", placement = { w = 10, h = 10 }, overlap_offset = { 0, 100 } }
    local rows = { { { name = "plank1" }, frame, cup,
                     _orn_list = { { w = frame, t = 1, gap = 40, rh = 280 },
                                   { w = cup, t = 0, dangle = true, gap = 40, rh = 280 } } },
                   { { name = "plank2" } } }
    hang({}, rows, 340, 70)
    eq(frame.overlap_offset[2], -70, "row 1's hanging piece does not meet the panel's bottom")
    eq(cup.overlap_offset[2], 100, "a piece anchored to its own plank moved")
    eq(frame.placement, pl, "a piece that reaches no higher than the panel's bottom was cropped")
    -- Raised past the panel's bottom (a positive height nudge): the part
    -- above it is cut off, so the piece never paints over the panel.
    local pl2 = { w = 100, h = 200 }
    local tall = { name = "tall", placement = pl2, overlap_offset = { 10, -60 } }
    local rows2 = { { { name = "plank1" }, tall, _orn_list = { { w = tall, t = 1, gap = 40, rh = 280 } } } }
    hang({}, rows2, 340, 70)
    eq(tall.overlap_offset[2], -70, "the cropped piece does not start at the panel's bottom")
    eq(tall.placement.crop.y, 20, "the part above the panel's bottom was not cut off")
    eq(tall.placement.crop.h, 180)
    assert(pl2.crop == nil, "the shared placement was changed")
    -- No top gap known (an older caller): row 1 is left as it was built.
    local still = { name = "still", placement = { w = 1, h = 1 }, overlap_offset = { 0, -40 } }
    hang({}, { { still, _orn_list = { { w = still, t = 1, gap = 40, rh = 280 } } } }, 340, nil)
    eq(still.overlap_offset[2], -40)
end)

t.test("the page turn repaints down from the panel's bottom", function()
    -- A row-1 piece reaches up to the panel's bottom, which the expanded
    -- view's spread slack can put above the PAD band the refresh reclaimed:
    -- the old page's piece would stay on screen there.
    local top = load("return function(shelf_top, d)\n"
        .. extract(widget, "BookshelfWidget._rowsRegionTop(shelf_top, d)") .. "\nend",
        "rt", "t", { math = math })()
    eq(top(500, { PAD = 20 }), 480, "the PAD band above row 1 is no longer swept")
    eq(top(500, { PAD = 20, hang_top_gap = 64 }), 436, "the region stops short of the panel's bottom")
    eq(top(500, { PAD = 20, hang_top_gap = 8 }), 480, "a narrow gap gave up the PAD band")
    eq(top(10, { PAD = 20 }), 0)
    local n = select(2, widget:gsub("BookshelfWidget%._rowsRegionTop%(shelf_top, d%)", ""))
    eq(n, 3, "the wipe and the scoped refresh do not both use it")
end)

t.done()
