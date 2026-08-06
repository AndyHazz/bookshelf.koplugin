--[[
Start-menu module: shelf size.
See README.md in this directory for the module spec contract.

A big total-books number over a per-status breakdown (unread / reading /
on hold / finished). Counts come from Repo.countByStatus(), which walks the
library once and classifies each book by its sidecar status (books that have
never been opened cost nothing beyond the walk). That walk + status read is
not free on a large library, so the result is memoised per menu-open via the
loader's menu_generation counter — render runs on every focus-step rebuild,
but the tally is computed at most once per time the menu is opened. No on_tap.
]]
local _ = require("lib/bookshelf_i18n").gettext

-- Display order and translatable labels for the per-status lines.
local STATUS_ROWS = {
    { id = "reading",  label = _("Reading") },
    { id = "unread",   label = _("Unread") },
    { id = "on_hold",  label = _("On hold") },
    { id = "finished", label = _("Finished") },
}

-- The status row is one comparable series -- "how many in each state" -- so it
-- wants to be read across, in one line. Breaking it over several lines loses
-- that reading, and truncating the headings ("Readi...", "Finish...") loses the
-- labels themselves. So the row is FITTED instead: both its faces shrink
-- together until the widest cell fits its slot.
--
-- 60% of nominal is the floor, the same legibility floor the hero fit engine
-- (_renderFitted) shrinks to. Only if a single row still won't fit at that
-- floor does it fall back to wrapping -- a last resort, not the first response.
local FIT_FLOOR_PCT = 60

-- Memo for the fitted sizes. render() runs on every focus-step rebuild, and the
-- probing below is the expensive part, so the decision is cached per
-- (width, scale, tally) and dropped whenever the tally changes -- which is once
-- per menu open, the same generation counter getCounts() keys off.
local _fit_memo, _fit_gen = {}, nil

-- Returns head_size, count_size, cols: the largest sizes at which all
-- #STATUS_ROWS columns fit one row across `mw`, or full-size 2-column wrap if
-- even the floor won't fit.
local function _fitStatusRow(mw, scale_pct, counts, gen)
    if _fit_gen ~= gen then _fit_memo, _fit_gen = {}, gen end
    local key = mw .. "|" .. tostring(scale_pct)
    local m = _fit_memo[key]
    if m then return m[1], m[2], m[3] end

    local Fonts      = require("lib/bookshelf_fonts")
    local TextWidget = require("ui/widget/textwidget")
    local n = #STATUS_ROWS
    local function scv(v) return math.max(1, math.floor(v * (scale_pct or 100) / 100 + 0.5)) end

    -- Widest rendered cell (heading OR count -- either can be the binding one:
    -- a long label like "Finished", or a five-digit count on a big library) at
    -- `pct` of the nominal sizes.
    local function widestAt(pct)
        local hs = math.max(1, math.floor(scv(12) * pct / 100 + 0.5))
        local cs = math.max(1, math.floor(scv(18) * pct / 100 + 0.5))
        local hface = Fonts:getFace("cfont", hs)
        local cface, cbold = Fonts:getFace("cfont", cs, { bold = true })
        local widest = 0
        for _i, st in ipairs(STATUS_ROWS) do
            local probes = {
                TextWidget:new{ text = st.label, face = hface },
                TextWidget:new{ text = tostring(counts[st.id] or 0),
                    face = cface, bold = cbold },
            }
            for _j, probe in ipairs(probes) do
                local w = probe:getSize().w
                probe:free()
                if w > widest then widest = w end
            end
        end
        return widest, hs, cs
    end

    -- Leave a gutter so a cell that fits EXACTLY doesn't sit flush against its
    -- neighbour, which reads as truncation even when nothing is clipped.
    local slot   = math.floor(mw / n)
    local usable = slot - math.max(2, math.floor(slot * 0.10))

    local pct = 100
    local widest, hs, cs = widestAt(pct)
    if widest > usable then
        -- Jump straight to the size the ratio implies, then creep down: font
        -- metrics aren't linear in size (hinting, rounding), so the ratio is a
        -- good first guess rather than an answer.
        pct = math.max(FIT_FLOOR_PCT, math.floor(100 * usable / widest))
        widest, hs, cs = widestAt(pct)
        while widest > usable and pct > FIT_FLOOR_PCT do
            pct = math.max(FIT_FLOOR_PCT, pct - 5)
            widest, hs, cs = widestAt(pct)
        end
    end

    local cols = n
    if widest > usable then
        cols = 2
        _, hs, cs = widestAt(100)
    end
    _fit_memo[key] = { hs, cs, cols }
    return hs, cs, cols
end

-- Per-menu-open memo: the walk + status reads are the expensive part, so cache
-- the tally against the loader's generation counter (bumped once per open).
local _gen, _total, _counts

local function getCounts()
    local Modules = require("lib/bookshelf_start_menu_modules")
    local gen = Modules.menu_generation
    if _gen ~= gen or not _counts then
        local Repo = require("lib/bookshelf_book_repository")
        local ok, total, counts = pcall(Repo.countByStatus)
        if ok then
            _gen, _total, _counts = gen, total, counts
        else
            _total, _counts = 0, { reading = 0, unread = 0, on_hold = 0, finished = 0 }
        end
    end
    return _total, _counts
end

return {
    key   = "shelf_size", -- stable id stored in user menus; never change it
    title = _("Shelf size"),
    summary = _("From your library. Works offline."),
    -- No height input is needed: the status table's wrap decision is purely
    -- width-driven (below), so it adapts identically in the start menu, the
    -- hero and the full-screen grid.
    render = function(ctx)
        local width, scale_pct, _preview = ctx.width, ctx.scale, ctx.preview
        local Blitbuffer      = require("ffi/blitbuffer")
        local Fonts           = require("lib/bookshelf_fonts")
        local TextWidget      = require("ui/widget/textwidget")
        local VerticalGroup   = require("ui/widget/verticalgroup")
        local VerticalSpan    = require("ui/widget/verticalspan")
        local HorizontalGroup = require("ui/widget/horizontalgroup")
        local HorizontalSpan  = require("ui/widget/horizontalspan")
        local LeftContainer   = require("ui/widget/container/leftcontainer")
        local Geom            = require("ui/geometry")
        local SM              = require("lib/bookshelf_start_menu_modules")
        local mw = math.max(50, width)
        local function sc(n) return math.max(1, math.floor(n * (scale_pct or 100) / 100 + 0.5)) end
        local BLACK = SM.COLOR_PRIMARY

        local total, counts = getCounts()

        -- Header: the big total with a smaller "Books" label after it, same
        -- weight and baseline-aligned. HorizontalGroup aligns box edges, not
        -- text baselines, so top-align the boxes and drop "Books" by the
        -- difference in baseline offsets to land both baselines on one line.
        local big_face, big_bold = Fonts:getFace("cfont", sc(40), {bold=true})
        local books_face, books_bold = Fonts:getFace("cfont", sc(20), {bold=true})
        local big_tw = TextWidget:new{ text = tostring(total), face = big_face,
            bold = big_bold, fgcolor = BLACK }
        local books_tw = TextWidget:new{ text = _("Books"), face = books_face,
            bold = books_bold, fgcolor = SM.COLOR_MUTED }
        local dy = math.max(0, big_tw:getBaseline() - books_tw:getBaseline())
        local header = HorizontalGroup:new{
            align = "top",
            big_tw,
            HorizontalSpan:new{ width = sc(12) },
            VerticalGroup:new{ align = "left", VerticalSpan:new{ width = dy }, books_tw },
        }

        -- Status table: label heading over its count, one cell per status.
        -- Status columns are spread evenly across the module width (one equal
        -- slot each), with each column's label + count LEFT-aligned within its
        -- slot. The leftmost column lines up with the big total above it, and
        -- the row fills the width evenly (issue #185 -- centred content left the
        -- total stranded against the spread row).
        --
        -- Sizes come from _fitStatusRow, which shrinks the row to keep all the
        -- statuses on ONE line (see its comment). It reports the column count
        -- too, since it owns the decision to give up and wrap. This works for a
        -- customised STATUS_ROWS as well: five or six statuses simply fit at a
        -- smaller size rather than being broken across lines.
        -- (The wrap was once gated on avail_h -- i.e. hero grid only -- because
        -- a taller wrapped card could inflate the start-menu panel past the
        -- screen. The panel now caps a row via ctx.max_height and paginates
        -- around it, so the gate is gone and every surface fits alike.)
        local head_size, count_size, status_cols =
            _fitStatusRow(mw, scale_pct, counts, require("lib/bookshelf_start_menu_modules").menu_generation)
        local head_face  = Fonts:getFace("cfont", head_size)
        local count_face, count_bold = Fonts:getFace("cfont", count_size, {bold=true})
        local col_w      = math.floor(mw / status_cols)
        local function statusCol(st)
            local col = VerticalGroup:new{
                align = "left",
                TextWidget:new{ text = st.label, face = head_face, fgcolor = SM.COLOR_MUTED,
                    max_width = col_w },
                VerticalSpan:new{ width = sc(2) },
                TextWidget:new{ text = tostring(counts[st.id] or 0),
                    face = count_face, bold = count_bold, fgcolor = BLACK,
                    max_width = col_w },
            }
            return LeftContainer:new{
                dimen = Geom:new{ w = col_w, h = col:getSize().h }, col }
        end
        local table_block = VerticalGroup:new{ align = "left" }
        local row
        for i, st in ipairs(STATUS_ROWS) do
            if (i - 1) % status_cols == 0 then
                if row then table_block[#table_block + 1] = VerticalSpan:new{ width = sc(6) } end
                row = HorizontalGroup:new{ align = "top" }
                table_block[#table_block + 1] = row
            end
            row[#row + 1] = statusCol(st)
        end

        return VerticalGroup:new{
            align = "left",
            header,
            VerticalSpan:new{ width = sc(6) },
            table_block,
        }
    end,
}
