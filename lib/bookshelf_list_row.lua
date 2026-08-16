-- bookshelf_list_row.lua
-- One list-view row: an item rendered across the active columns.
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
local OverlapGroup    = require("ui/widget/overlapgroup")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local LineWidget      = require("ui/widget/linewidget")
local RightContainer  = require("ui/widget/container/rightcontainer")
local TextWidget      = require("ui/widget/textwidget")
local Widget          = require("ui/widget/widget")
local GestureRange    = require("ui/gesturerange")
local Geom            = require("ui/geometry")
local Size            = require("ui/size")
local Blitbuffer      = require("ffi/blitbuffer")
local Screen          = require("device").screen
local logger          = require("logger")
local BFont           = require("lib/bookshelf_fonts")
local SpineWidget     = require("lib/bookshelf_spine_widget")
local Columns         = require("lib/bookshelf_list_columns")
local ListGeom        = require("lib/bookshelf_list_geom")
local Repo            = require("lib/bookshelf_book_repository")
local _gettime        = require("lib/bookshelf_gettime")

local ListRow = {}

-- Rendered for a column with no value for this item. A dash rather than
-- blank -- blank reads as "the renderer failed", a dash reads as "there is
-- nothing here", which is the truth for e.g. a series' page count.
local EMPTY_CELL = "\xE2\x80\x93"   -- en dash

-- The row's text face, EXPORTED rather than kept private: the widget's
-- row-height budget (BookshelfWidget:_listRowHeight) has to measure the same
-- face at the same size this row renders with, or the height reserved for a
-- row and the text that row has to hold drift apart -- clipped descenders if
-- the budget is short, dead space in every row if it is long. One declaration,
-- two readers.
ListRow.FONT_FACE = "cfont"
ListRow.FONT_SIZE = 16

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

-- How far the inter-row rule travels from paper towards ink. "Extra light
-- grey": far enough to read as a rule on a 1248px-wide page, nowhere near far
-- enough to read as a border.
--
-- Re-measure this if ROW_BG ever stops being paper-white. With the endpoints
-- as they stand the interpolation below is numerically identical to
-- Blitbuffer.gray(0.13), and someone will eventually notice that and "simplify"
-- it. The coincidence is the point of the exercise, not a redundancy: the
-- value is safe because the two endpoints are ATTACHED -- ROW_BG is the row
-- FrameContainer's real `background` and ROW_FG a real `fgcolor` on every text
-- cell, so what this function reads is what the surface paints. Move either
-- endpoint and gray(0.13) stops being the answer while the arithmetic below
-- keeps giving the right one.
local DIVIDER_INK = 0.13

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
--     ink 0 in both modes, so the rule paints 222 in both: displayed that is
--     222-on-255 in day (a light rule on white) and 33-on-0 in night (a faint
--     rule on black). Same relationship to the page either way, which is what
--     "extra light grey" has to mean on a surface that inverts.
--
-- CoverProgress.resolvedColors().border is the obvious "resolved dark
-- endpoint" and was measured before being rejected: it paints 0 in day but
-- #FAFAFA = 250 in night, five levels off the paper it would sit on, so any
-- weighting toward paper puts the night rule at 254 -- invisible. shadowGray()
-- is closer (128 day / 217 night) but still asymmetric enough that one weight
-- cannot serve both. Painted bytes, not palette intuition; grey names that
-- sound different land ~8 levels apart and vanish on e-ink.
local function dividerColor()
    local paper = ListRow.ROW_BG:getColor8().a
    local ink   = ListRow.ROW_FG:getColor8().a
    return Blitbuffer.Color8(math.floor(paper + (ink - paper) * DIVIDER_INK + 0.5))
end
ListRow.dividerColor = dividerColor

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
local ROW_GAP = Screen:scaleBySize(ListGeom.ROW_GAP_DP)
local RING    = Screen:scaleBySize(ListGeom.ROW_RING_DP)
ListRow.RING  = RING

-- ListRow.divider(width) -> the hairline rule between two rows, exactly
-- ROW_GAP tall so the rule IS the gap (bookshelf_library_modal.lua:1028,
-- bookshelf_color_palette.lua:382, bookshelf_collection_manager.lua:964 all
-- paint the plugin's hairline at the same height).
--
-- A fresh widget per call: sharing one LineWidget across paint positions
-- corrupts KOReader's geometry calculations, the same trap the library modal's
-- own divider() helper documents.
function ListRow.divider(width)
    return LineWidget:new{
        background = dividerColor(),
        dimen      = Geom:new{ w = width, h = ROW_GAP },
    }
end

-- The selection ring is drawn with the shelf's OWN BorderOverlay
-- (bookshelf_spine_widget.lua exports it precisely so other surfaces can draw
-- the identical mark -- the cover-picker grid does the same in
-- bookshelf_cover_grid_cell.lua), but at the ROW's thickness, not the grid
-- cover's SELECTED_BORDER. See ListGeom.ROW_RING_DP for why: on a table row
-- packed to the height of its own text, the grid's 7px band would be a third
-- of the row.
local BorderOverlay = SpineWidget.BorderOverlay

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

-- ListRow.pageLayout{ width, height, gap, columns } -> layout table
--
-- The page-CONSTANT half of a row's geometry: the content box inside the
-- selection ring, the thumbnail size, the solved column widths and the text
-- face. Every input is identical for every row on a page, so the caller
-- (bookshelf_widget.lua's _buildListRows) solves it ONCE and hands the result
-- to each ListRow.new via opts.layout. Doing it per row instead meant a
-- BFont:getFace plus a TextWidget probe per FIXED column per row -- N times
-- the work for N identical answers, on a code path this plugin has already had
-- to fix for regrid cost more than once.
--
-- Kept here rather than in the widget because it is row geometry: the ring
-- reservation and the cover inset are this file's decisions, and a second copy
-- of them in the caller is exactly the drift the row/height split above warns
-- about. ListRow.new falls back to computing it itself when no layout is
-- passed, so a one-off row (a test, a future single-row surface) still works.
function ListRow.pageLayout(opts)
    local gap     = opts.gap or Size.padding.default
    local pad     = Size.padding.small
    local columns = opts.columns or Columns.active()

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

    -- The thumbnail fills the content box top to bottom: no inset, no chrome.
    -- Sized from the ROW height so this and the two preload sites all take the
    -- ring off exactly once, inside ListGeom (see ListGeom.thumbSize).
    local cover_w, cover_h = 0, 0
    if ListGeom.hasCover(columns) then
        cover_w, cover_h = ListGeom.thumbSize(opts.height or 0, RING)
    end

    local face, bold = BFont:getFace(ListRow.FONT_FACE, ListRow.FONT_SIZE)
    local function measure(s)
        local probe = TextWidget:new{ text = s, face = face, bold = bold }
        local w = probe:getSize().w
        probe:free()
        return w
    end

    return {
        gap       = gap,
        pad       = pad,
        columns   = columns,
        content_w = content_w,
        content_h = content_h,
        cover_w   = cover_w,
        cover_h   = cover_h,
        face      = face,
        bold      = bold,
        widths    = Columns.solveWidths(columns, content_w, gap, measure, cover_w),
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
--   columns              table    active column set (Columns.active())
--   gap                  number   (optional) pixel gap between columns
--   layout               table|nil  (optional) the page-constant geometry from
--                                   ListRow.pageLayout; computed here when
--                                   absent, at the cost of re-solving the
--                                   column widths for every row on the page
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
    local columns          = L.columns
    local content_w        = L.content_w
    local content_h        = L.content_h
    local cover_w, cover_h = L.cover_w, L.cover_h
    local face, bold       = L.face, L.bold
    local widths           = L.widths

    -- Held so onTap/onDoubleTap can set SpineWidget.last_tapped on it (see
    -- below); stays nil when the cover column isn't active.
    local spine_widget

    local group = HorizontalGroup:new{ align = "center" }
    for i, col in ipairs(columns) do
        local w = widths[i] or 0
        if i > 1 then
            group[#group + 1] = HorizontalSpan:new{ width = gap }
        end
        if col.kind == "cover" then
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
                dimen = Geom:new{ w = w, h = content_h },
                spine_widget,
            }
        else
            local text = Columns.resolve(item, col) or EMPTY_CELL
            -- max_width MUST be positive: TextWidget divides by it. The
            -- solver guarantees non-negative widths whenever the available
            -- width can afford it, but a cramped row (or the ring
            -- reservation biting into an already-tight budget) can still
            -- yield zero, so floor at the point of use.
            local budget = w - pad * 2
            if budget < 1 then budget = 1 end
            local tw = TextWidget:new{
                text      = text,
                face      = face,
                bold      = bold,
                fgcolor   = ListRow.ROW_FG,
                max_width = budget,
            }
            local cell
            if col.align == "right" then
                -- RightContainer's own dimen (not the child's) is what the
                -- enclosing HorizontalGroup measures, so the column still
                -- contributes exactly `w` regardless of the text's natural
                -- width -- the trailing `gap` before the next column already
                -- gives right-aligned text its breathing room.
                cell = RightContainer:new{
                    dimen = Geom:new{ w = w, h = content_h },
                    tw,
                }
            else
                -- Left-aligned with a leading pad, vertically centred: the
                -- inner group's own width is engineered to equal `w` exactly
                -- (pad + text + a filler span soaking up the remainder), so
                -- CenterContainer's horizontal centring is a no-op and only
                -- its vertical centring actually does anything.
                cell = CenterContainer:new{
                    dimen = Geom:new{ w = w, h = content_h },
                    HorizontalGroup:new{
                        align = "center",
                        HorizontalSpan:new{ width = pad },
                        tw,
                        HorizontalSpan:new{ width = math.max(0, w - pad - tw:getSize().w) },
                    },
                }
            end
            group[#group + 1] = cell
        end
    end

    -- Selection / focus state: the same test ShelfRow applies per item kind
    -- (bookshelf_spine_widget.lua:649-661, :810), collapsed to one flag here
    -- since the whole row (not a per-cover corner flag) carries the cue.
    local fp       = itemFilepath(item)
    local selected = isBulkSelected(opts.selection, item)
        or (opts.selected_filepath ~= nil and fp ~= nil and fp == opts.selected_filepath)

    -- Opaque white fill behind the columns: needed even when unselected (a
    -- flat row on the page background), and load-bearing when selected --
    -- without it the BorderOverlay's black rect painted behind would show
    -- through the HorizontalSpan gaps *between* columns, not just around
    -- the row's own perimeter.
    local content = FrameContainer:new{
        bordersize = 0, margin = 0, padding = 0,
        background = ListRow.ROW_BG,
        group,
    }
    local card = content
    if selected then
        card = OverlapGroup:new{
            dimen = Geom:new{ w = content_w, h = content_h },
            BorderOverlay:new{
                width = content_w, height = content_h, thickness = RING,
            },
            content,
        }
    end
    -- Centring a (content_w, content_h) card inside the full (width, row_h)
    -- box leaves exactly RING on every side -- precisely where the ring's
    -- overhang paints when selected, and an inert margin when not.
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
