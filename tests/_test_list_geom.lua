-- tests/_test_list_geom.lua
-- Pure-Lua tests for list-view row geometry.
-- Usage (from plugin root): lua tests/_test_list_geom.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local helpers = dofile("tests/_helpers.lua")
local t       = helpers.runner()
local eq      = helpers.eq

local ListGeom = require("lib/bookshelf_list_geom")

-- Device baselines. Every number here is MEASURED, not invented: each comes
-- from driving KOReader offscreen at that geometry (SDL_VIDEODRIVER=offscreen
-- with EMULATE_READER_W/H/DPI) and reading back what the plugin actually
-- computed. The earlier fabricated `scale = 1.8 / 2.0` figures could not be
-- checked against anything, and a row-count test whose inputs are invented can
-- only ever prove its own arithmetic -- which is how a list view that showed
-- FEWER books than the cover grid passed this file.
--
--   w, h, dpi   the geometry the sweep ran. `dpi` is the screen_dpi override
--               in force; nil means NO override (see scaleBySize below).
--   font_h      rendered height of ListRow's face -- infofont, the CHIP BAR's
--               face, at the chip bar's size 16 -- measured there, at
--               list_font_scale = 100
--   PAD         _layoutPrimitives' PAD, the cover grid's inter-shelf gap
--   avail       the vertical budget _maxRows(list) hands the expanded shelf
--               block (logged as "[bookshelf perf] _maxRows(list) ... avail=")
--   grid_books  what the COVER grid shows expanded at the same geometry:
--               _nShelves() * _nCols(). This is the number list mode has to
--               beat to justify existing.
--   rows        what list mode ACTUALLY shows expanded, read back from the
--               same sweep. One number, not two: the row height no longer
--               depends on whether the Cover column is on.
--   was_rows    what the TEXT-TIGHT density model showed with covers on -- the
--               densest the list has ever been -- kept so the cost of moving
--               to the chip bar's band is stated in the suite rather than only
--               in a report.
--   h150 rows150 the row height and row count MEASURED at list_font_scale = 150
--   h200 rows200 the same at 200. Both from renders at the same geometries
--               with only that key changed (chip_font_scale left at 100), and
--               they are what makes the ceiling arithmetic below a checked
--               model rather than an assumption. chip_h was byte-identical to
--               the scale-100 render at both, on every panel -- the separation
--               of the two keys, measured.
--
-- The first four are the maintainer's calibrated geometries. ALL FOUR are
-- here: an earlier revision listed three and said the 600x800 Kindle was
-- "covered separately below", and nothing below covered it -- which mattered,
-- because that panel was the one where list mode showed 7 rows against the
-- grid's 12. An exemption nobody can find is not an exemption.
local PW5    = { name = "PW5",       w = 1248, h = 1648, dpi = 200,
                 font_h = 45, PAD = 37, avail = 1378, grid_books = 12,
                 rows = 26, was_rows = 27,
                 h150 =  77, rows150 = 17, h200 = 102, rows200 = 13 }
local PW3    = { name = "PW3",       w = 1088, h = 1448, dpi = 200,
                 font_h = 43, PAD = 32, avail = 1201, grid_books = 12,
                 rows = 24, was_rows = 25,
                 h150 =  71, rows150 = 16, h200 =  94, rows200 = 12 }
local KBASIC = { name = "Kindle 600x800", w = 600, h = 800, dpi = 167,
                 font_h = 30, PAD = 18, avail =  639, grid_books = 12,
                 rows = 18, was_rows = 18,
                 h150 =  49, rows150 = 12, h200 =  64, rows200 =  9 }
local LAND   = { name = "landscape", w = 1648, h = 1248, dpi = 200,
                 font_h = 45, PAD = 40, avail =  972, grid_books =  8,
                 rows = 18, was_rows = 19,
                 h150 =  77, rows150 = 12, h200 = 102, rows200 =  9 }

-- The same three Kindles in their OUT-OF-THE-BOX configuration: true panel
-- sizes, and no "screen_dpi" reader setting, which is the default. That
-- setting is the only thing that makes KOReader factor DPI into scaleBySize at
-- all: frontend/device/generic/device.lua reads it and, only if it is
-- non-nil, calls setScreenDPI, which is what raises fb.dpi_override. So a
-- stock Kindle scales by SIZE twice and everything comes out bigger.
--
-- They are pinned here because the four calibrated geometries above all carry
-- an override, and measuring only that configuration hid a real failure once
-- already. They are also the only rows the mm figures in the report can
-- honestly be computed from -- "dpi 200" is an emulator setting, not a panel.
local PW5_STOCK = { name = "PW5 stock",    w = 1236, h = 1648,
                    font_h = 55, PAD = 37, avail = 1332, grid_books = 12,
                    rows = 19, was_rows = 21,
                    h150 = 97, rows150 = 13, h200 = 128, rows200 = 10 }
local PW3_STOCK = { name = "PW3 stock",    w = 1072, h = 1448,
                    font_h = 48, PAD = 32, avail = 1172, grid_books = 12,
                    rows = 20, was_rows = 22,
                    h150 = 83, rows150 = 13, h200 = 110, rows200 = 10 }
local KT4_STOCK = { name = "Kindle stock", w =  600, h =  800,
                    font_h = 26, PAD = 18, avail =  648, grid_books = 12,
                    rows = 19, was_rows = 22,
                    h150 = 47, rows150 = 13, h200 =  62, rows200 = 10 }

local ALL = { PW5, PW3, KBASIC, LAND, PW5_STOCK, PW3_STOCK, KT4_STOCK }

-- KOReader's own scaleBySize, reproduced rather than approximated
-- (ffi/framebuffer.lua:414-425):
--
--   size_scale = min(w, h) / 600
--   dpi_scale  = dpi_override and (dpi / 160) or size_scale
--   scaleBySize(px) = ceil(px * (size_scale + dpi_scale) / 2)
--
-- The dpi_override branch is the one the calibrated sweep exercises and the
-- one an earlier revision of this file baked in unconditionally. Every scaled
-- primitive below (the ring, the hairline, and now the chip strip's height)
-- comes through here, so the test sizes rows exactly as the device does.
local function scaleBySize(dev, px)
    local size_scale = math.min(dev.w, dev.h) / 600
    local dpi_scale  = dev.dpi and (dev.dpi / 160) or size_scale
    return math.ceil(px * (size_scale + dpi_scale) / 2)
end

-- The primitives the density model is made of, ALL read from ListGeom's own
-- declarations. Nothing here restates a number the widget also carries: the
-- previous revision hardcoded the gap as scaleBySize(0.5) with nothing tying it
-- to _listRowGap(), so reverting that one accessor to PAD left this suite green
-- while PW5 dropped below the cover grid it exists to beat.
local function ringOf(dev)   return scaleBySize(dev, ListGeom.ROW_RING_DP)   end
local function gapOf(dev)    return scaleBySize(dev, ListGeom.ROW_GAP_DP)    end
local function borderOf(dev) return scaleBySize(dev, ListGeom.CHIP_BORDER_DP) end

-- Size.item.height_default is Screen:scaleBySize(30) -- the value the chip
-- strip is built from and the value bookshelf_list_row.lua passes through to
-- ListGeom.chipRowHeight. 30 is KOReader's number, not ours, so it is written
-- out here rather than declared in ListGeom: a copy in our own file would look
-- authoritative and would not be.
--
-- The border is ours to declare (CHIP_BORDER_DP) because it is a property of
-- how bookshelf_chip_bar.lua assembles the strip, not of KOReader.
local KO_ITEM_HEIGHT_DEFAULT_DP = 30
local function chipHOf(dev, pct)
    return ListGeom.chipRowHeight(
        scaleBySize(dev, KO_ITEM_HEIGHT_DEFAULT_DP), pct or 100, borderOf(dev))
end

-- fontHOf(dev, pct) -- the rendered line height at a given scale.
--
-- MEASURED at 100 (dev.font_h); MODELLED above it, as the measured height
-- scaled by the same rounding the rest of the band uses. Named as a model
-- rather than dressed up as a measurement -- FreeType's metrics are not
-- exactly linear in point size, and the modelled figure runs a few pixels HIGH
-- (a Paperwhite 5 at 150% models 68 and renders 63).
--
-- It is nevertheless safe for everything below, because the model is only ever
-- used through max() against the band, the band is the larger term at every
-- scale >= 100 on six of the seven baselines, and both terms are checked
-- against real renders at 150 and 200 in the test immediately below. The one
-- exception is the 600x800 Kindle at dpi 167, where the two terms are within a
-- pixel of each other and the modelled line can bind; that is called out where
-- it matters.
local function fontHOf(dev, pct)
    if not pct or pct == 100 then return dev.font_h end
    return math.floor(dev.font_h * pct / 100 + 0.5)
end

local function rowH(dev, pct)
    return ListGeom.rowHeight{
        chip_h       = chipHOf(dev, pct),
        line_heights = { fontHOf(dev, pct) },
        ring         = ringOf(dev),
    }
end

-- What _maxRows(list) does with those: n rows and n gaps in `avail`, so one
-- gap comes off up front and rowsThatFit counts the (n-1) between the rest.
local function rowsFor(dev, row_h)
    local gap = gapOf(dev)
    return ListGeom.rowsThatFit(dev.avail - gap, row_h, gap)
end

t.test("the cover is not detected out of a column list any more", function()
    -- Re-pointed rather than deleted. hasCover walked the active set looking
    -- for an id of "cover"; there is no such column now, so the helper would
    -- answer false for every list on every screen -- a silent "covers off"
    -- everywhere -- rather than failing loudly. Whether a row has a cover is
    -- Columns.layout().show_cover and nothing else.
    assert(ListGeom.hasCover == nil,
        "ListGeom.hasCover is back; the cover is a boolean, not a column id")
    local lines_src = io.open("lib/bookshelf_list_lines.lua"):read("*a")
    assert(not lines_src:match('id%s*=%s*"cover"'),
        "the line model must not carry a cover entry")
    local widget_src = io.open("lib/bookshelf_widget.lua"):read("*a")
    assert(not widget_src:match("hasCover%(self:_listLines"),
        "the widget must read show_cover, not re-derive it from a list")
end)

t.test("a second text line adds exactly one line height", function()
    -- The two-row item. The band term grows by one rendered line and nothing
    -- else -- not by a second band, which would spend a whole row's worth of
    -- whitespace per item on a surface built for density.
    local one = ListGeom.rowHeight{ chip_h = 50, line_heights = { 34 }, ring = 2 }
    local two = ListGeom.rowHeight{ chip_h = 50, line_heights = { 34, 34 }, ring = 2 }
    assert(two - one == 34, string.format(
        "expected one line height (34) more, got %d", two - one))
    -- The text's veto still applies per line: two 45px lines plus the ring
    -- beat a 50px band plus one line.
    local tall = ListGeom.rowHeight{ chip_h = 50, line_heights = { 45, 45 }, ring = 7 }
    assert(tall == 45 * 2 + 14, "expected 104, got " .. tostring(tall))
    -- And the count is genuinely variable: a third line costs the same as the
    -- second, so nothing in here is written for exactly two.
    local three = ListGeom.rowHeight{ chip_h = 50, line_heights = { 34, 34, 34 },
                                      ring = 2 }
    assert(three - two == 34, string.format(
        "a third line cost %d, not the 34 the second one did", three - two))
end)

t.test("one line is byte for byte the single-row expression", function()
    -- The pixel-identity promise for every one-line configuration: a row with
    -- one line must measure exactly as the list did before more than one was
    -- possible. The comparison is against the OLD EXPRESSION written out, not
    -- against another call of the function under test.
    for _i, c in ipairs({
        { chip_h = 50, font_h = 34, ring = 2 },
        { chip_h = 33, font_h = 34, ring = 1 },
        { chip_h = 0,  font_h = 41, ring = 7 },
        { chip_h = 156, font_h = 102, ring = 2 },
    }) do
        -- text_pad and lead are supplied and must not be spent: they belong to
        -- the lines BELOW the first, of which there are none here.
        local got = ListGeom.rowHeight{ chip_h = c.chip_h,
                                        line_heights = { c.font_h },
                                        ring = c.ring,
                                        text_pad = 4, lead = 2 }
        local old = math.max(c.chip_h, c.font_h + c.ring * 2)
        assert(got == old, string.format(
            "chip %d font %d ring %d: %d against the old %d",
            c.chip_h, c.font_h, c.ring, got, old))
    end
    -- Degenerate inputs degrade, they do not raise.
    assert(ListGeom.rowHeight{ chip_h = 50, line_heights = {} } == 50)
    assert(ListGeom.rowHeight{ chip_h = 50, line_heights = "two" } == 50)
end)

t.test("the density model is declared in dp, in one place", function()
    -- Both scaled primitives have to be readable from here, or the widget can
    -- move one and this file will not notice.
    assert(type(ListGeom.ROW_RING_DP) == "number", "ROW_RING_DP must be declared")
    assert(type(ListGeom.ROW_GAP_DP) == "number", "ROW_GAP_DP must be declared")
    assert(type(ListGeom.CHIP_BORDER_DP) == "number",
        "CHIP_BORDER_DP must be declared")
    -- And they must stay the sizes they were chosen to be: the gap is
    -- Size.line.thin (0.5dp), the ring Size.border.default (1dp). A gap that
    -- grew to PAD would silently cost a third of the rows.
    assert(ListGeom.ROW_GAP_DP == 0.5, "the row gap is the hairline rule")
    assert(ListGeom.ROW_RING_DP == 1, "the row ring is a 1dp border")
    -- Size.border.thin, which is the bordersize on the FrameContainer
    -- bookshelf_chip_bar.lua's _buildChipRow wraps the whole strip in. Move
    -- this and the row stops matching the band it is supposed to match.
    assert(ListGeom.CHIP_BORDER_DP == 0.5,
        "the chip strip's outer border is Size.border.thin")
end)

-- ── The second line: size, leading, and the grouping it has to produce ─────

t.test("row 2 is a fixed proportion of row 1, not a setting", function()
    -- The maintainer asked for a smaller secondary font and explicitly not for
    -- another settings row. Pinned as a PROPORTION so the relationship cannot
    -- drift: whatever list_font_scale does to the primary, the secondary is
    -- that at SECONDARY_PCT.
    assert(ListGeom.SECONDARY_PCT >= 80 and ListGeom.SECONDARY_PCT <= 90,
        "the secondary line should be 80-90% of the first; got "
        .. tostring(ListGeom.SECONDARY_PCT))
    for _i, pct in ipairs({ 50, 75, 100, 125, 150, 200, 300 }) do
        local primary   = ListGeom.fontSize(pct)
        local secondary = ListGeom.secondaryFontSize(pct)
        assert(secondary
               == ListGeom.scalePercent(primary, ListGeom.SECONDARY_PCT),
            string.format("scale %d: %d is not %d%% of %d",
                pct, secondary, ListGeom.SECONDARY_PCT, primary))
        assert(secondary < primary, string.format(
            "scale %d: the secondary line (%d) must be SMALLER than the "
            .. "primary (%d), or the distinction does nothing",
            pct, secondary, primary))
        assert(secondary >= 1, "a zero-point font renders nothing")
    end
    -- The default, which is what almost everyone sees: 16pt over 14pt.
    assert(ListGeom.fontSize(100) == 16 and ListGeom.secondaryFontSize(100) == 14,
        string.format("at the default scale expected 16/14, got %d/%d",
            ListGeom.fontSize(100), ListGeom.secondaryFontSize(100)))
end)

t.test("the leading inside an item is far tighter than the gap between items",
function()
    -- The maintainer's first ask, as arithmetic. Two lines of ONE book have to
    -- read as one thing; what separates two BOOKS is the item's own padding at
    -- each end, the ring reservation twice, and the hairline rule.
    --
    -- Measured on the four sweep panels rather than asserted in the abstract:
    -- every one of them must come out with the inner gap a fraction of the
    -- outer one, or the pair still reads as two rows on that panel.
    for _i, dev in ipairs({ PW5, PW3, KBASIC, LAND, PW5_STOCK, PW3_STOCK,
                            KT4_STOCK }) do
        local ring     = ringOf(dev)
        local gap      = gapOf(dev)
        local lead     = scaleBySize(dev, ListGeom.INTRA_LEAD_DP)
        -- TextWidget's own vertical padding is Size.padding.small, one side.
        local text_pad = scaleBySize(dev, 2)
        local font_h   = dev.font_h
        -- The secondary line renders ~SECONDARY_PCT of the primary's height.
        -- Modelled, and named as a model: what matters here is the SPACING,
        -- which does not depend on how tall the second line is.
        local line2_h  = math.floor(font_h * ListGeom.SECONDARY_PCT / 100 + 0.5)
        local row_h    = ListGeom.rowHeight{
            chip_h = chipHOf(dev), line_heights = { font_h, line2_h },
            ring = ring, text_pad = text_pad, lead = lead }
        local bands = ListGeom.textBands{
            content_h = row_h - 2 * ring, line_heights = { font_h, line2_h },
            text_pad = text_pad, lead = lead }
        -- Everything the bands hand out has to add back up to the content box,
        -- or the cover (which spans the whole row) and the text stop agreeing.
        assert(bands.top + bands.boxes[1] + bands.lead + bands.boxes[2]
               + bands.bottom == row_h - 2 * ring, string.format(
            "%s: the bands do not fill the content box", dev.name))
        -- Inside one item: the declared leading, and nothing else.
        local inner = bands.lead
        -- Between two items: this item's bottom padding, the ring, the rule,
        -- the ring again, the next item's top padding.
        local outer = bands.bottom + ring + gap + ring + bands.top
        assert(inner < outer, string.format(
            "%s: leading %d is not smaller than the item gap %d",
            dev.name, inner, outer))
        assert(inner * 3 <= outer, string.format(
            "%s: leading %d against an item gap of %d is not a CLEAR "
            .. "difference; the pair will still read as two rows",
            dev.name, inner, outer))
    end
end)

t.test("textBands trims the padding that is otherwise paid twice", function()
    -- The cause, isolated. Between two stacked lines TextWidget's padding is
    -- under the first and over the second, on top of the leading the face
    -- already carries -- which is why the two lines of one item sat as far
    -- apart as two separate items did.
    local b = ListGeom.textBands{ content_h = 100, line_heights = { 40, 30 },
                                  text_pad = 4, lead = 2 }
    assert(b.boxes[1] == 32 and b.boxes[2] == 22, string.format(
        "expected the two boxes trimmed to 32/22, got %d/%d",
        b.boxes[1], b.boxes[2]))
    -- What is left becomes the item's OWN padding, split evenly, odd pixel to
    -- the bottom -- the same direction the band plan splits its leftover.
    assert(b.top == 22 and b.bottom == 22, string.format(
        "expected 22/22 of item padding, got %d/%d", b.top, b.bottom))
    local odd = ListGeom.textBands{ content_h = 101, line_heights = { 40, 30 },
                                    text_pad = 4, lead = 2 }
    assert(odd.top == 22 and odd.bottom == 23,
        "the odd pixel goes to the bottom")
    -- Degenerate: a trim bigger than the box, and a box bigger than the band.
    local tiny = ListGeom.textBands{ content_h = 4, line_heights = { 6, 6 },
                                     text_pad = 9, lead = 3 }
    assert(tiny.boxes[1] >= 1 and tiny.boxes[2] >= 1 and tiny.top >= 0
           and tiny.bottom >= 0, "degenerate inputs must degrade, not raise")
    -- Three lines pay the leading twice, and the boxes still fill the band.
    local three = ListGeom.textBands{ content_h = 200,
                                      line_heights = { 40, 30, 30 },
                                      text_pad = 4, lead = 2 }
    assert(#three.boxes == 3, "three lines must yield three boxes")
    local sum = three.top + three.bottom + three.lead * 2
    for _i, box in ipairs(three.boxes) do sum = sum + box end
    assert(sum == 200, "three bands do not fill the content box: " .. sum)
end)

t.test("the second line's cost is its own box, trimmed, plus the leading",
function()
    -- rowHeight and textBands are the same arithmetic seen from the two ends:
    -- what the budget RESERVES for a second line has to be what the renderer
    -- SPENDS on it, or every item carries the difference.
    local one = ListGeom.rowHeight{ chip_h = 50, line_heights = { 40 }, ring = 2 }
    local two = ListGeom.rowHeight{ chip_h = 50, line_heights = { 40, 30 },
                                    ring = 2, text_pad = 4, lead = 2 }
    assert(two - one == 30 - 8 + 2, string.format(
        "expected the second line to cost 24, got %d", two - one))
    -- With no trim and no leading and the same face, it is the old expression
    -- exactly -- which is what keeps the existing measured baselines valid.
    local plain = ListGeom.rowHeight{ chip_h = 50, line_heights = { 40, 40 },
                                      ring = 2 }
    assert(plain == math.max(50 + 40, 2 * 40 + 4), string.format(
        "the defaults must reproduce the pre-secondary arithmetic, got %d",
        plain))
    -- A second line can never make an item shorter than a one-line one.
    local absurd = ListGeom.rowHeight{ chip_h = 50, line_heights = { 40, 10 },
                                       ring = 2, text_pad = 40 }
    assert(absurd > one, "a second line must never reduce the row height")
end)

-- ── The chip bar's sizing ──────────────────────────────────────────────────

t.test("the chip declarations are the chip bar's own", function()
    -- Both are copies of what bookshelf_chip_bar.lua renders with. If either
    -- moves without the chip bar moving, the row stops matching the thing it
    -- was told to match, and nothing else in the suite can see that.
    assert(ListGeom.FONT_FACE == "infofont",
        "the chip strip renders infofont; got " .. tostring(ListGeom.FONT_FACE))
    assert(ListGeom.FONT_SIZE_DP == 16,
        "the chip strip's base size is 16; got " .. tostring(ListGeom.FONT_SIZE_DP))
end)

t.test("scalePercent rounds the way both chip-bar sites round", function()
    -- floor(x + 0.5). Not ceil, not math.floor(x): _layoutPrimitives and the
    -- strip's own _scaled() both round half up, and a row that rounded the
    -- other way would sit a pixel off the chips on half the scales.
    assert(ListGeom.scalePercent(50, 100) == 50)
    assert(ListGeom.scalePercent(50, 150) == 75)
    assert(ListGeom.scalePercent(50, 101) == 51)   -- 50.5 rounds up
    assert(ListGeom.scalePercent(50, 99)  == 50)   -- 49.5 rounds up
    assert(ListGeom.scalePercent(50, nil) == 50)   -- unset scale is 100%
    assert(ListGeom.fontSize(100) == 16)
    assert(ListGeom.fontSize(200) == 32)
    assert(ListGeom.fontSize(50)  == 8)
    -- Degenerate scales must not produce a zero-point font or a zero-height
    -- row; FreeType and the row-count arithmetic both divide by these.
    assert(ListGeom.fontSize(1) >= 1)
    assert(ListGeom.chipRowHeight(0, 100) >= 1)
    assert(ListGeom.chipRowHeight(0, 100, 0) >= 1)
end)

t.test("chipRowHeight counts the strip's border twice", function()
    -- The defect this pass fixes. ChipBar builds its cells at the height the
    -- widget hands it and then wraps the lot in a FrameContainer whose border
    -- paints OUTSIDE that, so the band the user sees is height + 2*border --
    -- 52px against a chip_h of 50 on a Paperwhite 5, confirmed on a device
    -- capture and an offscreen render. A row at 50 was visibly short of it.
    assert(ListGeom.chipRowHeight(50, 100, 1) == 52)
    assert(ListGeom.chipRowHeight(50, 100, 2) == 54)
    -- The scale applies to the cell height, not to the border: a
    -- FrameContainer's bordersize does not know about chip_font_scale.
    assert(ListGeom.chipRowHeight(50, 200, 1) == 102)
    -- Omitting it degrades to the un-bordered height rather than raising.
    assert(ListGeom.chipRowHeight(50, 100) == 50)
end)

t.test("the row is the chip strip's painted height on every baseline", function()
    -- The ruling: a row and a chip are the same tap target. Where the chip is
    -- the taller of the two terms it IS the row, exactly.
    local chip_bound = {}
    for _i, dev in ipairs(ALL) do
        local chip_h = chipHOf(dev)
        local text_h = dev.font_h + 2 * ringOf(dev)
        local h      = rowH(dev)
        assert(h == math.max(chip_h, text_h), string.format(
            "%s: row %d is neither the chip's %d nor the text's %d",
            dev.name, h, chip_h, text_h))
        if chip_h >= text_h then chip_bound[#chip_bound + 1] = dev.name end
    end
    -- WHICH term binds is a measured fact, so it is stated rather than
    -- assumed. Counting the strip's border moved PW3 from text-bound to
    -- chip-bound (48 against a 47px line, where a 46px chip used to lose), so
    -- only the 600x800 Kindle at dpi 167 is still governed by its own text --
    -- there the row comes out slightly TALLER than the chip band, which is the
    -- harmless direction. Shorter is the one that clips descenders.
    table.sort(chip_bound)
    local got = table.concat(chip_bound, ", ")
    assert(got == "Kindle stock, PW3, PW3 stock, PW5, PW5 stock, landscape",
        string.format("the set of panels where the chip's height binds has "
        .. "changed: got \"%s\"", got))
end)

t.test("a line taller than the chip still gets a row that holds it", function()
    -- The text's veto. Without it a large user font clips its own descenders
    -- in every row.
    local h = ListGeom.rowHeight{ chip_h = 20, line_heights = { 400 }, ring = 3 }
    assert(h == 406, "row " .. h .. " cannot hold a 400px line")
end)

t.test("the row scales with its font scale, like the chips do with theirs", function()
    -- The user control the change exists to give. At 200% the band is twice as
    -- tall, so the row must be too (until the font term takes over, which it
    -- does not here: both terms scale together).
    --
    -- ListGeom takes the scale as an ARGUMENT and never learns which setting
    -- it came from -- list_font_scale for a row, chip_font_scale for the strip
    -- (lib/bookshelf_band_metrics.lua binds each). That is what lets the two
    -- surfaces share this arithmetic while moving independently; the
    -- independence itself is pinned in tests/_test_band_metrics.lua, which can
    -- see the keys.
    local dev = PW5
    local border = borderOf(dev)
    local at100 = chipHOf(dev, 100)
    local at200 = chipHOf(dev, 200)
    -- The CELL doubles; the strip's border is a fixed frame around it either
    -- way, so it comes off both sides of the comparison.
    assert(at200 - 2 * border == (at100 - 2 * border) * 2, string.format(
        "band height did not double: %d -> %d (border %d)",
        at100, at200, border))
    -- The row follows it, given a font that grew by the same factor.
    local big = ListGeom.rowHeight{
        chip_h = at200, line_heights = { dev.font_h * 2 }, ring = ringOf(dev) }
    assert(big >= at200, "the row did not follow the band")
end)

t.test("rowHeight has one degenerate guard and no floor", function()
    -- TAP_TARGET_DP used to be a floor on the text-only branch, which is what
    -- made turning the Cover column OFF produce TALLER rows. Re-applying it
    -- would undo the whole change: it is 42dp where a chip is 30dp, so it
    -- would fire on every panel. All that is left is "not zero".
    assert(ListGeom.rowHeight{} == 1, "an empty request must still be 1px")
    assert(ListGeom.rowHeight{ chip_h = 0, line_heights = { 0 }, ring = 0 } == 1)
    for _i, dev in ipairs(ALL) do
        local floor_h = math.floor(ListGeom.TAP_TARGET_DP * scaleBySize(dev, 1))
        assert(rowH(dev) < floor_h, string.format(
            "%s: row %d is at or above the old floor %d -- if a change ever "
            .. "pushes it there, the density trade needs re-deciding",
            dev.name, rowH(dev), floor_h))
    end
end)

t.test("the thumbnail is the row minus the ring, at the 2:3 book aspect", function()
    local w, h = ListGeom.thumbSize(90, 6)
    assert(h == 90 - 6 * 2, "thumbnail height should inset by the ring, got " .. h)
    assert(w == math.floor(h / 1.5), "thumbnail width should be h/1.5, got " .. w)
    -- Degenerate rows floor at 1x1 rather than going negative: TextWidget and
    -- ImageWidget both divide by these.
    local dw, dh = ListGeom.thumbSize(4, 10)
    assert(dw >= 1 and dh >= 1, "thumbnail must never be zero or negative")
end)

-- ── Which lines a row can afford ───────────────────────────────────────────
--
-- The row height is the reader's now, taken from the row count, so the content
-- has to adapt to it. Rows lose lines from the BOTTOM UP (the maintainer's
-- reversal of the first, last-line-anchored design: on screen it dropped the
-- author before the progress bar): 12345 -> 1234 -> 123 -> 12 -> 1.

-- Run the allocator and read the result back as the maintainer writes it: the
-- line number repeated once per rendered line it occupies. "115" is line 1
-- taking two of the row's three lines, with line 5 on the last.
--
-- `wants[i]` is how many rendered lines line i would use if it were offered
-- the whole row -- i.e. what its CONTENT needs, which is what the measure
-- callback answers with. nil means one.
local function fill(unit, wants, lead, height)
    local got = ListGeom.fillRow{
        n = #unit, unit = unit, lead = lead, height = height,
        measure = function(i, offer)
            local want = (wants and wants[i]) or 1
            if want == 0 then return 0 end          -- nothing to say
            local u = unit[i] or 0
            if u < 1 then return 0 end
            -- As many whole lines as the offer allows, never more than wanted.
            local fits = math.floor(offer / u)
            if fits < 1 then return 0 end
            return math.min(want, fits) * u
        end,
    }
    if not got then return "" end
    local out = {}
    for i = 1, #unit do
        if got.bands[i] then
            for _r = 1, math.floor(got.bands[i] / (unit[i] or 1)) do
                out[#out + 1] = tostring(i)
            end
        end
    end
    return table.concat(out), got
end

t.test("keep-priority is document order, top to bottom", function()
    eq(ListGeom.linePriority(5), { 1, 2, 3, 4, 5 })
    eq(ListGeom.linePriority(3), { 1, 2, 3 })
    eq(ListGeom.linePriority(1), { 1 })
    eq(ListGeom.linePriority(0), {})
end)

t.test("five lines degrade 12345 -> 1234 -> 123 -> 12 -> 1", function()
    -- Ten-pixel lines, no lead, so the available height IS the line count and
    -- the ladder is readable as arithmetic. Every line wants one line.
    local unit = { 10, 10, 10, 10, 10 }
    eq(fill(unit, nil, 0, 50), "12345")
    eq(fill(unit, nil, 0, 40), "1234")
    eq(fill(unit, nil, 0, 30), "123")
    eq(fill(unit, nil, 0, 20), "12")
    eq(fill(unit, nil, 0, 10), "1")
    -- Every height in between lands on a rung, never between two.
    local LADDER = { ["1"] = true, ["12"] = true, ["123"] = true,
                     ["1234"] = true, ["12345"] = true }
    for h = 10, 50 do
        local got = fill(unit, nil, 0, h)
        assert(LADDER[got], "height " .. h .. " gave an off-ladder set: " .. got)
    end
end)

t.test("a long first line pushes the BOTTOM line out: 123 becomes 112",
function()
    -- The heading still expands first; what it displaces is whatever sits at
    -- the bottom of the row, not a neighbour picked by an anchor rule.
    local unit = { 10, 10, 10, 10, 10 }
    eq(fill(unit, nil, 0, 30), "123")                 -- short title
    eq(fill(unit, { 2 }, 0, 30), "112")               -- title wants two
    eq(fill(unit, { 3 }, 0, 30), "111",
        "a title long enough to fill the row is allowed to")
end)

t.test("a missing middle line never lets a lower one climb past it", function()
    -- The walk STOPS at the first line that does not FIT -- otherwise a short
    -- line 3 could render under a line 2 that was dropped, recreating the
    -- title-plus-progress-bar hole this ladder replaced. A line with nothing
    -- to SAY is different: it costs nothing and does not block what follows.
    local unit = { 10, 20, 10 }
    -- Height 25: line 1 fits, line 2 (twice the height) does not -- and line
    -- 3, which WOULD fit, must not sneak in past it.
    eq(fill(unit, nil, 0, 25), "1")
    -- But an EMPTY line 2 that FITS steps aside entirely: it is never asked
    -- below its own line height (the measure contract), so stepping aside
    -- requires the room to ask.
    eq(fill(unit, { 1, 0, 1 }, 0, 40), "13")
end)

t.test("a middle line wraps only into what the lines below do not need",
function()
    -- The maintainer's case, from the screen: a blurb wrapping to two lines
    -- while the progress bar fell off the row. A line after the first is
    -- offered the leftover BEYOND one line for everything below it, so the
    -- bar keeps its line and the blurb wraps into genuine slack only.
    local unit = { 10, 10, 10 }
    eq(fill(unit, { 1, 9, 1 }, 0, 50), "12223")
    -- The LAST line has nothing below it and takes the true remainder.
    eq(fill(unit, { 1, 1, 9 }, 0, 50), "12333")
end)

t.test("the driving case: a wrapping blurb never costs the bar its line",
function()
    -- Four lines: title, author, blurb (greedy), bar. With exactly one line
    -- each the blurb stays clipped; only real leftover lets it wrap.
    local unit = { 10, 10, 10, 10 }
    eq(fill(unit, { 1, 1, 9, 1 }, 0, 40), "1234")
    eq(fill(unit, { 1, 1, 9, 1 }, 0, 60), "123334")
end)

t.test("line 1 keeps its expand-first privilege, at the bottom's expense",
function()
    -- A truncated title hurts more than a dropped bar: the heading reserves
    -- nothing and may take the whole row.
    local unit = { 10, 10, 10 }
    eq(fill(unit, { 9 }, 0, 30), "111")
    eq(fill(unit, { 2 }, 0, 30), "112")
end)

t.test("the leading between lines is paid for out of the same height",
function()
    -- Four 10px lines with a 2px lead need 46, not 40. A fit test that forgets
    -- the leads reports a row can hold one more line than it can.
    local unit = { 10, 10, 10, 10 }
    eq(fill(unit, nil, 2, 46), "1234")
    eq(fill(unit, nil, 2, 45), "123")
end)

t.test("a line with nothing to say costs the row nothing", function()
    -- A group row borrows the user's line styles and fills only the first two,
    -- so the rest expand to nothing. They must not hold a band open.
    local unit = { 10, 10, 10, 10 }
    eq(fill(unit, { 1, 1, 0, 0 }, 0, 40), "12")
    -- And the space they gave up is available to the lines that remain.
    eq(fill(unit, { 3, 1, 0, 0 }, 0, 40), "1112")
end)

t.test("lines are never emitted out of document order", function()
    local got = fill({ 10, 10, 10, 10, 10 }, nil, 0, 30)
    eq(got, "123")
end)

t.test("the row's leftover goes above the last line, or below everything",
function()
    -- Unchanged from the previous allocator, and load-bearing: a closing %bar
    -- keeps the row's bottom edge, so the bars line up across the page. But
    -- only when the last CONFIGURED line has something to say.
    local _s, got = fill({ 10, 10 }, { 1, 1 }, 0, 50)
    eq(got.extra_lead, 30)
    eq(got.extra_bottom, 0)
    local _s2, empty_last = fill({ 10, 10 }, { 1, 0 }, 0, 50)
    eq(empty_last.extra_lead, 0)
    eq(empty_last.extra_bottom, 40)
end)

t.test("a row with room for nothing at all reports nothing", function()
    local got = ListGeom.fillRow{ n = 2, unit = { 10, 10 }, lead = 0,
                                  height = 4,
                                  measure = function() return 10 end }
    assert(got == nil, "a row that can hold no line must return nil, so the "
        .. "caller lays its page layout down unchanged")
end)

-- ── The art budget ─────────────────────────────────────────────────────────
--
-- THE PINCH CRASH. Artwork is sized off the row HEIGHT; in a multi-column list
-- a tall row is a narrow one, so pinching the rows taller grew the cover until
-- the text column was thinner than one ellipsis glyph -- and TextBoxWidget
-- raises on that rather than truncating, which took KOReader down from inside
-- a draft regrid. Reproduced offscreen at 1248x1648, two columns,
-- list_font_scale 226 (cover 381px of a 568px column, 130px left for text).

t.test("a capped thumbnail shrinks in BOTH dimensions", function()
    -- Width alone would leave a squashed cover in a full-height box. The point
    -- of the cap is a smaller book, not a distorted one.
    local w, h = ListGeom.thumbSize(600, 0, 100)
    eq(w, 100)
    assert(h == math.floor(100 * 1.5), "capped height should keep the aspect, got " .. h)
    -- Uncapped is untouched, so no existing caller moves.
    local uw, uh = ListGeom.thumbSize(600, 0)
    eq(uw, math.floor(600 / 1.5))
    eq(uh, 600)
    -- A cap wider than the natural size does nothing.
    local nw, nh = ListGeom.thumbSize(600, 0, 10000)
    eq(nw, uw)
    eq(nh, uh)
end)

t.test("the art budget is half the row and never negative", function()
    eq(ListGeom.artBudget(568), 284)
    eq(ListGeom.artBudget(0), 0)
    eq(ListGeom.artBudget(-50), 0)
    eq(ListGeom.artBudget(nil), 0)
end)

t.test("the budget keeps a text column clear of the ellipsis that broke it",
function()
    -- The failure condition, stated as arithmetic: the text column must stay
    -- wider than one ellipsis glyph, and the ellipsis grows with the font.
    -- 55px was measured at list_font_scale 300, the widest the pinch reaches;
    -- the column at that scale used to be 21px.
    local WORST_ELLIPSIS = 55
    local col_w = 568                      -- two columns on a PW5
    for row_h = 100, 900, 10 do
        local cover = ListGeom.thumbSize(row_h, 6, ListGeom.artBudget(col_w))
        local text  = col_w - cover
        assert(text > WORST_ELLIPSIS, string.format(
            "row_h=%d leaves %dpx for text, and an ellipsis is %d",
            row_h, text, WORST_ELLIPSIS))
    end
end)

t.test("the row height and the thumbnail round-trip", function()
    -- ListRow.pageLayout and the two BIM/preload sites all size the thumbnail
    -- by handing thumbSize the ROW height. Taking the ring off once, inside
    -- thumbSize, is what stops a caller warming an 88px cover for a 74px slot.
    -- Measured cover dims from the sweep, in baseline order.
    local expect = { ["PW5"] = { 32, 48 }, ["PW3"] = { 29, 44 },
                     ["Kindle 600x800"] = { 20, 30 }, ["landscape"] = { 32, 48 },
                     ["PW5 stock"] = { 40, 60 }, ["PW3 stock"] = { 34, 52 },
                     ["Kindle stock"] = { 20, 30 } }
    for _i, dev in ipairs(ALL) do
        local cw, ch = ListGeom.thumbSize(rowH(dev), ringOf(dev))
        local want = expect[dev.name]
        assert(cw == want[1] and ch == want[2], string.format(
            "%s: thumbnail %dx%d, sweep rendered %dx%d",
            dev.name, cw, ch, want[1], want[2]))
    end
end)

t.test("rowsThatFit is exact at the boundary", function()
    -- 4 rows of 100 with a 10 gap occupy 4*100 + 3*10 = 430.
    assert(ListGeom.rowsThatFit(430, 100, 10) == 4)
    assert(ListGeom.rowsThatFit(429, 100, 10) == 3)
    assert(ListGeom.rowsThatFit(440, 100, 10) == 4)
    -- One more row needs another 110 (gap + row).
    assert(ListGeom.rowsThatFit(540, 100, 10) == 5)
end)

t.test("rowsThatFit always yields at least one row", function()
    -- Zero rows would render an empty shelf with a live pagination footer,
    -- which reads as a bug rather than a tight screen.
    assert(ListGeom.rowsThatFit(10, 100, 10) == 1)
    assert(ListGeom.rowsThatFit(0, 100, 10) == 1)
    assert(ListGeom.rowsThatFit(-50, 100, 10) == 1)
end)

t.test("a list beats the cover grid on every baseline, at the default scale", function()
    -- THE assertion. Its absence is why a list view that showed 9 rows where
    -- the grid showed 12 books passed this suite: nothing here compared list
    -- mode against the mode it is an alternative to, so "at least 5 rows"
    -- looked healthy while the feature failed its own premise.
    --
    -- AT THE DEFAULT SCALE, which is in the name because it is a real
    -- qualifier: list_font_scale grows the row and does not touch the grid, so
    -- the premise has a ceiling. Where, per panel, is the next test.
    --
    -- It now holds for EVERY column set, not just the default one, because the
    -- row height no longer depends on the column set. Before this pass a
    -- text-only list lost to the grid on the 600x800 Kindle (7 rows to 12) and
    -- on a stock PW5 (10 to 12); both are gone with the branch that caused
    -- them. grid_books is measured at the same geometry in the same sweep, so
    -- it is a like-for-like count of books on screen, not two budgets.
    for _i, dev in ipairs(ALL) do
        local rows = rowsFor(dev, rowH(dev))
        assert(rows > dev.grid_books, string.format(
            "%s: list shows %d rows (row_h=%d gap=%d avail=%d), the cover grid "
            .. "shows %d books -- list view has to show MORE, not fewer",
            dev.name, rows, rowH(dev), gapOf(dev), dev.avail, dev.grid_books))
    end
end)

-- ── ...but only up to a point, and the point is stated ─────────────────────

t.test("the arithmetic lands on what the sweep rendered at 150% and 200%", function()
    -- Validates the scale model before anything is concluded from it. Both
    -- points come from real renders at every geometry with ONLY
    -- list_font_scale changed; chip_font_scale stayed at 100 and the chip
    -- band came back byte-identical to the scale-100 shot on all seven, which
    -- is the separation of the two keys measured rather than argued.
    for _i, dev in ipairs(ALL) do
        for _j, pct in ipairs({ 150, 200 }) do
            local want_h = (pct == 150) and dev.h150 or dev.h200
            local want_n = (pct == 150) and dev.rows150 or dev.rows200
            local got_h  = rowH(dev, pct)
            assert(got_h == want_h, string.format(
                "%s at %d%%: computed a %dpx row, the sweep rendered %dpx",
                dev.name, pct, got_h, want_h))
            local got_n = rowsFor(dev, got_h)
            assert(got_n == want_n, string.format(
                "%s at %d%%: computed %d rows, the sweep rendered %d",
                dev.name, pct, got_n, want_n))
        end
    end
end)

t.test("the density premise has a ceiling, and here it is", function()
    -- "A list shows more books than the cover grid" is true at the default
    -- scale on every baseline (the test above) and is NOT scale-free. The grid
    -- does not move with list_font_scale at all -- that is new, and it is the
    -- separation working: while the two surfaces shared a key, raising it also
    -- grew the chip strip and took height off the grid, so both sides of the
    -- comparison moved and the crossover was hidden.
    --
    -- These are the highest whole percentages at which the list still shows
    -- MORE than the grid. They are consequences of the model validated
    -- directly above, not a second guess: at 150 and 200 -- two of the points
    -- inside this range -- it reproduces the rendered row count exactly on all
    -- seven panels.
    --
    -- The ceiling is a real limit, not a defect: a list row twice the height
    -- of a chip is a deliberately sparse table, and a user who asks for one
    -- has asked for fewer rows. What would be a defect is the suite claiming
    -- the density premise universally while it quietly stopped holding.
    local CEILING = {
        ["PW5"]            = 206,
        ["PW3"]            = 194,
        -- 148 or 149 depending on whether the rendered line or the band binds
        -- at exactly that scale -- the one panel where they are within a pixel
        -- of each other, so the one place fontHOf's approximation can decide.
        -- Pinned at the model's answer; the band-only arithmetic says 149.
        ["Kindle 600x800"] = 148,
        ["landscape"]      = 210,
        ["PW5 stock"]      = 155,
        ["PW3 stock"]      = 162,
        ["Kindle stock"]   = 154,
    }
    for _i, dev in ipairs(ALL) do
        local want = CEILING[dev.name]
        assert(want, "no ceiling recorded for " .. dev.name)
        local at   = rowsFor(dev, rowH(dev, want))
        local over = rowsFor(dev, rowH(dev, want + 1))
        assert(at > dev.grid_books, string.format(
            "%s: at %d%% the list shows %d rows against %d books -- the "
            .. "recorded ceiling is too high",
            dev.name, want, at, dev.grid_books))
        assert(over <= dev.grid_books, string.format(
            "%s: at %d%% the list still shows %d rows against %d books -- the "
            .. "recorded ceiling is too low",
            dev.name, want + 1, over, dev.grid_books))
    end
    -- The headline, so a reader does not have to scan the table: the tightest
    -- panel gives up the premise before 150%.
    local lowest = math.huge
    for _k, v in pairs(CEILING) do if v < lowest then lowest = v end end
    assert(lowest == 148, "the tightest ceiling is now " .. lowest .. "%, not 148%")
end)

t.test("the row count matches what the sweep actually rendered", function()
    -- The arithmetic above is only worth anything if it lands on the same
    -- number the device does. Each `rows` came from the expanded list shot's
    -- own "[bookshelf perf] _maxRows(list)=" line at that geometry.
    for _i, dev in ipairs(ALL) do
        local rows = rowsFor(dev, rowH(dev))
        assert(rows == dev.rows, string.format(
            "%s: computed %d rows, the sweep rendered %d", dev.name, rows, dev.rows))
    end
end)

t.test("what the chip's band cost in density, stated", function()
    -- The trade, in the suite rather than only in a report, measured against
    -- the densest the list has ever been (text-tight, covers on). One baseline
    -- keeps every row it had; the rest lose one to three, and the worst case is
    -- a stock 600x800 Kindle at 22 -> 19. If a future change makes that worse,
    -- this is the line that says so. Every one of them still shows more books
    -- than the cover grid at the same geometry -- that is the test above.
    local worst = 0
    for _i, dev in ipairs(ALL) do
        local lost = dev.was_rows - dev.rows
        assert(lost >= 0, string.format(
            "%s gained rows (%d -> %d) -- update was_rows rather than leaving "
            .. "the comparison stale", dev.name, dev.was_rows, dev.rows))
        if lost > worst then worst = lost end
    end
    assert(worst == 3, "the worst density loss is now " .. worst .. " rows, not 3")
end)

t.test("turning the cover column off no longer changes anything", function()
    -- The inversion, gone by construction: rowHeight has no has_cover input to
    -- branch on. This asserts the SIGNATURE, because that is what made the old
    -- behaviour possible -- a caller that starts passing has_cover again gets
    -- an ignored argument, not a second density model.
    for _i, dev in ipairs(ALL) do
        local with_flag = ListGeom.rowHeight{
            chip_h = chipHOf(dev), line_heights = { dev.font_h },
            ring = ringOf(dev), has_cover = false, scale = scaleBySize(dev, 1) }
        assert(with_flag == rowH(dev), string.format(
            "%s: has_cover still moves the row (%d vs %d)",
            dev.name, with_flag, rowH(dev)))
    end
end)

-- ── %bar{rel}: the relative-length curve ───────────────────────────────────

t.test("relativeBarFraction is monotonic and stays inside its bounds",
function()
    local prev = 0
    for _i, pages in ipairs({ 1, 20, 75, 175, 350, 700, 1200, 5000, 100000 }) do
        local f = ListGeom.relativeBarFraction(pages)
        assert(f >= ListGeom.REL_BAR_MIN and f <= 1,
            string.format("%d pages -> %.3f, outside [%.2f, 1]",
                pages, f, ListGeom.REL_BAR_MIN))
        assert(f >= prev, string.format(
            "a longer book got a SHORTER bar: %d pages -> %.3f after %.3f",
            pages, f, prev))
        prev = f
    end
end)

t.test("a reference-length book gets the reference fraction", function()
    -- The anchor the whole curve is calibrated on. If this drifts, every
    -- library's bars re-scale silently.
    local f = ListGeom.relativeBarFraction(ListGeom.REL_BAR_REFERENCE)
    assert(math.abs(f - ListGeom.REL_BAR_AT_REFERENCE) < 0.001,
        string.format("reference book -> %.3f, expected %.3f",
            f, ListGeom.REL_BAR_AT_REFERENCE))
    -- Four times the reference is twice the bar, capped at the full line: the
    -- square root is the whole point, so pin the shape and not just the ends.
    assert(math.abs(ListGeom.relativeBarFraction(ListGeom.REL_BAR_REFERENCE / 4)
        - ListGeom.REL_BAR_AT_REFERENCE / 2) < 0.001)
end)

t.test("an unknown page count draws a TYPICAL bar, not a full one", function()
    -- Drawing full-width would make "no metadata" the longest-looking book in
    -- the library, which is the one reading that is definitely wrong.
    for _i, bad in ipairs({ nil, 0, -5, "", "abc", false }) do
        assert(ListGeom.relativeBarFraction(bad)
            == ListGeom.REL_BAR_AT_REFERENCE,
            "unknown page count did not fall back: " .. tostring(bad))
    end
end)

t.test("a nonsense reference falls back rather than dividing by zero",
function()
    assert(ListGeom.relativeBarFraction(350, 0)
        == ListGeom.relativeBarFraction(350))
    assert(ListGeom.relativeBarFraction(350, -1)
        == ListGeom.relativeBarFraction(350))
    assert(ListGeom.relativeBarFraction(350, "nope")
        == ListGeom.relativeBarFraction(350))
end)

-- ── Finding the elastic token ──────────────────────────────────────────────
--
-- findElastic / stripElastic are locals in bookshelf_list_row.lua, which needs
-- KOReader's widget stack to load. They are pure string functions, so they are
-- extracted by name and run here -- the same trick tests/_test_list_view_gesture
-- uses on the widget's methods.

local row_src = io.open("lib/bookshelf_list_row.lua"):read("*a")
local function localFn(name, deps)
    local args, code = row_src:match(
        "\nlocal function " .. name .. "%((.-)%)\n(.-)\nend\n")
    assert(args and code, "could not find local " .. name .. " - renamed?")
    local env = { string = string, math = math, tonumber = tonumber }
    for k, v in pairs(deps or {}) do env[k] = v end
    local chunk = "return function(" .. args .. ")\n" .. code .. "\nend"
    local f
    if _G.setfenv then
        f = assert(_G.loadstring(chunk, name)); _G.setfenv(f, env)
    else
        f = assert(load(chunk, name, "t", env))
    end
    return f()
end

-- The REAL patterns, from the module that now owns them, rather than a third
-- copy typed here. A restated copy is how the extraction can keep passing
-- while the row and the walker disagree about what a token looks like -- which
-- is the bug that moved these constants into Tokens in the first place.
-- bookshelf_tokens is pure string work but its catalogue reads gettext and its
-- device tokens read a settings object, so it gets the same three stubs
-- tests/_test_tokens.lua installs.
local Tokens
do
    package.loaded["device"] = package.loaded["device"] or {
        getPowerDevice = function() return nil end,
        isKindle = function() return false end,
        hasNaturalLight = function() return false end,
        home_dir = "/",
    }
    package.loaded["datetime"] = package.loaded["datetime"]
        or { secondsToClockDuration = function() return "" end }
    local i18n = { gettext = function(s) return s end,
                   ngettext = function(s, p, n) return n == 1 and s or p end }
    package.loaded["bookshelf_i18n"]     = i18n
    package.loaded["lib/bookshelf_i18n"] = i18n
    _G.G_reader_settings = _G.G_reader_settings or setmetatable({}, {
        __index = function() return function() return false end end,
    })
    Tokens = require("lib/bookshelf_tokens")
end

local PATTERNS = {
    Tokens               = Tokens,
    SPACER_TOKEN_PATTERN = Tokens.SPACER_PATTERN,
    BAR_TOKEN_PATTERN    = Tokens.BAR_PATTERN,
}

-- The same extraction for a `function ListRow.name(...)` rather than a local.
local function localFn2(name, deps)
    local args, code = row_src:match(
        "\nfunction " .. name:gsub("%.", "%%.") .. "%((.-)%)\n(.-)\nend\n")
    assert(args and code, "could not find " .. name .. " - renamed?")
    local env = { string = string, math = math, tonumber = tonumber,
                  type = type }
    for k, v in pairs(deps or {}) do env[k] = v end
    local chunk = "return function(" .. args .. ")\n" .. code .. "\nend"
    local f
    if _G.setfenv then
        f = assert(_G.loadstring(chunk, name)); _G.setfenv(f, env)
    else
        f = assert(load(chunk, name, "t", env))
    end
    return f()
end

t.test("findElastic gives the slack to %bar wherever it sits", function()
    local findElastic = localFn("findElastic", PATTERNS)
    local kind, s, e, mod = findElastic("Dune%spacer50%")
    assert(kind == "spacer" and s == 5 and e == 11 and mod == nil,
        string.format("%s %s %s %s", tostring(kind), tostring(s),
            tostring(e), tostring(mod)))
    kind, s, e, mod = findElastic("Dune %bar 50%")
    assert(kind == "bar" and s == 6 and e == 9 and mod == nil)

    -- A bar wins even when a spacer comes first, which is NOT a tie-break on
    -- position. Reported as "the %bar doesn't display after %spacer": the
    -- spacer won, the bar was stripped from the trailing segment, and the line
    -- silently lost its bar. Giving the slack to the bar still separates the
    -- two halves (the bar sits between them); the reverse throws content away.
    assert(select(1, findElastic("a%bar b%spacer c")) == "bar")
    assert(select(1, findElastic("a%spacer b%bar c")) == "bar",
        "a spacer before a bar still swallowed the slack")
    local k2, s2, e2 = findElastic("%authors%spacer%bar")
    assert(k2 == "bar" and ("%authors%spacer%bar"):sub(s2, e2) == "%bar")
    -- ...and the modifier still parses in that position.
    assert(select(4, findElastic("a%spacer%bar{rel}")) == "rel")

    assert(findElastic("no tokens here") == nil)
end)

t.test("findElastic reads the brace modifier and swallows it", function()
    local findElastic = localFn("findElastic", PATTERNS)
    local kind, s, e, mod = findElastic("Dune %bar{rel}")
    assert(kind == "bar" and mod == "rel",
        "modifier not captured: " .. tostring(mod))
    -- The modifier must be INSIDE the matched span, or the renderer leaves
    -- "{rel}" on screen as literal text.
    assert(("Dune %bar{rel}"):sub(s, e) == "%bar{rel}",
        "span was " .. ("Dune %bar{rel}"):sub(s, e))
    -- An empty or unknown modifier still parses; the renderer just ignores it.
    assert(select(4, findElastic("%bar{}")) == "")
    assert(select(4, findElastic("%bar{nonsense}")) == "nonsense")
    -- A brace that is NOT immediately after the token is ordinary text.
    local _k, _s, e2 = findElastic("%bar {rel}")
    assert(e2 == 4, "a detached brace was swallowed, stop=" .. tostring(e2))
end)

-- ── {xN} is retired ────────────────────────────────────────────────────────
--
-- The modifier no longer chooses anything: how many rendered lines a line gets
-- is ListGeom.fillRow's answer, per row, from what the text needs and what the
-- row has left. What survives is the STRIPPER, because saved templates still
-- carry {x2} and {x3} and a literal one would render as text.

t.test("the retired modifier never reaches the renderer as text", function()
    local strip = localFn2("ListRow.stripWrapModifier", {})
    -- %description IS a real token, so expanding first would substitute the
    -- blurb and strand "{x4}" after it.
    eq(strip("%description{x4}"), "%description")
    eq(strip("A %description{x3} B"), "A %description B")
    -- Other brace modifiers are NOT its business: %bar{rel} is the layout's,
    -- and eating it here would silently disable relative bars.
    eq(strip("%bar{rel}"), "%bar{rel}")
    eq(strip("%title"), "%title")
end)

t.test("nothing reads a wrap count off a template any more", function()
    -- The rule, pinned: a line does not declare how tall it is. Leave a reader
    -- of {xN} in the tree and the row height has two owners again.
    assert(not row_src:match("function ListRow%.wrapLines"),
        "ListRow.wrapLines is back; the row height is the reader's now")
    assert(not row_src:match("line%.wrap"),
        "a line still carries a wrap count")
end)

t.test("stripElastic removes every leftover token, modifiers included",
function()
    local stripElastic = localFn("stripElastic", PATTERNS)
    assert(stripElastic(" x %spacer y %bar z") == " x  y  z")
    assert(stripElastic("a%bar{rel}b") == "ab",
        "a second %bar{rel} left its braces behind: "
        .. stripElastic("a%bar{rel}b"))
    assert(stripElastic("clean") == "clean")
end)

-- ── The old proportional allocator is gone ────────────────────────────────
--
-- shareBands redistributed a row's height between lines that each DECLARED a
-- size ({xN}); fillRow, tested above, replaced it when lines stopped
-- declaring anything. One allocator in the tree, so the budget and the render
-- cannot disagree about how a row divides.

t.test("shareBands is deleted, not merely unused", function()
    assert(ListGeom.shareBands == nil,
        "two allocators in the tree is how the budget and the render come "
        .. "to disagree; fillRow is the only one now")
end)

t.done()
