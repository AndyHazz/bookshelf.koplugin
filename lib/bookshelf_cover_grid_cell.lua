-- bookshelf_cover_grid_cell.lua
-- One tile in the Cover-picker grid: a candidate cover thumbnail with a
-- two-line caption (source label; then "W×Hpx · size"). When the candidate is
-- the currently-applied cover it draws the shelf's exact selection ring
-- (SpineWidget.BorderOverlay), so "selected here" reads identically to
-- "selected on the shelf". Tapping fires on_tap(candidate).
--
-- The tile renders from candidate.local_path (every candidate is a local file
-- by the time it reaches the grid -- online results are downloaded first, the
-- embedded cover is extracted to a PNG). Decoding goes through ImageSource's
-- shared cache, so the dimension probe done when the candidate was built is a
-- cache hit here.

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local ImageWidget     = require("ui/widget/imagewidget")
local InputContainer  = require("ui/widget/container/inputcontainer")
local OverlapGroup    = require("ui/widget/overlapgroup")
local Size            = require("ui/size")
local TextWidget      = require("ui/widget/textwidget")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Device          = require("device")
local Screen          = Device.screen
local BFont           = require("lib/bookshelf_fonts")
local ImageSource     = require("lib/bookshelf_image_source")
local SpineWidget     = require("lib/bookshelf_spine_widget")
local T               = require("ffi/util").template
local _               = require("lib/bookshelf_i18n").gettext

local BorderOverlay = SpineWidget.BorderOverlay
local RING          = SpineWidget.SELECTED_BORDER
local RADIUS        = SpineWidget.CARD_RADIUS

-- InputContainer that draws a focus ring on dpad/keyboard focus, distinct from
-- the black selection ring (which marks the ACTIVE cover, not the focused one).
local FocusCell = InputContainer:extend{ _focused = false }
function FocusCell:paintTo(bb, x, y)
    InputContainer.paintTo(self, bb, x, y)
    if self._focused and self.dimen then
        bb:paintBorder(x, y, self.dimen.w, self.dimen.h,
                       Size.border.thick, Blitbuffer.COLOR_BLACK, Size.radius.default)
    end
end
function FocusCell:onFocus() self._focused = true; return true end
function FocusCell:onUnfocus() self._focused = false; return true end

local CoverGridCell = {}

local function _fmtSize(bytes)
    if type(bytes) ~= "number" then return nil end
    if bytes >= 1024 * 1024 then
        return string.format("%.1f MB", bytes / 1024 / 1024)
    elseif bytes >= 1024 then
        return string.format("%d KB", math.floor(bytes / 1024 + 0.5))
    end
    return string.format("%d B", bytes)
end

-- Second caption line: dimensions and/or filesize, whichever are known.
local function _metaLine(c)
    local has_dims = c.width and c.height
    local size = _fmtSize(c.filesize)
    if has_dims and size then
        return T(_("%1×%2px · %3"), c.width, c.height, size)
    elseif has_dims then
        return T(_("%1×%2px"), c.width, c.height)
    end
    return size or ""
end

-- The height of the two-line caption for a given font size, so the grid can
-- reserve exactly that much and size the cover box from the rest. Uses the same
-- faces new() does, measured against sample text with ascenders + descenders.
function CoverGridCell.captionHeight(font_size)
    local fsize = font_size or 13
    local label_face = BFont:getFace("cfont", fsize, { bold = true })
    local meta_face  = BFont:getFace("cfont", math.max(9, fsize - 2))
    local vg = VerticalGroup:new{
        align = "center",
        TextWidget:new{ text = "Xg", face = label_face },
        TextWidget:new{ text = "Xg", face = meta_face },
    }
    return vg:getSize().h
end

-- CoverGridCell.new(opts) -> widget
--   opts.width, opts.height   outer tile box
--   opts.candidate            the Candidate table (see bookshelf_cover_apply)
--   opts.on_tap               function(candidate)
--   opts.font_size            caption label size (default 13)
function CoverGridCell.new(opts)
    local width   = opts.width
    local height  = opts.height
    local c       = opts.candidate
    local fsize   = opts.font_size or 13
    local thin    = Size.border.thin

    local label_face, label_bold = BFont:getFace("cfont", fsize, { bold = true })
    local meta_face = BFont:getFace("cfont", math.max(9, fsize - 2))

    local caption = VerticalGroup:new{
        align = "center",
        TextWidget:new{
            text = c.source_label or "", face = label_face, bold = label_bold,
            max_width = width, truncate_with_ellipsis = true,
        },
        TextWidget:new{
            text = _metaLine(c), face = meta_face,
            max_width = width, truncate_with_ellipsis = true,
        },
    }
    local cap_h = caption:getSize().h
    local gap   = Screen:scaleBySize(4)

    -- Cover box fills what's left, inset by RING on every side so the selection
    -- ring (which paints RING pixels beyond the box) stays within the tile.
    local box_w = width - 2 * RING
    local box_h = height - cap_h - gap - 2 * RING
    if box_h < Screen:scaleBySize(24) then box_h = Screen:scaleBySize(24) end

    local bb = c.local_path and ImageSource.loadImageNative(c.local_path) or nil
    local inner
    if bb then
        inner = ImageWidget:new{
            image = bb, image_disposable = false,
            width = box_w - 2 * thin, height = box_h - 2 * thin,
            scale_factor = 0,  -- aspect-preserving fit within the box
        }
    else
        inner = CenterContainer:new{
            dimen = Geom:new{ w = box_w - 2 * thin, h = box_h - 2 * thin },
            TextWidget:new{ text = "?", face = label_face },
        }
    end
    local card = FrameContainer:new{
        bordersize = thin, padding = 0, margin = 0, radius = RADIUS,
        bordercolor = Blitbuffer.COLOR_BLACK, inner,
    }

    local overlap = {}
    if c.is_active then
        overlap[#overlap + 1] = BorderOverlay:new{
            width = box_w, height = box_h, thickness = RING, radius = RADIUS,
        }
    end
    overlap[#overlap + 1] = card
    local cover = OverlapGroup:new{ dimen = Geom:new{ w = box_w, h = box_h }, unpack(overlap) }

    local col = VerticalGroup:new{
        align = "center",
        CenterContainer:new{ dimen = Geom:new{ w = width, h = box_h + 2 * RING }, cover },
        VerticalSpan:new{ width = gap },
        caption,
    }

    local cell = FocusCell:new{ dimen = Geom:new{ w = width, h = height }, col }
    cell.ges_events = {
        TapSelect = { GestureRange:new{ ges = "tap", range = cell.dimen } },
    }
    cell.onTapSelect = function()
        if opts.on_tap then opts.on_tap(c) end
        return true
    end
    return cell
end

return CoverGridCell
