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

t.test("the pointer is NOT lifted clear of the frame's border", function()
    local fn = src:match("\nlocal function _actionButton%(o%)\n(.-)\nend\n")
    local expr = fn:match("pointer%.overlap_offset = { 0, ([^}]+) }")
    assert(expr == "-pointer_h", "the pointer is lifted by " .. tostring(expr))
    -- ...which stops it one border clear of the frame it sits on, so the
    -- frame's top edge draws a line across the join and the two read as a
    -- triangle stacked on a box. The join is what closes that.
    assert(fn:find("PointerJoin:new", 1, true), "nothing covers that border")
    local i_frame = fn:find("\n        widget,", 1, true)
    local i_join  = fn:find("\n        join,", 1, true)
    local i_ptr   = fn:find("\n        pointer,", 1, true)
    assert(i_frame and i_join and i_ptr, "the overlap group lost a member")
    assert(i_join > i_frame, "the join must be painted AFTER the frame it covers")
    local args = fn:match("PointerJoin:new{(.-)}")
    assert(args:match("inset%s*=%s*b"),
        "the join must stop a border short at each end, or it eats the "
        .. "frame's corners and the outline no longer meets the slopes")
    assert(args:match("color%s*=%s*o%.pointer%.color"),
        "the join must take the pointer's own fill, or it shows in its own right")
end)

t.test("the border comes OUT of the declared width, not added to it", function()
    local fn = src:match("\nlocal function _actionButton%(o%)\n(.-)\nend\n")
    assert(fn:match("o%.w %- 2 %* b") and fn:match("o%.h %- 2 %* b"),
        "callers lay out on o.w and the strip records it for hit-testing, so "
        .. "the frame has to fit inside it")
    assert(fn:match("bordersize = 0"),
        "the body must not carry the border itself -- an InvertedFrame that "
        .. "inverts its own border leaves a white ring on a KT6")
end)

-- ── where the strip puts it ────────────────────────────────────────────────
--
-- The cell sits just inside the strip's own outline. A button framed WITHIN
-- the cell therefore has that outline immediately outside its border, and on
-- a dark theme the strip's ink is near-white: "it looks like the button has a
-- white border outside the black border" (maintainer, on the render).
-- Painting it a border further out lands it ON the strip's edge and replaces
-- it, so the button carries one outline, as the drilled-in one does.
t.test("the strip's button lands ON the strip's edge, not inside it", function()
    local call = src:match("(local wants_button.-\n        local chip_slot)")
    assert(call, "the chips-mode button block moved or was renamed")
    assert(call:match("w%s*=%s*w %+ 2 %* bb") and call:match("h%s*=%s*self%.height %+ 2 %* bb"),
        "the button must be a border bigger than the cell on every side")
    assert(call:match("overlap_offset = { %-bb, %-bb }"),
        "...and offset back by one, or it covers the cell instead of the edge")
    -- the enclosing group still measures the CELL: the row lays out on w and
    -- _chip_dimens records it for hit-testing
    assert(call:match("dimen = Geom:new{ w = w, h = self%.height }"),
        "the slot must still report the cell's own size")
end)

t.test("only the chips that point at the hero are buttons", function()
    local call = src:match("local wants_button = ([^\n]+)")
    assert(call and call:match("chip%.action and is_active"),
        "wants_button reads: " .. tostring(call))
    -- every other chip keeps the plain cell it always had
    local body = src:match("(local wants_button.-\n        local chip_slot)")
    assert(body:find("else", 1, true) and body:find("InvertedFrame:new", 1, true),
        "the ordinary chips lost their plain body")
end)

t.done()
