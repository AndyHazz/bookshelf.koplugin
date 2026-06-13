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
    render = function(width, scale_pct)
        local Blitbuffer      = require("ffi/blitbuffer")
        local Fonts           = require("lib/bookshelf_fonts")
        local TextWidget      = require("ui/widget/textwidget")
        local VerticalGroup   = require("ui/widget/verticalgroup")
        local VerticalSpan    = require("ui/widget/verticalspan")
        local HorizontalGroup = require("ui/widget/horizontalgroup")
        local HorizontalSpan  = require("ui/widget/horizontalspan")
        local CenterContainer = require("ui/widget/container/centercontainer")
        local Geom            = require("ui/geometry")
        local mw = math.max(50, width)
        local function sc(n) return math.max(1, math.floor(n * (scale_pct or 100) / 100 + 0.5)) end
        local BLACK = Blitbuffer.COLOR_BLACK

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
            bold = books_bold, fgcolor = BLACK }
        local dy = math.max(0, big_tw:getBaseline() - books_tw:getBaseline())
        local header = HorizontalGroup:new{
            align = "top",
            big_tw,
            HorizontalSpan:new{ width = sc(12) },
            VerticalGroup:new{ align = "left", VerticalSpan:new{ width = dy }, books_tw },
        }

        -- Status table: a column per status, label heading over its count.
        local col_w      = math.floor(mw / #STATUS_ROWS)
        local head_face  = Fonts:getFace("cfont", sc(12))
        local count_face, count_bold = Fonts:getFace("cfont", sc(18), {bold=true})
        local table_row  = HorizontalGroup:new{ align = "top" }
        for _i, st in ipairs(STATUS_ROWS) do
            local col = VerticalGroup:new{
                align = "center",
                TextWidget:new{ text = st.label, face = head_face, fgcolor = BLACK,
                    max_width = col_w },
                VerticalSpan:new{ width = sc(2) },
                TextWidget:new{ text = tostring(counts[st.id] or 0),
                    face = count_face, bold = count_bold, fgcolor = BLACK,
                    max_width = col_w },
            }
            table_row[#table_row + 1] = CenterContainer:new{
                dimen = Geom:new{ w = col_w, h = col:getSize().h }, col }
        end

        return VerticalGroup:new{
            align = "left",
            header,
            VerticalSpan:new{ width = sc(6) },
            table_row,
        }
    end,
}
