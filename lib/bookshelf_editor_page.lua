-- bookshelf_editor_page.lua (see STYLE.md)
-- The shelf editor's pages (Sort, Source, Shelf style, Filters, Face out) as
-- data: a page is a list of blocks, and this lays them out in the popup
-- style, so a page says what it holds and how it looks stays in one place.
-- Page.toButtons flattens the same blocks to a ButtonDialog's rows, for when
-- the editor is not up to host the page (tests, a caller outside it).
--
-- Blocks ({ type = ..., ... }):
--   summary   text: what the shelf will do, in a sentence (the strip's lead)
--   heading   text, tag (optional: a word in a badge at the right, OR)
--   hint      text: grey
--   chips     items { {text, icon, on, enabled, callback} }: cards sized to
--             their labels (icon: a symbols-font glyph before it), wrapping;
--             the one(s) on are black
--   segmented label (optional), items { {key, label} }, active, on_pick(key),
--             allow_none (a tap on the active one un-picks it): label at the
--             left, the control at the right (full width with no label)
--   stepper   label, value (text), on_dec, on_inc: label, then  -  value  +
--   slider    label (optional), value, min, max, step, default, format(v),
--             on_change(v), big, big_label: the label and the value, then
--             -  track  +  (-10 and +10 cards with big), with
--             the range's ends and Default ticked under it (bookshelf_slider)
--   row       label, value, icon, callback, on, on_clear, half: a card reading
--             "label   value >"; on (a setting made) turns it black and
--             on_clear adds a cross beside it; half rows pair up two a line
--   option    text, desc, icon, on, callback, links { {text, on, callback} },
--             half: a card with a title and a grey line saying what it does,
--             and small buttons at its right (Pick one >)
--   pills     items { {label, trailing, on_tap} }: small outlined pills in
--             lines, as the book menu's tags (trailing: a glyph inside,
--             after the label, as the cross on a tag that removes it)
--   Any block with half = true pairs with the next one, two to a line.
--   order     label, selected, on_up, on_down, up_enabled, down_enabled,
--             on_edit: a shelf's label as its chip draws it (a tap on it
--             opens that shelf's editor, with on_edit), then up and down
--   slot      badge, text, selected, callback, seg {items, active,
--             on_pick}, on_clear: a numbered line (a sort level), outlined
--             when selected
-- Widgets are required on the first render, so toButtons runs without them.
local Blitbuffer, CenterContainer, FrameContainer, Geom, HorizontalGroup
local HorizontalSpan, LeftContainer, VerticalGroup, VerticalSpan, Font
local TextWidget, Kit, Space
local function loadDeps()
    if Kit then return end
    Blitbuffer      = require("ffi/blitbuffer")
    CenterContainer = require("ui/widget/container/centercontainer")
    FrameContainer  = require("ui/widget/container/framecontainer")
    Geom            = require("ui/geometry")
    HorizontalGroup = require("ui/widget/horizontalgroup")
    HorizontalSpan  = require("ui/widget/horizontalspan")
    LeftContainer   = require("ui/widget/container/leftcontainer")
    VerticalGroup   = require("ui/widget/verticalgroup")
    VerticalSpan    = require("ui/widget/verticalspan")
    Font            = require("ui/font")
    TextWidget      = require("lib/bookshelf_colour_text")
    Kit             = require("lib/bookshelf_popup_kit")
    Space           = require("lib/bookshelf_space")
end

local Page = {}

local CHEVRON = " \xE2\x80\xBA"   -- " ›"
local CROSS   = "\xE2\x9C\x95"    -- "✕"

-- One laid-out page: the faces, the width and the keys' layout it fills.
local Ctx = {}
Ctx.__index = Ctx

local function newCtx(o)
    local fs = o.font_size or 20
    local ctx = setmetatable({
        fs = fs, w = o.width - 2 * o.inset,
        face = require("lib/bookshelf_fonts"):getFace("cfont", fs),
        small = require("lib/bookshelf_fonts"):getFace("cfont", math.max(10, fs - 3)),
        chip_face = require("lib/bookshelf_fonts"):getFace("cfont", math.max(10, fs - 2)),
        gap = Space.px(10), layout = {},
    }, Ctx)
    return ctx
end

-- leftRight(left, right, w): left at the start, right flush with the end.
local function leftRight(left, right, w)
    local lw = left and left:getSize().w or 0
    local rw = right and right:getSize().w or 0
    local hg = HorizontalGroup:new{ align = "center" }
    if left then hg[#hg + 1] = left end
    hg[#hg + 1] = HorizontalSpan:new{ width = math.max(0, w - lw - rw) }
    if right then hg[#hg + 1] = right end
    return hg
end

-- tapCard(content, w, h, on, callback, enabled, outline, pad, instant) -> a
-- Kit.card as a w x h tap target, its focus ring the card's corner. instant:
-- a choice, shown by the page drawn again rather than pressed (Kit.tapCell).
local function tapCard(content, w, h, on, callback, enabled, outline, pad, instant)
    pad = pad or Space.px(12)
    local card = Kit.card{ width = w, height = h, on = on, outline = outline,
        padding_left = pad, padding_right = pad,
        LeftContainer:new{ dimen = Geom:new{ w = w - 2 * pad, h = h }, content } }
    local cell = Kit.tapCell(card, w, h, callback, enabled, nil, instant)
    cell.focus_radius = Kit.RADIUS
    return cell
end

function Ctx:ink(on, enabled)
    if on then return Blitbuffer.COLOR_WHITE end
    -- Grey, not dark grey: dark grey reads as black on e-ink (STYLE.md), so
    -- a greyed control looked live.
    if enabled == false then return Blitbuffer.COLOR_GRAY end
    return Blitbuffer.COLOR_BLACK
end

function Ctx:text(text, o)
    o = o or {}
    return TextWidget:new{ text = text or "", face = o.face or self.face, bold = o.bold,
        fgcolor = o.fgcolor or Blitbuffer.COLOR_BLACK, max_width = o.max_width }
end

-- The height of a one-line card: the body face and its padding.
function Ctx:cardH()
    if not self._card_h then
        self._card_h = self:text("Hg"):getSize().h + 2 * Space.px(10)
    end
    return self._card_h
end

-- A small button the height of a one-line control (Pick one >, the cross).
function Ctx:smallButton(text, on, callback, h)
    return Kit.button{ text = text, face = require("lib/bookshelf_fonts"):getFace("cfont", math.max(10, self.fs - 2)),
        height = h or (self:cardH() - Space.px(12)), inverted = on or false,
        bold = on or false, on_tap = callback }
end

-- icon(glyph, ink) -> a symbols-font glyph a step larger than the body,
-- for a row's or option's icon.
function Ctx:icon(glyph, ink)
    return TextWidget:new{ text = glyph, face = Font:getFace("symbols", self.fs + 2),
        fgcolor = ink or Blitbuffer.COLOR_BLACK }
end
-- iconW() -> an icon's width and the gap after it.
function Ctx:iconW()
    if not self._icon_w then self._icon_w = self:icon("\u{EA31}"):getSize().w + Space.px(12) end
    return self._icon_w
end

-- A folder row's path, cut in the middle (TextFit.pathMiddle).
local function shortenPath(path, fits) return require("lib/bookshelf_text_fit").pathMiddle(path, fits) end
Page._shortenPath = shortenPath   -- for tests

local R = {}

function R.summary(ctx, b)
    return require("ui/widget/textboxwidget"):new{ text = b.text or "", width = ctx.w,
        face = ctx.face, fgcolor = Blitbuffer.COLOR_BLACK, bgcolor = ctx.bg }
end

-- tag: a word on a grey tag at the line's right end (a filter list's OR,
-- AND or NOT), apart from the heading's own sentence. Filled, white on
-- grey: an outline reads as a button (STYLE.md).
function R.heading(ctx, b)
    local head = Kit.heading(b.text, ctx.fs)
    if not b.tag then return head end
    local badge = FrameContainer:new{
        bordersize = 0, background = Blitbuffer.COLOR_DARK_GRAY,
        radius = Space.px(6), margin = 0,
        padding = 0, padding_left = Space.px(8), padding_right = Space.px(8),
        Kit.heading(b.tag, ctx.fs, Blitbuffer.COLOR_WHITE),
    }
    local gap = math.max(Space.px(8), ctx.w - head:getSize().w - badge:getSize().w)
    return HorizontalGroup:new{ align = "center", head, HorizontalSpan:new{ width = gap }, badge }
end

-- The book menu's own pills (its Tags tab in edit mode), so a list of
-- picks with crosses reads the same in both places.
function R.pills(ctx, b)
    local W = require("lib/bookshelf_widget")
    local group, rows = W._buildPillGroup(nil, b.items or {}, ctx.w, 9999, ctx.fs,
        "left", Space.px(8), nil, nil, Kit.BORDER)
    for _i, r in ipairs(rows or {}) do ctx.layout[#ctx.layout + 1] = r end
    return group
end

function R.hint(ctx, b)
    return Kit.hintText(b.text or "", nil, ctx.w, nil, { face = ctx.small, bg = ctx.bg })
end

function R.chips(ctx, b)
    local vg = VerticalGroup:new{ align = "left" }
    local line, line_w, focus = nil, 0, nil
    local face = ctx.chip_face
    local h = ctx:text("Hg", { face = face }):getSize().h + 2 * Space.px(10)
    local pad = Space.px(14)
    for _i, it in ipairs(b.items or {}) do
        local enabled = it.enabled ~= false
        local label = ctx:text(it.text, { bold = it.on, fgcolor = ctx:ink(it.on, enabled),
            max_width = ctx.w - 2 * pad, face = face })
        if it.icon then
            -- A glyph from the symbols font before the label (the reader's
            -- favourites mark).
            label = HorizontalGroup:new{ align = "center",
                ctx:text(it.icon, { face = Font:getFace("symbols", math.max(10, ctx.fs - 2)),
                    fgcolor = ctx:ink(it.on, enabled) }),
                HorizontalSpan:new{ width = Space.px(8) }, label }
        end
        local cw = label:getSize().w + 2 * pad
        if line and line_w + ctx.gap + cw > ctx.w then
            vg[#vg + 1] = line
            vg[#vg + 1] = VerticalSpan:new{ width = ctx.gap }
            line = nil
        end
        if not line then
            line, line_w, focus = HorizontalGroup:new{ align = "top" }, 0, {}
            ctx.layout[#ctx.layout + 1] = focus
        else
            line[#line + 1] = HorizontalSpan:new{ width = ctx.gap }
            line_w = line_w + ctx.gap
        end
        -- A chip that is on or off is a choice; one without (Edit collection
        -- order >) goes somewhere and is shown pressed.
        -- On the grey strip (Clear all filters) the strip's own button, as
        -- the pickers' Clear: white, outlined, no shadow (maintainer).
        local cell
        if ctx.bg then
            cell = Kit.button{ text = it.text, face = face, height = h, pad_h = pad,
                inverted = it.on or false, bold = it.on or false, enabled = enabled,
                on_tap = it.callback }
            cw = cell:getSize().w
        else
            cell = tapCard(label, cw, h, it.on, it.callback, enabled, nil, pad, it.on ~= nil)
        end
        line[#line + 1] = cell
        focus[#focus + 1] = cell
        line_w = line_w + cw
    end
    if line then vg[#vg + 1] = line end
    return vg
end

-- labelled(ctx, label, ctl): the label at the left and the control at the
-- right end; the label above the control when the two do not fit side by
-- side (a half-width pair).
local function labelled(ctx, label, ctl)
    local cw = ctl:getSize().w
    local lt = ctx:text(label)
    if lt:getSize().w + ctx.gap + cw <= ctx.w then return leftRight(lt, ctl, ctx.w) end
    return VerticalGroup:new{ align = "left",
        ctx:text(label, { max_width = ctx.w }), VerticalSpan:new{ width = Space.px(6) }, ctl }
end

function R.segmented(ctx, b)
    local face = require("lib/bookshelf_fonts"):getFace("cfont", math.max(10, ctx.fs - 2))
    if not b.label then
        local seg, rows = Kit.segmented{ items = b.items, active = b.active,
            on_pick = b.on_pick, allow_none = b.allow_none, face = face, width = ctx.w,
            pad_v = Space.px(8) }
        for _i, r in ipairs(rows) do ctx.layout[#ctx.layout + 1] = r end
        return seg
    end
    local seg, rows = Kit.segmented{ items = b.items, active = b.active,
        on_pick = b.on_pick, allow_none = b.allow_none, face = face, pad_v = Space.px(8),
        pad_h = Space.px(14) }
    for _i, r in ipairs(rows) do ctx.layout[#ctx.layout + 1] = r end
    return labelled(ctx, b.label, seg)
end

function R.slider(ctx, b)
    local fmt = b.format or tostring
    local w, keys = require("lib/bookshelf_slider").new{ width = ctx.w,
        value = b.value, min = b.min, max = b.max, step = b.step, default = b.default,
        big = b.big, big_label = b.big_label,
        format = fmt, on_change = b.on_change, face = ctx.face, small = ctx.small }
    ctx.layout[#ctx.layout + 1] = keys
    -- no_value: the value is shown elsewhere (the dialog's title).
    if b.no_value and not b.label then return w end
    local head = leftRight(b.label and ctx:text(b.label) or nil,
        ctx:text(fmt(b.value), { bold = true }), ctx.w)
    return VerticalGroup:new{ align = "left", head, VerticalSpan:new{ width = Space.px(4) }, w }
end

-- The stepper's - and + nudge a value in place, so they are grey cards
-- (STYLE.md: a card nudges or opens, an outline chooses or commits), with the
-- kit's minus and plus (Kit.MINUS, Kit.PLUS; Kit is loaded on the first
-- render, so read where they are used).
-- nudgeCard(glyph, callback, h, enabled, size) -> a square grey card with
-- a symbols-font glyph: a stepper's - and +, a Shelf order row's up and down.
function Ctx:nudgeCard(glyph, callback, h, enabled, size)
    return Kit.button{ icon_glyph = glyph, card = true,
        icon_face = Font:getFace("symbols", size or math.max(10, self.fs - 4)), width = h,
        height = h, instant = true, enabled = enabled, on_tap = callback }
end

function R.stepper(ctx, b)
    local h = ctx:cardH() - Space.px(8)
    local minus = ctx:nudgeCard(Kit.MINUS, b.on_dec, h)
    local plus = ctx:nudgeCard(Kit.PLUS, b.on_inc, h)
    local value = CenterContainer:new{ dimen = Geom:new{ w = Space.px(84), h = h },
        ctx:text(b.value, { bold = true }) }
    ctx.layout[#ctx.layout + 1] = { minus, plus }
    local ctl = HorizontalGroup:new{ align = "center", minus, value, plus }
    return labelled(ctx, b.label, ctl)
end

-- A Shelf order row: the shelf's label drawn as its chip is on the menu bar
-- (icons, pictures and the bar's case: ChipBar.buildChipLabel), outlined,
-- black for the shelf being edited, then up and down as grey cards (they
-- nudge a place, STYLE.md). on_edit: a tap on the pill opens that shelf's
-- editor; it looked like a button and did nothing, and the pencil beside it
-- that did went (maintainer). The shelf being edited has none.
local CHEV_UP   = "\xEE\xA1\x82"   -- U+E842 mdi-chevron-up
local CHEV_DOWN = "\xEE\xA0\xBF"   -- U+E83F mdi-chevron-down
function R.order(ctx, b)
    local Size = require("ui/size")
    local h = ctx:cardH() - Space.px(8)
    local up = ctx:nudgeCard(CHEV_UP, b.on_up, h, b.up_enabled ~= false, ctx.fs + 4)
    local down = ctx:nudgeCard(CHEV_DOWN, b.on_down, h, b.down_enabled ~= false, ctx.fs + 4)
    local gap = Space.px(8)
    -- The cards as they are (a card is wider than its height by its
    -- shadow): the row overflowed the page by the two shadows and the frame
    -- grew to it (PW5).
    local pill_w = ctx.w - up:getSize().w - down:getSize().w - 2 * gap
    local border = Size.border.button
    local pad = Space.px(12)
    local ink = b.selected and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
    local label = require("lib/bookshelf_chip_bar").buildChipLabel(b.label or "",
        math.max(10, ctx.fs - 2), pill_w - 2 * (border + pad), ink, b.selected)
    local pill = FrameContainer:new{ bordersize = border, radius = Space.px(6),
        margin = 0, padding = 0, color = Blitbuffer.COLOR_BLACK,
        background = b.selected and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
        CenterContainer:new{ dimen = Geom:new{ w = pill_w - 2 * border, h = h - 2 * border }, label } }
    local cell
    if b.on_edit then cell = Kit.tapCell(pill, pill_w, h, b.on_edit) end
    local keys = {}
    if cell then keys[1] = cell end
    keys[#keys + 1] = up
    keys[#keys + 1] = down
    ctx.layout[#ctx.layout + 1] = keys
    return HorizontalGroup:new{ align = "center", cell or pill, HorizontalSpan:new{ width = gap },
        up, HorizontalSpan:new{ width = gap }, down }
end

-- rowParts(b, w) -> the row's inner width, ink, and whether its label and
-- value fit side by side.
function Ctx:rowParts(b, w)
    if b.on and b.on_clear then w = w - self:cardH() - Space.px(6) end
    local inner = w - 2 * Space.px(12)
    local ink = self:ink(b.on, b.enabled ~= false)
    local vt = b.value and (b.value .. (b.callback and CHEVRON or ""))
    local fits = true
    if vt then
        fits = (b.icon and self:iconW() or 0) + self:text(b.label):getSize().w + self.gap
            + self:text(vt, { bold = true }):getSize().w <= inner
    end
    return inner, ink, vt, fits
end

-- row(b, w, stacked) -> the card, and the cross beside it when the row can
-- be cleared. Stacked (too narrow for both, or its pair is): the label as a
-- heading over the value, as the editor's own cards read.
function Ctx:row(b, w, stacked)
    local h = self:cardH()
    local enabled = b.enabled ~= false
    local inner, ink, vt, fits = self:rowParts(b, w)
    if stacked == nil then stacked = not fits end
    local cross_w = h
    if b.on and b.on_clear then w = w - cross_w - Space.px(6) end
    local body
    if stacked and vt then
        -- The icon beside the label on a line of their own, the value under
        -- them across the card's whole width (maintainer).
        body = VerticalGroup:new{ align = "left",
            Kit.iconHeading(b.icon, b.label, self.fs, ink),
            VerticalSpan:new{ width = Space.px(4) },
            self:text(vt, { bold = true, fgcolor = ink, max_width = inner }) }
        h = body:getSize().h + 2 * Space.px(10)
    else
        local iw = b.icon and self:iconW() or 0
        local value = vt and self:text(vt, { bold = true, fgcolor = ink,
            max_width = math.floor(inner * 0.6) })
        local label_w = inner - iw - (value and value:getSize().w + self.gap or 0)
        local text = b.label
        if b.path and text then
            text = shortenPath(text, function(t) return self:text(t):getSize().w <= label_w end)
        end
        local label = self:text(text, { fgcolor = ink, max_width = label_w })
        if b.icon then
            label = HorizontalGroup:new{ align = "center", self:icon(b.icon, ink),
                HorizontalSpan:new{ width = Space.px(12) }, label }
        end
        body = leftRight(label, value, inner)
    end
    local cell = tapCard(body, w, h, b.on, b.callback, enabled)
    -- The cross as tall as the card beside it (maintainer), as wide as a
    -- one-line card is tall.
    local cross
    if b.on and b.on_clear then
        cross = tapCard(self:text(CROSS, { bold = true }), cross_w, h, false, b.on_clear, true, nil,
            math.floor((cross_w - self:text(CROSS):getSize().w) / 2))
    end
    if not cross then return cell, { cell } end
    return HorizontalGroup:new{ align = "center", cell, HorizontalSpan:new{ width = Space.px(6) }, cross },
        { cell, cross }
end

-- option(b, w) -> a card with its title and a grey line, and link buttons
-- inside it at the right.
function Ctx:option(b, w)
    local pad = Space.px(12)
    local inner = w - 2 * pad
    local links = HorizontalGroup:new{ align = "center" }
    local focus = {}
    for i, l in ipairs(b.links or {}) do
        if i > 1 then links[#links + 1] = HorizontalSpan:new{ width = Space.px(6) } end
        local btn = self:smallButton(l.text, l.on, l.callback)
        links[#links + 1] = btn
        focus[#focus + 1] = btn
    end
    local links_w = (#links > 0) and (links:getSize().w + self.gap) or 0
    local ink = self:ink(b.on, b.enabled)
    -- The icon leads the title's line and the grey line runs under both,
    -- the card's whole width (maintainer).
    local text_w = inner - links_w
    local icon_gap = Space.px(12)
    local title = self:text(b.text, { bold = true, fgcolor = ink,
        max_width = text_w - (b.icon and (self:iconW() + icon_gap) or 0) })
    if b.icon then
        title = HorizontalGroup:new{ align = "center", self:icon(b.icon, ink),
            HorizontalSpan:new{ width = icon_gap }, title }
    end
    local vg = VerticalGroup:new{ align = "left", title }
    if b.desc then
        vg[#vg + 1] = VerticalSpan:new{ width = Space.px(2) }
        vg[#vg + 1] = require("ui/widget/textboxwidget"):new{ text = b.desc, width = text_w,
            face = self.small, fgcolor = b.on and Blitbuffer.COLOR_GRAY_E or Kit.DIM_ON_GREY,
            bgcolor = b.on and Blitbuffer.COLOR_BLACK or Kit.STRIP_BG }
    end
    local h = math.max(vg:getSize().h, links:getSize().h) + 2 * Space.px(b.desc and 12 or 6)
    if not b.desc then h = math.max(h, self:cardH()) end
    local body = (#links > 0) and leftRight(vg, links, inner) or vg
    local cell = tapCard(body, w, h, b.on, b.callback, b.enabled, nil, nil, true)
    table.insert(focus, 1, cell)
    return cell, focus
end

-- Half-width blocks of a kind side by side, two to a line.
local function halves(ctx, list, build)
    local vg = VerticalGroup:new{ align = "left" }
    local w = math.floor((ctx.w - ctx.gap) / 2)
    for i = 1, #list, 2 do
        if i > 1 then vg[#vg + 1] = VerticalSpan:new{ width = ctx.gap } end
        local a, fa = build(list[i], w)
        local hg = HorizontalGroup:new{ align = "center", a }
        local focus = fa
        if list[i + 1] then
            local bw_, fb = build(list[i + 1], ctx.w - w - ctx.gap)
            hg[#hg + 1] = HorizontalSpan:new{ width = ctx.gap }
            hg[#hg + 1] = bw_
            for _j, f in ipairs(fb) do focus[#focus + 1] = f end
        end
        vg[#vg + 1] = hg
        if #focus > 0 then ctx.layout[#ctx.layout + 1] = focus end
    end
    return vg
end

function R.row(ctx, b)
    local wdg, focus = ctx:row(b, ctx.w)
    ctx.layout[#ctx.layout + 1] = focus
    return wdg
end

function R.option(ctx, b)
    local wdg, focus = ctx:option(b, ctx.w)
    ctx.layout[#ctx.layout + 1] = focus
    return wdg
end

function R.slot(ctx, b)
    local h = ctx:cardH()
    local pad = Space.px(12)
    local focus = {}
    local seg
    if b.seg then
        local rows
        seg, rows = Kit.segmented{ items = b.seg.items, active = b.seg.active,
            on_pick = b.seg.on_pick, face = require("lib/bookshelf_fonts"):getFace("cfont", math.max(10, ctx.fs - 3)),
            pad_v = Space.px(6), pad_h = Space.px(10) }
        for _i, c in ipairs(rows[1] or {}) do focus[#focus + 1] = c end
    end
    local cross
    if b.on_clear then
        cross = ctx:smallButton(CROSS, false, b.on_clear, h - Space.px(14))
        focus[#focus + 1] = cross
    end
    local right = HorizontalGroup:new{ align = "center" }
    if seg then right[#right + 1] = seg end
    if cross then
        if seg then right[#right + 1] = HorizontalSpan:new{ width = Space.px(8) } end
        right[#right + 1] = cross
    end
    local inner = ctx.w - 2 * pad
    local badge = ctx:text(b.badge or "", { bold = true, fgcolor = Blitbuffer.COLOR_DARK_GRAY })
    local bw = Space.px(36)
    local label = ctx:text(b.text, { bold = true,
        max_width = math.max(Space.px(40), inner - bw - right:getSize().w - ctx.gap) })
    local left = HorizontalGroup:new{ align = "center",
        CenterContainer:new{ dimen = Geom:new{ w = bw, h = label:getSize().h }, badge }, label }
    local card = Kit.card{ width = ctx.w, height = h, background = Blitbuffer.COLOR_WHITE,
        outline = b.selected, padding_left = pad, padding_right = pad,
        LeftContainer:new{ dimen = Geom:new{ w = inner, h = h },
            leftRight(left, (#right > 0) and right or nil, inner) } }
    local cell = Kit.tapCell(card, ctx.w, h, b.callback, b.callback ~= nil, nil, true)
    cell.focus_radius = Kit.RADIUS
    table.insert(focus, 1, cell)
    ctx.layout[#ctx.layout + 1] = focus
    return cell
end

-- One run of blocks, stacked: consecutive half rows/options pair up.
local function stack(ctx, blocks, spacing)
    local vg = VerticalGroup:new{ align = "left" }
    local i = 1
    local prev
    while i <= #blocks do
        local b = blocks[i]
        local wdg
        if b.half then
            -- Half-width blocks pair up, two to a line: rows and options
            -- sized to the half, other controls laid out in it (their own
            -- keys rows).
            local run = {}
            while blocks[i] and blocks[i].half do
                run[#run + 1] = blocks[i]; i = i + 1
            end
            -- A pair of rows stacks its labels together, or not at all,
            -- so the two cards are one height.
            local half_w = math.floor((ctx.w - ctx.gap) / 2)
            local stacked = {}
            for j = 1, #run, 2 do
                local a_, b_ = run[j], run[j + 1]
                local s_ = false
                for _k, x in ipairs({ a_, b_ }) do
                    if x and x.type == "row" and not select(4, ctx:rowParts(x, half_w)) then s_ = true end
                end
                stacked[a_] = s_
                if b_ then stacked[b_] = s_ end
            end
            wdg = halves(ctx, run, function(x, w)
                if x.type == "row" then return ctx:row(x, w, stacked[x]) end
                if x.type == "option" then return ctx:option(x, w) end
                local saved = ctx.w
                ctx.w = w
                local out = R[x.type](ctx, x)
                ctx.w = saved
                return out, {}
            end)
        else
            local r = R[b.type]
            wdg = r and r(ctx, b)
            i = i + 1
        end
        if wdg then
            if prev then
                -- A heading sits close to what it heads, further from what
                -- went before.
                local gap = (b.type == "heading") and math.floor(spacing * 1.8)
                    or (prev.type == "heading") and Space.px(6) or spacing
                vg[#vg + 1] = VerticalSpan:new{ width = gap }
            end
            vg[#vg + 1] = wdg
            prev = b
        end
    end
    return vg
end

-- units(blocks) -> the blocks in runs that stay together on a page: a
-- heading (and a hint under it) with what follows, a run of half blocks.
local function units(blocks)
    local out, cur = {}, nil
    local glue = false
    local halves_in = 0   -- half blocks in the current unit's pair so far
    for i, b in ipairs(blocks) do
        local prev = blocks[i - 1]
        -- The second of a pair joins the first; a page may break between
        -- pairs, as it may between any two lines.
        local join = cur and (glue or (b.half and prev and prev.half and halves_in % 2 == 1))
        if not join then
            cur = {}
            out[#out + 1] = cur
            halves_in = 0
        end
        cur[#cur + 1] = b
        if b.half then halves_in = halves_in + 1 else halves_in = 0 end
        glue = (b.type == "heading") or (b.type == "hint" and prev and prev.type == "heading")
    end
    return out
end

Page._units = units   -- for tests

-- pager(ctx, n, of, on_page) -> the page row: < n of m >, the ends greyed.
local function pager(ctx, n, of, on_page)
    local h = ctx:cardH() - Space.px(8)
    local isz = h - Space.px(16)
    local prev = Kit.button{ icon = "chevron.left", icon_size = isz, height = h,
        pad_h = Space.px(20), enabled = n > 1, on_tap = function() on_page(n - 1) end }
    local nxt = Kit.button{ icon = "chevron.right", icon_size = isz, height = h,
        pad_h = Space.px(20), enabled = n < of, on_tap = function() on_page(n + 1) end }
    ctx.layout[#ctx.layout + 1] = { prev, nxt }
    local label = CenterContainer:new{ dimen = Geom:new{ w = Space.px(160), h = h },
        ctx:text(require("ffi/util").template(require("lib/bookshelf_i18n").gettext("%1 of %2"), n, of)) }
    return CenterContainer:new{ dimen = Geom:new{ w = ctx.w, h = h },
        HorizontalGroup:new{ align = "center", prev, label, nxt } }
end

-- render(model, o) -> strip (nil without one), body, layout, pages
--   model { strip = {blocks}, blocks = {blocks} }
--   o { width (the popup's), inset, font_size, max_h (the most the body may
--   take; past it the blocks go onto pages), page (1-based), on_page(n) }
-- A page break never splits a unit (units()), so a heading stays with what
-- it heads; a unit taller than a whole page has one to itself.
function Page.render(model, o)
    loadDeps()
    local ctx = newCtx(o)
    local strip
    if model.strip and #model.strip > 0 then
        ctx.bg = Kit.STRIP_BG
        strip = Kit.withShadow(FrameContainer:new{
            bordersize = 0, margin = 0, width = o.width,
            background = Kit.STRIP_BG,
            padding_left = o.inset, padding_right = o.inset,
            padding_top = Space.px(12), padding_bottom = Space.px(12),
            stack(ctx, model.strip, Space.px(10)),
        }, o.width)
        ctx.bg = nil
    end
    local spacing = Space.px(10)
    local pad_top, pad_bottom = Space.px(14), o.inset
    -- Each unit laid out on its own, with the keys rows it adds.
    -- under: the heading a unit sits under, repeated at the top of a page
    -- the section carries on to.
    local built = {}
    local strip_layout = ctx.layout
    local under
    for _i, u in ipairs(units(model.blocks or {})) do
        ctx.layout = {}
        local w = stack(ctx, u, spacing)
        if u[1].type == "heading" then under = u[1].text end
        built[#built + 1] = { w = w, h = w:getSize().h, layout = ctx.layout, under = under,
            head = u[1].type == "heading",
            gap = (u[1].type == "heading") and math.floor(spacing * 1.8) or spacing }
    end
    local cont_h = Kit.heading("Hg", ctx.fs):getSize().h + Space.px(6)
    -- What a page starting at unit i spends before it on the carried heading.
    local function carried(i)
        return (not built[i].head and built[i].under) and cont_h or 0
    end
    ctx.layout = strip_layout
    local function total(from, to)
        local h = 0
        for i = from, to do h = h + built[i].h + ((i > from) and built[i].gap or 0) end
        return h
    end
    -- Greedy pages within the room left.
    local room = o.max_h and (o.max_h - (strip and strip:getSize().h or 0) - pad_top - pad_bottom)
        or math.huge
    local pages = { { 1, #built } }
    if #built > 0 and total(1, #built) > room then
        local pager_h = ctx:cardH() - Space.px(8) + spacing
        local fit = room - pager_h
        pages = {}
        local first = 1
        while first <= #built do
            local last = first
            while last < #built and carried(first) + total(first, last + 1) <= fit do last = last + 1 end
            pages[#pages + 1] = { first, last }
            first = last + 1
        end
    end
    local n = math.max(1, math.min(o.page or 1, #pages))
    local vg = VerticalGroup:new{ align = "left" }
    local span = pages[n]
    if span and span[1] <= span[2] then
        if #pages > 1 and carried(span[1]) > 0 then
            vg[#vg + 1] = Kit.heading(built[span[1]].under, ctx.fs)
            vg[#vg + 1] = VerticalSpan:new{ width = Space.px(6) }
        end
        for i = span[1], span[2] do
            if i > span[1] then vg[#vg + 1] = VerticalSpan:new{ width = built[i].gap } end
            vg[#vg + 1] = built[i].w
            for _j, row in ipairs(built[i].layout) do ctx.layout[#ctx.layout + 1] = row end
        end
    end
    if #pages > 1 then
        -- The page row at the foot, the same place on every page.
        local used = (span and span[1] <= span[2]) and (carried(span[1]) + total(span[1], span[2])) or 0
        local pager_h = ctx:cardH() - Space.px(8)
        vg[#vg + 1] = VerticalSpan:new{ width = math.max(spacing, room - used - pager_h) }
        vg[#vg + 1] = pager(ctx, n, #pages, o.on_page or function() end)
    end
    local body = FrameContainer:new{ bordersize = 0, margin = 0,
        padding_left = o.inset, padding_right = o.inset,
        padding_top = pad_top, padding_bottom = pad_bottom, vg }
    return strip, body, ctx.layout, #pages
end

-- toButtons(model) -> ButtonDialog rows for the same page: a button for
-- each thing to tap, the ones on ticked, and headings, hints and the summary
-- as greyed rows.
function Page.toButtons(model)
    local rows = {}
    local TICK, BLANK = "\xE2\x9C\x93 ", "  "
    local function mark(on) return on and TICK or BLANK end
    local function add(blocks)
        for _i, b in ipairs(blocks or {}) do
            local t = b.type
            if t == "summary" or t == "heading" or t == "hint" then
                rows[#rows + 1] = { { text = b.text, enabled = false } }
            elseif t == "pills" then
                local row = {}
                for _j, it in ipairs(b.items or {}) do
                    row[#row + 1] = { text = it.label .. (it.trailing and " " .. it.trailing or ""),
                        callback = it.on_tap }
                end
                rows[#rows + 1] = row
            elseif t == "chips" then
                local row = {}
                for _j, it in ipairs(b.items or {}) do
                    row[#row + 1] = { text = mark(it.on) .. it.text, callback = it.callback,
                        enabled = it.enabled }
                end
                rows[#rows + 1] = row
            elseif t == "segmented" then
                local row = {}
                for _j, it in ipairs(b.items or {}) do
                    local key = it.key
                    row[#row + 1] = { text = mark(key == b.active) .. it.label,
                        callback = function() if key ~= b.active then b.on_pick(key) end end }
                end
                if b.label then rows[#rows + 1] = { { text = b.label, enabled = false } } end
                rows[#rows + 1] = row
            elseif t == "slider" then
                local fmt, step = b.format or tostring, b.step or 1
                rows[#rows + 1] = { { text = "\u{2212}", callback = function() b.on_change(math.max(b.min, b.value - step)) end },
                    { text = (b.label and (b.label .. ": ") or "") .. fmt(b.value), enabled = false },
                    { text = "+", callback = function() b.on_change(math.min(b.max, b.value + step)) end } }
            elseif t == "order" then
                rows[#rows + 1] = { { text = mark(b.selected) .. (b.label or ""), enabled = false },
                    { text = "\u{2191}", callback = b.on_up, enabled = b.up_enabled ~= false },
                    { text = "\u{2193}", callback = b.on_down, enabled = b.down_enabled ~= false } }
                if b.on_edit then
                    rows[#rows][4] = { text = require("lib/bookshelf_i18n").gettext("Edit"), callback = b.on_edit }
                end
            elseif t == "stepper" then
                rows[#rows + 1] = { { text = "\u{2212}", callback = b.on_dec },
                    { text = b.label .. ": " .. tostring(b.value), enabled = false },
                    { text = "+", callback = b.on_inc } }
            elseif t == "row" then
                local row = { { text = b.label .. (b.value and (": " .. b.value) or ""),
                    callback = b.callback, enabled = b.enabled } }
                if b.on and b.on_clear then row[2] = { text = CROSS, callback = b.on_clear } end
                rows[#rows + 1] = row
            elseif t == "option" then
                local row = { { text = mark(b.on) .. b.text, callback = b.callback, enabled = b.enabled } }
                for _j, l in ipairs(b.links or {}) do
                    row[#row + 1] = { text = mark(l.on) .. l.text, callback = l.callback }
                end
                rows[#rows + 1] = row
            elseif t == "slot" then
                local row = { { text = mark(b.selected) .. (b.badge or "") .. " " .. b.text,
                    callback = b.callback } }
                if b.seg then
                    for _j, it in ipairs(b.seg.items) do
                        local key = it.key
                        row[#row + 1] = { text = mark(key == b.seg.active) .. it.label,
                            callback = function() if key ~= b.seg.active then b.seg.on_pick(key) end end }
                    end
                end
                if b.on_clear then row[#row + 1] = { text = CROSS, callback = b.on_clear } end
                rows[#rows + 1] = row
            end
        end
    end
    add(model.strip)
    add(model.blocks)
    return rows
end

return Page
