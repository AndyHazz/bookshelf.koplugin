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

-- Painted for real, like the pointer above: the rule's whole job is which
-- pixels it touches.
local join_body = src:match("\nfunction PointerJoin:paintTo%(bb, x, y%)\n(.-)\nend\n")
assert(join_body, "could not find PointerJoin:paintTo - renamed?")

local function paintJoin(w, h, inset, fill, rgb32_capable)
    local px = {}
    local function put(_s, x, y, rw, rh, c)   -- called as bb:paintRect(...)
        for iy = y, y + rh - 1 do
            for ix = x, x + rw - 1 do px[ix .. "," .. iy] = c end
        end
    end
    local bb = { paintRect = put }
    if rgb32_capable then bb.paintRectRGB32 = put end
    local self_ = { width = w, height = h, color = fill, inset = inset }
    local fn = compile("local self, bb, x, y = ...\n" .. join_body,
                       { math = math }, "PointerJoin:paintTo")
    fn(self_, bb, 0, 0)
    return px
end

t.test("the join covers the border row between its two ends", function()
    local px = paintJoin(40, 1, 1, WHITE, false)
    for x = 1, 38 do
        assert(px[x .. ",0"] == WHITE,
            "x=" .. x .. " left uncovered; the frame's top edge shows through "
            .. "there as a line between the box and the pointer")
    end
end)

t.test("...and keeps the frame's corners at both ends", function()
    -- Painting the full width would eat the border's corners, and the
    -- pointer's outline would no longer meet the box's.
    local px = paintJoin(40, 1, 1, WHITE, false)
    assert(px["0,0"] == nil, "the left corner was painted over")
    assert(px["39,0"] == nil, "the right corner was painted over")
end)

t.test("a thick border is covered to its full depth", function()
    -- Size.border.thin is scaled, so it is 2px on a 300dpi panel. Covering
    -- only the first row would leave the line the rule exists to remove.
    local px = paintJoin(40, 2, 2, WHITE, false)
    assert(px["20,0"] == WHITE and px["20,1"] == WHITE,
        "both rows of a 2px border must be covered")
    assert(px["1,0"] == nil, "and the inset must follow the border's width")
end)

t.test("it prefers the RGB32 path where the buffer has one", function()
    -- paintRect flattens a custom fill to its luminance (#294). A grey rule
    -- across the join is the same visible seam in a different colour.
    local calls = {}
    local function rec(name)
        return function(_s, x, y, w, h, c) calls[#calls + 1] = name end
    end
    local self_ = { width = 40, height = 1, color = WHITE, inset = 1 }
    local bb = { paintRect = rec("flat"), paintRectRGB32 = rec("rgb32") }
    -- a colour that can answer in RGB32, as a real Blitbuffer colour does
    self_.color = { getColorRGB32 = function() return "RGB" end }
    compile("local self, bb, x, y = ...\n" .. join_body,
            { math = math }, "PointerJoin:paintTo")(self_, bb, 0, 0)
    assert(calls[1] == "rgb32", "took the flattening path: " .. tostring(calls[1]))
end)

t.test("a colour with no RGB32 of its own still paints", function()
    local px = paintJoin(40, 1, 1, WHITE, true)   -- WHITE has no getColorRGB32
    assert(px["20,0"] == WHITE, "the rule dropped out entirely")
end)

t.test("nothing is painted when the inset would swallow the rule", function()
    -- A narrow chip on a chunky border: better a visible seam than a rule
    -- painted backwards across the whole strip.
    local px = paintJoin(4, 1, 2, WHITE, false)
    for x = -4, 8 do assert(px[x .. ",0"] == nil, "painted at x=" .. x) end
end)

-- ── ONE builder, two layouts ──────────────────────────────────────────────
--
-- These buttons are drawn in both chip layouts: the strip as a cell in the
-- row, the breadcrumb as a fixed box before the pills. They were built twice
-- and drifted three times in a week - the theme colours, then the outline,
-- then the roof's join, each reported from a PW5 with both on screen. They
-- come from _actionButton now, and the point of these tests is that they
-- keep coming from there.
t.test("neither layout builds a pointer, a join or an outline of its own", function()
    local fn = src:match("\nlocal function _actionButton%(o%)\n.-\nend\n")
    assert(fn, "_actionButton moved or was renamed")
    for _, what in ipairs({ "UpTrianglePointer:new", "PointerJoin:new" }) do
        local total = select(2, src:gsub(what, ""))
        local mine  = select(2, fn:gsub(what, ""))
        assert(total == 1 and mine == 1,
            what .. " appears " .. total .. " time(s), " .. mine
            .. " of them in _actionButton -- a second copy is how these two "
            .. "drifted apart before")
    end
    local calls = select(2, src:gsub("_actionButton{", ""))
    assert(calls == 2, "expected one call per layout, found " .. calls)
end)

t.test("the pointer is NOT lifted clear of the outline", function()
    local fn = src:match("\nlocal function _actionButton%(o%)\n(.-)\nend\n")
    local expr = fn:match("pointer%.overlap_offset = { %-ol, ([^}]+) }")
    assert(expr and expr:match("^%-pointer_h %- ot$"),
        "the pointer is lifted by " .. tostring(expr) .. "; anything more "
        .. "stops it clear of the outline, and the outline then draws a line "
        .. "across the join -- a triangle stacked on a box")
    assert(fn:find("PointerJoin:new", 1, true), "nothing covers that edge")
    local i_ring = fn:find("\n        ring,", 1, true)
    local i_join = fn:find("group[#group + 1] = join", 1, true)
    local i_ptr  = fn:find("group[#group + 1] = pointer", 1, true)
    assert(i_ring and i_join and i_ptr, "the overlap group lost a member")
    assert(i_join > i_ring and i_join > i_ptr,
        "the join covers the ring's top edge AND the pointer's own base row, "
        .. "so it has to be painted after both")
    local args = fn:match("PointerJoin:new{(.-)}")
    assert(args:match("inset%s*=%s*b"),
        "the join must stop a border short at each end, or it eats the "
        .. "ring's corners and the outline no longer meets the slopes")
    assert(args:match("color%s*=%s*o%.pointer%.color"),
        "the join must take the pointer's own fill, or it shows in its own right")
end)

-- ── which sides of the outline reach outward ───────────────────────────────
--
-- Two reports, one after the other, and the fix has to satisfy both. An
-- outline drawn inside the cell leaves the strip's own edge showing as a
-- second, lighter line around it: "a white border outside the black border".
-- An outline pushed out on EVERY side paints over the separator, and the
-- button then runs into the chip beside it whenever both are filled the same
-- way. So each side goes out only where the strip's edge is what lies beyond.
t.test("the outline reaches out per side, not all round", function()
    local fn = src:match("\nlocal function _actionButton%(o%)\n(.-)\nend\n")
    assert(fn:find("EdgeRing:new", 1, true) and not fn:find("FrameContainer:new", 1, true),
        "a FrameContainer cannot do this -- its four sides are all alike")
    for _, side in ipairs({ "out_l", "out_r", "out_t", "out_b" }) do
        assert(fn:find(side, 1, true), "the ring lost " .. side)
    end
end)

t.test("the strip asks for it on the sides that touch its edge", function()
    local call = src:match("(local wants_button.-\n        local chip_slot)")
    assert(call, "the chips-mode button block moved or was renamed")
    local out = call:match("out%s*=%s*{(.-)}")
    assert(out, "the chips-mode button no longer says where its edges go")
    assert(out:match("t = bb") and out:match("b = bb"),
        "top and bottom always touch the strip's edge")
    assert(out:match("l = %(i == 1%)") and out:match("r = %(i == #render_chips%)"),
        "left and right only at the ends of the row; anywhere else a "
        .. "separator lies beyond and has to keep its contrasting line")
end)

t.test("the body fills the cell, so the outline sits ON its edge", function()
    local fn = src:match("\nlocal function _actionButton%(o%)\n(.-)\nend\n")
    assert(fn:match("dimen = Geom:new{ w = o%.w, h = o%.h }"),
        "the body must measure the full cell now -- the ring paints on its "
        .. "edge rather than taking a border out of it")
    assert(fn:match("bordersize = 0"),
        "the body must not carry a border itself -- an InvertedFrame that "
        .. "inverts its own border leaves a white ring on a KT6")
end)

t.test("every FILLED chip is a button, but only an action chip gets a roof", function()
    -- The selected shelf reads as a button in the way the currently-reading
    -- one does, and takes the same border (maintainer, 2026-09-19). The roof
    -- does not follow: it says "this controls what is above", which a shelf
    -- chip does not.
    local call = src:match("local wants_button = ([^\n]+)")
    assert(call and call:match("^is_active") and not call:find("chip.action", 1, true),
        "wants_button reads: " .. tostring(call))
    local body = src:match("(local wants_button.-\n        local chip_slot)")
    assert(body:match("pointer = chip%.action and"),
        "the roof must still be an action chip's alone")
    -- every unfilled chip keeps the plain cell it always had
    assert(body:find("else", 1, true) and body:find("InvertedFrame:new", 1, true),
        "the ordinary chips lost their plain body")
end)

-- ── the strip's ground ─────────────────────────────────────────────────────
--
-- An unfilled chip has NO background of its own (it would hide a wallpaper),
-- so what reads as its fill is the strip's ground. That ground was laid over
-- self.height while the row sits inside a border, so the strip paints two
-- rows taller than it - and the row's last line came up bare: a hairline of
-- wallpaper between an unfilled chip and the strip's bottom edge, spotted on
-- a PW5. The page-flip region (issue 352) and the wipe already allow for the
-- same discrepancy; the paint did not.
t.test("the ground covers what the strip PAINTS, not what it declares", function()
    local body = src:match("\nfunction ChipBar:paintTo%(bb, x, y%)\n(.-)\nend\n")
    assert(body, "ChipBar:paintTo moved or was renamed")
    assert(body:find("self[1]", 1, true) and body:find("getSize", 1, true),
        "the ground must measure the painted child, not self.width/self.height")
    assert(body:match("math%.max"),
        "...and take whichever is bigger, as the page-flip region does")
end)

-- ── two buttons meeting ────────────────────────────────────────────────────
--
-- Each drawing its own outline at the boundary, with the separator between
-- them, made THREE columns of it: measured 117/118/119 all black between two
-- pink-filled chips. One is wanted, so neither draws the facing side and the
-- separator is the line.
t.test("neither button draws the side facing another button", function()
    local body = src:match("\nfunction EdgeRing:paintTo%(bb, x, y%)\n(.-)\nend\n")
    assert(body, "EdgeRing:paintTo moved or was renamed")
    assert(body:match("if not self%.no_l then") and body:match("if not self%.no_r then"),
        "a side must be skippable, or two buttons meeting draw two outlines")
    local call = src:match("(local wants_button.-\n        local chip_slot)")
    assert(call:match("no_l = _isButton%(render_chips%[i %- 1%]%)")
       and call:match("no_r = _isButton%(render_chips%[i %+ 1%]%)"),
        "each button must skip the side whose neighbour is another button")
end)

t.test("...and the separator between them is the line", function()
    -- It has to CONTRAST with the fill, not match the outline. Taking the
    -- outline's black put black between two inverted chips, which are black
    -- themselves, and the line went missing altogether (maintainer, on a
    -- PW5, the morning after it was introduced).
    -- the whole decision, from the first branch to the widget it colours
    local sep = src:match("(local sep_color.-LineWidget)")
    assert(sep, "the separator block moved or was renamed")
    assert(sep:match("_separatorOnFill%(custom%)"),
        "a custom fill needs the luminance answer, not a fixed colour")
    assert(sep:match("or%s+_stripGround%(%)"),
        "and an inverted fill is the opposite of the strip, so the strip's "
        .. "own colour is what shows on it")
    assert(not sep:find("Blitbuffer.COLOR_BLACK", 1, true),
        "a fixed black here is invisible between two inverted chips")
end)

t.test("the pending ring lands on the strip's edge too", function()
    -- Inside the cell and flush, its top and bottom ran into that edge and
    -- read as one fat line. Held a border clear of it, the gap showed as a
    -- thin light line all the way round. On it is neither.
    local pend = src:match("(if is_pending or is_cursor then.-\n        end\n)")
    assert(pend, "the pending-ring block moved or was renamed")
    assert(pend:find("EdgeRing:new", 1, true),
        "the ring must reach onto the strip's edge, as a button's outline does")
    assert(pend:match("out_t%s*=%s*rb") and pend:match("out_b%s*=%s*rb"),
        "top and bottom always touch it")
    assert(pend:match("bw%s*=%s*pb"), "it is still the THICK border")
    -- and it takes the separator's column with it. Stopped at the cell, the
    -- separator stayed visible as an extra line between the ring and the
    -- chip before it: two edges where the tap should read as one.
    assert(pend:match("out_l%s*=%s*%(i == 1%) and rb or separator_w")
       and pend:match("out_r%s*=%s*%(i == #render_chips%) and rb or separator_w"),
        "the ring must reach over the separator, or an extra line shows "
        .. "between it and the neighbouring chip")
    -- Reaching over it is not enough on its own: the separator BEFORE a chip
    -- is painted before it, the one after is painted after, so on the right
    -- the separator won and showed as a second edge beside the ring. It went
    -- unnoticed until someone selected LEFTWARDS. Colouring it settles it
    -- whichever way round the two are painted.
    local sep = src:match("(local function _touchesTap.-LineWidget)")
    assert(sep, "the tap-adjacent separator rule moved or was renamed")
    assert(sep:match("c%.key == self%._pending_key")
       and sep:match("c%.key == self%.focused_key"),
        "both the tapped chip and the focused one carry a ring")
    assert(sep:match("sep_color = _stripInk%(%)"),
        "a separator beside the ring must take the ring's own colour")
end)

-- ── the breadcrumb pill's tip ─────────────────────────────────────────────
--
-- The tip was drawn as two tapers, an outer black and an inner white, each
-- rounded on its own terms. They agreed on the row width often enough to
-- leave the outline with holes: on a PW5 two rows of the slope had no black
-- at all. The inner one is measured off the outer now.
t.test("the pill's tip keeps its outline on every row", function()
    local body = src:match("(Right tip inner.-\n        end\n)")
    assert(body, "the pill's inner-tip block moved or was renamed")
    assert(body:match("local outer_w"),
        "the inner taper must be measured from the OUTER one")
    assert(body:match("outer_w %- b"),
        "...less the border, so b of it survives on every row")
    assert(not body:find("inner_tip_w", 1, true),
        "a taper of its own is what left the holes")
end)

t.test("a skipped side leaves the others alone", function()
    local join_like = src:match("\nfunction EdgeRing:paintTo%(bb, x, y%)\n(.-)\nend\n")
    local px = {}
    local function put(_s, x, y, w, h, c)
        for iy = y, y + h - 1 do
            for ix = x, x + w - 1 do px[ix .. "," .. iy] = c end
        end
    end
    local self_ = { width = 10, height = 6, color = WHITE, bw = 1,
                    out_l = 0, out_r = 0, out_t = 0, out_b = 0,
                    no_l = false, no_r = true }
    compile("local self, bb, x, y = ...\n" .. join_like,
            { math = math }, "EdgeRing:paintTo")(self_, { paintRect = put }, 0, 0)
    assert(px["0,3"] == WHITE, "the left side went missing with it")
    assert(px["9,3"] == nil, "the right side was drawn although skipped")
    assert(px["5,0"] == WHITE and px["5,5"] == WHITE,
        "top and bottom must still run the full width, up to the boundary")
end)

-- ── the tap flash stays on the strip's own ground ──────────────────────────
--
-- "fast" is A2: two tones and nothing between. Over the strip's solid ground
-- that is exactly right, and it is why the flash is quick. Extended over the
-- band above it to take in the roof, the wallpaper up there came back as a
-- white block on a PW5.
t.test("the pending flash does not reach above the strip", function()
    local body = src:match("\nfunction ChipBar:flashPending%(key%)\n(.-)\nend\n")
    assert(body, "flashPending moved or was renamed")
    assert(body:find('"fast"', 1, true), "the flash is meant to be quick")
    local y = body:match("\n%s*y = ([^,\n]+),")
    assert(y and y:match("^self%.dimen%.y$"),
        "y is " .. tostring(y) .. "; anything above the strip is not solid "
        .. "ground and A2 will crush it")
    local h = body:match("\n%s*h = ([^,\n]+),")
    assert(h and not h:find("ph", 1, true),
        "h is " .. tostring(h) .. "; the roof is the rebuild's business")
end)

-- ── the breadcrumb band stops at the trail ─────────────────────────────────
t.test("the deepest crumb is outside the band", function()
    local build = src:match("(local function build%(visible_pills%).-\n    end\n)")
    assert(build, "the breadcrumb build helper moved or was renamed")
    assert(build:match("outer%[#outer %+ 1%] = deepest_widget"),
        "the deepest crumb must be added OUTSIDE the framed band -- it is "
        .. "the name of where you are, not another control")
    assert(build:match("HorizontalGroup:new{ band }"),
        "the outer row must carry the band and nothing else before the crumb")
    -- and the band must NOT frame itself: the chips band's frame is what
    -- gives its rows an edge, because a chip only draws one when filled.
    -- Here the button and every pill carry their own, and a frame outside
    -- them made every border 2px against 1px elsewhere.
    assert(not build:find("FrameContainer:new", 1, true),
        "a frame here doubles every border in the band")
    assert(src:match("local band_h = self%.height %+ 2 %* band_b"),
        "the band still has to paint as tall as the chips band, or the "
        .. "button moves when you drill in")
    assert(build:match("return outer, zones, cursor, band_w"),
        "the band's width has to come back out, or the ground cannot stop at it")
    local paint = src:match("\nfunction ChipBar:paintTo%(bb, x, y%)\n(.-)\nend\n")
    assert(paint:find("self._band_w or", 1, true),
        "the ground must stop at the band in breadcrumb mode")
    assert(src:find("self._band_w = nil", 1, true),
        "...and chips mode must clear it, or a stale one narrows the strip")
end)

t.done()
