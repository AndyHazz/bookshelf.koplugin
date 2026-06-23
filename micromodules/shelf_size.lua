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
    -- avail_h (4th arg) is accepted for signature parity with the hero grid;
    -- the status table's wrap decision is width-driven (below) so it adapts in
    -- both the start menu and the hero.
    render = function(ctx)
        local width, scale_pct, _preview, avail_h = ctx.width, ctx.scale, ctx.preview, ctx.height
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
        -- A single row of #STATUS_ROWS columns reads well in a wide cell but
        -- cramps in a narrow / square / portrait one, so wrap to 2 columns
        -- (2 rows) there. ONLY in the hero grid (avail_h given): the start
        -- menu (avail_h nil) keeps the original single row, because its cards
        -- are narrow AND the menu sizes its panel to each card's height — a
        -- taller wrapped card there would inflate the panel past the screen
        -- and destabilise the start-menu layout. Gating on avail_h keeps the
        -- menu's behaviour exactly as it shipped.
        local head_face  = Fonts:getFace("cfont", sc(12))
        local count_face, count_bold = Fonts:getFace("cfont", sc(18), {bold=true})
        local n_status   = #STATUS_ROWS
        -- Status columns are spread evenly across the module width (one equal
        -- slot each), with each column's label + count LEFT-aligned within its
        -- slot. The leftmost column lines up with the big total above it, and
        -- the row fills the width evenly (issue #185 -- centred content left the
        -- total stranded against the spread row). A single wide row cramps in a
        -- narrow / square cell, so wrap to 2 columns there.
        local status_cols = (avail_h and math.floor(mw / n_status) < sc(70))
            and 2 or n_status
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
