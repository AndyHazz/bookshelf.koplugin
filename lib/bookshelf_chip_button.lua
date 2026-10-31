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
local LeftContainer   = require("ui/widget/container/leftcontainer")
local Size            = require("ui/size")
local TextWidget      = require("lib/bookshelf_colour_text")
local Device          = require("device")
local Screen          = Device.screen
local Space           = require("lib/bookshelf_space")

-- FrameContainer that pixel-inverts its own rect after painting -- the same
-- device-independent "selected/active" idiom used by the Tags-tab pills and
-- the segmented source-chip bars (paint black-on-white then flip via a
-- blitbuffer primitive, since some builds don't honour a TextWidget's
-- fgcolor). Lets the button show a "busy"/pressed state without the icon and
-- label needing any color awareness of their own.
local ChipFrame = FrameContainer:extend{}
function ChipFrame:paintTo(bb, x, y)
    FrameContainer.paintTo(self, bb, x, y)
    local r = self.radius or 0
    if self.square_bottom and r > 0 and self.dimen then
        -- Square bottom corners and an open bottom: the bottom r rows
        -- filled out to the edges (over the frame's own bottom line) and the
        -- sides drawn straight down. Flush with the screen's edge, a line
        -- along it looked cut off (maintainer).
        local w, h, b = self.dimen.w, self.dimen.h, self.bordersize or 0
        local Color = require("lib/bookshelf_color")
        if self.background then
            Color.paintRect(bb, x, y + h - r, w, r, self.background)
        end
        if b > 0 then
            local ink = self.color or Blitbuffer.COLOR_BLACK
            Color.paintRect(bb, x, y + h - r, b, r, ink)
            Color.paintRect(bb, x + w - b, y + h - r, b, r, ink)
        end
    end
    if (self.inverted or self._pressed) and self.dimen then
        require("lib/bookshelf_popup_kit").invertRounded(bb, x, y,
            self.dimen.w, self.dimen.h, r, self.square_bottom)
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
--   opts.width      at least this wide (buttons stacked in a column, one
--                   width); an icon and a label start at the left, else centred
--   opts.inverted   render pixel-inverted (busy/active state)
--   opts.square_bottom only the top corners rounded: a button flush with the
--                   bottom of the screen (the layout editor's footer)
--   opts.on_tap     function() fired on tap
--   opts.on_hold    function() fired on a long-press (a nudge's big step)
--   opts.instant    act at once, with no pressed look first: a tap whose
--                   result shows at once (a nudge's value), where the pressed
--                   frame was one more refresh for every tap (maintainer)
--   opts.enabled    false: grey border, label and icon, and a tap does nothing
function ChipButton.build(opts)
    -- Can't act now: light grey all over, the border lighter still. Dark
    -- grey read as nearly black on the PW5 (maintainer).
    local fg = opts.enabled == false and Blitbuffer.COLOR_GRAY or Blitbuffer.COLOR_BLACK
    local border = opts.border or Size.border.default
    local pad_h  = opts.pad_h or Space.px(12)
    local gap    = opts.gap or Space.px(6)
    local height = opts.height

    local icon_widget
    if opts.icon_glyph then
        icon_widget = TextWidget:new{
            text = opts.icon_glyph, face = opts.icon_face, fgcolor = fg,
        }
    elseif opts.icon then
        icon_widget = IconWidget:new{
            icon = opts.icon, width = opts.icon_size, height = opts.icon_size,
            -- Greyed with the label when the button can't act.
            dim = opts.enabled == false or nil,
        }
    end
    local label_widget
    if opts.text then
        label_widget = require("lib/bookshelf_cap_centre").centre(TextWidget:new{
            text = opts.text, face = opts.face, bold = opts.bold or false,
            fgcolor = fg,
        })
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
        radius         = opts.radius or Space.radius.default,
        background     = Blitbuffer.COLOR_WHITE,
        -- Greyed all over when it can't act: the border too, not the label
        -- alone, which was too easy to miss (maintainer).
        color          = opts.enabled == false and Blitbuffer.COLOR_LIGHT_GRAY or nil,
        inverted       = opts.inverted or false,
        square_bottom  = opts.square_bottom or nil,
        -- An icon and a label start at the left, so a column of them lines
        -- up (maintainer); a label or an icon alone is centred.
        ((icon_widget and label_widget) and LeftContainer or CenterContainer):new{
            dimen = Geom:new{ w = math.max(row_size.w,
                (opts.width or 0) - 2 * pad_h - 2 * border), h = inner_h },
            row,
        },
    }
    local btn_w = frame:getSize().w
    local btn = InputContainer:new{ dimen = Geom:new{ w = btn_w, h = height }, frame }
    -- As a stock Button's: the keys pass over one that can't act (Kit.keyFocus).
    btn.enabled = opts.enabled ~= false
    btn.ges_events = { TapSelect = { GestureRange:new{ ges = "tap", range = btn.dimen } } }
    -- Shown pressed (inverted) at once, then the tap acts: a slow action
    -- still shows it was taken.
    btn.onTapSelect = function()
        if opts.on_tap and opts.enabled ~= false then
            if opts.instant then opts.on_tap()
            else require("lib/bookshelf_popup_kit").pressThen(btn, frame, opts.on_tap) end
        end
        return true
    end
    if opts.on_hold then
        btn.ges_events.HoldSelect = { GestureRange:new{ ges = "hold", range = btn.dimen } }
        btn.onHoldSelect = function()
            if opts.enabled ~= false then
                -- A nudge's hold (its big step) acts at once too.
                if opts.instant then opts.on_hold()
                else require("lib/bookshelf_popup_kit").pressThen(btn, frame, opts.on_hold) end
            end
            return true
        end
    end
    -- Dpad/keyboard focus: the kit's ring inside the button (popup kit's
    -- invertRing), not the button inverted, which looked like a button that
    -- is on (an active header button is inverted too).
    local focused = false
    function btn:paintTo(bb, x, y)
        InputContainer.paintTo(self, bb, x, y)
        if focused then
            local Kit = require("lib/bookshelf_popup_kit")
            local sz = frame:getSize()
            Kit.invertRing(bb, x, y, sz.w, sz.h, Kit.focusWidth(), frame.radius or 0,
                frame.square_bottom)
        end
    end
    btn.onFocus = function() focused = true; return true end
    btn.onUnfocus = function() focused = false; return true end
    return btn
end

return ChipButton
