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

-- ── The chip bar's sizing, which is now the row's ────────────────────────────
--
-- A list row is the same kind of thing as a chip: a full-width strip of one
-- line of text that you tap. The maintainer's ruling is that it should measure
-- like one -- same height, same face, same size, and above all the same user
-- control, so the one Text size setting that already grows the chip strip
-- grows the table too instead of the table having a private hardcoded 16pt
-- nobody can reach.
--
-- What the chip bar declares, in the three places it declares it:
--   height  bookshelf_widget.lua's _layoutPrimitives (and the same two lines
--           inlined at the top of _rebuild):
--             chip_h = floor(Size.item.height_default * chip_font_scale/100 + 0.5)
--   border  bookshelf_chip_bar.lua's _buildChipRow wraps the whole strip in
--           FrameContainer{ bordersize = Size.border.thin }, whose border is
--           painted OUTSIDE the height above (see CHIP_BORDER_DP)
--   font    bookshelf_chip_bar.lua: BFont:getFace("infofont", _scaled(16)),
--           where _scaled(n) = floor(n * chip_font_scale/100 + 0.5)
--
-- Both are reproduced below as pure functions of their inputs. ListGeom cannot
-- read Size or the settings store -- it is deliberately widget-free so the row
-- arithmetic is testable off-device -- so the caller supplies
-- Size.item.height_default and the scale, and bookshelf_list_row.lua is the
-- one file that does that reading. Everything else (the widget's row budget,
-- the pure test) goes through these functions, so there is one rounding rule,
-- not three.
ListGeom.FONT_FACE = "infofont"

-- The chip bar's base font size, before chip_font_scale. Changing this here
-- and not in bookshelf_chip_bar.lua would make the row and the chip disagree,
-- which is the whole thing this pass is removing.
ListGeom.FONT_SIZE_DP = 16

-- scalePercent(n, pct) -- chip_font_scale applied, rounding exactly as both
-- chip-bar sites round (floor(x + 0.5), not ceil, not math.floor(x)).
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
-- The ring's reserved band IS the row's vertical padding when the text is what
-- sets the height: the content box sits inside it and the ring paints into it
-- when selected, so selecting a row changes only the perimeter pixels and
-- never moves a pixel of its content -- the same invariant SpineWidget's own
-- selection ring keeps, at a fraction of the cost.
ListGeom.ROW_RING_DP = 1

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

-- Book cover aspect. true_cover_aspect is deliberately NOT consulted:
-- variable-width thumbnails would give the table a ragged left edge, which
-- costs more than uncropped covers gain at thumbnail size.
local COVER_ASPECT = 1.5

function ListGeom.hasCover(active)
    if type(active) ~= "table" then return false end
    for _i, c in ipairs(active) do
        if c and c.id == "cover" then return true end
    end
    return false
end

-- rowHeight{ chip_h, font_h, ring } -> pixels
--   chip_h   the chip strip's painted height (ListGeom.chipRowHeight)
--   font_h   rendered line height of the row's text face at ListGeom.fontSize
--   ring     selection-ring reservation, one side (ROW_RING_DP, scaled)
--
-- THE CHIP sets the height. A row and a chip are the same gesture target and
-- now measure the same, so the tap the user learns on the chip strip is the
-- tap they get in the table, and the one Text size setting moves both.
--
-- No has_cover branch, and that is the point of the change rather than a
-- simplification of it. Two branches meant the cover-off case was governed by
-- a 42dp floor while the cover-on case was governed by the text, so turning
-- the Cover column OFF made rows TALLER -- 84px and 16 rows on a Paperwhite 5
-- against 49px and 27 with covers on. One expression cannot invert.
--
-- The max() is the text's veto, and it is NOT a formality: 30dp of chip and a
-- 16pt line are close enough together that which one wins depends on the
-- panel. Measured across the seven sweep baselines, the chip binds on five and
-- the rendered line binds on two -- a 1088x1448 Paperwhite 3 at dpi 200 (47px
-- of text against a 46px chip) and a 600x800 Kindle at dpi 167 (34 against
-- 31). There the row comes out a few pixels TALLER than a chip, which is the
-- harmless direction; a row one pixel SHORTER than its own line clips
-- descenders in every row on the page. Both terms still scale by
-- chip_font_scale together, so the relationship holds across the 50-300 range
-- the nudge dialog offers. Which term binds where is pinned in
-- tests/_test_list_geom.lua rather than asserted here.
--
-- Earlier models, named so none of them comes back: font_h * 2.4 spent ~40% of
-- every row on padding and left list mode LESS dense than the cover grid it
-- exists as an alternative to (9 rows against 12 books on a 1248x1648 panel).
-- A fixed 44dp cover bought 14 rows, still only two more than the grid.
-- Text-tight got 27, and the chip's height keeps essentially all of it while
-- buying back the tap target and the user control: measured, four of the seven
-- baselines keep exactly the row count they had and the other three lose one
-- or two.
--
-- On the tap target: a stock Paperwhite 5 row is 62px, which on its 300ppi
-- panel is 5.2mm against the ~9mm usually quoted -- but it is now precisely
-- the chip strip's own target on that device, so the two surfaces are no
-- longer asking the thumb for different things. Excel density and a 9mm target
-- are not both achievable on these screens; the mitigation is that in
-- collapsed list mode a tap PREVIEWS rather than opens (double tap opens), so
-- a mis-tap costs a preview rather than the wrong book. See TAP_TARGET_DP.
function ListGeom.rowHeight(opts)
    opts = opts or {}
    local font_h = opts.font_h or 0
    local ring   = opts.ring or 0
    local h = opts.chip_h or 0
    local text_h = font_h + ring * 2
    if text_h > h then h = text_h end
    -- The degenerate guard, and all that is left of one: a row cannot be zero
    -- pixels tall. Reached only when a caller passes nothing at all.
    if h < 1 then h = 1 end
    return h
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

return ListGeom
