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

-- tapCell(widget, w, h, on_tap, enabled, on_hold) -> widget as a w x h tap
-- target that inverts when the dpad focuses it. enabled == false swallows the
-- tap (not the hold).
function Kit.tapCell(widget, w, h, on_tap, enabled, on_hold)
    local cell = InputContainer:new{ dimen = Geom:new{ w = w, h = h }, widget }
    cell.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = cell.dimen } } }
    cell.onTap = function()
        if enabled ~= false and on_tap then on_tap() end
        return true
    end
    if on_hold then
        cell.ges_events.Hold = { GestureRange:new{ ges = "hold", range = cell.dimen } }
        cell.onHold = function() on_hold(); return true end
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

-- invertRounded(bb, x, y, w, h, r): invert a rounded box, leaving the
-- corners outside the radius as they were (a plain invertRect shows square
-- black corners past a rounded outline).
function Kit.invertRounded(bb, x, y, w, h, r)
    bb:invertRect(x, y, w, h)
    r = math.min(r or 0, math.floor(w / 2), math.floor(h / 2))
    for i = 0, r - 1 do
        local dy = r - i - 0.5
        local out = math.floor(r - math.sqrt(r * r - dy * dy) + 0.5)
        if out > 0 then
            bb:invertRect(x, y + i, out, 1)
            bb:invertRect(x + w - out, y + i, out, 1)
            bb:invertRect(x, y + h - 1 - i, out, 1)
            bb:invertRect(x + w - out, y + h - 1 - i, out, 1)
        end
    end
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
        bb:paintRoundedRect(x, y, w, h, Blitbuffer.COLOR_WHITE, r)
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

-- segmentedWrap(o) -> widget, focus_rows: Kit.segmented, split into as many
-- rows as it takes to fit o.max_w (each row its own rounded control), for a
-- choice with more options than one line holds (a picker's filter chips).
-- Takes Kit.segmented's options (sized to labels) plus o.max_w, o.gap
-- (between rows) and o.max_rows. Past max_rows the last cell is "More"
-- (o.more_label), which calls o.on_more(hidden_items); the active option is
-- always among the ones shown.
function Kit.segmentedWrap(o)
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan  = require("ui/widget/verticalspan")
    local pad_h = o.pad_h or Space.px(16)
    local function width(it)
        -- The bold (active) width, so a row can't overflow once picked.
        return TextWidget:new{ text = it.label or "", face = o.face, bold = true }:getSize().w
            + 2 * pad_h
    end
    -- pack(list, last_cap) -> rows, hidden: greedy rows; past max_rows the
    -- last row holds only last_cap (room left for More).
    local function pack(list, last_cap)
        local rows, row, row_w, hidden = {}, {}, 0, {}
        for _i, it in ipairs(list) do
            local w = width(it)
            local cap = (o.max_rows and #rows == o.max_rows - 1) and last_cap or o.max_w
            if #hidden > 0 then
                hidden[#hidden + 1] = it
            elseif #row > 0 and row_w + w > cap then
                if o.max_rows and #rows + 1 >= o.max_rows then
                    hidden[#hidden + 1] = it
                else
                    rows[#rows + 1], row, row_w = row, { it }, w
                end
            else
                row[#row + 1], row_w = it, row_w + w
            end
        end
        if #row > 0 then rows[#rows + 1] = row end
        return rows, hidden
    end
    local items = o.items
    local rows, hidden = pack(items, o.max_w)
    local more
    if #hidden > 0 and o.on_more then
        more = { key = "\0more", label = o.more_label or "More" }
        rows, hidden = pack(items, o.max_w - width(more))
        -- Keep the active option in sight: it takes the last shown place.
        local active_hidden
        for _i, it in ipairs(hidden) do if it.key == o.active then active_hidden = it end end
        if active_hidden and #rows > 0 then
            local shown = {}
            for _r, row in ipairs(rows) do for _i, it in ipairs(row) do shown[#shown + 1] = it end end
            local list = {}
            for i = 1, #shown - 1 do list[#list + 1] = shown[i] end
            list[#list + 1] = active_hidden
            for _i, it in ipairs(items) do
                local seen = it == active_hidden
                for _j, sh in ipairs(list) do if sh == it then seen = true end end
                if not seen then list[#list + 1] = it end
            end
            rows, hidden = pack(list, o.max_w - width(more))
        end
        local last = rows[#rows]
        last[#last + 1] = more
    end
    local function pick(key)
        if more and key == more.key then o.on_more(hidden) else o.on_pick(key) end
    end
    if #rows <= 1 then
        return Kit.segmented{ items = rows[1] or {}, active = o.active,
            face = o.face, pad_h = pad_h, pad_v = o.pad_v, on_pick = pick }
    end
    return Kit.segmentedGrid{ rows = rows, active = o.active, face = o.face,
        width = o.max_w, pad_h = pad_h, pad_v = o.pad_v, on_pick = pick }
end

-- segmentedGrid(o) -> widget, focus_rows: Kit.segmented over several rows
-- as ONE control: every row stretched to o.width, one rounded outline round
-- the lot, a line between rows (a wrapped bar of separate rows read as two
-- unconnected controls). Only the control's own corners are rounded.
--   o.rows { { {key=, label=}, ... }, ... }, o.active, o.on_pick, o.face,
--   o.width, o.pad_h, o.pad_v
function Kit.segmentedGrid(o)
    local pad_h = o.pad_h or Space.px(16)
    local pad_v = o.pad_v or Space.px(12)
    local W, B, r = o.width, Kit.BORDER, Kit.RADIUS
    local black, white = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
    local label_h = 0
    local built = {}
    for ri, items in ipairs(o.rows) do
        local labels, natural, sum = {}, {}, 0
        for i, it in ipairs(items) do
            local on = it.key == o.active
            labels[i] = TextWidget:new{ text = it.label or "", face = o.face, bold = on,
                fgcolor = on and white or black }
            natural[i] = labels[i]:getSize().w + 2 * pad_h
            sum = sum + natural[i]
            label_h = math.max(label_h, labels[i]:getSize().h)
        end
        -- Stretch the row to the full width, the slack shared out evenly.
        local n, extra = #items, math.max(0, W - sum)
        local each = math.floor(extra / n)
        local widths = {}
        for i = 1, n do widths[i] = natural[i] + each + ((i == n) and (extra - each * n) or 0) end
        built[ri] = { items = items, labels = labels, widths = widths }
    end
    local h = label_h + 2 * pad_v
    local VerticalGroup = require("ui/widget/verticalgroup")
    local vg, focus_rows, cells = VerticalGroup:new{ align = "left" }, {}, {}
    for ri, row in ipairs(built) do
        local hg, fr = HorizontalGroup:new{ align = "top" }, {}
        local cx = 0
        for i, it in ipairs(row.items) do
            local key, w = it.key, row.widths[i]
            local cell = Kit.tapCell(
                CenterContainer:new{ dimen = Geom:new{ w = w, h = h }, row.labels[i] },
                w, h, function()
                    if key ~= o.active and o.on_pick then o.on_pick(key) end
                end)
            hg[#hg + 1], fr[#fr + 1] = cell, cell
            cells[#cells + 1] = { x = cx, y = (ri - 1) * h, w = w, on = key == o.active,
                last = i == #row.items }
            cx = cx + w
        end
        vg[#vg + 1], focus_rows[#focus_rows + 1] = hg, fr
    end
    local H = h * #built
    local grid = WidgetContainer:new{ dimen = Geom:new{ w = W, h = H }, vg }
    function grid:paintTo(bb, x, y)
        self.dimen.x, self.dimen.y = x, y
        bb:paintRoundedRect(x, y, W, H, white, r)
        for _i, c in ipairs(cells) do
            if c.on then
                local cx, cy = x + c.x, y + c.y
                bb:paintRoundedRect(cx, cy, c.w, h, black, r)
                -- Square every corner that is not one of the control's own.
                local left, right = c.x == 0, c.x + c.w >= W
                local top, bottom = c.y == 0, c.y + h >= H
                if not (left and top) then bb:paintRect(cx, cy, r, r, black) end
                if not (right and top) then bb:paintRect(cx + c.w - r, cy, r, r, black) end
                if not (left and bottom) then bb:paintRect(cx, cy + h - r, r, r, black) end
                if not (right and bottom) then bb:paintRect(cx + c.w - r, cy + h - r, r, r, black) end
            end
        end
        for _i, c in ipairs(cells) do
            if not c.last then bb:paintRect(x + c.x + c.w, y + c.y, B, h, black) end
        end
        for ri = 1, #built - 1 do bb:paintRect(x, y + ri * h, W, B, black) end
        bb:paintBorder(x, y, W, H, B, black, r)
        vg:paintTo(bb, x, y)
    end
    return grid, focus_rows
end

-- card(o) -> a light grey card with a hairline shadow down and right: the
-- book popup's action cards and the start menu's module rows. Black when on.
--   o[1] the content, o.width/o.height (optional; else sized to content),
--   o.on, o.padding (default 0), o.padding_top..., o.radius (Kit.RADIUS),
--   o.background (Kit.STRIP_BG), o.outline (a heavy black outline: picked)
function Kit.card(o)
    local radius = o.radius or Kit.RADIUS
    local card = FrameContainer:new{
        bordersize = 0, margin = 0, radius = radius,
        padding = o.padding or 0,
        padding_top = o.padding_top, padding_bottom = o.padding_bottom,
        padding_left = o.padding_left, padding_right = o.padding_right,
        background = o.on and Blitbuffer.COLOR_BLACK or (o.background or Kit.STRIP_BG),
        width = o.width, height = o.height,
        o[1],
    }
    local s = Kit.shadowSize()
    function card:paintTo(bb, x, y)
        local sz = self:getSize()
        bb:paintRoundedRect(x + s, y + s, sz.w, sz.h, Kit.SHADOW, radius)
        FrameContainer.paintTo(self, bb, x, y)
        if o.outline then
            bb:paintBorder(x, y, sz.w, sz.h, Space.px(4), Blitbuffer.COLOR_BLACK, radius)
        end
    end
    return card
end

-- cardify(frame, o) -> frame as a Kit.card: no border, light grey (unless
-- o.keep_bg), the kit's corner and hairline shadow, and a heavy outline
-- when o.outline (the one in use). For a picker's own card builder.
function Kit.cardify(frame, o)
    o = o or {}
    frame.bordersize = 0
    frame.radius = Kit.RADIUS
    if not o.keep_bg then frame.background = Kit.STRIP_BG end
    local paint, s = frame.paintTo, Kit.shadowSize()
    function frame:paintTo(bb, x, y)
        local sz = self:getSize()
        bb:paintRoundedRect(x + s, y + s, sz.w, sz.h, Kit.SHADOW, Kit.RADIUS)
        paint(self, bb, x, y)
        if o.outline then
            bb:paintBorder(x, y, sz.w, sz.h, Space.px(4), Blitbuffer.COLOR_BLACK, Kit.RADIUS)
        end
    end
    return frame
end

-- hintText(text, font_size, width) -> grey secondary text: a hint or a
-- note, never a greyed-out button (a border says "tap me").
function Kit.hintText(text, font_size, width)
    local TextBoxWidget = require("ui/widget/textboxwidget")
    return TextBoxWidget:new{ text = text, width = width,
        face = require("ui/font"):getFace("cfont", math.max(10, (font_size or 20) - 3)),
        fgcolor = Blitbuffer.COLOR_DARK_GRAY }
end

-- button(opts) -> a small rounded button (lib/bookshelf_chip_button) with the
-- popup's border and corner. Takes ChipButton.build's options.
function Kit.button(opts)
    opts.border = opts.border or Kit.BORDER
    opts.radius = opts.radius or Kit.RADIUS
    return require("lib/bookshelf_chip_button").build(opts)
end

-- headerButton(o) -> a tab's own action (Edit, Refresh, Choose from device):
-- a small rounded button, label then icon, the same height as a source
-- switch, so every tab's top row holds the same control. Tabs put these at
-- the right end of their first row (headerRow).
--   o.text, o.icon (a symbols-font glyph, optional), o.icon_size (its face
--   size, default font_size - 2), o.font_size (the popup's), o.inverted
--   (busy or on), o.enabled (false: greyed), o.on_tap
function Kit.headerButton(o)
    local face = Kit.sourceFace(o.font_size)
    local probe = TextWidget:new{ text = "Hg", face = face }
    return Kit.button{
        text       = o.text,
        face       = face,
        icon_glyph = o.icon,
        icon_face  = o.icon and require("ui/font"):getFace("symbols",
            o.icon_size or math.max(10, (o.font_size or 20) - 2)) or nil,
        icon_after = true,
        height     = probe:getSize().h + 2 * Kit.SOURCE_PAD_V,
        inverted   = o.inverted or false,
        enabled    = o.enabled,
        on_tap     = o.on_tap,
    }
end

-- iconButton(o) -> headerButton with only an icon, the same height as the
-- labelled ones (icon_size = font_size; a bigger glyph grows the button).
function Kit.iconButton(o)
    return Kit.headerButton{ icon = o.icon, icon_size = o.font_size or 20,
        font_size = o.font_size, inverted = o.inverted, enabled = o.enabled, on_tap = o.on_tap }
end

-- The light grey strip a tab's controls sit in, edge to edge under the tabs.
Kit.STRIP_BG = Blitbuffer.COLOR_GRAY_E

-- The hairline shadow under a strip and the action cards: the light grey
-- alone is faint on e-ink with no border.
Kit.SHADOW = Blitbuffer.COLOR_GRAY
function Kit.shadowSize() return Space.px(1) end

-- withShadow(strip, w) -> the strip with a shadow line under it, w wide.
function Kit.withShadow(strip, w)
    local VerticalGroup = require("ui/widget/verticalgroup")
    local LineWidget    = require("ui/widget/linewidget")
    return VerticalGroup:new{ align = "left", strip,
        LineWidget:new{ background = Kit.SHADOW,
            dimen = Geom:new{ w = w, h = Kit.shadowSize() } } }
end

-- headerRow(o) -> a tab's controls strip: o.left (a source switch; optional)
-- at the content edge, o.buttons (headerButtons) at the right end, on the
-- grey strip the tab's full width. Stacks the two when they don't fit side
-- by side.
--   o.width (the tab's), o.inset (its side padding), o.pad_top, o.pad_bottom,
--   o.top (a full-width line above the row, e.g. a picker's search box)
function Kit.headerRow(o)
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan  = require("ui/widget/verticalspan")
    local content_w = o.width - 2 * o.inset
    local btns = HorizontalGroup:new{ align = "center" }
    for i, b in ipairs(o.buttons or {}) do
        if i > 1 then btns[#btns + 1] = HorizontalSpan:new{ width = Space.px(10) } end
        btns[#btns + 1] = b
    end
    local bw = 0
    for _i, wdg in ipairs(btns) do bw = bw + wdg:getSize().w end
    local lw = o.left and o.left:getSize().w or 0
    local row
    if not o.left and #btns == 0 then
        row = nil
    elseif o.left and #btns > 0 and lw + Space.px(10) + bw > content_w then
        row = VerticalGroup:new{ align = "left",
            o.left, VerticalSpan:new{ width = Space.px(8) }, btns }
    else
        row = HorizontalGroup:new{ align = "center" }
        if o.left then row[#row + 1] = o.left end
        row[#row + 1] = HorizontalSpan:new{ width = math.max(0, content_w - lw - bw) }
        row[#row + 1] = btns
    end
    if o.top then
        row = row and VerticalGroup:new{ align = "left",
            o.top, VerticalSpan:new{ width = Space.px(10) }, row } or o.top
    end
    return Kit.withShadow(FrameContainer:new{
        bordersize = 0, margin = 0, width = o.width,
        background = Kit.STRIP_BG,
        padding_left = o.inset, padding_right = o.inset,
        padding_top = o.pad_top or Space.px(10), padding_bottom = o.pad_bottom or Space.px(10),
        row,
    }, o.width)
end

return Kit
