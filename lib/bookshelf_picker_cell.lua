-- bookshelf_picker_cell.lua
-- Shared cell renderer used by every Bookshelf picker / tagger so all the
-- "grid of choices" views feel like one component.
--
-- Consumers:
--   * bookshelf_library_modal grid (chip editor → "Specific X…" flow:
--     folder, author, series, genre, format, rating, tag pickers).
--   * bookshelf_collection_manager (book-tag toggle + manage modes).
--
-- Cell anatomy:
--   * FrameContainer with thin border + slight radius + white background.
--   * CenterContainer wraps a VerticalGroup of:
--       - bold label (single line, truncated with an ellipsis if too long)
--       - optional secondary count ("n book(s)") OR a freeform subtitle
--         (e.g. folder paths) in lighter weight below.
--   * Selected state inverts the cell (black bg, white text) via
--     FrameContainer.invert -- no extra glyph needed to flag membership,
--     the inverted block reads at a glance even on grayscale e-ink.

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Font            = require("ui/font")
local BFont           = require("lib/bookshelf_fonts")
local Geom            = require("ui/geometry")
local Size            = require("ui/size")
local TextWidget      = require("ui/widget/textwidget")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Device          = require("device")
local Space           = require("lib/bookshelf_space")
local Screen          = Device.screen

local _ = require("lib/bookshelf_i18n").gettext

local PickerCell = {}

-- render(item, dimen, opts) -> FrameContainer widget
--
-- item = {
--   label    = "Favourites",        -- required, primary text (bold)
--   count    = 3,                   -- optional; rendered as "n book(s)"
--   subtitle = "/folder/path",      -- optional; overrides count
-- }
-- dimen = Geom{ w = cell_w, h = cell_h }
-- opts = {
--   selected = bool,                -- true = inverted (filled) cell
--   tint     = bool,                -- true = light-gray fill (mutually
--                                   --       exclusive with selected; used
--                                   --       to flag a staged action that
--                                   --       isn't a "filled / in" state,
--                                   --       e.g. stage-remove on a
--                                   --       collection that's currently in).
-- }
function PickerCell.render(item, dimen, opts)
    opts = opts or {}
    local content_inset = Space.padding.large
    local content_w     = dimen.w - 2 * content_inset
    -- Text stays black in BOTH normal and selected states. The selected
    -- state uses FrameContainer.invert (full-region pixel flip), which
    -- automatically flips the black text to white when the white bg
    -- flips to black. Setting fgcolor=WHITE here would double-flip the
    -- text back to black, producing the black-on-black render we hit
    -- in the first pass.
    local fgcolor     = Blitbuffer.COLOR_BLACK
    -- Subtitle is black (same weight as the label, not lighter): on
    -- e-ink anything below black washes out, especially when the cell
    -- is inverted and the contrast already runs the other way.
    local sub_fgcolor = Blitbuffer.COLOR_BLACK

    local children = {}
    local label_face, label_bold = BFont:getFace("cfont", 18, { bold = true })
    children[#children + 1] = TextWidget:new{
        text      = item.label or "",
        face      = label_face,
        bold      = label_bold,
        fgcolor   = fgcolor,
        max_width = content_w,
    }

    -- Secondary line: subtitle wins over count when both are present.
    -- count + subtitle are mutually exclusive at every current callsite,
    -- but the precedence is documented here in case that changes.
    -- Count format is "(n book(s))" -- the brackets visually demote it
    -- as supporting info even though the weight matches the label.
    local sub_text
    if item.subtitle and item.subtitle ~= "" then
        sub_text = item.subtitle
    elseif item.count and item.count > 0 then
        sub_text = "(" .. tostring(item.count) .. " "
            .. (item.count == 1 and _("book") or _("books")) .. ")"
    end
    if sub_text then
        -- Tight 1px vertical span between label and subtitle -- with both
        -- lines bold the visual relationship reads as one stacked unit;
        -- a larger gap broke that into two separate lines.
        children[#children + 1] = VerticalSpan:new{ width = Space.px(1) }
        local sub_face, sub_bold = BFont:getFace("cfont", 12, { bold = true })
        children[#children + 1] = TextWidget:new{
            text      = sub_text,
            face      = sub_face,
            bold      = sub_bold,
            fgcolor   = sub_fgcolor,
            max_width = content_w,
        }
    end

    local stack = VerticalGroup:new{ align = "center" }
    for _i, c in ipairs(children) do stack[#stack + 1] = c end

    -- tint takes precedence over selected: a tinted cell paints the
    -- gray background literally rather than relying on invert (so it
    -- reads as a third, distinct state next to plain white and inverted
    -- black).
    local bg     = opts.tint and Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_WHITE
    local invert = opts.selected and not opts.tint
    return FrameContainer:new{
        bordersize = Size.border.thin,
        radius     = Space.radius.default,
        padding    = 0,
        margin     = 0,
        background = bg,
        invert     = invert,
        CenterContainer:new{
            dimen = Geom:new{ w = dimen.w, h = dimen.h },
            stack,
        },
    }
end

return PickerCell
