-- bookshelf_list_geom.lua
-- Row height and row count for list view. Pure arithmetic, no widgets: the
-- cover grid's equivalent maths (_maxRows / _maxShelfRows / _baseShelves) is
-- screen-derived and cannot be reproduced off-device, which is exactly why
-- issue #329's row-count bug was so expensive to find. This half is testable.
--
-- Everything the density model decides is declared HERE, in dp, and scaled by
-- the callers (bookshelf_list_row.lua and bookshelf_widget.lua through
-- Screen:scaleBySize, tests/_test_list_geom.lua through its own reproduction of
-- the same formula). No caller carries its own copy of a number: a value the
-- test hardcodes alongside the widget rather than reading from it is a value
-- the widget can change while the suite stays green -- which is how a half of
-- this model went unpinned once already.

local ListGeom = {}

-- ── The chip bar's sizing, which is also the row's ───────────────────────────
--
-- A list row is the same kind of thing as a chip: a full-width strip of one
-- line of text that you tap. The maintainer's ruling is that it should measure
-- like one -- same shape, same face, same base size, same rounding -- rather
-- than having a private hardcoded 16pt nobody can reach.
--
-- Same SHAPE, separate SETTING. The row is driven by list_font_scale and the
-- chip strip by chip_font_scale, both defaulting to 100, where the two render
-- identically. They were briefly the same key; the maintainer separated them
-- so the two surfaces can be tuned independently -- a user who wants a denser
-- table should not have to shrink the chips to get one.
--
-- What the chip bar declares:
--   height  Size.item.height_default at the scale, via
--           lib/bookshelf_band_metrics.lua (which is the ONLY place that
--           derivation is written; it used to be inlined at three call sites)
--   border  bookshelf_chip_bar.lua's _buildChipRow wraps the whole strip in
--           FrameContainer{ bordersize = Size.border.thin }, whose border is
--           painted OUTSIDE the height above (see CHIP_BORDER_DP)
--   font    bookshelf_chip_bar.lua: BFont:getFace("infofont", _scaled(16)),
--           where _scaled goes through the same file
--
-- All of it is reproduced below as pure functions of their inputs. ListGeom
-- cannot read Size or the settings store -- it is deliberately widget-free so
-- the row arithmetic is testable off-device -- so lib/bookshelf_band_metrics.lua
-- does those reads, binds them to a scale key, and calls in here for the
-- arithmetic. Every consumer goes through that pair, so there is one rounding
-- rule for both surfaces, not one per call site.
ListGeom.FONT_FACE = "infofont"

-- The chip bar's base font size, before any scale. Changing this here and not
-- in bookshelf_chip_bar.lua would make the row and the chip disagree at equal
-- scales, which is the thing this arithmetic exists to prevent.
ListGeom.FONT_SIZE_DP = 16

-- scalePercent(n, pct) -- a font scale applied, rounding exactly as every
-- chip-bar site rounds (floor(x + 0.5), not ceil, not math.floor(x)).
function ListGeom.scalePercent(n, pct)
    if type(n) ~= "number" then return 0 end
    if type(pct) ~= "number" then pct = 100 end
    return math.floor(n * pct / 100 + 0.5)
end

-- fontSize(pct) -- the point size a row renders at. Identical to the chip
-- strip's _scaled(16).
function ListGeom.fontSize(pct)
    local s = ListGeom.scalePercent(ListGeom.FONT_SIZE_DP, pct)
    if s < 1 then s = 1 end
    return s
end

-- SECONDARY_PCT -- how big the SECOND text line is, as a percentage of the
-- first. Not a setting, and deliberately not one: the second line carries the
-- author, the series, the page count -- information that is secondary to the
-- title by definition, not by preference -- and the List view submenu is at
-- the five rows the maintainer agreed to.
--
-- 85 rather than 80 or 90, chosen against renders rather than in the abstract:
--
--   * at the default list_font_scale of 100 the primary is 16pt, and 80 / 85 /
--     90 give 13 / 14 / 14pt. So the only choice the DEFAULT user ever sees is
--     13 against 14, and 13 is a step too far -- on a 600x800 Kindle the
--     secondary line loses a further pixel of rendered height at 13 and the
--     author starts to read as a caption rather than as part of the item.
--   * 85 and 90 agree at the default and diverge above it: at
--     list_font_scale 150 the primary is 24pt and the secondary is 20 (85) or
--     22 (90). 22 against 24 is not a distinction anyone can see across a
--     table, which would leave the SIZE half of "smaller and muted" doing no
--     work for exactly the users who turned the scale up.
--
-- So: the smallest proportion that does not change the default rendering, and
-- the largest that still reads as smaller when the scale is raised. The muted
-- colour (bookshelf_list_row.lua's secondaryColor) carries the rest of the
-- distinction; neither is asked to do the job alone.
ListGeom.SECONDARY_PCT = 85

-- secondaryFontSize(pct) -- the point size the SECOND line renders at, at the
-- same list_font_scale. Derived from the primary size rather than from
-- FONT_SIZE_DP directly, so the two lines cannot drift: whatever the primary
-- becomes, the secondary is that at SECONDARY_PCT, through the same rounding
-- rule every other size in this file uses.
function ListGeom.secondaryFontSize(pct)
    local s = ListGeom.scalePercent(ListGeom.fontSize(pct), ListGeom.SECONDARY_PCT)
    if s < 1 then s = 1 end
    return s
end

-- CHIP_BORDER_DP -- the chip strip's outer border, one side, pre-scale.
--
-- 0.5dp, i.e. exactly Size.border.thin, which is the `bordersize` on the
-- FrameContainer bookshelf_chip_bar.lua's _buildChipRow wraps the whole strip
-- in. A FrameContainer paints its border OUTSIDE the content it wraps, and the
-- chip cells inside are built at the strip's declared `height` -- so the band
-- the user actually sees is that height plus this border twice.
--
-- Measured rather than reasoned about, because ChipBar also overwrites its own
-- `self.dimen` with the un-bordered height, so nothing in the widget tree
-- reports the real footprint. On a 1248x1648 panel at dpi 200 a device
-- framebuffer capture and an offscreen render agree: the chip band's outer
-- rules sit 52px apart (full-width dark rows at y=95 and y=146 offscreen,
-- y=91 and y=142 on the maintainer's Paperwhite 5) while chip_h is 50.
-- Matching the row to 50 left it visibly 2px shy of the band beside it, which
-- is the "height doesn't seem to match the chip bar" the maintainer reported.
ListGeom.CHIP_BORDER_DP = 0.5

-- chipRowHeight(item_height_default, pct, strip_border) -- the chip strip's
-- PAINTED height, which is what a row has to match to look like one.
--
-- `item_height_default` is KOReader's Size.item.height_default, i.e.
-- Screen:scaleBySize(30); passed in rather than reproduced so the row tracks
-- whatever KOReader makes that, the same value the chip bar is built from.
-- `strip_border` is Size.border.thin (CHIP_BORDER_DP scaled), counted twice
-- for the top and bottom edges of the strip's outer frame; omitted it degrades
-- to the un-bordered height rather than raising.
function ListGeom.chipRowHeight(item_height_default, pct, strip_border)
    local h = ListGeom.scalePercent(item_height_default, pct)
             + 2 * (strip_border or 0)
    if h < 1 then h = 1 end
    return h
end

-- TAP_TARGET_DP -- the ~9mm touch-target figure a list row is measured
-- AGAINST. It is not a floor and no longer used as one.
--
-- It was: rowHeight floored text-only rows at 42dp * scale, which produced the
-- inversion the chip-bar pass removes -- turning the Cover column OFF made
-- rows TALLER (84px/16 rows on a Paperwhite 5 against 49px/27 with covers on),
-- because only one of the two branches was floored. Now both branches are the
-- chip's height, and re-applying this figure over the top would undo the
-- change outright: 42dp is 84px where a chip is 50, and 126px against a stock
-- Paperwhite 5's 62. A floor that fires on every panel is not a floor.
--
-- Kept, and kept at 42, because the suite states in numbers how far the
-- shipped row sits from the usual guideline, and that trade is worth being
-- able to see. rowHeight's own degenerate guard is the >= 1 at the bottom of
-- it: the honest statement that a row cannot be zero pixels tall, and nothing
-- more.
ListGeom.TAP_TARGET_DP = 42

-- ROW_RING_DP -- the list row's selection-ring thickness, one side, pre-scale.
--
-- NOT SpineWidget.SELECTED_BORDER. That is 7px on a 1248x1648 panel, sized to
-- read around a small cover among many in the grid; reserved on all four sides
-- of a table row it would spend 14 of the row's pixels on a band that is
-- page-white whenever the row isn't selected. A row is a full-width rectangle,
-- so a thin box round it reads as clearly as a 7px box round a thumbnail.
--
-- 1dp, i.e. exactly Size.border.default, against the inter-row rule's 0.5dp.
-- That is half the DECLARED thickness, not half the rendered one: both go
-- through Screen:scaleBySize, which is ceil(px * scale), and ceil(x) is not
-- 2 * ceil(x/2) in general. On a 1248x1648 panel at 200dpi the ring lands on
-- 2px and the rule on 1px, but on a stock 600x800 Kindle both round up to 1px
-- and the two marks are the same thickness. The ring is still distinguishable
-- there -- it is a rectangle round the whole row where the rule is a single
-- line between two of them -- but "double the rule" is not a property this
-- file can promise, so it does not.
--
-- The ring's reserved band IS part of the row's vertical padding when the text
-- is what sets the height: the content box sits inside it and the ring paints
-- into it when selected, so selecting a row changes only the perimeter pixels
-- and never moves a pixel of its content -- the same invariant SpineWidget's
-- own selection ring keeps, at a fraction of the cost.
ListGeom.ROW_RING_DP = 1

-- ROW_INNER_PAD_DP -- breathing room between the row's border and its content,
-- one side, pre-scale.
--
-- Reserved ALWAYS, like the ring, so nothing moves when a row is selected.
--
-- It exists because the selection mark became a box again and a box needs air:
-- the first ring sat hard against the text and read as a cramped rectangle,
-- which is half of why it was rejected. The maintainer's ask, third time round:
-- "can we add more padding inside each row, and try a round edge border around
-- the entire row".
--
-- It costs almost NOTHING in rows, which is worth stating because the opposite
-- is the obvious assumption. rowHeight takes max(chip_h, line1 + 2*inset)
-- before adding the lines below, so the inset only pushes a row taller once the
-- first line plus the inset exceeds the chip band it is sized against -- and at
-- the default sizes it does not. Measured on a PW5 render before and after:
-- the row pitch stayed at 98px. Raise this far enough, or the font scale, and
-- it will start to cost; it is not free by design, it is absorbed by the slack
-- the chip band was already reserving.
--
-- Declared here rather than sprinkled as Size.padding at the call site because
-- the row-height budget and the renderer both have to inset by the same amount:
-- a second opinion about it is how the row and its contents come to disagree.
ListGeom.ROW_INNER_PAD_DP = 2

-- ROW_GAP_DP -- the vertical gap between two list rows, pre-scale.
--
-- A hairline, not the PAD the cover grid uses between shelves. Covers need PAD
-- because a shelf row is a block of art that has to read as separate from the
-- one below it; list rows are a table, and a table's rows are separated by a
-- rule, not by a 37px band.
--
-- 0.5dp, i.e. exactly Size.line.thin -- the plugin's established hairline, and
-- the height ListRow.divider paints. The gap IS the divider, so there is no
-- whitespace to account for on top of it, which is what keeps the row-count
-- arithmetic (n * (row_h + gap)) honest. Both the divider and the row-count
-- budget read this one number, so they cannot drift.
ListGeom.ROW_GAP_DP = 0.5

-- INTRA_LEAD_DP -- the leading BETWEEN two adjacent text lines of ONE item,
-- pre-scale, measured from the bottom of the upper line's trimmed box to the
-- top of the lower one's. Paid once per gap, so an n-line item pays it n-1
-- times.
--
-- Small on purpose, and much smaller than the gap between two ITEMS: the lines
-- have to read as one thing with more said under it, not as separate rows that
-- happen to be adjacent. What separates two items is ROW_GAP's rule plus the
-- ring reservation at each end plus each item's own top/bottom padding; what
-- separates two lines inside one item is this and nothing else.
--
-- 1dp rather than 0. Zero is the tightest honest setting -- the lines set
-- solid, separated only by the leading the face itself carries -- but the
-- trimmed boxes below cancel TextWidget's own vertical padding, which is what
-- normally absorbs a fallback glyph that overruns its nominal metrics (a
-- diacritic, a CJK fallback face). 1dp is a cushion for that overrun which is
-- still invisible as leading: it scales to 2px on a Paperwhite 5 and 1px on a
-- stock 600x800 Kindle, against a box-level inter-item gap of 16px and 11px on
-- those same two panels (the whole table is in
-- .superpowers/.../shots/lead_table.lua, and the ratio is asserted per panel
-- in tests/_test_list_geom.lua).
ListGeom.INTRA_LEAD_DP = 1

-- Book cover aspect. true_cover_aspect is deliberately NOT consulted:
-- variable-width thumbnails would give the table a ragged left edge, which
-- costs more than uncropped covers gain at thumbnail size.
local COVER_ASPECT = 1.5

-- No hasCover() here any more. It used to walk the active column set looking
-- for an id of "cover"; there are no columns now, and the cover is the
-- list_show_cover boolean, so the answer is Lines.layout().show_cover and a
-- helper that re-derives it from a list would be a second, weaker source of
-- truth for a plain flag. See bookshelf_list_lines.lua's header.

-- rowHeight{ chip_h, line_heights, ring, text_pad, lead } -> pixels
--   chip_h        the chip strip's painted height (ListGeom.chipRowHeight)
--   line_heights  rendered height of EACH text line in the item, in order.
--                 One entry for a one-line row, N for an N-line one. Each is
--                 measured at that line's own face and size, so a row whose
--                 second line is bigger than its first costs what it really
--                 costs.
--   ring          selection-ring reservation, one side (ROW_RING_DP, scaled)
--
-- THE BAND sets the height. A row and a chip are the same gesture target and
-- measure the same at equal scales, so the tap the user learns on the chip
-- strip is the tap they get in the table -- and list_font_scale moves the row
-- as a whole, height and type together, which is what makes it a density
-- control rather than only a text-size one.
--
-- No has_cover branch, and that is the point of the change rather than a
-- simplification of it. Two branches meant the cover-off case was governed by
-- a 42dp floor while the cover-on case was governed by the text, so turning
-- the Cover column OFF made rows TALLER -- 84px and 16 rows on a Paperwhite 5
-- against 49px and 27 with covers on. One expression cannot invert.
--
-- The max() is the text's veto, and it is NOT a formality: 30dp of band and a
-- 16pt line are close enough together that which one wins depends on the
-- panel. Measured across the seven sweep baselines at scale 100, the band
-- binds on six and the rendered line binds on ONE -- a 600x800 Kindle at dpi
-- 167, 34px of text against a 33px band. There the row comes out a pixel
-- TALLER than a chip, which is the harmless direction; a row one pixel SHORTER
-- than its own line clips descenders in every row on the page. Both terms
-- scale with list_font_scale together, so the relationship holds across the
-- 50-300 range the nudge dialog offers. Which term binds where is pinned in
-- tests/_test_list_geom.lua rather than left to this comment to keep true.
--
-- Earlier models, named so none of them comes back: font_h * 2.4 spent ~40% of
-- every row on padding and left list mode LESS dense than the cover grid it
-- exists as an alternative to (9 rows against 12 books on a 1248x1648 panel).
-- A fixed 44dp cover bought 14 rows, still only two more than the grid.
-- Text-tight got 27, and the band keeps nearly all of it while buying back the
-- tap target and the user control: measured at scale 100, ONE of the seven
-- baselines keeps exactly the row count it had and the other six lose between
-- one and three. Both figures are asserted in the test file.
--
-- On the tap target: a stock Paperwhite 5 row is 66px, which on its 300ppi
-- panel is 5.6mm against the ~9mm usually quoted -- but it is precisely the
-- chip strip's own target on that device, so the two surfaces are not asking
-- the thumb for different things, and a user who wants more can now say so
-- without shrinking the chips. Excel density and a 9mm target are not both
-- achievable on these screens; the mitigation is that in collapsed list mode a
-- tap PREVIEWS rather than opens (double tap opens), so a mis-tap costs a
-- preview rather than the wrong book. See TAP_TARGET_DP.
--
-- The density premise -- a list shows MORE books than the cover grid -- is
-- true at the default scale on every baseline and is NOT scale-free: the grid
-- does not move with list_font_scale, so a large enough row loses to it. Where
-- that crossover sits per panel is measured and pinned in
-- tests/_test_list_geom.lua; it is a real ceiling, not a bug, and the suite
-- states it rather than this comment.
--
-- EVERY LINE AFTER THE FIRST costs its own line box, LESS the padding that box
-- is carrying twice over, PLUS the declared leading. Written as
--
--     rowHeight(n lines) = rowHeight(1 line) + Σ secondLineCost(line i)
--
-- so that at one line the expression is byte for byte what it was before more
-- than one was possible: a single-line list cannot move by a pixel, whatever
-- happens to the arithmetic for the lines below it. The sum is over an ARRAY
-- because the count is a user setting now -- one line, two, or six -- and
-- because each line carries its own font size, so they are not interchangeable
-- terms.
--
-- WHY THE SUBTRACTION. A KOReader TextWidget is not the height of its text: it
-- is `ceil(face_height) + 2 * padding`, where padding defaults to
-- Size.padding.small (ui/widget/textwidget.lua:113, and the default at :34).
-- That padding is decoration -- it exists so a fallback glyph that overruns
-- the face's nominal metrics does not touch whatever sits above or below --
-- and every line carries it on BOTH sides. Stack two such boxes and the pair
-- is paid twice between the lines, on top of the internal leading the face
-- already has. On a Paperwhite 5 that is 8px of it. Measured off a render at
-- that panel, glyph extent to glyph extent, the white INSIDE an item came to
-- 19-25px and the white BETWEEN two items to 24-30px -- two ranges that
-- overlap, which is exactly why the pair read as two rows rather than as one
-- book. Trimmed, the same items measure 10-17px inside against 25-30px
-- between: ranges that no longer meet.
--
-- So a second line costs `line2_h - 2 * text_pad + lead`: its own box with the
-- doubled decoration cancelled, plus the leading this file declares. The
-- renderer (bookshelf_list_row.lua) trims the same 2 * text_pad off both boxes
-- and gives the item back a symmetric top/bottom padding out of the band, so
-- the sum here and the layout there are the same arithmetic.
--
-- Doubling the band instead (max(chip_h * lines, ...)) would have spent a
-- whole row's worth of whitespace per item on a surface whose entire point is
-- density.
--
--   text_pad  TextWidget's own vertical padding, ONE side. Passed in rather
--             than read, because this file cannot see ui/size.
--   lead      INTRA_LEAD_DP, scaled by the caller.
--
-- lineHeights(opts) normalises the input: an absent or empty array is one line
-- of zero height, which is what makes rowHeight{} answer the degenerate 1px
-- rather than raising.
local function lineHeights(opts)
    local h = opts.line_heights
    if type(h) ~= "table" or #h == 0 then return { 0 } end
    return h
end

function ListGeom.rowHeight(opts)
    opts = opts or {}
    local ring    = opts.ring or 0
    local heights = lineHeights(opts)
    -- The one-line row, unchanged: the chip's band, with the text's veto over
    -- it (a line taller than the band still gets its row).
    local h = opts.chip_h or 0
    local text_h = (heights[1] or 0) + ring * 2
    if text_h > h then h = text_h end
    for i = 2, #heights do
        h = h + ListGeom.secondLineCost{
            line2_h  = heights[i],
            text_pad = opts.text_pad,
            lead     = opts.lead,
        }
    end
    -- The degenerate guard, and all that is left of one: a row cannot be zero
    -- pixels tall. Reached only when a caller passes nothing at all.
    if h < 1 then h = 1 end
    return h
end

-- secondLineCost{ line2_h, text_pad, lead } -> pixels
-- What ONE line below the first adds to a row. Never negative: a text_pad big
-- enough to swallow the whole box would otherwise make a two-line item
-- SHORTER than a one-line one.
function ListGeom.secondLineCost(opts)
    opts = opts or {}
    local line2_h  = opts.line2_h or 0
    local text_pad = opts.text_pad or 0
    local lead     = opts.lead or 0
    local cost = line2_h - 2 * text_pad + lead
    if cost < 1 then cost = 1 end
    return cost
end

-- textBands{ content_h, line_heights, text_pad, lead } -> bands
--
-- How the lines of one item are laid down the row's content box, and the other
-- half of the arithmetic above: rowHeight says what the item COSTS, this says
-- where the ink goes inside it. Both are here, in one file, because the two
-- disagreeing is the whole failure mode -- a budget that reserves one thing
-- and a renderer that draws another.
--
-- Returns, top to bottom:
--   top      padding above the first line
--   boxes    each line's box, TRIMMED: its height less the 2 * text_pad of
--            decoration. One entry per line, in order.
--   lead     the declared intra-item leading, between EVERY adjacent pair
--   bottom   padding below the last line
--
-- top and bottom are whatever the band has left over, split evenly with the
-- odd pixel going to the bottom. They are the item's OWN padding, and they are
-- what makes the lines read as one item rather than several: on a Paperwhite 5
-- they come to 5 and 6 pixels, so box to box there are 16px between two books
-- (6 + ring + rule + ring + 5) against the 2px of leading inside one -- and
-- the ink that lands in those boxes measures 25-30px against 10-17px.
--
-- A one-line item does not come through here: its band is content_h and its
-- box keeps its padding, which is what keeps it pixel-identical.
function ListGeom.textBands(opts)
    opts = opts or {}
    local content_h = opts.content_h or 0
    local text_pad  = opts.text_pad or 0
    local lead      = opts.lead or 0
    local heights   = lineHeights(opts)
    local boxes, sum = {}, 0
    for i = 1, #heights do
        local t = (heights[i] or 0) - 2 * text_pad
        if t < 1 then t = 1 end
        boxes[i] = t
        sum = sum + t
    end
    local rest = content_h - sum - lead * (#heights - 1)
    if rest < 0 then rest = 0 end
    local top = math.floor(rest / 2)
    return {
        top    = top,
        boxes  = boxes,
        lead   = lead,
        bottom = rest - top,
    }
end

-- thumbSize(row_h, ring) -> w, h
-- The cover-column thumbnail for a row of `row_h` pixels: the content box
-- inside the ring reservation, at the book aspect, with nothing else taken off
-- it. Takes the ROW height rather than the content height so that every
-- caller -- the row itself, and the two BIM/preload sites that warm covers
-- before a row exists -- subtracts the ring exactly once, here. Passing the
-- row height and forgetting the ring is how the preloader came to warm 88px
-- covers for a 74px thumbnail; there is now no signature that lets it.
function ListGeom.thumbSize(row_h, ring)
    local h = (row_h or 0) - (ring or 0) * 2
    if h < 1 then h = 1 end
    local w = math.floor(h / COVER_ASPECT)
    if w < 1 then w = 1 end
    return w, h
end

-- rowsThatFit(available_h, row_h, gap) -> count >= 1
-- n rows occupy n*row_h + (n-1)*gap. Always returns at least 1: zero rows
-- would render an empty shelf under a live pagination footer, which reads as
-- a bug rather than a tight screen.
function ListGeom.rowsThatFit(available_h, row_h, gap)
    gap = gap or 0
    if type(row_h) ~= "number" or row_h < 1 then return 1 end
    if type(available_h) ~= "number" or available_h < row_h then return 1 end
    local n = math.floor((available_h + gap) / (row_h + gap))
    if n < 1 then n = 1 end
    return n
end

-- ── %bar{rel}: a bar as long as the book ───────────────────────────────────
--
-- A plain %bar fills the line: every book's bar is the same length and only
-- the fill differs, so 40% of a 900-page book looks exactly like 40% of a
-- novella. %bar{rel} scales the bar's TOTAL length by how long the book is, so
-- the filled part is comparable down the column -- which is the actual question
-- ("how much reading have I done here?") rather than the proportional one.
--
-- Requested as: "an option (perhaps via {rel} modifier) to show relative book
-- length for each book by adjusting the total length of the bar ... perhaps by
-- hardcoding an 'average' book length, and applying a percentage scale based on
-- how much above or below that the current book is? Maybe there's a better
-- way."
--
-- ── THE CURVE, AND WHY IT IS NOT LINEAR ────────────────────────────────────
--
-- Linear against a fixed average is the obvious answer and reads badly: real
-- libraries span 60-page novellas to 1200-page doorstops, so a linear scale
-- normalised on a typical novel either clips the top half of the range or
-- squashes everything typical into the left third of the row. Page counts are
-- roughly log-normal, and a square root is the cheap compression that matches:
-- it keeps the ordering exact, keeps typical books using most of the width, and
-- still makes a doorstop visibly a doorstop.
--
--   pages   fraction of the line
--     75    0.32
--    175    0.49
--    350    0.70   <- REFERENCE
--    700    0.99
--   1200    1.00   (capped)
--
-- The alternative considered and rejected: normalising against the longest book
-- on the CURRENT PAGE. That needs no constant and is self-calibrating, but the
-- scale then changes as you page -- the same book draws a different bar on page
-- 1 than on page 2 -- which makes the one thing the feature is for (comparing
-- down a column) unreliable across a scroll.
--
-- REFERENCE is a constant rather than a setting for now: it is the sort of
-- number that wants to be picked once by eye against a real library, and one
-- more nudge dialog nobody opens is worse than a good default.
ListGeom.REL_BAR_REFERENCE    = 350   -- pages: a typical novel
ListGeom.REL_BAR_AT_REFERENCE = 0.70  -- how much of the line that book gets
ListGeom.REL_BAR_MIN          = 0.20  -- a bar shorter than this reads as a dot

-- relativeBarFraction(pages [, reference]) -> 0 < f <= 1
--
-- An unknown page count answers the reference fraction, NOT 1: a book we know
-- nothing about is a typical book, and drawing it full-width would make "no
-- metadata" look like "the longest thing in the library".
function ListGeom.relativeBarFraction(pages, reference)
    reference = tonumber(reference) or ListGeom.REL_BAR_REFERENCE
    if reference <= 0 then reference = ListGeom.REL_BAR_REFERENCE end
    local n = tonumber(pages)
    if not n or n <= 0 then return ListGeom.REL_BAR_AT_REFERENCE end
    local f = ListGeom.REL_BAR_AT_REFERENCE * math.sqrt(n / reference)
    if f < ListGeom.REL_BAR_MIN then return ListGeom.REL_BAR_MIN end
    if f > 1 then return 1 end
    return f
end

return ListGeom
