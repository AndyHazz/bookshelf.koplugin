-- bookshelf_popup_kit.lua
-- The book popup's controls, shared by its tabs so they read as one set:
-- every tappable thing is a closed rounded shape with the button border and
-- corner, set in from the frame, and black fill means only "this is on". No
-- control leans on the frame edge or a neighbour to finish its outline (the
-- stock button grid did, and left lines that ended nowhere once inset).

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputContainer  = require("ui/widget/container/inputcontainer")
local Size            = require("ui/size")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local TextWidget      = require("lib/bookshelf_colour_text")
local Space           = require("lib/bookshelf_space")

local Kit = {}

Kit.BORDER = Size.border.button
Kit.RADIUS = Space.radius.button

-- A source switch (Embedded | Hardcover, My review | Hardcover) is the same
-- control as Reading status, a step smaller: it picks what a tab shows.
Kit.SOURCE_PAD_V = Space.px(8)
function Kit.sourceFace(font_size)
    return require("ui/font"):getFace("cfont", math.max(10, (font_size or 20) - 2))
end

-- tapCell(widget, w, h, on_tap, enabled) -> widget as a w x h tap target
-- that inverts when the dpad focuses it. enabled == false swallows the tap.
function Kit.tapCell(widget, w, h, on_tap, enabled)
    local cell = InputContainer:new{ dimen = Geom:new{ w = w, h = h }, widget }
    cell.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = cell.dimen } } }
    cell.onTap = function()
        if enabled ~= false and on_tap then on_tap() end
        return true
    end
    cell._focused = false
    function cell:paintTo(bb, x, y)
        InputContainer.paintTo(self, bb, x, y)
        if self._focused then bb:invertRect(x, y, w, h) end
    end
    cell.onFocus = function() cell._focused = true; return true end
    cell.onUnfocus = function() cell._focused = false; return true end
    return cell
end

-- segmented(o) -> widget, focus_rows: one rounded control split into cells,
-- the active cell filled black with a bold white label. It draws its own
-- outline and dividers.
--   o.items   { { key=, label= }, ... }
--   o.active  the key shown selected (may match none)
--   o.on_pick function(key), fired for a tap on an inactive cell
--   o.face    label face
--   o.width   total width, split evenly; nil sizes each cell to its label
--   o.pad_h   label side padding when sized to labels (default Space.px(16))
--   o.pad_v   label top/bottom padding (default Space.px(12))
function Kit.segmented(o)
    local items, n = o.items, #o.items
    local pad_h = o.pad_h or Space.px(16)
    local pad_v = o.pad_v or Space.px(12)
    local labels, widths, label_h = {}, {}, 0
    if o.width then
        local each = math.floor(o.width / n)
        for i = 1, n do widths[i] = (i == n) and (o.width - each * (n - 1)) or each end
    end
    for i, it in ipairs(items) do
        local on = it.key == o.active
        labels[i] = TextWidget:new{ text = it.label or "", face = o.face, bold = on,
            fgcolor = on and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK,
            max_width = widths[i] and (widths[i] - 2 * Space.px(6)) or nil }
        label_h = math.max(label_h, labels[i]:getSize().h)
    end
    local w = 0
    if o.width then
        w = o.width
    else
        for i = 1, n do
            widths[i] = labels[i]:getSize().w + 2 * pad_h
            w = w + widths[i]
        end
    end
    local h = label_h + 2 * pad_v
    local row = HorizontalGroup:new{ align = "top" }
    local cells, sel = {}, nil
    for i, it in ipairs(items) do
        if it.key == o.active then sel = i end
        local key = it.key
        local cell = Kit.tapCell(
            CenterContainer:new{ dimen = Geom:new{ w = widths[i], h = h }, labels[i] },
            widths[i], h, function()
                if key ~= o.active and o.on_pick then o.on_pick(key) end
            end)
        row[#row + 1] = cell
        cells[#cells + 1] = cell
    end
    local seg = WidgetContainer:new{ dimen = Geom:new{ w = w, h = h }, row }
    function seg:paintTo(bb, x, y)
        self.dimen.x, self.dimen.y = x, y
        local r, black = Kit.RADIUS, Blitbuffer.COLOR_BLACK
        local starts, sx = {}, x
        for i = 1, n do starts[i] = sx; sx = sx + widths[i] end
        if sel then
            local cx, cw = starts[sel], widths[sel]
            bb:paintRoundedRect(cx, y, cw, h, black, r)
            -- Only the control's own ends are rounded.
            if sel > 1 then bb:paintRect(cx, y, r, h, black) end
            if sel < n then bb:paintRect(cx + cw - r, y, r, h, black) end
        end
        for i = 2, n do
            if i ~= sel and i - 1 ~= sel then
                bb:paintRect(starts[i], y, Kit.BORDER, h, black)
            end
        end
        bb:paintBorder(x, y, w, h, Kit.BORDER, black, r)
        row:paintTo(bb, x, y)
    end
    return seg, { cells }
end

-- button(opts) -> a small rounded button (lib/bookshelf_chip_button) with the
-- popup's border and corner. Takes ChipButton.build's options.
function Kit.button(opts)
    opts.border = opts.border or Kit.BORDER
    opts.radius = opts.radius or Kit.RADIUS
    return require("lib/bookshelf_chip_button").build(opts)
end

-- wideTile(o) -> a rounded tile o.width wide: an icon then a label, centred.
--   o.icon (a symbols-font glyph), o.icon_face, o.text, o.face,
--   o.pad_v (default Space.px(16)), o.on_tap
function Kit.wideTile(o)
    local pad_v = o.pad_v or Space.px(16)
    local group = HorizontalGroup:new{ align = "center" }
    if o.icon then
        group[#group + 1] = TextWidget:new{ text = o.icon, face = o.icon_face,
            fgcolor = Blitbuffer.COLOR_BLACK }
        group[#group + 1] = HorizontalSpan:new{ width = Space.px(12) }
    end
    local used = 0
    for _i, wdg in ipairs(group) do used = used + wdg:getSize().w end
    group[#group + 1] = TextWidget:new{ text = o.text, face = o.face,
        fgcolor = Blitbuffer.COLOR_BLACK,
        max_width = o.width - 2 * Kit.BORDER - 2 * Space.px(12) - used }
    local h = group:getSize().h + 2 * pad_v + 2 * Kit.BORDER
    local frame = FrameContainer:new{
        bordersize = Kit.BORDER, radius = Kit.RADIUS, margin = 0, padding = 0,
        width = o.width, height = h,
        CenterContainer:new{
            dimen = Geom:new{ w = o.width - 2 * Kit.BORDER, h = h - 2 * Kit.BORDER },
            group,
        },
    }
    return Kit.tapCell(frame, o.width, h, o.on_tap)
end

return Kit
