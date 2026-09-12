-- bookshelf_spine_layout.lua
-- Pure geometry for the "spines" shelf style: books stood on a shelf edge-on,
-- like a real bookcase. No widgets, no Screen, no i18n -- everything here is
-- a function of plain numbers so the whole layout is testable headless.
--
-- NOT to be confused with lib/bookshelf_spine_widget.lua, which despite its
-- name is the COVER TILE (one book's front cover on the cover-grid shelf).
-- That name predates this view. This module is the spine view's maths.
--
-- ── THE MODEL ───────────────────────────────────────────────────────────────
--
--   width   <- page count. A thick book is a wide spine. Unknown page count
--              gets a typical-paperback default rather than a degenerate
--              sliver, because most libraries have SOME books the scanner
--              never opened.
--   height  <- the cover's true aspect ratio (h/w). A tall cover is a tall
--              book. All spines stand on the shelf baseline; tops vary,
--              exactly like a real shelf.
--   face-out<- a favourite can face outwards (front cover shown, bookstore
--              style). Its slot width is then the cover width at spine
--              height, not the page-count width.
--
-- Pagination is greedy fill: pack spines left to right until the shelf row
-- is full, then start the next row; a page is n_rows rows. Pages therefore
-- hold a VARIABLE number of books -- the footer must say "10-13 of 324",
-- not "page 3 of 27 x 12".

local SpineLayout = {}

-- Width mapping, in unscaled dp (callers put these through Screen:scaleBySize
-- so the physical proportions survive DPI changes).
SpineLayout.DEFAULT_PAGES = 300  -- assumed when the page count is unknown
SpineLayout.MIN_PAGES     = 60   -- everything thinner renders at MIN_W_DP
SpineLayout.MAX_PAGES     = 1200 -- everything thicker renders at MAX_W_DP
-- 14..52 rather than the first cut's 11..46: on the device the whole shelf
-- read "a bit thin" (user), and the default-pages book in particular. The
-- per-chip thickness setting scales from here.
SpineLayout.MIN_W_DP      = 14
SpineLayout.MAX_W_DP      = 52

-- Height mapping. Real covers cluster in aspect (h/w) 1.3..1.7; the tallest
-- common shape (1.8) nearly fills the row and everything shorter scales
-- linearly from there, floored so a square children's book is still a
-- book and not a pamphlet.
SpineLayout.REF_ASPECT      = 1.8   -- this aspect fills TOP_FRAC of the row
SpineLayout.DEFAULT_ASPECT  = 1.5   -- assumed when cover dimensions unknown
SpineLayout.TOP_FRAC        = 0.98
SpineLayout.MIN_FRAC        = 0.62

-- Auto thickness: a spine's width scales with the shelf's height, so one
-- tall row doesn't stand needle-thin books. User calibration on device:
-- at REF_ROW_DP (the two-row shelf under a standard hero) the base widths
-- read right (scale 1.0), and one row -- roughly double the height --
-- wants about 1.5x. A power curve fits both: (h/REF)^0.6, since
-- 2^0.6 = 1.52. Clamped so degenerate shelves stay recognisable.
SpineLayout.THICKNESS_REF_ROW_DP = 240
SpineLayout.THICKNESS_EXP        = 0.6
SpineLayout.THICKNESS_MIN        = 0.7
SpineLayout.THICKNESS_MAX        = 2.2

-- autoThickness(row_h_dp) -> multiplier for spineWidthDp's answer.
function SpineLayout.autoThickness(row_h_dp)
    row_h_dp = tonumber(row_h_dp)
    if not row_h_dp or row_h_dp <= 0 then return 1 end
    local scale = (row_h_dp / SpineLayout.THICKNESS_REF_ROW_DP)
                  ^ SpineLayout.THICKNESS_EXP
    if scale < SpineLayout.THICKNESS_MIN then scale = SpineLayout.THICKNESS_MIN end
    if scale > SpineLayout.THICKNESS_MAX then scale = SpineLayout.THICKNESS_MAX end
    return scale
end

-- spineWidthDp(pages) -> dp
-- Linear in page count between the clamps. nil/invalid -> DEFAULT_PAGES.
function SpineLayout.spineWidthDp(pages)
    pages = tonumber(pages)
    if not pages or pages <= 0 then pages = SpineLayout.DEFAULT_PAGES end
    if pages < SpineLayout.MIN_PAGES then pages = SpineLayout.MIN_PAGES end
    if pages > SpineLayout.MAX_PAGES then pages = SpineLayout.MAX_PAGES end
    local t = (pages - SpineLayout.MIN_PAGES)
            / (SpineLayout.MAX_PAGES - SpineLayout.MIN_PAGES)
    return SpineLayout.MIN_W_DP
         + t * (SpineLayout.MAX_W_DP - SpineLayout.MIN_W_DP)
end

-- spineHeight(row_h, aspect) -> px
-- aspect is the cover's h/w. Result is always >= 1 and <= row_h.
function SpineLayout.spineHeight(row_h, aspect)
    aspect = tonumber(aspect)
    if not aspect or aspect <= 0 then aspect = SpineLayout.DEFAULT_ASPECT end
    local frac = SpineLayout.TOP_FRAC * (aspect / SpineLayout.REF_ASPECT)
    if frac > SpineLayout.TOP_FRAC then frac = SpineLayout.TOP_FRAC end
    if frac < SpineLayout.MIN_FRAC then frac = SpineLayout.MIN_FRAC end
    local h = math.floor(row_h * frac + 0.5)
    if h < 1 then h = 1 end
    if h > row_h then h = row_h end
    return h
end

-- The camera: sin(12 deg). A horizontal depth d into the shelf projects to
-- d * VIEW_SIN of screen height. Lives here, with the rest of the geometry,
-- so both the painter and the planner read one number (SpineShelf.VIEW_SIN
-- aliases it).
SpineLayout.VIEW_SIN = 0.208
-- The visible top edge is capped at a fifth of the book, so an extreme aspect
-- cannot turn a book into mostly lid.
SpineLayout.TOP_EDGE_MAX_FRAC = 0.2

-- topEdgeHeight(book_h, aspect, min_px) -> px
--
-- The page-block sliver you see above a SPINE-OUT book: its depth into the
-- shelf is the COVER WIDTH (book_h / aspect), foreshortened by the camera's
-- pitch. The painter carves this out of the book's allotted height, so a
-- spine-out book's visible FRONT FACE is book_h minus this.
--
-- Exposed, and the face-out planner subtracts the SAME value, because the two
-- have to agree: a face-out and a spine-out of the same book are the same
-- physical object, so their front faces must be identical on screen. They
-- were not -- the face-out subtracted its own (much smaller) thickness
-- instead, which left its cover taller than the neighbouring spine by very
-- nearly that spine's whole top edge. Device report: "the face out cover is
-- as tall as the spine plus its pages top box".
--
-- What legitimately differs is the top box ABOVE the front face: a spine-out
-- shows its cover width up there, a face-out only its thickness. So a
-- face-out's total silhouette is genuinely SHORTER, and the space it leaves
-- at the top of the row is correct rather than a gap to fill.
function SpineLayout.topEdgeHeight(book_h, aspect, min_px)
    book_h = tonumber(book_h) or 0
    if book_h <= 0 then return 0 end
    aspect = tonumber(aspect)
    if not aspect or aspect <= 0 then aspect = SpineLayout.DEFAULT_ASPECT end
    local edge = math.floor((book_h / aspect) * SpineLayout.VIEW_SIN)
    local e_max = math.floor(book_h * SpineLayout.TOP_EDGE_MAX_FRAC)
    min_px = tonumber(min_px) or 0
    if edge < min_px then edge = min_px end
    if edge > e_max then edge = e_max end
    if edge < 0 then edge = 0 end
    return edge
end

-- faceOutWidth(spine_h, aspect) -> px
-- The cover width when a favourite faces outwards at its spine height.
function SpineLayout.faceOutWidth(spine_h, aspect)
    aspect = tonumber(aspect)
    if not aspect or aspect <= 0 then aspect = SpineLayout.DEFAULT_ASPECT end
    local w = math.floor(spine_h / aspect + 0.5)
    if w < 1 then w = 1 end
    return w
end

-- fillRows(widths, avail_w, gap) -> { {first=i, last=j}, ... }
--
-- Greedy left-to-right fill. Every row holds at least one book even when
-- that book alone is wider than the shelf (it gets clipped by the painter
-- rather than looping forever here).
--
-- gap is either one number, or an array where gap[i] is the gap painted
-- BEFORE book i (so a group boundary can be wider than the gap inside a
-- run). A book that starts a row carries no leading gap either way.
function SpineLayout.fillRows(widths, avail_w, gap)
    gap = gap or 0
    local gaps = type(gap) == "table" and gap or nil
    local flat = gaps and 0 or gap
    local rows = {}
    local x, first
    for i, w in ipairs(widths) do
        if not first then
            first, x = i, w
        else
            local g = gaps and (gaps[i] or 0) or flat
            local need = x + g + w
            if need > avail_w then
                rows[#rows + 1] = { first = first, last = i - 1 }
                first, x = i, w
            else
                x = need
            end
        end
    end
    if first then
        rows[#rows + 1] = { first = first, last = #widths }
    end
    return rows
end

-- ── Balanced row breaking ───────────────────────────────────────────────────
--
-- Greedy fill packs the most books it can into the rows available, which is
-- exactly what pagination needs -- but it dumps every scrap of leftover space
-- onto the last row, and rows are painted CENTRED. Sixteen books on a two-row
-- shelf come out as fifteen books and one marooned mid-plank.
--
-- balanceRows re-breaks the SAME books across the SAME number of rows, so
-- nothing the fill decided moves: the page's book set, `shown`, the cursor
-- step, the footer's "10-13 of 324". Only where the breaks fall.

-- How far the balancer will shift a break, measured in average books, to
-- avoid cutting a section in half. The unit comes out of the arithmetic:
-- moving a break by one book of width w off an even split costs exactly
-- 2*w^2 of squared slack, whatever the slack happens to be. So "two books"
-- is 2 * (2 * mean_w)^2, and the constant reads as what it buys instead of
-- as a magic number of pixels.
SpineLayout.RUN_BREAK_BOOKS = 2

-- balanceRows(widths, avail_w, gap, count, n_rows, opts) -> rows | nil
--
-- Breaks widths[1..count] into exactly n_rows rows, minimising the sum of
-- squared row slack. gap works as in fillRows: one number, or an array where
-- gap[i] is painted BEFORE book i and is dropped when book i starts a row.
--
-- opts.runs[i] is the id of the section book i stands in (on a grouping chip,
-- the flattened group's item index). A break landing INSIDE a section is
-- charged RUN_BREAK_BOOKS' worth of slack, so the balancer gives up a little
-- evenness to keep a series or an author's shelf together. A preference, not
-- a rule -- a break that would strand a book still wins. Sections too wide to
-- stand on one row are exempt: they get cut wherever the breaks land, so
-- charging for it would only buy a lopsided shelf.
--
-- Returns nil when there is nothing to do -- fewer than two rows or two
-- books, or no partition fits -- and the caller keeps the greedy rows.
function SpineLayout.balanceRows(widths, avail_w, gap, count, n_rows, opts)
    count  = math.min(tonumber(count) or #widths, #widths)
    n_rows = tonumber(n_rows) or 1
    if count < 2 or n_rows < 2 or n_rows > count then return nil end

    local gaps = type(gap) == "table" and gap or nil
    local flat = gaps and 0 or (tonumber(gap) or 0)
    local function gapAt(i)
        if i < 2 then return 0 end
        return gaps and (gaps[i] or 0) or flat
    end

    -- run_w[i]: the painted width of books 1..i standing in one row.
    local run_w = { [0] = 0 }
    for i = 1, count do
        run_w[i] = run_w[i - 1] + widths[i] + gapAt(i)
    end
    -- A row holding books a..b: book a starts the row, so its leading gap is
    -- never painted.
    local function sliceWidth(a, b)
        return run_w[b] - run_w[a - 1] - gapAt(a)
    end

    -- The section penalty, and the sections already past defending.
    local runs, penalty, exempt = opts and opts.runs, 0, nil
    if runs then
        local sum = 0
        for i = 1, count do sum = sum + widths[i] end
        penalty = 2 * (SpineLayout.RUN_BREAK_BOOKS * (sum / count)) ^ 2
        exempt = {}
        local a = 1
        for i = 2, count + 1 do
            if i > count or runs[i] ~= runs[a] then
                if sliceWidth(a, i - 1) > avail_w then exempt[runs[a]] = true end
                a = i
            end
        end
    end
    -- What a row starting at book i costs on top of its slack.
    local function breakCost(i)
        if not runs or i < 2 then return 0 end
        if runs[i] ~= runs[i - 1] then return 0 end   -- lands on a boundary
        if exempt[runs[i]] then return 0 end          -- cut anyway, so free
        return penalty
    end

    -- cost[r][i]: the cheapest way to stand books 1..i on r rows.
    local cost, from = { [0] = { [0] = 0 } }, {}
    for r = 1, n_rows do
        cost[r], from[r] = {}, {}
        for i = r, count do
            local best, best_j
            for j = i - 1, r - 1, -1 do
                local w = sliceWidth(j + 1, i)
                -- One book alone always gets its row however wide it is (the
                -- fill's contract); beyond that, an overfull row is no row,
                -- and every j below this one is wider still.
                if w > avail_w and j + 1 ~= i then break end
                local prev = cost[r - 1][j]
                if prev then
                    local slack = avail_w - w
                    if slack < 0 then slack = 0 end
                    local c = prev + slack * slack + breakCost(j + 1)
                    -- Strict, and j walks downward, so a tie keeps the
                    -- fullest early rows -- what the greedy fill would do.
                    if not best or c < best then best, best_j = c, j end
                end
            end
            cost[r][i], from[r][i] = best, best_j
        end
    end
    if not cost[n_rows][count] then return nil end

    local rows, i = {}, count
    for r = n_rows, 1, -1 do
        local j = from[r][i]
        table.insert(rows, 1, { first = j + 1, last = i })
        i = j
    end
    return rows
end

-- paginate(rows, rows_per_page) -> { {first=i, last=j, rows={...}}, ... }
--
-- Groups fillRows() output into pages of rows_per_page rows. first/last are
-- BOOK indices (for the "10-13 of 324" footer), rows keeps the row slices
-- for the painter.
function SpineLayout.paginate(rows, rows_per_page)
    rows_per_page = rows_per_page or 1
    if rows_per_page < 1 then rows_per_page = 1 end
    local pages = {}
    for i = 1, #rows, rows_per_page do
        local page_rows = {}
        for j = i, math.min(i + rows_per_page - 1, #rows) do
            page_rows[#page_rows + 1] = rows[j]
        end
        pages[#pages + 1] = {
            first = page_rows[1].first,
            last  = page_rows[#page_rows].last,
            rows  = page_rows,
        }
    end
    return pages
end

return SpineLayout
