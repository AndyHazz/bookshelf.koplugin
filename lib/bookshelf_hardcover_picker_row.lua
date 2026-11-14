-- bookshelf_hardcover_picker_row.lua
-- One cell of the Hardcover picker (lib/bookshelf_hardcover_picker): the
-- cover on the left, a third of the cell wide, then the title and the
-- detail line, both wrapping. The same card as every other picker's cell
-- (lib/bookshelf_picker_cell), with a picture.
--
-- cellHeight(w) -> the height of a cell w wide: its cover's, at 2:3.
-- render(item, dimen, opts) -> widget
--   item = { label =, subtitle =, stats =, cover_path = path | nil,
--            no_cover = true when there is none to come (a grey "No cover") }
--   stats (pages, reads) sits on one line at the foot of the text, lighter
--   and not bold, a size smaller when it would not fit, cut only if still not
--   opts = { selected = bool }
-- With no cover_path the cell keeps the cover's space as an outlined box, so
-- the text does not move when the picture arrives.

local Blitbuffer      = require("ffi/blitbuffer")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local BFont           = require("lib/bookshelf_fonts")
local Space           = require("lib/bookshelf_space")

local Row = {}

-- The cover's share of the cell's width.
Row.COVER_SHARE = 0.32
-- Lines the title may take before it is cut with an ellipsis.
Row.TITLE_LINES = 3

local function vpad() return Space.px(5) end

-- coverSize(cell_w, share) -> w, h of the cover in a cell that wide; share
-- defaults to COVER_SHARE (one column of wide cells passes a smaller one).
function Row.coverSize(cell_w, share)
    local w = math.max(8, math.floor(cell_w * (share or Row.COVER_SHARE)))
    return w, math.floor(w * 3 / 2)
end

function Row.cellHeight(cell_w, share)
    local _w, h = Row.coverSize(cell_w, share)
    return h + 2 * vpad() + require("lib/bookshelf_popup_kit").shadowSize()
end

-- Wrapped text, at most max_h tall (ellipsis when cut). On the card's grey:
-- a text box paints its own background, white by default (rig: white
-- blocks on the grey card), and has no see-through mode.
local function wrapped(text, face, bold, width, max_h)
    local bg = require("lib/bookshelf_popup_kit").STRIP_BG
    local box = TextBoxWidget:new{
        text = text, face = face, bold = bold, width = width,
        fgcolor = Blitbuffer.COLOR_BLACK, bgcolor = bg, alignment = "left",
    }
    if max_h and box:getSize().h > max_h then
        box:free()
        box = TextBoxWidget:new{
            text = text, face = face, bold = bold, width = width,
            fgcolor = Blitbuffer.COLOR_BLACK, bgcolor = bg, alignment = "left",
            height = max_h, height_overflow_show_ellipsis = true,
        }
    end
    return box
end

-- The counts line: grey, regular weight, one line. A size down when it is
-- too wide; cut with an ellipsis only at the smallest.
Row.STATS_SIZES = { 13, 12, 11 }
local function statsLine(text, width)
    local TextWidget = require("lib/bookshelf_colour_text")
    local w
    for i, size in ipairs(Row.STATS_SIZES) do
        if w then w:free() end
        local last = i == #Row.STATS_SIZES
        w = TextWidget:new{
            text = text, face = BFont:getFace("cfont", size),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            max_width = last and width or nil,
        }
        if last or w:getSize().w <= width then return w end
    end
    return w
end

-- The height of n lines of text in this face.
local function linesHeight(face, bold, n)
    local probe = TextBoxWidget:new{ text = "Ag", face = face, bold = bold, width = 400 }
    local h = probe:getSize().h
    probe:free()
    return h * n
end

function Row.render(item, dimen, opts)
    opts = opts or {}
    local Kit = require("lib/bookshelf_popup_kit")
    local inner_w = dimen.w - Kit.shadowSize()
    local inner_h = dimen.h - Kit.shadowSize()
    local pad, vp = Space.padding.large, vpad()
    local cover_w, cover_h = Row.coverSize(inner_w, opts.cover_share)
    -- A cell given less room than it asked for: the cover keeps its shape.
    if cover_h > inner_h - 2 * vp then
        cover_h = math.max(8, inner_h - 2 * vp)
        cover_w = math.floor(cover_h * 2 / 3)
    end

    local cover
    if item.cover_path then
        local ok, bb = pcall(function()
            return require("lib/bookshelf_image_source").loadImageCover(item.cover_path, cover_w, cover_h)
        end)
        if ok and bb then
            -- The bb is the image cache's: never freed by this widget.
            cover = require("ui/widget/imagewidget"):new{
                image = bb, image_disposable = false,
                width = cover_w, height = cover_h,
            }
        end
    end
    if not cover and item.no_cover then
        -- None to come: grey, and says so (a white box reads as loading).
        local CenterContainer = require("ui/widget/container/centercontainer")
        local TextWidget = require("lib/bookshelf_colour_text")
        cover = FrameContainer:new{
            bordersize = 0, margin = 0, padding = 0,
            background = Blitbuffer.COLOR_LIGHT_GRAY,
            CenterContainer:new{
                dimen = Geom:new{ w = cover_w, h = cover_h },
                TextWidget:new{ text = require("lib/bookshelf_i18n").gettext("No cover"),
                    face = BFont:getFace("cfont", 11), fgcolor = Blitbuffer.COLOR_DARK_GRAY,
                    max_width = cover_w - Space.px(4) },
            },
        }
    end
    if not cover then
        cover = FrameContainer:new{
            bordersize = Space.px(1), margin = 0, padding = 0,
            color = Blitbuffer.COLOR_GRAY,
            background = Blitbuffer.COLOR_WHITE,
            WidgetContainer:new{ dimen = Geom:new{
                w = cover_w - 2 * Space.px(1), h = cover_h - 2 * Space.px(1) } },
        }
    end

    local text_w = inner_w - cover_w - 3 * pad
    local text_h = inner_h - 2 * vp
    local label_face, label_bold = BFont:getFace("cfont", 17, { bold = true })
    local sub_face, sub_bold = BFont:getFace("cfont", 14, { bold = true })
    -- The counts first: they keep their line at the foot, and the title
    -- and detail share what is above it.
    local stats = item.stats and item.stats ~= "" and statsLine(item.stats, text_w) or nil
    local stats_h = stats and (stats:getSize().h + Space.px(4)) or 0
    local top_h = text_h - stats_h
    local title = wrapped(item.label or "", label_face, label_bold, text_w,
        math.min(top_h, linesHeight(label_face, label_bold, Row.TITLE_LINES)))
    local lines = VerticalGroup:new{ align = "left", title }
    local left = top_h - title:getSize().h - Space.px(4)
    if item.subtitle and item.subtitle ~= "" and left > linesHeight(sub_face, sub_bold, 1) then
        lines[#lines + 1] = VerticalSpan:new{ width = Space.px(4) }
        lines[#lines + 1] = wrapped(item.subtitle, sub_face, sub_bold, text_w, left)
    end
    if stats then
        -- Down to the foot of the text column, level with the cover's foot.
        local used = 0
        for _i, w in ipairs(lines) do used = used + w:getSize().h end
        lines[#lines + 1] = VerticalSpan:new{ width = math.max(Space.px(4), text_h - used - stats:getSize().h) }
        lines[#lines + 1] = stats
    end

    local cover_y = vp + math.floor((inner_h - 2 * vp - cover_h) / 2)
    local row = HorizontalGroup:new{
        align = "top",
        HorizontalSpan:new{ width = pad },
        VerticalGroup:new{ VerticalSpan:new{ width = cover_y }, cover },
        HorizontalSpan:new{ width = pad },
        VerticalGroup:new{ align = "left", VerticalSpan:new{ width = vp }, lines },
    }
    local card = Kit.card{
        WidgetContainer:new{ dimen = Geom:new{ w = inner_w, h = inner_h }, row },
    }
    if opts.selected then
        -- The linked one: the card in negative, as every picker marks its
        -- choice. The cover is put back, so it is not a photo negative.
        local paint = card.paintTo
        function card:paintTo(bb, x, y)
            paint(self, bb, x, y)
            local sz = self:getSize()
            Kit.invertRounded(bb, x, y, sz.w, sz.h, Kit.RADIUS)
            bb:invertRect(x + pad, y + cover_y, cover_w, cover_h)
        end
    end
    return card
end

return Row
