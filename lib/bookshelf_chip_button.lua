-- bookshelf_chip_button.lua
-- A small bordered, rounded, white "chip" button: an optional leading icon
-- plus a centered text label, sized to an explicit height so it lines up with
-- whatever row it sits in (an input field, a line of body text). Originally
-- the Icons Library's search/clear button style (bookshelf_library_modal.lua,
-- _renderSearchInput's local chipButton); pulled out here, with an icon slot
-- and invert-on-tap-state added, so any small independent action button in
-- the app can reuse the same look instead of re-implementing it.

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local IconWidget      = require("ui/widget/iconwidget")
local InputContainer  = require("ui/widget/container/inputcontainer")
local Size            = require("ui/size")
local TextWidget      = require("ui/widget/textwidget")
local Device          = require("device")
local Screen          = Device.screen

-- FrameContainer that pixel-inverts its own rect after painting -- the same
-- device-independent "selected/active" idiom used by the Tags-tab pills and
-- the segmented source-chip bars (paint black-on-white then flip via a
-- blitbuffer primitive, since some builds don't honour a TextWidget's
-- fgcolor). Lets the button show a "busy"/pressed state without the icon and
-- label needing any color awareness of their own.
local ChipFrame = FrameContainer:extend{}
function ChipFrame:paintTo(bb, x, y)
    FrameContainer.paintTo(self, bb, x, y)
    if self.inverted and self.dimen then
        bb:invertRect(x, y, self.dimen.w, self.dimen.h)
    end
end

local ChipButton = {}

-- build(opts) -> a tappable widget, opts.height tall, bordered/rounded/white
-- (pixel-inverted to black/white when opts.inverted), containing an optional
-- leading icon and/or a centered text label.
--   opts.text       label text (optional if icon-only)
--   opts.face       label font face (required when opts.text is set)
--   opts.bold       label bold (default false)
--   opts.icon       stock icon name, e.g. "close" (resources/icons/mdlight)
--   opts.icon_size  icon square size in px (required when opts.icon is set)
--   opts.icon_glyph a Nerd Font PUA glyph instead of a stock SVG icon (takes
--                   priority over opts.icon when both are set)
--   opts.icon_face  font face for opts.icon_glyph (required when it's set),
--                   e.g. BFont:getFace("symbols", size)
--   opts.height     outer row height, required -- match the sibling row
--   opts.border     border thickness (default Size.border.default)
--   opts.radius     corner radius (default Size.radius.default)
--   opts.pad_h      horizontal inner padding (default Screen:scaleBySize(12))
--   opts.gap        icon/label gap when both are set (default Screen:scaleBySize(6))
--   opts.icon_after put the icon after the label instead of before (default false)
--   opts.inverted   render pixel-inverted (busy/active state)
--   opts.on_tap     function() fired on tap
function ChipButton.build(opts)
    local border = opts.border or Size.border.default
    local pad_h  = opts.pad_h or Screen:scaleBySize(12)
    local gap    = opts.gap or Screen:scaleBySize(6)
    local height = opts.height

    local icon_widget
    if opts.icon_glyph then
        icon_widget = TextWidget:new{
            text = opts.icon_glyph, face = opts.icon_face, fgcolor = Blitbuffer.COLOR_BLACK,
        }
    elseif opts.icon then
        icon_widget = IconWidget:new{
            icon = opts.icon, width = opts.icon_size, height = opts.icon_size,
        }
    end
    local label_widget
    if opts.text then
        label_widget = TextWidget:new{
            text = opts.text, face = opts.face, bold = opts.bold or false,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
    end
    local content = {}
    local function addPart(w)
        if not w then return end
        if #content > 0 then content[#content + 1] = HorizontalSpan:new{ width = gap } end
        content[#content + 1] = w
    end
    if opts.icon_after then
        addPart(label_widget); addPart(icon_widget)
    else
        addPart(icon_widget); addPart(label_widget)
    end
    local row = HorizontalGroup:new{ align = "center", unpack(content) }
    local row_size = row:getSize()
    local inner_h = math.max(height - 2 * border, row_size.h)

    local frame = ChipFrame:new{
        bordersize     = border,
        padding        = 0,
        padding_left   = pad_h,
        padding_right  = pad_h,
        padding_top    = 0,
        padding_bottom = 0,
        margin         = 0,
        radius         = opts.radius or Size.radius.default,
        background     = Blitbuffer.COLOR_WHITE,
        inverted       = opts.inverted or false,
        CenterContainer:new{
            dimen = Geom:new{ w = row_size.w, h = inner_h },
            row,
        },
    }
    local btn_w = frame:getSize().w
    local btn = InputContainer:new{ dimen = Geom:new{ w = btn_w, h = height }, frame }
    btn.ges_events = { TapSelect = { GestureRange:new{ ges = "tap", range = btn.dimen } } }
    btn.onTapSelect = function()
        if opts.on_tap then opts.on_tap() end
        return true
    end
    -- Dpad/keyboard focus highlight. Restores to the caller's own `inverted`
    -- baseline (not unconditionally false) on unfocus, so focusing away from
    -- a button that's mid-refresh doesn't clear its busy indicator.
    btn.onFocus = function() frame.inverted = true; return true end
    btn.onUnfocus = function() frame.inverted = opts.inverted or false; return true end
    return btn
end

return ChipButton
