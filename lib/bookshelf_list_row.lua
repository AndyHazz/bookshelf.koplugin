-- bookshelf_list_row.lua
-- One list-view row: an item rendered as N lines of expanded token template.
--
-- Mirrors bookshelf_shelf_row.lua's external contract so the widget's
-- existing callback plumbing works untouched -- same opts keys, same
-- item-kind dispatch order (bookshelf_shelf_row.lua:448-670: explicit `kind`
-- first, then the legacy series shape detected by a `.books` array, then a
-- plain book), and the same reporting of the cover area actually rendered
-- into (bookshelf_shelf_row.lua:814-822) so the preloader warms next-page
-- covers at the size the row really used. The one difference: ShelfRow.new
-- takes an `items` ARRAY (a row of n_cols covers); ListRow.new takes a
-- single `item`, because a list row is one item. The caller (Task 6) builds
-- N of them.

local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer  = require("ui/widget/container/framecontainer")
local InputContainer  = require("ui/widget/container/inputcontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local VerticalGroup   = require("ui/widget/verticalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local VerticalSpan    = require("ui/widget/verticalspan")
local LineWidget      = require("ui/widget/linewidget")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local RightContainer  = require("ui/widget/container/rightcontainer")
local TextWidget      = require("ui/widget/textwidget")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local Widget          = require("ui/widget/widget")
local GestureRange    = require("ui/gesturerange")
local Geom            = require("ui/geometry")
local Size            = require("ui/size")
local Font            = require("ui/font")
local Blitbuffer      = require("ffi/blitbuffer")
local Screen          = require("device").screen
local logger          = require("logger")
local BFont           = require("lib/bookshelf_fonts")
local SpineWidget     = require("lib/bookshelf_spine_widget")
local Lines           = require("lib/bookshelf_list_lines")
local ListGroup       = require("lib/bookshelf_list_group")
local CoverProgress   = require("lib/bookshelf_cover_progress")
local Tokens          = require("lib/bookshelf_tokens")
local TextSegments    = require("lib/bookshelf_text_segments")
local ListGeom        = require("lib/bookshelf_list_geom")
local BookshelfSettings = require("lib/bookshelf_settings_store")
local BandMetrics     = require("lib/bookshelf_band_metrics")
local Repo            = require("lib/bookshelf_book_repository")
local _gettime        = require("lib/bookshelf_gettime")

local ListRow = {}

-- %spacer is NOT an expander (lib/bookshelf_tokens.lua:741-750 says why: an
-- expander would replace it with empty text before any renderer saw it). It is
-- detected here, AFTER expansion, and splits the line into
-- [before, elastic gap, after] -- which is what gives a line the left/right
-- anchoring the right-aligned columns used to provide. Same pattern, same
-- one-shot semantics and the same overflow handling as the hero's own
-- buildLine (lib/bookshelf_hero_card.lua).
local SPACER_TOKEN_PATTERN = "%%spacer"
local BAR_TOKEN_PATTERN    = "%%bar"

-- findElastic(text) -> kind, start, stop, modifier
--
-- The elastic token in an expanded line. Both %bar and %spacer take the
-- remaining width, and a line can only give that away once.
--
-- ── %bar WINS, wherever it sits ────────────────────────────────────────────
--
-- It used to be "whichever comes first", which read as a bug the moment anyone
-- wrote "%authors %spacer %bar": the spacer won on position, the bar was
-- stripped from the trailing segment, and the line silently lost its progress
-- bar. Reported exactly that way -- "the %bar doesn't display after %spacer".
--
-- Position is the wrong tie-break because the two are not equivalent. A
-- %spacer's only job is to push the halves apart; a %bar is CONTENT that
-- happens to be stretchy. Giving the width to the bar still separates the
-- halves -- the bar sits between them and fills the gap -- so the spacer's
-- intent survives, while the reverse throws the bar away entirely.
--
-- %bar accepts a brace modifier -- %bar{rel} today. It has to be matched here
-- rather than left to the token expander because it is not a text
-- substitution: it changes the WIDGET's geometry. Braces are safe as a
-- modifier syntax because Tokens.expand only consumes them after %datetime.
local function findElastic(text)
    local bs, be = text:find(BAR_TOKEN_PATTERN)
    if bs then
        local mod
        local _ms, me, captured = text:find("^{([%w_,]*)}", be + 1)
        if me then be, mod = me, captured end
        return "bar", bs, be, mod
    end
    local ss = text:find(SPACER_TOKEN_PATTERN)
    if ss then return "spacer", ss, ss + 6, nil end
    return nil
end

-- Strip every elastic token from a trailing segment, modifier and all, so a
-- hand-edited template with two of them does not render the second as literal
-- text.
local function stripElastic(s)
    return (s:gsub(BAR_TOKEN_PATTERN .. "{[%w_,]*}", "")
             :gsub(BAR_TOKEN_PATTERN, "")
             :gsub(SPACER_TOKEN_PATTERN, ""))
end

-- ── The row's type and height: the chip bar's shape, on its OWN key ────────
--
-- A row measures like a chip -- same face, same base size, same painted band,
-- same arithmetic (BandMetrics, which both surfaces go through). What it no
-- longer shares is the SETTING: list rows are driven by list_font_scale and
-- the chip strip by chip_font_scale, so the two can be tuned independently.
-- At the default 100 on both they render identically, which is the point:
-- nobody sees a change until they nudge one.
--
-- Why the row's height moves with its font scale rather than staying fixed:
-- nudging the list scale is meant to be a DENSITY control -- fewer, larger
-- rows or more, smaller ones -- not a text-size control that grows type inside
-- a band that cannot hold it.
--
-- NOT the same WEIGHT as a chip, and that is a ruling rather than an
-- oversight. Chip labels are bold -- _buildLabelContent asks for
-- `{ bold = <segment is text> }` (bookshelf_chip_bar.lua:114 and :148), so
-- every non-icon run of a chip label renders bold, and the breadcrumb pills
-- say so outright at :966. Rows are not. Measured on a Paperwhite 5 capture
-- the two are already the same SIZE -- cap height 19px for both,
-- "HOME"/"SERIES" in the strip against "Dan Simmons" in a row -- and the whole
-- of the apparent difference was stem weight, 4px against 2-3px. Bold on 26
-- rows of a table reads as a page of headings, so the maintainer's call is
-- size and height yes, weight no.
--
-- The scale is read on demand rather than at load: it is a live setting and
-- the nudge dialog has to take effect on the next rebuild without a restart --
-- the same reason bookshelf_chip_bar.lua reads its own that way. The widget's
-- row-height budget (BookshelfWidget:_listRowHeight) goes through the same
-- lineStyles below that the render does, so the space reserved for a row and
-- the text it has to hold cannot drift apart: clipped descenders if the budget
-- is short, dead space in every row if it is long.
--
-- The row's DEFAULT face, for a line that names no family of its own.
ListRow.FONT_FACE = ListGeom.FONT_FACE

-- ── A line's own face ──────────────────────────────────────────────────────
--
-- Each line carries a point size and, optionally, a font family. The size is
-- declared BEFORE list_font_scale and multiplied by it here -- exactly the way
-- the hero multiplies a region's font_size by its own global scale knob. That
-- is what keeps list_font_scale a DENSITY control: nudge it and the type and
-- the band it sits in move together, rather than the type growing inside a
-- band that cannot hold it.
--
-- At the shipped defaults (16 and 14 at scale 100) this reproduces the sizes
-- the two-row column model rendered at, to the point.

-- ListRow.lineFontSize(line) -> the point size this line renders at.
function ListRow.lineFontSize(line)
    local pt = (type(line) == "table" and line.font_size)
        or ListGeom.FONT_SIZE_DP
    local s = BandMetrics.scaled(pt, BandMetrics.LIST_KEY)
    if s < 1 then s = 1 end
    return s
end

-- ListRow.lineFace(line) -> face, bold.
--
-- A named family resolves through the plugin's font scanner, the same call the
-- hero's [font=NAME] override makes; an unresolvable name falls back to the
-- row's own face rather than crashing a render, which is what happens when a
-- user deletes a font file a saved line still names.
--
-- The bold flag comes back from BFont:getFace for the default face because a
-- real bold FILE means the widget must not faux-bold on top of it. A named
-- family has no sibling lookup here, so it keeps the flag it was given.
function ListRow.lineFace(line)
    local want_bold   = (type(line) == "table" and line.bold == true) or false
    local want_italic = (type(line) == "table" and line.italic == true) or false
    local size = ListRow.lineFontSize(line)
    local name = type(line) == "table" and line.font_face or nil
    if name then
        local file = BFont.resolveFontNameToFile(name) or name
        -- A real style FILE beats faux-bolding, and is the ONLY way to get
        -- italic at all -- TextWidget can synthesise weight but not slant, so
        -- without a variant file an italic line would render regular and the
        -- setting would look broken.
        local variant = BFont.variantOf(file, want_bold, want_italic)
        if variant then
            local ok_v, vface = pcall(Font.getFace, Font, variant, size)
            -- bold=false: the file already carries the weight, and faux-bolding
            -- a bold file on top smears it.
            if ok_v and vface then return vface, false end
        end
        local ok, face = pcall(Font.getFace, Font, file, size)
        -- No variant on disk: the weight still degrades to faux-bold, and the
        -- slant is simply lost. Better than refusing to render.
        if ok and face then return face, want_bold end
    end
    return BFont:getFace(ListRow.FONT_FACE, size,
                         { bold = want_bold, italic = want_italic })
end

-- ── {xN}: a line that may WRAP ─────────────────────────────────────────────
--
-- Every list line is one rendered line, because a row that wrapped would break
-- the uniform row height the whole model depends on. That is right for a title
-- and wrong for %description, which is a paragraph and reads as a fragment cut
-- off mid-word. The maintainer's ask: "could we add a modifier e.g. {x4} to
-- allow wrapping up to 4 lines?"
--
-- So {xN} is a LAYOUT modifier, not a text one, and it is read off the TEMPLATE
-- rather than the expanded text -- the row-height budget has to know how tall
-- the line is before any record has been expanded against it. A line declared
-- {x4} reserves four line-heights and renders into them; the budget then fits
-- proportionally fewer rows on the page, which is the honest trade and needs no
-- special handling anywhere else.
--
-- The cap matches Lines.MAX_LINES's reasoning: past this a single row is most
-- of the shelf, which is not a configuration.
local WRAP_MAX = 6

-- ListRow.wrapLines(template) -> how many rendered lines this line may occupy.
function ListRow.wrapLines(template)
    if type(template) ~= "string" then return 1 end
    local n = tonumber(template:match("%%[%a_]+{x(%d+)}"))
    if not n or n < 1 then return 1 end
    if n > WRAP_MAX then return WRAP_MAX end
    return n
end

-- The modifier is consumed by the LAYOUT, so it must never reach the renderer
-- as text: %description is a real token, so expanding first substitutes the
-- blurb and strands a literal "{x4}" after it.
function ListRow.stripWrapModifier(template)
    if type(template) ~= "string" then return template end
    return (template:gsub("(%%[%a_]+){x%d+}", "%1"))
end

-- ListRow.lineStyles(lines) -> array of { face, bold, wrap, height }, one per
-- line.
--
-- The single place a line's face is resolved and measured. Both the row-height
-- BUDGET (BookshelfWidget:_listRowHeight) and the row LAYOUT below go through
-- it, so the space reserved for a line and the text drawn into it cannot drift
-- apart -- the failure this file's header warns about, now multiplied by a
-- variable number of lines.
function ListRow.lineStyles(lines)
    local out = {}
    for i, line in ipairs(lines or {}) do
        local face, bold = ListRow.lineFace(line)
        local wrap = ListRow.wrapLines(type(line) == "table" and line.template)
        out[i] = { face = face, bold = bold, wrap = wrap,
                   height = ListRow.lineHeight(face, bold) * wrap }
    end
    return out
end

-- ListRow.lineHeights(lines) -> just the heights, in order. What
-- ListGeom.rowHeight wants; a helper so the widget does not unpack lineStyles
-- for itself and grow a second opinion about which faces the row uses.
function ListRow.lineHeights(lines)
    local out = {}
    for i, s in ipairs(ListRow.lineStyles(lines)) do out[i] = s.height end
    return out
end

-- ListRow.lineHeight(face, bold) -> the rendered height of one line in that
-- face, memoised per face object.
--
-- Every list-mode geometry site goes through here: the row-height budget
-- (BookshelfWidget:_listRowHeight, once or twice per rebuild) and the
-- page-constant layout below (twice per page). Each miss costs a TextWidget
-- probe, and this plugin has had to fix per-render probe costs before.
--
-- Weak keys: BFont:getFace hands back a cached face table, so a user font
-- change -- or a change of list_font_scale, which moves both sizes -- yields a
-- different key, a fresh measurement, and lets the stale entry go. Lived in
-- bookshelf_widget.lua until the second line needed the same measurement; two
-- caches keyed on the same faces is one cache.
local _line_h_cache = setmetatable({}, { __mode = "k" })

function ListRow.lineHeight(face, bold)
    local cached = face and _line_h_cache[face]
    if cached then return cached end
    local probe = TextWidget:new{ text = "Ag", face = face, bold = bold }
    local h = probe:getSize().h
    probe:free()
    if face then _line_h_cache[face] = h end
    return h
end

-- ListRow.TEXT_PAD -- the vertical padding a KOReader TextWidget puts above
-- AND below every line it draws (ui/widget/textwidget.lua:34, :113). Named
-- here because the row CANCELS it between its two lines and hands the pixels
-- back as the item's own top/bottom padding -- see ListGeom.textBands -- and
-- because the height budget has to subtract exactly what the renderer trims.
-- Read from Size, not restated: it is TextWidget's default, and if KOReader
-- moves it the trim has to move with it.
ListRow.TEXT_PAD = Size.padding.small

-- ListRow.chipRowHeight() -> the row's painted band height in pixels: the
-- chip strip's geometry (cell height plus the strip frame's border twice) at
-- the LIST scale. Named for the shape it copies, not for the key it reads --
-- at list_font_scale = 100 it is exactly the chip band, and away from 100 it
-- is deliberately not.
function ListRow.chipRowHeight()
    return BandMetrics.paintedHeight(BandMetrics.LIST_KEY)
end

-- The two colours a row paints with, declared once so the divider below can be
-- derived FROM them instead of guessed alongside them.
--
-- Both are mode-independent, and that is the whole point. KOReader inverts the
-- entire framebuffer at refresh time for night mode, so a surface that paints
-- white paper and black ink comes out as black paper and white ink without
-- knowing the mode exists -- which is exactly what the shelf does (the page
-- background in bookshelf_widget.lua's _rebuild is an unconditional
-- COLOR_WHITE, and the cells below take TextWidget's default black).
ListRow.ROW_BG = Blitbuffer.COLOR_WHITE
ListRow.ROW_FG = Blitbuffer.COLOR_BLACK

-- How far the inter-row rule travels from paper towards ink.
--
-- Seven fifteenths, which on this surface's endpoints paints byte 136 --
-- exactly Blitbuffer.COLOR_DARK_GRAY, and that is the whole of the choice.
-- Two independent precedents already name that byte for a rule between list
-- items, and they agree:
--
--   * KOReader's own Menu separates its items with it: `line_color =
--     Blitbuffer.COLOR_DARK_GRAY` (ui/widget/menu.lua:635), which is the
--     colour of every underline and separator in every stock list on the
--     device. A table of books sits next to those lists and should not be
--     ruled in a different grey.
--   * This plugin paints its own hairlines with it at three other sites --
--     bookshelf_library_modal.lua:1027, bookshelf_color_palette.lua:382,
--     bookshelf_collection_manager.lua:964 -- the same three ListRow.divider
--     below already cites for the rule's HEIGHT. Colour and height now come
--     out of one precedent rather than the height following it and the colour
--     being invented alongside.
--
-- It replaces 0.13 / byte 222, which was picked as "extra light grey" against
-- an LCD preview and read as barely-there on hardware in BOTH modes. The
-- reason is quantisation, not taste: an e-ink panel renders 16 levels, one
-- every 17 bytes, so 222 lands on 0xDD -- ONE step off paper out of fifteen,
-- on a rule one pixel tall. Midtones wash out further on e-ink than any
-- desktop render shows, so the byte has to be chosen with room to lose some.
-- 136 is eight steps off paper and lands exactly on a palette level, so a 1px
-- rule needs no dithering to reach it.
--
-- The ceiling on darkening, so the next round of this does not overshoot: the
-- rule must stay LIGHTER than the row's own secondary text (SECONDARY_INK
-- below, byte 85). A rule that out-weighs the type it separates has become a
-- border, which is the failure in the other direction.
--
-- Re-measure this if ROW_BG ever stops being paper-white. With the endpoints
-- as they stand the interpolation below is numerically identical to
-- Blitbuffer.gray(7/15), and someone will eventually notice that and
-- "simplify" it. The coincidence is the point of the exercise, not a
-- redundancy: the value is safe because the two endpoints are ATTACHED --
-- ROW_BG is the row FrameContainer's real `background` and ROW_FG a real
-- `fgcolor` on every text cell, so what this function reads is what the
-- surface paints. Move either endpoint and gray(7/15) stops being the answer
-- while the arithmetic below keeps giving the right one.
local DIVIDER_INK = 7/15

-- The divider colour, interpolated IN PAINTED SPACE between the row's own two
-- painted colours. Deliberately NOT computed from Blitbuffer.gray() and not
-- switched on night_mode:
--
--   * gray()'s argument is DARKNESS (ffi/blitbuffer.lua:2637 -- "0 is white,
--     1.0 is black", painting 255*(1-f)), so a value picked to look
--     extra-light paints near-white and the night inversion turns it into a
--     heavy dark line. This plugin has got that backwards on the stack-pile
--     borders more than once.
--   * Interpolating between two colours the surface ALREADY paints means no
--     inversion reasoning enters this file at all. Paper is painted 255 and
--     ink 0 in both modes, so the rule paints 136 in both: displayed that is
--     136-on-255 in day (a grey rule on white) and 119-on-0 in night (the
--     same rule on black). Same distance from the page either way, which is
--     what a rule has to be on a surface that inverts -- and it is why one
--     darkening fixed both modes, which is what the report of "feint in both"
--     predicted it would.
--
-- CoverProgress.resolvedColors().border is the obvious "resolved dark
-- endpoint" and was measured before being rejected: it paints 0 in day but
-- #FAFAFA = 250 in night, five levels off the paper it would sit on, so any
-- weighting toward paper puts the night rule at 254 -- invisible. shadowGray()
-- is closer (128 day / 217 night) but still asymmetric enough that one weight
-- cannot serve both. Painted bytes, not palette intuition; grey names that
-- sound different land ~8 levels apart and vanish on e-ink.
local function inkAt(f)
    local paper = ListRow.ROW_BG:getColor8().a
    local ink   = ListRow.ROW_FG:getColor8().a
    return Blitbuffer.Color8(math.floor(paper + (ink - paper) * f + 0.5))
end

local function dividerColor()
    return inkAt(DIVIDER_INK)
end
ListRow.dividerColor = dividerColor

-- How far the text of every line BELOW THE FIRST travels from paper towards
-- ink: the muted half of "smaller and secondary".
--
-- Which lines are muted is a rule, not a per-line setting, and deliberately:
-- the first line is the item's subject and everything under it is a note about
-- that subject, whatever the user has put there. A per-line colour would be a
-- sixth field on a shape that is already the hero's, and the hero has no such
-- field either.
--
-- Two thirds, which on this surface's endpoints paints byte 85 -- exactly
-- Blitbuffer.COLOR_GRAY_5, which is this plugin's declared MUTED role
-- (lib/bookshelf_start_menu_modules.lua:42 names it, and the hero modules and
-- the module kit draw every heading, hint and attribution with it). So the
-- list's secondary line is the same grey as every other piece of secondary
-- text in the plugin; it is reached the way THIS surface has to reach a colour
-- rather than by naming the constant.
--
-- Why not name the constant. A row paints its own paper and its own ink and
-- relies on KOReader's night inversion to turn white-on-black into
-- black-on-white without knowing the mode exists (see ROW_BG / ROW_FG above).
-- Interpolating between the two colours the surface actually paints keeps that
-- property: 85-on-255 in day, 170-on-0 in night, the same distance from the
-- page either way. Blitbuffer.gray() is NOT usable here -- its argument is
-- darkness, so the intuitive value paints its own opposite; the divider
-- comment above has the full account.
--
-- The test pins the resulting byte against COLOR_GRAY_5, so if either endpoint
-- ever moves, the mismatch is a failure rather than a slow drift away from the
-- plugin's own palette.
--
-- If a device ignores TextWidget fgcolor (bookshelf_widget.lua:175 records
-- that some Kindles do, for the inverted case) the second line renders black.
-- That degrades to "smaller but not muted", which still reads as secondary --
-- neither half of the treatment is asked to do the job alone.
local SECONDARY_INK = 2/3

local function secondaryColor()
    return inkAt(SECONDARY_INK)
end
ListRow.secondaryColor = secondaryColor


-- The row's own two scaled sizes, both from ListGeom's dp declarations rather
-- than from Size.* directly. They come out as exactly Size.line.thin and
-- Size.border.default on every panel, and taking them the long way round is
-- the point: the row-count budget in bookshelf_widget.lua and the pure test in
-- tests/_test_list_geom.lua scale the SAME two declarations, so the rule this
-- file paints and the space the budget leaves for it cannot drift apart. They
-- did, once -- see bookshelf_list_geom.lua's header.
--
-- RING is exported because BookshelfWidget:_listRowHeight has to add it to the
-- line height, and one of them restating it is exactly the drift above.
-- The bulk-selection checkbox, in the bundled symbols face. PUA only: that
-- face covers U+E000..U+F8FF and nothing else, and a non-PUA codepoint has
-- segfaulted this plugin before.
--   U+E832 checkbox-marked-circle        -> in the selection
--   U+E82F checkbox-blank-circle-outline -> not in it
ListRow.TICK_ON  = "\xEE\xA0\xB2"
ListRow.TICK_OFF = "\xEE\xA0\xAF"

-- How much of a line's reported height the checkbox glyph fills. See the
-- gutter's own note in pageLayout for why it is not 1.
local TICK_FILL = 0.75

-- tickCell(width, height, on) -> the checkbox for one row.
--
-- The unticked box is drawn in the row's SECONDARY ink, the ticked one in its
-- full ink: an unticked box is scaffolding for the one decision the user is
-- making, and drawn at full weight a column of them out-shouts the titles they
-- are meant to be helping you pick between.
-- No focused/unfocused variant: the focused row is a TINT, so the row's ink is
-- unchanged and the checkbox reads on it exactly as it does on paper. (An
-- inverted row was the other candidate and would have needed one, along with a
-- recoloured copy of every line.)
function ListRow.tickCell(width, height, on)
    local glyph = CoverProgress.buildGlyphWidget(
        on and ListRow.TICK_ON or ListRow.TICK_OFF,
        height,
        on and ListRow.ROW_FG or secondaryColor())
    return CenterContainer:new{
        dimen = Geom:new{ w = width, h = height },
        glyph,
    }
end

local ROW_GAP = Screen:scaleBySize(ListGeom.ROW_GAP_DP)
local BORDER  = Screen:scaleBySize(ListGeom.ROW_RING_DP)
-- The declared padding PLUS whatever OUTER gave up, so moving the box outward
-- costs the row no height and re-baselines nothing.
local INNER   = Screen:scaleBySize(ListGeom.ROW_INNER_PAD_DP)
              + Screen:scaleBySize(ListGeom.ROW_RING_DP)
-- ZERO. The selection box reaches the row's own edge, which is as far out as
-- it can go and lands it where the hairline rule between rows sits.
--
-- It was one border's worth, on the reasoning that a rounded corner touching a
-- straight rule would read as a misprint. On screen the opposite happened: the
-- box sat INSIDE the line the unselected rows are bounded by, so selecting a
-- row appeared to shrink it -- "visually it has an odd feeling like the row
-- contracts when selected".
--
-- Kept as a named zero rather than deleted because it is a real term of the
-- inset arithmetic, and because the space it gave up is handed straight to
-- INNER below: RING is unchanged, so the row height, the thumbnail size and
-- the whole pinned density table stay exactly as they are, and the only thing
-- that moves is where the box is drawn.
local OUTER   = 0

-- RING is what every consumer reserves on EACH SIDE of the row: the gap outside
-- the selection box, the box's own stroke, and the breathing room inside it.
-- One number, because the height budget, the thumbnail sizing and the renderer
-- must inset by the same amount or the row and its contents disagree -- exactly
-- the drift this file's header warns about.
--
-- The name is unchanged deliberately: BookshelfWidget:_listRowHeight, the cover
-- preloader and ListGeom.thumbSize all read ListRow.RING, and it still means
-- "the band round the row's content".
local RING    = OUTER + BORDER + INNER
ListRow.RING  = RING

-- The selection box's corner radius, borrowed from the cover card rather than
-- invented: "the same style/thickness we use for cover images". A row and a
-- thumbnail rounded to different radii on the same screen read as two
-- different design languages.
local RADIUS  = SpineWidget.CARD_RADIUS or Screen:scaleBySize(4)

-- The leading between the two lines of ONE item, from the same declaration the
-- height budget reads (ListGeom.INTRA_LEAD_DP). Exported for the same reason
-- RING is: BookshelfWidget:_listRowHeight has to add it, and a second copy
-- there is the drift this file's header warns about.
ListRow.INTRA_LEAD = Screen:scaleBySize(ListGeom.INTRA_LEAD_DP)

-- ListRow.divider(width) -> the hairline rule between two rows, exactly
-- ROW_GAP tall so the rule IS the gap (bookshelf_library_modal.lua:1028,
-- bookshelf_color_palette.lua:382, bookshelf_collection_manager.lua:964 all
-- paint the plugin's hairline at the same height).
--
-- A fresh widget per call: sharing one LineWidget across paint positions
-- corrupts KOReader's geometry calculations, the same trap the library modal's
-- own divider() helper documents.
-- ── The rule is PER COLUMN, and it gets out of the way of a selection ──────
--
-- opts (all optional):
--   n_cols  how many columns the page is in (default 1)
--   gap     the inter-column gap, left unruled
--   skip    { [col] = true } -- columns whose segment must not be drawn
--
-- TWO reasons it is not one line across the whole width any more.
--
-- A rule spanning the column gap says the two cells beside it are one thing.
-- They are not: at two columns the page is two independent lists side by side,
-- and a continuous rule reads as a table with a missing vertical, which is why
-- it looked wrong the moment multi-column shipped.
--
-- And a rounded selection box cannot share an edge with a straight hairline.
-- The box sits inset from the row edge, so the rule above and below it runs
-- along its corners -- close enough to read as a join that did not quite meet.
-- `skip` blanks the segments the focused cell touches, so the box lands in
-- clear space. Only that COLUMN's segments go: the rule either side of it is
-- separating cells that have nothing to do with the selection.
function ListRow.divider(width, opts)
    opts = opts or {}
    local n_cols = math.max(1, opts.n_cols or 1)
    local skip   = opts.skip
    if n_cols == 1 and not (skip and skip[1]) then
        return LineWidget:new{
            background = dividerColor(),
            dimen      = Geom:new{ w = width, h = ROW_GAP },
        }
    end
    local gap   = opts.gap or 0
    local col_w = math.max(1, math.floor((width - gap * (n_cols - 1)) / n_cols))
    local hg = HorizontalGroup:new{ align = "center" }
    for c = 1, n_cols do
        if c > 1 then
            hg[#hg + 1] = HorizontalSpan:new{ width = gap }
        end
        if skip and skip[c] then
            -- A SIZED WIDGET, not a HorizontalSpan: a span reports zero height
            -- (horizontalspan.lua:10), so a single-column page with its only
            -- segment skipped would collapse the gap to nothing and shuffle
            -- every row below it up by the rule's height. The blank has to
            -- occupy exactly what the rule would have.
            hg[#hg + 1] = Widget:new{
                dimen = Geom:new{ w = col_w, h = ROW_GAP },
            }
        else
            hg[#hg + 1] = LineWidget:new{
                background = dividerColor(),
                dimen      = Geom:new{ w = col_w, h = ROW_GAP },
            }
        end
    end
    return hg
end

-- A list row used to wear the shelf's own BorderOverlay ring at ROW_RING_DP
-- thickness. It does not any more -- the focused row INVERTS instead (see the
-- FrameContainer in ListRow.new), and bulk membership is the checkbox. The
-- ring's RESERVATION survives as the row's vertical padding, which is a
-- separate job it was always doing.

-- Dispatch an item to its tap/hold pair. Order matches
-- bookshelf_shelf_row.lua's own dispatch: explicit `kind` first, then the
-- legacy series shape (`.books` array, no `kind`), then a plain book.
local function handlersFor(item, opts)
    local k = item.kind
    if     k == "folder"   then return opts.on_folder_tap,   opts.on_folder_hold
    elseif k == "opds_nav" then return opts.on_opds_nav_tap, nil
    elseif k == "author"   then return opts.on_author_tap,   opts.on_author_hold
    elseif k == "genre"    then return opts.on_genre_tap,    opts.on_genre_hold
    elseif k == "tag"      then return opts.on_tag_tap,      opts.on_tag_hold
    elseif k == "language" then return opts.on_language_tap, opts.on_language_hold
    elseif item.books      then return opts.on_series_tap,   opts.on_series_hold
    end
    return opts.on_book_tap, opts.on_book_hold
end

-- The book-like record SpineWidget renders in the cover column. A plain book
-- IS that record; every group kind hands SpineWidget a representative member
-- (a folder's first_book, a group's first book) so the thumbnail shows real
-- cover art without growing a second, stack-aware cover path just for the
-- list's much smaller thumbnail -- SpineWidget already knows how to turn a
-- book record into a cover, no-cover placeholder included, and books should
-- look the same everywhere they appear.
local function coverBookFor(item)
    local k = item.kind
    if k == "folder" then return item.first_book end
    if k == "opds_nav" then
        -- A nav record may carry its own cover_image_path (the feed's own
        -- image, or one borrowed from a cached child -- see
        -- bookshelf_shelf_row.lua's opds_nav branch); SpineWidget reads that
        -- field directly regardless of has_cover/filepath, so the record can
        -- stand in for its own cover.
        return item.cover_image_path and item or nil
    end
    if item.books and item.books[1] then return item.books[1] end
    return item
end

-- The filepath that identifies this item for selection purposes, matching
-- bookshelf_shelf_row.lua's per-kind fp derivation (folder: first_book;
-- other groups: first member; book: itself).
local function itemFilepath(item)
    if item.kind == "folder" then
        return item.first_book and item.first_book.filepath
    end
    if item.kind == "opds_nav" then return item.filepath end
    if item.books and item.books[1] then return item.books[1].filepath end
    return item.filepath
end

-- Bulk-selection membership test, mirroring bookshelf_shelf_row.lua's real
-- per-kind checks rather than matching only a single representative
-- filepath. Matching only the first member (the earlier draft's bug) is
-- never a false positive, but it IS a false negative: selecting individual
-- books inside a folder, or a status-filtered "select all" that excludes
-- the first book, would show the group unselected here while ShelfRow
-- would show it selected -- the two view modes disagreeing about the same
-- selection.
--
-- folder: mirrors bookshelf_shelf_row.lua:456-481 -- `sel_active` gates the
--   walk (`if sel_active and folder_fpaths then` at :474), the walk itself
--   is `Repo.getFolderBookPaths(item.path)` (:467, cached by the repo), and
--   `folder_bulk = folder_k > 0` where folder_k counts `selection:contains`
--   hits over that path list (:475-479). Reproduced here as an early-exit
--   membership test rather than a full count, since a row only needs the
--   boolean, not "K/N".
-- other groups (`item.books`): mirrors `stack_sel_count`
--   (bookshelf_shelf_row.lua:300-310) exactly -- gated on
--   `selection:isActive()`, then a full sweep of `item.books[_i].filepath`
--   against `selection:contains`. `stack_sel_count` is the ONE helper every
--   non-folder group kind (author/genre/tag/language/series) calls
--   (:563-565 author, :585-587 genre, :608-610 tag, :629-631 language,
--   :652-654 series), so one unified branch here is a faithful merge of
--   five identical call sites, not a divergence from any of them.
-- plain book: mirrors `book_bulk` (bookshelf_shelf_row.lua:673-674)
--   EXACTLY, including its lack of an isActive() guard -- ShelfRow's own
--   plain-book check trusts `selection:contains` to read false when
--   selection is inactive/empty, unlike the folder/group paths, and this
--   preserves that same (already slightly inconsistent) behaviour rather
--   than "cleaning it up" into a new, untested semantic.
local function isBulkSelected(selection, item)
    if not selection then return false end
    if item.kind == "folder" then
        if not selection.isActive or not selection:isActive() then return false end
        if not item.path then return false end
        local paths = Repo.getFolderBookPaths(item.path)
        if not paths then return false end
        for _i = 1, #paths do
            if selection:contains(paths[_i]) then return true end
        end
        return false
    end
    if item.books then
        if not selection.isActive or not selection:isActive() then return false end
        for _i = 1, #item.books do
            local fp = item.books[_i].filepath
            if fp and selection:contains(fp) then return true end
        end
        return false
    end
    return item.filepath ~= nil and selection:contains(item.filepath) == true
end

-- ListRow.pageLayout{ width, height, gap, lines } -> layout table
--
-- The page-CONSTANT half of a row's geometry: the content box inside the
-- selection ring, the thumbnail size, and each line's face, colour and band.
-- Every input is identical for every row on a page, so the caller
-- (bookshelf_widget.lua's _buildListRows) solves it ONCE and hands the result
-- to each ListRow.new via opts.layout. Doing it per row instead meant a
-- BFont:getFace plus a TextWidget probe per line per row -- N times the work
-- for N identical answers, on a code path this plugin has already had to fix
-- for regrid cost more than once.
--
-- `opts.lines` is the LAYOUT table Lines.layout() returns
-- ({ show_cover, lines }) -- see that file's header for the shape and why the
-- cover is not one of the lines.
--
-- Kept here rather than in the widget because it is row geometry: the ring
-- reservation and the cover inset are this file's decisions, and a second copy
-- of them in the caller is exactly the drift the row/height split above warns
-- about. ListRow.new falls back to computing it itself when no layout is
-- passed, so a one-off row (a test, a future single-row surface) still works.
function ListRow.pageLayout(opts)
    local gap   = opts.gap or Size.padding.default
    local pad   = Size.padding.small
    local model = opts.lines or Lines.layout()

    -- Reserve the selection ring's footprint on every side, always -- not
    -- only when selected -- so toggling selection never resizes the row or
    -- shifts a single pixel of its content (the same "identical pixel
    -- position, only the perimeter changes" invariant SpineWidget's own
    -- selection ring keeps). A cover's shadow only needs an L-shaped margin
    -- because its ring can bleed sideways into the inter-cover gap; a list
    -- row has no such gap to its left/right (it spans the full content
    -- width), so all four sides are reserved here instead.
    --
    -- This band is also the row's ONLY vertical padding, which is what makes a
    -- text-tight row possible: ListGeom.rowHeight adds exactly 2*RING to the
    -- line height, so the reservation is not an extra cost on top of a padded
    -- row -- it IS the padding, and it happens to be able to hold a ring.
    local content_w = math.max(1, (opts.width or 0) - 2 * RING)
    local content_h = math.max(1, (opts.height or 0) - 2 * RING)

    -- The thumbnail fills the content box top to bottom: no inset, no chrome,
    -- and EVERY text line beside it. Sized from the ROW height so this and the
    -- two preload sites all take the ring off exactly once, inside ListGeom
    -- (see ListGeom.thumbSize). A taller multi-line row therefore gets a
    -- proportionally larger thumbnail, which is the point of spanning.
    local cover_w, cover_h = 0, 0
    if model.show_cover then
        cover_w, cover_h = ListGeom.thumbSize(opts.height or 0, RING)
    end

    local styles = ListRow.lineStyles(model.lines)

    -- The tick gutter: a checkbox at the head of every row, present ONLY while
    -- a bulk selection is running.
    --
    -- Cover mode marks a selected book with a corner flag painted over its
    -- artwork (bookshelf_spine_widget.lua's CornerFlag). A list row has no
    -- artwork to paint over -- with covers off it has no cover cell at all --
    -- and the request was for the equivalent, not the copy. A checkbox column
    -- is what a list uses, and it answers a question the flag cannot: which
    -- rows are NOT selected. The flag only ever appears on chosen covers, so
    -- "nothing marked" and "nothing selectable" look the same; an empty box on
    -- every other row says the selection is live and this one is not in it.
    --
    -- It also disambiguates the two states that previously drew the same ring.
    -- A row can be the FOCUSED row (the one the preview is showing) or a
    -- SELECTED row (in the bulk set), and both painted a border, so in a
    -- selection of one you could not tell which was which.
    --
    -- Sized off the first line's measured height so it tracks list_font_scale
    -- with the type it sits beside, rather than being a fixed square that
    -- swamps a dense row and gets lost in a loose one.
    --
    -- TICK_FILL of that height, not all of it: the line height a face reports
    -- includes its leading and descender, so a circle drawn at the full figure
    -- comes out noticeably larger than the capitals next to it -- the same trap
    -- the hero's %bar height rule documents. Three quarters lands the circle at
    -- about cap height.
    local tick_w, tick_h = 0, 0
    if opts.selection_active then
        local line_h = styles[1] and styles[1].height or content_h
        tick_h = math.max(Screen:scaleBySize(10),
                          math.floor(line_h * TICK_FILL + 0.5))
        tick_h = math.min(tick_h, content_h)
        tick_w = tick_h
    end

    -- What the text lines have to themselves. Taking the tick gutter, the cover
    -- cell and the gaps between them off HERE, once, is what keeps every line
    -- measuring against the same width without any of them knowing about the
    -- others. The trailing pad is the breathing room between the cover and the
    -- first character.
    local text_w = content_w
    if tick_w > 0  then text_w = math.max(1, text_w - tick_w - gap) end
    if cover_w > 0 then text_w = math.max(1, text_w - cover_w - gap) end
    text_w = math.max(1, text_w - pad)

    -- The vertical split.
    --
    -- ONE LINE: the band is the whole content box and the line keeps
    -- TextWidget's own padding, centred in it -- byte for byte the single-row
    -- model, which is what keeps a one-line configuration pixel-identical.
    --
    -- MORE THAN ONE: every box is TRIMMED of that padding (it is decoration,
    -- and between two stacked lines of one item it is paid twice -- see
    -- ListGeom.rowHeight) and the pixels are handed back as the item's own
    -- top/bottom padding, with ListGeom.INTRA_LEAD between each adjacent pair.
    -- So the white inside an item is small and the white between two items is
    -- the item padding at each end plus the ring and the rule -- which is what
    -- makes the lines read as one book with more said about it rather than as
    -- rows that happen to be adjacent.
    --
    -- The arithmetic is ListGeom's, not this file's, so the height the budget
    -- reserves and the bands the renderer draws are the same expression.
    local multiline = #styles > 1
    local boxes, band_top, band_lead, band_bottom = { content_h }, 0, 0, 0
    local line_pad = nil                     -- nil = TextWidget's own default
    if multiline then
        local heights = {}
        for i, s in ipairs(styles) do heights[i] = s.height end
        local bands = ListGeom.textBands{
            content_h    = content_h,
            line_heights = heights,
            text_pad     = ListRow.TEXT_PAD,
            lead         = ListRow.INTRA_LEAD,
        }
        boxes = bands.boxes
        band_top, band_lead, band_bottom = bands.top, bands.lead, bands.bottom
        line_pad = 0
    end

    -- Everything the renderer needs per line, resolved once for the page. The
    -- first line takes the row's own ink and every line under it the muted
    -- grey -- see SECONDARY_INK for why that is a rule and not a setting.
    local lines = {}
    for i, s in ipairs(styles) do
        local def = model.lines[i]
        lines[i] = {
            template  = def.template,
            face      = s.face,
            bold      = s.bold,
            uppercase = def.uppercase == true,
            alignment = def.alignment or "left",
            fgcolor   = (i == 1) and ListRow.ROW_FG or secondaryColor(),
            padding   = line_pad,
            band_h    = boxes[i] or content_h,
            -- >1 when the template carried {xN}; the renderer then uses a
            -- wrapping box instead of a single truncated line.
            wrap      = s.wrap or 1,
            -- Carried through for %bar, exactly as a hero region carries them.
            -- Absent on every line that has no bar, which costs nothing.
            bar_height = def.bar_height,
            bar_style  = def.bar_style,
        }
    end

    return {
        gap       = gap,
        pad       = pad,
        model     = model,
        content_w = content_w,
        content_h = content_h,
        cover_w   = cover_w,
        cover_h   = cover_h,
        tick_w    = tick_w,
        tick_h    = tick_h,
        text_w    = text_w,
        lines     = lines,
        band_top    = band_top,
        band_lead   = band_lead,
        band_bottom = band_bottom,
    }
end

-- ── The progress bar ───────────────────────────────────────────────────────
--
-- ListRow.bar(line, width) -> a paintable bar for this line's %bar.
--
-- The same backend the hero uses (lib/bookshelf_hero_bar.lua: bookends's
-- painter when it is installed, KOReader's ProgressWidget when it is not), the
-- same two colour settings, and the same height rule -- a percentage of the
-- face's NOMINAL point size rather than of its rendered line height, because
-- the rendered height includes leading and descender and a bar measured
-- against it comes out about twice as tall as the glyphs beside it.
--
-- A list line carries bar_height / bar_style exactly as a hero region does:
-- Lines.resolveLine copies every scalar on a stored line, so the fields survive
-- a round trip without the model naming them, and the shared line editor
-- surfaces them on the same button row.
local function resolvedBarColors(style)
    -- Pacman has a fixed identity baked into bookends's painter (yellow body,
    -- peach pellets) and ignores overrides, so the plumbing is skipped rather
    -- than passed and discarded.
    if style == "pacman" then return nil end
    local custom_fill  = BookshelfSettings.read("progress_fill")
    local custom_track = BookshelfSettings.read("progress_track")
    -- Only pass colours the user actually picked: each bookends style has its
    -- own defaults, and handing over this plugin's dark-grey-on-white would
    -- wash them out for everyone who never opened the colours menu.
    if not (custom_fill or custom_track) then return nil end
    local Color    = require("lib/bookshelf_color")
    local is_color = Screen:isColorEnabled()
    return {
        fill = custom_fill  and Color.parseColorValue(custom_fill,  is_color) or nil,
        bg   = custom_track and Color.parseColorValue(custom_track, is_color) or nil,
    }
end

function ListRow.bar(line, width, pct)
    local HeroBar   = require("lib/bookshelf_hero_bar")
    local face_size = (line.face and line.face.size) or 14
    local bar_h = math.max(2,
        math.floor(face_size * (line.bar_height or 100) / 100 + 0.5))
    -- Never taller than the band it sits in: a 200% bar on a dense row would
    -- paint over the lines above and below it.
    bar_h = math.min(bar_h, math.max(2, line.band_h or bar_h))
    local style = line.bar_style or "bordered"
    return HeroBar:new{
        width      = width,
        height     = bar_h,
        percentage = tonumber(pct) or 0,
        style      = style,
        colors     = resolvedBarColors(style),
    }
end

-- ── One line of expanded template ──────────────────────────────────────────
--
-- ListRow.textLine(record, line, width, pad) -> a widget exactly `width` wide.
--
-- The template is expanded against `record` -- a WRAPPED book or a projected
-- group, both from Lines.recordFor -- and then rendered as ONE line: a table
-- row that wrapped would break the uniform row height every other piece of
-- this model depends on, so an overlong line truncates with an ellipsis
-- instead.
--
-- No device state is passed to Tokens.expand. A row is not a status strip:
-- %batt and friends read `state`, and every one of them guards on it being
-- absent, so they answer empty here rather than costing a battery read per row.
-- The clock tokens still work -- they fall back to os.time().
--
-- `template` overrides the line's own, for the one caller that needs it: a
-- group row substitutes its own content while keeping the line's STYLE (see
-- lib/bookshelf_list_group.lua). Passing the override rather than copying the
-- line and patching it keeps the per-row allocation at zero.
function ListRow.textLine(record, line, width, pad, template)
    local inner_w = math.max(1, width - 2 * pad)
    -- {xN} is the layout's, not the renderer's: off before expansion, or the
    -- braces render as text beside the value they were modifying.
    local tpl  = ListRow.stripWrapModifier(template or line.template)
    local text = Tokens.expand(tpl, record, nil)
    -- The v0.1 inline format tags the hero also strips: they are a formatting
    -- vocabulary this surface does not implement, and left in they render as
    -- literal "[b]".
    text = text:gsub("%[/?[biu]%]", "")
    if line.uppercase then text = TextSegments.upper(text) end

    -- ── The wrapping path ──────────────────────────────────────────────────
    --
    -- A {xN} line is a paragraph, so it goes through TextBoxWidget with a
    -- height of exactly the band the budget reserved for it and an ellipsis on
    -- overflow -- the same "never taller than its band" contract every other
    -- line keeps, just with N lines inside it instead of one.
    --
    -- The elastic tokens are STRIPPED rather than honoured here: %spacer and
    -- %bar split a line into left and right halves, which is a single-line
    -- idea. Wrapping wins because it is the more specific request -- a reader
    -- who wrote {x4} wants the paragraph.
    if (line.wrap or 1) > 1 then
        local flat = stripElastic(text):gsub("%s+", " ")
        flat = flat:match("^%s*(.-)%s*$") or ""
        local box = TextBoxWidget:new{
            text      = flat,
            face      = line.face,
            bold      = line.bold,
            fgcolor   = line.fgcolor,
            -- Stated, not defaulted. TextBoxWidget FILLS its own background
            -- (textboxwidget.lua:50 defaults it to white) where TextWidget does
            -- not, so a wrapping line punches an opaque white rectangle through
            -- any row background that is not white. That is precisely what went
            -- wrong when selection was a tinted band -- "some text areas keep a
            -- white background when selected" -- and naming the row's own paper
            -- here means it cannot come back if a fill ever returns.
            bgcolor   = ListRow.ROW_BG,
            width     = inner_w,
            height    = line.band_h,
            height_overflow_show_ellipsis = true,
            alignment = line.alignment or "left",
        }
        return HorizontalGroup:new{
            align = "center",
            HorizontalSpan:new{ width = pad },
            box,
            HorizontalSpan:new{ width = pad },
        }
    end

    local function seg(s, max_w, trunc_left)
        return TextWidget:new{
            text          = s,
            face          = line.face,
            bold          = line.bold,
            fgcolor       = line.fgcolor,
            -- nil leaves TextWidget's own default in place, which is what the
            -- one-line row must have; 0 trims the decoration for a multi-line
            -- item (see ListGeom.textBands).
            padding       = line.padding,
            max_width     = max_w,
            truncate_left = trunc_left or false,
        }
    end

    local content
    local kind, e_start, e_stop, e_mod = findElastic(text)
    if not kind then
        content = seg(text, inner_w)
    else
        -- BOTH sides are stripped of any other elastic token, not just the
        -- trailing one. Now that %bar wins wherever it sits, a %spacer can be
        -- in front of it -- and "%authors%spacer%bar" rendered the literal
        -- word "%spacer" between the author and the bar, because only `after`
        -- was ever cleaned.
        local before = stripElastic(text:sub(1, e_start - 1))
        local after  = stripElastic(text:sub(e_stop + 1))
        -- Trim LINE-EDGE whitespace only. Whatever the user typed AT the token
        -- boundary is theirs and renders as part of its side's text.
        before = before:gsub("^%s+", "")
        after  = after:gsub("%s+$", "")
        local b_widget = before ~= "" and seg(before) or nil
        local a_widget = after  ~= "" and seg(after)  or nil
        local b_w = b_widget and b_widget:getSize().w or 0
        local a_w = a_widget and a_widget:getSize().w or 0
        -- Overflow: the two sides together are wider than the line. Truncate
        -- the RIGHT side first (keep the left text whole), and only if the
        -- left alone still does not fit is the left truncated and the right
        -- dropped. Same rule, and same reason, as the hero's (issue #170) --
        -- an un-truncated HorizontalGroup renders at its natural width and
        -- spills out of the row.
        --
        -- Two rules here the hero does not have, both learned from a
        -- three-column render where the right side had almost no room:
        --
        -- 1. The right side keeps its HEAD, not its tail. The hero truncates
        --    it from the left, on the reasoning that a right-anchored value
        --    should keep the end it is anchored by and put the ellipsis at the
        --    spacer (#170). That is correct anchoring and the wrong half of
        --    the text: the shipped second line is "N% of M pages", whose
        --    meaning is entirely at the front, and tail-truncation rendered it
        --    as "...ages" and "... pages" beside the author -- which says
        --    nothing and reads as a rendering bug. Head-first gives
        --    "0% of 63..." instead, which still answers the question.
        --
        --    It is a trade, not a strict improvement: a right-aligned date
        --    reads better by its tail. The numeric-prefix case is both far
        --    more common and far worse when it goes wrong.
        --
        -- 2. Below MIN_KEEP of its natural width the right side is DROPPED.
        --    Past that point even the head is a stub, and an empty right side
        --    is better than a fragment. Low, because head-truncation degrades
        --    gracefully -- this is the floor where it stops meaning anything
        --    at all, not the point where it starts being cramped.
        local MIN_KEEP = 0.3
        if (b_w + a_w) > inner_w then
            local trunc_gap = Size.padding.large
            local avail_a   = inner_w - b_w - trunc_gap
            if a_widget and avail_a >= math.floor(a_w * MIN_KEEP) and avail_a > 0 then
                a_widget:free()
                a_widget = seg(after, math.max(1, avail_a))
                a_w = a_widget:getSize().w
            elseif a_widget and b_w <= inner_w then
                -- No room worth giving it: drop the right side and let the
                -- left have the whole line.
                a_widget:free()
                a_widget, a_w = nil, 0
            else
                if a_widget then a_widget:free() end
                a_widget, a_w = nil, 0
                if b_widget then
                    b_widget:free()
                    b_widget = seg(before, inner_w)
                    b_w = b_widget:getSize().w
                end
            end
        end
        -- A bar has a visible body, so it needs breathing room from adjacent
        -- text -- but only where the user did not already type a space at that
        -- boundary, or the gap is paid twice. Same rule as the hero's.
        -- %spacer needs none: the span IS the gap.
        local pre_gap, post_gap = 0, 0
        if kind == "bar" then
            if b_widget and not before:match("%s$") then pre_gap  = Size.padding.small end
            if a_widget and not after:match("^%s")  then post_gap = Size.padding.small end
        end
        local elastic_w = math.max(0, inner_w - b_w - a_w - pre_gap - post_gap)

        local hg = HorizontalGroup:new{ align = "center" }
        if b_widget then
            hg[#hg + 1] = b_widget
            if pre_gap > 0 then hg[#hg + 1] = HorizontalSpan:new{ width = pre_gap } end
        end
        if kind == "bar" and elastic_w >= 2 then
            -- {rel} shortens the bar in proportion to the book's length; the
            -- pixels it gives up become a plain gap AFTER it, so every bar on
            -- the page starts at the same x and their lengths are what you are
            -- comparing. Handing the slack to the left instead would right-align
            -- the bars and defeat the point.
            local bar_w = elastic_w
            if e_mod == "rel" then
                bar_w = math.max(2, math.floor(elastic_w
                    * ListGeom.relativeBarFraction(record and record.page_count)))
            end
            hg[#hg + 1] = ListRow.bar(line, bar_w, record and record.book_pct)
            if bar_w < elastic_w then
                hg[#hg + 1] = HorizontalSpan:new{ width = elastic_w - bar_w }
            end
        else
            -- Either a %spacer, or a %bar with nowhere to draw itself; both are
            -- the remaining width as empty space. A bar squeezed to nothing
            -- degrades to the gap rather than to a smear, which is what the
            -- hero does too.
            hg[#hg + 1] = HorizontalSpan:new{ width = elastic_w }
        end
        if a_widget then
            if post_gap > 0 then hg[#hg + 1] = HorizontalSpan:new{ width = post_gap } end
            hg[#hg + 1] = a_widget
        end
        content = hg
    end

    -- The alignment container is what makes `alignment` mean anything: a
    -- TextWidget sits at its own natural width and would otherwise always look
    -- left-aligned. All three of these centre VERTICALLY inside band_h, which
    -- is what puts the line in the middle of its band.
    --
    -- A line carrying a %spacer is already exactly inner_w wide, so its
    -- alignment is a no-op -- which is correct: the spacer decided where each
    -- half sits.
    local box = Geom:new{ w = inner_w, h = line.band_h }
    local aligned
    if line.alignment == "right" then
        aligned = RightContainer:new{ dimen = box, content }
    elseif line.alignment == "center" then
        aligned = CenterContainer:new{ dimen = box, content }
    else
        aligned = LeftContainer:new{ dimen = box, content }
    end
    -- pad either side, so the text does not touch the cover or the row edge
    -- and the group measures exactly `width` -- the row's white background is
    -- this group's size, so a short line would leave the page showing through.
    return HorizontalGroup:new{
        align = "center",
        HorizontalSpan:new{ width = pad },
        aligned,
        HorizontalSpan:new{ width = pad },
    }
end

-- ListRow.new(opts) -> widget with .dimen, .cover_w, .cover_h
--
-- opts: {
--   width, height        number   row footprint in pixels
--   item                 table|nil  a Book, SeriesGroup or folder/nav/group
--                                   record; nil renders a blank spacer (the
--                                   trailing padding row on a partial last
--                                   page, matching ShelfRow's empty-slot
--                                   treatment)
--   lines                table    the line layout (Lines.layout()):
--                                 { show_cover, lines }
--   gap                  number   (optional) pixel gap between cover and text
--   layout               table|nil  (optional) the page-constant geometry from
--                                   ListRow.pageLayout; computed here when
--                                   absent, at the cost of re-resolving and
--                                   re-measuring every line's face per row
--   selected_filepath    string|nil  filepath that should render selected
--   selection            table|nil  bulk-selection set (:contains/:isActive)
--   on_book_tap, on_book_open, on_book_hold,
--   on_series_tap, on_series_hold, on_author_tap, on_author_hold,
--   on_genre_tap, on_genre_hold, on_tag_tap, on_tag_hold,
--   on_language_tap, on_language_hold, on_folder_tap, on_folder_hold,
--   on_opds_nav_tap                 -- identical keys to ShelfRow.new's opts
-- }
function ListRow.new(opts)
    local width = opts.width
    local row_h = opts.height
    local item  = opts.item

    if not item then
        -- Blank spacer, matching bookshelf_shelf_row.lua's empty-slot
        -- treatment (a bare Widget with a sized dimen) rather than a row of
        -- placeholder dashes.
        local blank = Widget:new{ dimen = Geom:new{ w = width, h = row_h } }
        blank.cover_w, blank.cover_h = 0, 0
        return blank
    end

    -- Page-constant geometry, solved once by the caller for the whole page
    -- (see ListRow.pageLayout) and reused by every row on it.
    local L = opts.layout or ListRow.pageLayout(opts)
    local gap, pad         = L.gap, L.pad
    local content_w        = L.content_w
    local content_h        = L.content_h
    local cover_w, cover_h = L.cover_w, L.cover_h

    -- The one thing that IS per row: what the templates are expanded against.
    -- A book gets the lazy adapter, which resolves progress, page count, size
    -- and the two dates on demand -- and not at all for a template that names
    -- none of them. A group gets a projection onto the same field names, since
    -- the token vocabulary is written for books and a folder is not one.
    -- Built ONCE for the row: every line shares it, so a two-line template
    -- naming %book_pct twice still costs one sidecar read.
    local record = Lines.recordFor(item)

    -- A folder or a stack does not render as a book: chevron instead of a
    -- cover, its own name and member count instead of the user's templates.
    -- nil for a plain book, which is the common case and pays nothing.
    -- See lib/bookshelf_list_group.lua for why this is hardcoded and why it
    -- borrows the user's line STYLES rather than setting its own.
    local group_templates
    if Lines.isGroup(item) then
        group_templates = ListGroup.templates(item, opts.selection, #L.lines)
    end

    -- Held so onTap/onDoubleTap can set SpineWidget.last_tapped on it (see
    -- below); stays nil when covers are switched off, and for a group row,
    -- whose cover cell is a chevron with no cover to squeeze into.
    local spine_widget

    -- cover | text lines stacked. The cover cell is content_h tall -- the whole
    -- row -- so it spans every text line rather than belonging to any of them,
    -- and the text column beside it is the same height whatever the line count
    -- is. With one line the VerticalGroup wraps a single band of exactly
    -- content_h and measures the same as the bare HorizontalGroup the column
    -- model built, which is what keeps a one-line row pixel-identical.
    --
    -- With more the column is padding, line, leading, line, ... padding -- and
    -- those add to content_h by construction (ListGeom.textBands solves the two
    -- paddings as what is left), so the cover still spans exactly the text
    -- beside it and the row is still one height.
    -- Selection / focus state: the same test ShelfRow applies per item kind
    -- (bookshelf_spine_widget.lua:649-661, :810). TWO booleans and two separate
    -- marks, because they answer different questions -- the checkbox says "in
    -- the bulk set", the tramline says "this is the row the preview is
    -- showing". They were one flag drawing one ring, which meant a selection of
    -- one was indistinguishable from the focused row.
    local fp        = itemFilepath(item)
    local bulk      = isBulkSelected(opts.selection, item)
    local focused   = opts.selected_filepath ~= nil and fp ~= nil
                      and fp == opts.selected_filepath

    local group = HorizontalGroup:new{ align = "center" }
    if L.tick_w > 0 then
        group[#group + 1] = ListRow.tickCell(L.tick_w, L.tick_h, bulk)
        group[#group + 1] = HorizontalSpan:new{ width = gap }
    end
    if cover_w > 0 and group_templates then
        group[#group + 1] = ListGroup.chevron(cover_w, content_h)
        group[#group + 1] = HorizontalSpan:new{ width = gap }
    elseif cover_w > 0 then
        spine_widget = SpineWidget:new{
            book   = coverBookFor(item),
            width  = cover_w,
            height = cover_h,
            -- No title/author on the no-cover placeholder: at thumbnail
            -- size that text would be an unreadable duplicate of the
            -- title column two pixels to its right. The grid keeps its
            -- lettered placeholder; only this caller opts out.
            bare_placeholder = true,
            -- Square corners, no drop shadow, and no shadow reservation
            -- eating the row's height. A table cell is not a card: the
            -- radius and the shadow are what make a grid tile read as an
            -- object lying on the page, and at 30x45 they would be most of
            -- what you can see. Declared here rather than inferred from the
            -- size in SpineWidget -- the grid and the hero want their
            -- chrome at every size they render at.
            flat_thumb = true,
        }
        group[#group + 1] = CenterContainer:new{
            dimen = Geom:new{ w = cover_w, h = content_h },
            spine_widget,
        }
        group[#group + 1] = HorizontalSpan:new{ width = gap }
    end
    -- A little breathing room where the tramline used to be, so the text does
    -- not start hard against the cover.
    group[#group + 1] = HorizontalSpan:new{ width = pad }

    local text_col = VerticalGroup:new{ align = "left" }
    -- The item's own top padding. Zero for a one-line item, whose single band
    -- IS the content box -- a one-line row is untouched by any of this.
    if L.band_top > 0 then
        text_col[#text_col + 1] = VerticalSpan:new{ width = L.band_top }
    end
    for i, line in ipairs(L.lines) do
        if i > 1 and L.band_lead > 0 then
            text_col[#text_col + 1] = VerticalSpan:new{ width = L.band_lead }
        end
        -- The line tables are used AS THEY COME, no per-row copy: a tinted band
        -- keeps the row's own ink, so nothing about a focused row's text
        -- differs. (An inverted row was the other candidate and would have
        -- needed a recoloured copy of every line, since pageLayout hands the
        -- same tables to every row on the page.)
        text_col[#text_col + 1] = ListRow.textLine(
            record, line, L.text_w, pad,
            group_templates and group_templates[i])
    end
    if L.band_bottom > 0 then
        text_col[#text_col + 1] = VerticalSpan:new{ width = L.band_bottom }
    end
    group[#group + 1] = text_col

    -- ── SELECTION: a rounded box round the row ─────────────────────────────
    --
    -- Fourth design. The square ring was cramped against the text; the tramline
    -- was too small a mark to find; the tinted band was rejected on screen --
    -- and had a bug the border does not: TextBoxWidget FILLS its own background
    -- (default white, textboxwidget.lua:50), so a {xN} wrapping line punched a
    -- white hole in the tint. A border touches no pixel the text owns.
    --
    -- Rounded to the COVER CARD's radius, not a radius of its own: "the same
    -- style/thickness we use for cover images". Two roundings on one screen
    -- read as two design languages.
    --
    -- The border is present in EVERY state and only changes colour -- drawn in
    -- the row's own paper when unselected, so it occupies the same pixels and
    -- is simply invisible. Toggling `bordersize` instead would resize the
    -- FrameContainer (its getSize includes the border) and shift every row on
    -- selection.
    --
    -- The opaque background is load-bearing even UNSELECTED: a row draws its
    -- own paper so a %spacer's elastic gap shows page white rather than
    -- whatever is behind it.
    local content = FrameContainer:new{
        bordersize = BORDER,
        radius     = RADIUS,
        color      = focused and ListRow.ROW_FG or ListRow.ROW_BG,
        background = ListRow.ROW_BG,
        margin     = OUTER,
        padding    = INNER,
        group,
    }
    -- No ring. Selection is the tint (focus) and the checkbox (bulk); a
    -- rectangle round the row as well was too much ink for a soft state,
    -- competed with the hairline rules, and read as a box round the PAIR on a
    -- two-column layout. RING survives as the row's vertical padding --
    -- see ListGeom.ROW_RING_DP, where that reservation is what lets the row be
    -- packed to the height of its own text.
    local card = content
    -- Centring a (content_w, content_h) card inside the full (width, row_h)
    -- box leaves exactly RING on every side.
    local positioned = CenterContainer:new{
        dimen = Geom:new{ w = width, h = row_h },
        card,
    }

    local tap_cb, hold_cb = handlersFor(item, opts)
    local row_dimen = Geom:new{ w = width, h = row_h }
    local row = InputContainer:new{
        dimen = row_dimen,
        positioned,
    }
    row.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = row_dimen } },
        Hold = { GestureRange:new{ ges = "hold", range = row_dimen } },
        DoubleTap = { GestureRange:new{ ges = "double_tap", range = row_dimen } },
    }

    -- Menu-zone fall-through: same guard SpineWidget's own onTap/onDoubleTap
    -- apply, so a list row near the very top of the screen doesn't swallow a
    -- tap meant for KOReader's top menu.
    local function in_menu_zone(ges)
        return ges and ges.pos and ges.pos.y < Screen:scaleBySize(60)
    end

    function row:onTap(_, ges)
        if in_menu_zone(ges) then return false end
        -- Record the rendezvous for the opening-book squeeze effect, exactly
        -- as bookshelf_shelf_row.lua's expanded-mode slot:onTap does
        -- (:771) for its own inert SpineWidget: on_tap=nil means
        -- SpineWidget's own onTap -- which would otherwise set this itself
        -- -- never runs (bookshelf_spine_widget.lua:2084-2096 returns false
        -- before reaching that line when self.on_tap is nil). nil when the
        -- cover column isn't active, so a stale flag from the grid can't
        -- survive into list mode and target a rect that no longer belongs
        -- to a cover (bookshelf_widget.lua:5084-5093's fp validation would
        -- otherwise still match and squeeze the wrong pixels).
        SpineWidget.last_tapped = spine_widget
        if not tap_cb then return false end
        if tap_cb == opts.on_book_tap then
            -- Stamped the same way ShelfRow's on_book_tap_stamped does:
            -- _previewBook reads the second arg to compute tap-to-handler
            -- latency for [bookshelf perf] logging.
            local _t = _gettime()
            logger.dbg(string.format(
                "[bookshelf perf] list row onTap fired t=%.3f fp=%s",
                _t, tostring(item.filepath or "?")))
            tap_cb(item, _t)
        else
            tap_cb(item)
        end
        return true
    end

    function row:onHold()
        if hold_cb then
            hold_cb(item)
            return true
        end
        -- opds_nav has no per-item hold action, but ShelfRow's own wiring
        -- still swallows the gesture there (a no-op long-press) rather than
        -- letting it fall through for a remote entry with nothing on disk
        -- to act on.
        if item.kind == "opds_nav" then return true end
        return false
    end

    function row:onDoubleTap(_, ges)
        if in_menu_zone(ges) then return false end
        -- Same rendezvous as onTap, and for the same reason.
        SpineWidget.last_tapped = spine_widget
        -- Double tap opens a book directly, matching #271's behaviour on
        -- covers. Groups have no "open", so they fall through to their tap
        -- handler instead -- gated on the SAME dispatch test onTap uses
        -- (tap_cb == opts.on_book_tap), not a bare item.filepath check: an
        -- opds_nav record can legitimately carry a .filepath too (see
        -- itemFilepath and bookshelf_shelf_row.lua's nav_cur), and a bare
        -- check would wrongly hand a nav record to on_book_open. The
        -- explicit `opts.on_book_tap ~= nil` guard matters when a caller
        -- omits both on_book_tap and on_opds_nav_tap: without it,
        -- `tap_cb == opts.on_book_tap` is `nil == nil` (true), which would
        -- misfire the same way a bare item.filepath check would.
        if opts.on_book_tap ~= nil and tap_cb == opts.on_book_tap
                and item.filepath and opts.on_book_open then
            opts.on_book_open(item)
            return true
        end
        if tap_cb then
            tap_cb(item)
            return true
        end
        return false
    end

    row.cover_w = cover_w
    row.cover_h = cover_h
    return row
end

return ListRow
