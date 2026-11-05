-- bookshelf_popup_kit.lua (see STYLE.md for how the pieces are used)
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
    return require("lib/bookshelf_fonts"):getFace("cfont", math.max(10, (font_size or 20) - 2))
end

-- tapCell(widget, w, h, on_tap, enabled, on_hold, instant) -> widget as a
-- w x h tap target that shows the keys' ring when they focus it. enabled == false
-- swallows the tap (not the hold). instant: a choice on a page that is drawn
-- again to show it (a sort key, an option), so no pressed frame first: that
-- was one more state for every tap to pass through (maintainer, PW5).
function Kit.tapCell(widget, w, h, on_tap, enabled, on_hold, instant)
    local cell = InputContainer:new{ dimen = Geom:new{ w = w, h = h }, widget }
    -- As a stock Button's: the keys pass over one that can't act (Kit.keyFocus).
    cell.enabled = enabled ~= false
    cell.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = cell.dimen } } }
    cell.onTap = function(_self, _arg, ges)
        -- Only a tap inside it. A card that is a tap cell itself re-sends its
        -- matched tap as "Tap" to its children first, and a cell inside it
        -- (a sort level's direction switch) took every tap on the card
        -- (maintainer, PW5). Left alone, the tap goes on to the card.
        local p, d = ges and ges.pos, cell.dimen
        if p and p.x and d and d.x and (p.x < d.x or p.x >= d.x + d.w
                or p.y < d.y or p.y >= d.y + d.h) then
            return false
        end
        if enabled ~= false and on_tap then
            if instant then on_tap()
            else Kit.pressThen(cell, Kit.findCard(widget), on_tap) end
        end
        return true
    end
    if on_hold then
        cell.ges_events.Hold = { GestureRange:new{ ges = "hold", range = cell.dimen } }
        cell.onHold = function() on_hold(); return true end
    end
    cell._focused = false
    function cell:paintTo(bb, x, y)
        InputContainer.paintTo(self, bb, x, y)
        if self._focused then
            -- A ring, not the whole cell inverted: inverted, a focused cell
            -- looked exactly like a selected one (black means "on"), and a
            -- tab strip showed two tabs picked. The ring inverts what is
            -- under it, so it shows on a black (selected) cell as on a white
            -- one. focus_radius: round it to a rounded card's corner.
            -- focus_inset: set it in from the cell's edge, clear of an
            -- outline drawn round the cell (a segmented control's).
            local i = self.focus_inset or 0
            Kit.invertRing(bb, x + i, y + i, w - 2 * i, h - 2 * i, Kit.focusWidth(),
                self.focus_radius or 0)
        end
    end
    cell.onFocus = function() cell._focused = true; return true end
    cell.onUnfocus = function() cell._focused = false; return true end
    return cell
end

-- invertRounded(bb, x, y, w, h, r, square_bottom): invert a rounded box,
-- leaving the corners outside the radius as they were (a plain invertRect
-- shows square black corners past a rounded outline). square_bottom: only
-- the top corners are rounded (a button flush with the screen's bottom).
function Kit.invertRounded(bb, x, y, w, h, r, square_bottom)
    bb:invertRect(x, y, w, h)
    r = math.min(r or 0, math.floor(w / 2), math.floor(h / 2))
    for i = 0, r - 1 do
        local dy = r - i - 0.5
        local out = math.floor(r - math.sqrt(r * r - dy * dy) + 0.5)
        if out > 0 then
            bb:invertRect(x, y + i, out, 1)
            bb:invertRect(x + w - out, y + i, out, 1)
            if not square_bottom then
                bb:invertRect(x, y + h - 1 - i, out, 1)
                bb:invertRect(x + w - out, y + h - 1 - i, out, 1)
            end
        end
    end
end

-- focusWidth() -> the keys' focus ring's width.
function Kit.focusWidth() return Space.px(4) end

-- invertRing(bb, x, y, w, h, t, r, square_bottom): invert a ring t wide
-- inside the box, its corners rounded to r: the whole box inverted, then the
-- part inside the ring inverted back, so only the ring changes.
function Kit.invertRing(bb, x, y, w, h, t, r, square_bottom)
    if w <= 2 * t or h <= 2 * t then return bb:invertRect(x, y, w, h) end
    Kit.invertRounded(bb, x, y, w, h, r, square_bottom)
    -- Open at the bottom, as the button is (ChipFrame): the inside runs to
    -- the bottom edge.
    Kit.invertRounded(bb, x + t, y + t, w - 2 * t, h - (square_bottom and t or 2 * t),
        math.max(0, r - t), square_bottom)
end

-- ringFocus(btn, inset, radius) -> btn: a stock KOReader Button that shows
-- the keys' focus as the kit's ring, set in by inset with corners rounded to
-- radius, instead of inverting the whole button: inverted, a focused Cancel
-- in a footer looked like one that is on (black means "on").
function Kit.ringFocus(btn, inset, radius)
    local focused = false
    local paint = btn.paintTo
    function btn:paintTo(bb, x, y)
        paint(self, bb, x, y)
        if focused then
            -- inset: a number, or { x, y } for a short, wide button (a
            -- footer's: clear of the frame's corners, clear of the label).
            local sz = self:getSize()
            local ix = type(inset) == "table" and inset[1] or inset or 0
            local iy = type(inset) == "table" and inset[2] or inset or 0
            Kit.invertRing(bb, x + ix, y + iy, sz.w - 2 * ix, sz.h - 2 * iy, Kit.focusWidth(), radius or 0)
        end
    end
    btn.onFocus = function(self)
        if self.no_focus then return end
        focused = true
        return true
    end
    btn.onUnfocus = function(self)
        if self.no_focus then return end
        focused = false
        return true
    end
    return btn
end

-- ringFocusTable(bt, inset, radius) -> bt: ringFocus on every button of a
-- stock ButtonTable (its rows of buttons).
function Kit.ringFocusTable(bt, inset, radius)
    -- buttons_layout: set whether or not the device has a D-pad (layout
    -- only with one).
    for _i, row in ipairs(bt.buttons_layout or bt.layout or {}) do
        for _j, b in ipairs(row) do Kit.ringFocus(b, inset, radius) end
    end
    return bt
end

-- quietFocus(fm) -> fm: a FocusManager (a KOReader ButtonTable is one) whose
-- buttons an outer FocusManager keys. Events go to children before their
-- parent, so left alone the inner one took every arrow (FocusMove) and could
-- move nowhere, and pressed its own button on Press: no key reached the
-- outer one (maintainer, desktop: the shelf editor took no keys). Its key
-- bindings and its focus handlers stand down.
function Kit.quietFocus(fm)
    fm.key_events = {}
    local function pass() return false end
    fm.onFocusMove, fm.onFocusHalfMove = pass, pass
    fm.onFocusNext, fm.onFocusPrevious = pass, pass
    fm.onPress, fm.onHold = pass, pass
    return fm
end

-- keyFocus(fm, state, seed_y): the keys on a FocusManager our popup rebuilds
-- (STYLE.md): the cursor seeded on row seed_y (the first thing a reader
-- would reach for, not the strip above it), hidden until the first key,
-- which shows it there rather than moving it; after that each key moves it.
-- state lives as long as the popup, so a rebuild (every change rebuilds)
-- keeps the cursor where it was and showing: state.shown, state.sel;
-- state.page names the page it was on, and a new page seeds afresh.
function Kit.keyFocus(fm, state, seed_y, page)
    if not (fm and fm.layout and #fm.layout > 0) then return end
    -- A control that can't act (greyed) is no stop for the keys: out of the
    -- layout, and a row with nothing left goes too (maintainer). seed_y
    -- names a row of the layout as given. at[y][x] is where each control of
    -- the given layout went (nil: greyed), back[ky][kx] where each kept one
    -- came from: the cursor is kept by its place in the layout as given, so
    -- a neighbour greying does not shift it onto another (the slider's -5
    -- greying at its minimum put it on +10).
    local kept, new_seed, at, back, len = {}, nil, {}, {}, {}
    for y, row in ipairs(fm.layout) do
        local r, b = {}, {}
        at[y], len[y] = {}, #row
        for x, item in ipairs(row) do
            if item.enabled ~= false then
                r[#r + 1] = item
                b[#r] = { y = y, x = x }
                at[y][x] = { x = #r }
            end
        end
        if #r > 0 then
            kept[#kept + 1] = r
            back[#kept] = b
            for _x, a in pairs(at[y]) do a.y = #kept end
            if not new_seed and y >= (seed_y or 1) then new_seed = #kept end
        end
    end
    if #kept == 0 then return end
    fm.layout, seed_y = kept, new_seed or 1
    local FocusManager = require("ui/widget/focusmanager")
    local UIManager = require("ui/uimanager")
    if state.page ~= page then state.page, state.sel = page, nil end
    local x, y = 1, seed_y or 1
    local sel = state.sel
    if sel then
        -- Where it was, else the nearest live control on its row, else the
        -- first row at or after it that has one.
        local function nearest(oy, ox)
            local row = at[oy]
            if not row then return nil end
            if row[ox] then return row[ox] end
            for d = 1, len[oy] do
                local hit = row[ox + d] or row[ox - d]
                if hit then return hit end
            end
        end
        local hit = nearest(sel.y, sel.x)
        for oy = sel.y + 1, #at do
            if hit then break end
            hit = nearest(oy, 1)
        end
        if hit then x, y = hit.x, hit.y else y = #kept end
    end
    y = math.max(1, math.min(#fm.layout, y))
    x = math.max(1, math.min(#fm.layout[y], x))
    fm.selected = { x = x, y = y }
    -- The ring shown at the first key: the cursor's own box (the focused
    -- widget's), not the whole of a popup that spans the screen.
    local function repaint()
        local target = fm.show_parent or fm
        local row = fm.layout[fm.selected.y]
        local w = row and row[fm.selected.x]
        local d = w and w.dimen
        if d and d.x then
            UIManager:setDirty(target, function() return "ui", d end)
        else
            UIManager:setDirty(target, "ui")
        end
    end
    local move = fm.onFocusMove
    function fm:onFocusMove(args)
        if not state.shown then
            state.shown = true
            self:moveFocusTo(self.selected.x, self.selected.y, FocusManager.FORCED_FOCUS)
            repaint()
            return true
        end
        local r = move(self, args)
        local from = back[self.selected.y] and back[self.selected.y][self.selected.x]
        if from then state.sel = { x = from.x, y = from.y } end
        return r
    end
    -- Rebuilt with the cursor already showing: show it again where it was.
    if state.shown then fm:moveFocusTo(x, y, FocusManager.FORCED_FOCUS) end
end

-- findCard(widget) -> the kit card in widget (itself, or a few levels in),
-- or nil: what a tap shows pressed.
function Kit.findCard(widget, depth)
    depth = depth or 0
    if type(widget) ~= "table" or depth > 4 then return nil end
    if widget._kit_card then return widget end
    for i = 1, #widget do
        local c = Kit.findCard(widget[i], depth + 1)
        if c then return c end
    end
    return nil
end

-- segmented(o) -> widget, focus_rows: one rounded control split into cells,
-- the active cell filled black with a bold white label. It draws its own
-- outline and dividers.
--   o.items   { { key=, label= }, ... }
--   o.active  the key shown selected (may match none)
--   o.on_pick function(key), fired for a tap on an inactive cell
--   o.allow_none  a tap on the active cell un-picks it: on_pick(nil)
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
    -- Not mirrored in a right-to-left UI: the black of the one chosen and the
    -- dividers are painted from the left by their own offsets, and under a
    -- mirrored row they fell on another cell (as the shelf bar's chips, 559).
    local row = HorizontalGroup:new{ align = "top", allow_mirroring = false }
    local cells, sel = {}, nil
    for i, it in ipairs(items) do
        if it.key == o.active then sel = i end
        local key = it.key
        local cell = Kit.tapCell(
            CenterContainer:new{ dimen = Geom:new{ w = widths[i], h = h }, labels[i] },
            widths[i], h, function()
                if not o.on_pick then return end
                if key ~= o.active then o.on_pick(key)
                elseif o.allow_none then o.on_pick(nil) end
            end)
        -- The keys' ring set in from the cell, rounded: on the cell's edge
        -- its square corners stuck out past the control's rounded ends and
        -- ran over the outline and dividers (maintainer).
        cell.focus_inset = Kit.BORDER + Space.px(3)
        cell.focus_radius = math.max(Space.px(4), Kit.RADIUS - cell.focus_inset)
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
-- Takes Kit.segmented's options (sized to labels) plus o.max_w and
-- o.max_rows. Past max_rows the last cell is "More"
-- (o.more_label), which calls o.on_more(hidden_items); the active option is
-- always among the ones shown.
function Kit.segmentedWrap(o)
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
    -- Two rows with everything shown: split them evenly (as many options
    -- on each, then as near the same width), not a full row over a stub.
    if #rows == 2 and #hidden == 0 then
        local n, best, best_i = #items, nil, nil
        for i = 1, n - 1 do
            local w1, w2 = 0, 0
            for j = 1, n do
                if j <= i then w1 = w1 + width(items[j]) else w2 = w2 + width(items[j]) end
            end
            if w1 <= o.max_w and w2 <= o.max_w then
                local score = math.abs(2 * i - n) * o.max_w + math.abs(w1 - w2)
                if not best or score < best then best, best_i = score, i end
            end
        end
        if best_i then
            local r1, r2 = {}, {}
            for j = 1, n do
                if j <= best_i then r1[#r1 + 1] = items[j] else r2[#r2 + 1] = items[j] end
            end
            rows = { r1, r2 }
        end
    end
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
        if #rows == 0 then rows[1] = {} end
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
        -- Painted by its own offsets, as Kit.segmented: not mirrored.
        local hg, fr = HorizontalGroup:new{ align = "top", allow_mirroring = false }, {}
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

-- paintCard(frame, bb, x, y, outline): a kit card. Raised: a hairline
-- shadow down and right. Pressed (frame._pressed, while its tap's action
-- runs): the shadow flips inside, along the top and left, and nothing else
-- changes (maintainer), so a slow action shows it was taken at once.
local function paintCard(frame, bb, x, y, outline)
    -- A set width/height is what FrameContainer fills; getSize is only the
    -- content's measure, so a card stretched to its row had a short shadow.
    local sz = frame:getSize()
    sz = { w = frame.width or sz.w, h = frame.height or sz.h }
    local r, s = Kit.RADIUS, Kit.shadowSize()
    if frame._pressed then
        local d = 2 * s
        local bg = frame.background
        bb:paintRoundedRect(x, y, sz.w, sz.h, Kit.SHADOW, r)
        require("lib/bookshelf_color").paintRoundedRect(bb, x + d, y + d, sz.w - d, sz.h - d, bg, r)
        frame.background = nil
        FrameContainer.paintTo(frame, bb, x, y)
        frame.background = bg
    else
        bb:paintRoundedRect(x + s, y + s, sz.w, sz.h, Kit.SHADOW, r)
        FrameContainer.paintTo(frame, bb, x, y)
    end
    if outline then
        bb:paintBorder(x, y, sz.w, sz.h, Space.px(4), Blitbuffer.COLOR_BLACK, r)
    end
end

-- waitForPanel(): after a forceRePaint, wait until the panel has taken that
-- refresh, so a paint straight after cannot get into it. Where the screen can
-- say (Kindles, MediaTek Kobos) that is milliseconds, not the refresh's whole
-- run; elsewhere the 1 ms yield KOReader's Button uses.
function Kit.waitForPanel()
    local UIManager = require("ui/uimanager")
    local Screen = require("device").screen
    local wait = Screen and Screen.mech_wait_update_submission
    if not (wait and Screen.marker and Screen.marker ~= 0
            and pcall(wait, Screen, Screen.marker)) then
        UIManager:yieldToEPDC()
    end
end

-- pressThen(cell, card, action): show card pressed at once (repainted and
-- refreshed in place), run action on the next tick, then let it up. Without
-- dimen yet (not painted, or headless), just the action.
function Kit.pressThen(cell, card, action)
    if not action then return end
    local d = cell and cell.dimen
    if not (card and d and d.x) then return action() end
    local UIManager = require("ui/uimanager")
    local box = Geom:new{ x = d.x, y = d.y, w = d.w + 2, h = d.h + 2 }
    card._pressed = true
    UIManager:widgetRepaint(cell, d.x, d.y)
    -- "ui", not "fast": fast is black and white only on e-ink, which turned
    -- a grey card white and a black button's rounded corners jagged
    -- (maintainer, PW5).
    UIManager:setDirty(nil, "ui", box)
    UIManager:forceRePaint()
    -- Let the panel take the pressed card before the action paints: closing
    -- the window (the editor's Modules card) otherwise put the shelf behind
    -- into the card's refresh now and then (maintainer, PW5). KOReader's
    -- Button yields 1 ms; on a MediaTek Kindle (the PW5) a refresh is sent
    -- without waiting for the panel to take it, and the close wrote the
    -- shelf back 20 ms later. Where the screen can wait for that (Kindles,
    -- MediaTek Kobos), wait: milliseconds, not the refresh's whole run.
    Kit.waitForPanel()
    local top = UIManager:getTopmostVisibleWidget()
    UIManager:tickAfterNext(function()
        action()
        card._pressed = false
        -- Let it up while its window is still open, also when the action
        -- put something over it (a note, a menu): the windows above repaint
        -- with it. Only the top one before left the layout editor's d-pad
        -- and Settings black on the PW5 (maintainer).
        if top and UIManager:isWidgetShown(top) then
            UIManager:setDirty(top, "ui", box)
        end
    end)
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
    card._kit_card = true
    function card:paintTo(bb, x, y) paintCard(self, bb, x, y, o.outline) end
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
    frame._kit_card = true
    function frame:paintTo(bb, x, y) paintCard(self, bb, x, y, o.outline) end
    return frame
end

-- heading(text, font_size, fgcolor) -> a section heading: grey, bold, upper
-- case, a step smaller than the body, no line (the book popup's
-- _sectionHeadingBar). fgcolor: on a card, Kit.headInk's.
function Kit.heading(text, font_size, fgcolor)
    local BFont = require("lib/bookshelf_fonts")
    local face, bold = BFont:getFace("cfont", math.max(10, (font_size or 20) - 4), { bold = true })
    return TextWidget:new{ text = require("lib/bookshelf_text_segments").upper(text),
        face = face, bold = bold, fgcolor = fgcolor or Blitbuffer.COLOR_DARK_GRAY }
end

-- headInk(ink) -> a card's heading colour for the card's own ink: on a black
-- card (white ink) light grey, on a grey one the darker grey that reads on
-- it (dark grey on a black card could not be seen, and on the grey was
-- faint); a greyed card's grey as it is.
function Kit.headInk(ink)
    -- `not ink`: a Color8 raises when compared with nil.
    if not ink or ink == Blitbuffer.COLOR_BLACK then return Kit.DIM_ON_GREY end
    if ink == Blitbuffer.COLOR_WHITE then return Blitbuffer.COLOR_LIGHT_GRAY end
    return ink
end

-- iconHeading(glyph, text, font_size, ink) -> a card's heading with its
-- icon before it, on a line of their own, so the value under them has the
-- card's whole width (maintainer). glyph nil: the heading alone.
function Kit.iconHeading(glyph, text, font_size, ink)
    local head = Kit.heading(text, font_size, Kit.headInk(ink))
    if not glyph then return head end
    local icon = TextWidget:new{ text = glyph,
        face = require("ui/font"):getFace("symbols", math.max(10, (font_size or 20) - 2)),
        fgcolor = ink or Blitbuffer.COLOR_BLACK }
    return HorizontalGroup:new{ align = "center", icon,
        HorizontalSpan:new{ width = Space.px(8) }, head }
end

-- hintText(text, font_size, width, align, o) -> grey secondary text: a hint
-- or a note, never a greyed-out button (a border says "tap me").
-- width: the box it wraps in (else TextBoxWidget's default, 400 at 160 dpi,
-- whatever the room); align: "center" to centre it in that box.
-- o.face: a face of its own (else a step under font_size); o.bg: the grey
-- strip or card it sits on, which takes the darker DIM_ON_GREY.
function Kit.hintText(text, font_size, width, align, o)
    o = o or {}
    local TextBoxWidget = require("ui/widget/textboxwidget")
    return TextBoxWidget:new{ text = text, width = width, alignment = align,
        face = o.face or require("lib/bookshelf_fonts"):getFace("cfont", math.max(10, (font_size or 20) - 3)),
        fgcolor = o.bg and Kit.DIM_ON_GREY or Blitbuffer.COLOR_DARK_GRAY,
        bgcolor = o.bg }
end

-- footerRow(actions, w, o) -> widget, btns: a popup's footer row (STYLE.md):
-- equal stock Buttons edge to edge under a full-width rule, thin dividers
-- their full height, the end buttons rounded as the frame is (o.radius; not
-- a nil background: a Button's tap feedback inverts it), the keys' ring in
-- each rather than the button inverted. actions { { text, primary, enabled,
-- callback } }; btns, left to right, for the keys. PageDialog's and
-- LibraryModal's footers.
-- buttonFont(size, bold) -> { face, size, bold }: a stock Button's font
-- fields (text_font_face/size/bold) for the Bookshelf UI font, by the name
-- KOReader's Font resolves (the face's orig_font).
function Kit.buttonFont(size, bold)
    local face, faux = require("lib/bookshelf_fonts"):getFace("cfont", size, { bold = bold })
    return { face = (face and face.orig_font) or "cfont", size = (face and face.orig_size) or size,
             bold = faux and true or false }
end

-- uiFontButtons(rows) -> rows: a stock ButtonTable's rows, each button in
-- the Bookshelf UI font (font_face/size/bold), in the look ButtonTable
-- gives them (cfont, 20, bold), where the entry sets none of its own.
function Kit.uiFontButtons(rows)
    local ff = Kit.buttonFont(20, true)
    for _i, row in ipairs(rows or {}) do
        for _j, b in ipairs(row) do
            if b.font_face == nil then
                b.font_face, b.font_size, b.font_bold = ff.face, ff.size, ff.bold
            end
        end
    end
    return rows
end

function Kit.footerRow(actions, w, o)
    o = o or {}
    local Button          = require("ui/widget/button")
    local LineWidget      = require("ui/widget/linewidget")
    local VerticalGroup   = require("ui/widget/verticalgroup")
    local Size            = require("ui/size")
    local n = #actions
    local each = math.floor(w / n)
    local hg = HorizontalGroup:new{ align = "center" }
    local btns = {}
    -- KOReader's Button takes its font by name, not a face: the face this
    -- passed was ignored, and the footers were KOReader's cfont, 20, bold.
    -- That look, in the UI font (Kit.buttonFont).
    local ff = Kit.buttonFont(20, true)
    for i, a in ipairs(actions) do
        local enabled = a.enabled ~= false
        local btn = Button:new{
            text = a.text,
            text_font_face = ff.face, text_font_size = ff.size, text_font_bold = ff.bold,
            bordersize = 0, radius = 0, padding_v = Space.px(12),
            width = (i == n) and (w - each * (n - 1)) or each,
            enabled = enabled,
            callback = function() if enabled then a.callback() end end,
            show_parent = o.show_parent,
        }
        if btn.frame then btn.frame.radius = o.radius or Space.radius.window end
        Kit.ringFocus(btn, { Space.px(10), Space.px(4) }, Kit.RADIUS)
        if i > 1 then
            hg[#hg + 1] = LineWidget:new{ background = Blitbuffer.COLOR_DARK_GRAY,
                dimen = Geom:new{ w = Size.line.thin, h = btn:getSize().h } }
        end
        hg[#hg + 1] = btn
        btns[#btns + 1] = btn
    end
    return VerticalGroup:new{ align = "left",
        LineWidget:new{ background = Blitbuffer.COLOR_DARK_GRAY,
            dimen = Geom:new{ w = w, h = Size.line.thin } },
        hg }, btns
end

-- The steppers' minus and plus: the symbols font's pair (U+F068, U+F44D),
-- one width, where the text minus ran wider than its +.
Kit.MINUS, Kit.PLUS = "\xEF\x81\xA8", "\xEF\x91\x8D"

-- button(opts) -> a small rounded button (lib/bookshelf_chip_button) with the
-- popup's border and corner. Takes ChipButton.build's options, and
-- opts.card: a grey card with no border (STYLE.md: it nudges a value or
-- opens a thing) rather than an outline.
function Kit.button(opts)
    local card = opts.card
    opts.card = nil
    if card then opts.border = 0 end
    opts.border = opts.border or Kit.BORDER
    opts.radius = opts.radius or Kit.RADIUS
    local btn = require("lib/bookshelf_chip_button").build(opts)
    if card then Kit.cardify(btn[1]) end
    return btn
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
-- Secondary text (a summary, a description, a hint) on a grey card or
-- strip: dark grey (0x88) on 0xEE was too faint to read (maintainer).
Kit.DIM_ON_GREY = Blitbuffer.COLOR_GRAY_5

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

-- iconTitle(title_bar, title) -> title_bar: a stock TitleBar's text swapped
-- for the title drawn as the shelf menu draws a shelf's name, its
-- [icon=NAME] pictures and icon glyphs among the text, in the bar's own
-- font. A title with no picture is left as TitleBar made it. A shelf named
-- with a picture showed the markup itself in the shelf editor (PW5).
function Kit.iconTitle(title_bar, title)
    if type(title) ~= "string" or not title:find("[icon=", 1, true) then return title_bar end
    local old = title_bar and title_bar.title_widget
    if not (old and old.face) then return title_bar end
    local ok, label = pcall(function()
        return require("lib/bookshelf_chip_bar").buildLabel(title, old.face.orig_size or 20,
            old.max_width or math.floor(title_bar.width * 0.7), Blitbuffer.COLOR_BLACK, old.face)
    end)
    if not (ok and label) then return title_bar end
    for _i, group in ipairs({ title_bar.title_group, title_bar.inner_title_group }) do
        for i, child in ipairs(group) do
            if child == old then
                group[i] = label
                group:resetLayout()
            end
        end
    end
    title_bar.title_widget = label
    -- The text's own font and baseline, for what lines up with it (backLabel).
    title_bar._text_face, title_bar._text_baseline = old.face, old:getBaseline()
    old:free()
    return title_bar
end

-- titleFace() -> a title bar's font: the Bookshelf UI font's bold at the size
-- KOReader's own title bars use (x_smalltfont, 22), so a menu's title is in
-- the same typeface as the rest of it (maintainer). Follow mode: KOReader's.
function Kit.titleFace()
    return (require("lib/bookshelf_fonts"):getFace("x_smalltfont", 22))
end

-- centreTitle(title_bar) -> title_bar: a stock TitleBar's title with its
-- capitals in the middle of the bar, between its top and its bottom line,
-- where its icons are. TitleBar sets the text by KOReader's font's baseline:
-- in another font, or as a row with a shelf's picture, it sat low
-- (maintainer). The bar's height stays as TitleBar made it.
function Kit.centreTitle(title_bar)
    local tw = title_bar and title_bar.title_widget
    local group = title_bar and title_bar.title_group
    if not (tw and group and group[1] and group[1].width and title_bar.dimen) then return title_bar end
    -- A plain title's capitals centred in its own box (a picture row's are).
    if not title_bar._text_face then require("lib/bookshelf_cap_centre").centre(tw) end
    local Size = require("ui/size")
    local line = title_bar.with_bottom_line and Size.line.thick or 0
    group[1].width = math.max(0, math.floor((title_bar.dimen.h - line - tw:getSize().h) / 2))
    group:resetLayout()
    -- The chevron and the X on the same line: TitleBar puts them at its
    -- padding, 2 px above the text's middle on a PW5 (maintainer). An
    -- aligned child ignores an offset, so they take a place of their own;
    -- not in a mirrored layout, where OverlapGroup flips an offset per paint.
    local mid = group[1].width + math.floor(tw:getSize().h / 2)
    if not require("ui/bidi").mirroredUILayout() then
        for _i, btn in ipairs({ title_bar.left_button, title_bar.right_button }) do
            local pad = title_bar.button_padding or 0
            local dy = mid - (pad + math.floor((btn and btn.height or 0) / 2))
            if btn and dy ~= 0 then
                local x = (btn == title_bar.right_button) and (title_bar.width - btn:getSize().w) or 0
                btn.overlap_align = nil
                btn.overlap_offset = { x, dy }
            end
        end
    end
    return title_bar
end

-- backLabel(title_bar) -> title_bar: "Back" beside a stock TitleBar's back
-- chevron, where it clears the centred title with padding; nothing where
-- it would crowd it. The chevron alone was easy to miss (maintainer). A tap
-- on it goes back as the chevron does; where the chevron's own tap zone
-- reaches over it, the chevron takes the tap (one back, not two).
function Kit.backLabel(title_bar)
    local btn = title_bar and title_bar.left_button
    local tw = title_bar and title_bar.title_widget
    local face = tw and (tw.face or title_bar._text_face)
    if not (btn and tw and tw.getSize and face) then return title_bar end
    local _ = require("lib/bookshelf_i18n").gettext
    -- The title's size, not its bold (maintainer): a word beside the
    -- chevron, not a second title.
    local regular = require("lib/bookshelf_fonts"):getFace("cfont", face.orig_size or 20)
    local label = TextWidget:new{ text = _("Back"), face = regular,
        fgcolor = Blitbuffer.COLOR_BLACK }
    local pad = title_bar.button_padding or Space.px(11)
    local x = pad + (btn.width or 0) + Space.px(4)
    local lw = label:getSize().w
    local title_left = math.floor((title_bar.width - tw:getSize().w) / 2)
    local gap = Space.px(24)
    if x + lw + gap > title_left then
        label:free()
        return title_bar
    end
    -- On the title's baseline: the title sits under the bar's top padding
    -- (its title_group's first span).
    local group = title_bar.title_group
    local top = (group and group[1] and group[1].width) or 0
    -- The title's capitals are centred in its box (centreTitle; a picture
    -- row's always are): the label's, centred on that box, line up with them.
    require("lib/bookshelf_cap_centre").centre(label)
    local y = top + math.floor((tw:getSize().h - label:getSize().h) / 2)
    local cell = InputContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = lw + Space.px(12), h = label:getSize().h },
        label,
    }
    cell.ges_events = { TapBack = { GestureRange:new{ ges = "tap",
        range = function() return cell.dimen end } } }
    function cell:onTapBack()
        if title_bar.left_icon_tap_callback then title_bar.left_icon_tap_callback() end
        return true
    end
    cell.overlap_offset = { x, y }
    table.insert(title_bar, cell)
    return title_bar
end

return Kit
