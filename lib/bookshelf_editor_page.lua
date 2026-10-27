-- bookshelf_editor_page.lua (see STYLE.md)
-- The shelf editor's pages (Sort, Source, Shelf style, Filters, Face out) as
-- data: a page is a list of blocks, and this lays them out in the popup
-- style, so a page says what it holds and how it looks stays in one place.
-- Page.toButtons flattens the same blocks to a ButtonDialog's rows, for when
-- the editor is not up to host the page (tests, a caller outside it).
--
-- Blocks ({ type = ..., ... }):
--   summary   text: what the shelf will do, in a sentence (the strip's lead)
--   heading   text
--   hint      text: grey
--   chips     items { {text, on, enabled, callback} }: cards sized to their
--             labels, wrapping; the one(s) on are black
--   segmented label (optional), items { {key, label} }, active, on_pick(key):
--             label at the left, the control at the right (full width with
--             no label)
--   stepper   label, value (text), on_dec, on_inc: label, then  -  value  +
--   row       label, value, callback, on, on_clear, half: a card reading
--             "label   value >"; on (a setting made) turns it black and
--             on_clear adds a cross beside it; half rows pair up two a line
--   option    text, desc, on, callback, links { {text, on, callback} },
--             half: a card with a title and a grey line saying what it does,
--             and small buttons at its right (Pick one >)
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
        face = Font:getFace("cfont", fs),
        small = Font:getFace("cfont", math.max(10, fs - 3)),
        chip_face = Font:getFace("cfont", math.max(10, fs - 2)),
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

-- tapCard(content, w, h, on, callback, enabled, outline) -> a Kit.card as a
-- w x h tap target, its focus ring the card's corner.
local function tapCard(content, w, h, on, callback, enabled, outline, pad)
    pad = pad or Space.px(12)
    local card = Kit.card{ width = w, height = h, on = on, outline = outline,
        padding_left = pad, padding_right = pad,
        LeftContainer:new{ dimen = Geom:new{ w = w - 2 * pad, h = h }, content } }
    local cell = Kit.tapCell(card, w, h, callback, enabled)
    cell.focus_radius = Kit.RADIUS
    return cell
end

function Ctx:ink(on, enabled)
    if on then return Blitbuffer.COLOR_WHITE end
    if enabled == false then return Blitbuffer.COLOR_DARK_GRAY end
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
        self._card_h = self:text("Hg"):getSize().h + 2 * Space.px(14)
    end
    return self._card_h
end

-- A small button the height of a one-line control (Pick one >, the cross).
function Ctx:smallButton(text, on, callback, h)
    return Kit.button{ text = text, face = Font:getFace("cfont", math.max(10, self.fs - 2)),
        height = h or (self:cardH() - Space.px(12)), inverted = on or false,
        bold = on or false, on_tap = callback }
end

local R = {}

function R.summary(ctx, b)
    return require("ui/widget/textboxwidget"):new{ text = b.text or "", width = ctx.w,
        face = ctx.face, fgcolor = Blitbuffer.COLOR_BLACK, bgcolor = ctx.bg }
end

function R.heading(ctx, b)
    return Kit.heading(b.text, ctx.fs)
end

function R.hint(ctx, b)
    return require("ui/widget/textboxwidget"):new{ text = b.text or "", width = ctx.w,
        face = ctx.small, fgcolor = Blitbuffer.COLOR_DARK_GRAY, bgcolor = ctx.bg }
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
        local cell = tapCard(label, cw, h, it.on, it.callback, enabled, nil, pad)
        line[#line + 1] = cell
        focus[#focus + 1] = cell
        line_w = line_w + cw
    end
    if line then vg[#vg + 1] = line end
    return vg
end

function R.segmented(ctx, b)
    local face = Font:getFace("cfont", math.max(10, ctx.fs - 2))
    if not b.label then
        local seg, rows = Kit.segmented{ items = b.items, active = b.active,
            on_pick = b.on_pick, face = face, width = ctx.w, pad_v = Space.px(10) }
        for _i, r in ipairs(rows) do ctx.layout[#ctx.layout + 1] = r end
        return seg
    end
    local seg, rows = Kit.segmented{ items = b.items, active = b.active,
        on_pick = b.on_pick, face = face, pad_v = Space.px(10), pad_h = Space.px(14) }
    for _i, r in ipairs(rows) do ctx.layout[#ctx.layout + 1] = r end
    local sw = seg:getSize().w
    return leftRight(ctx:text(b.label, { max_width = math.max(Space.px(40), ctx.w - sw - ctx.gap) }),
        seg, ctx.w)
end

function R.stepper(ctx, b)
    local h = ctx:cardH() - Space.px(12)
    local minus = ctx:smallButton("\u{2212}", false, b.on_dec, h)
    local plus = ctx:smallButton("+", false, b.on_inc, h)
    local value = CenterContainer:new{ dimen = Geom:new{ w = Space.px(110), h = h },
        ctx:text(b.value, { bold = true }) }
    ctx.layout[#ctx.layout + 1] = { minus, plus }
    local ctl = HorizontalGroup:new{ align = "center", minus, value, plus }
    return leftRight(ctx:text(b.label, { max_width = ctx.w - ctl:getSize().w - ctx.gap }),
        ctl, ctx.w)
end

-- row(b, w) -> the card, and the cross beside it when the row can be cleared.
function Ctx:row(b, w)
    local h = self:cardH()
    local enabled = b.enabled ~= false
    local cross
    if b.on and b.on_clear then
        cross = tapCard(self:text(CROSS, { bold = true }), h, h, false, b.on_clear, true, nil,
            math.floor((h - self:text(CROSS):getSize().w) / 2))
        w = w - h - Space.px(6)
    end
    local pad = Space.px(12)
    local inner = w - 2 * pad
    local ink = self:ink(b.on, enabled)
    local value = b.value and self:text(b.value .. (b.callback and CHEVRON or ""),
        { bold = true, fgcolor = ink, max_width = math.floor(inner * 0.6) })
    local label = self:text(b.label, { fgcolor = ink,
        max_width = inner - (value and value:getSize().w + self.gap or 0) })
    local cell = tapCard(leftRight(label, value, inner), w, h, b.on, b.callback, enabled)
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
    local text_w = inner - links_w
    local vg = VerticalGroup:new{ align = "left",
        self:text(b.text, { bold = true, fgcolor = ink, max_width = text_w }) }
    if b.desc then
        vg[#vg + 1] = VerticalSpan:new{ width = Space.px(2) }
        vg[#vg + 1] = require("ui/widget/textboxwidget"):new{ text = b.desc, width = text_w,
            face = self.small, fgcolor = b.on and Blitbuffer.COLOR_GRAY_E or Blitbuffer.COLOR_DARK_GRAY,
            bgcolor = b.on and Blitbuffer.COLOR_BLACK or Kit.STRIP_BG }
    end
    local h = math.max(vg:getSize().h, links:getSize().h) + 2 * Space.px(b.desc and 12 or 6)
    if not b.desc then h = math.max(h, self:cardH()) end
    local body = (#links > 0) and leftRight(vg, links, inner) or vg
    local cell = tapCard(body, w, h, b.on, b.callback, b.enabled)
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
        local hg = HorizontalGroup:new{ align = "top", a }
        local focus = fa
        if list[i + 1] then
            local bw_, fb = build(list[i + 1], ctx.w - w - ctx.gap)
            hg[#hg + 1] = HorizontalSpan:new{ width = ctx.gap }
            hg[#hg + 1] = bw_
            for _j, f in ipairs(fb) do focus[#focus + 1] = f end
        end
        vg[#vg + 1] = hg
        ctx.layout[#ctx.layout + 1] = focus
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
            on_pick = b.seg.on_pick, face = Font:getFace("cfont", math.max(10, ctx.fs - 3)),
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
    local cell = Kit.tapCell(card, ctx.w, h, b.callback, b.callback ~= nil)
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
        if b.half and (b.type == "row" or b.type == "option") then
            local run = {}
            while blocks[i] and blocks[i].half and blocks[i].type == b.type do
                run[#run + 1] = blocks[i]; i = i + 1
            end
            local method = (b.type == "row") and Ctx.row or Ctx.option
            wdg = halves(ctx, run, function(x, w) return method(ctx, x, w) end)
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

-- render(model, o) -> strip (nil without one), body, layout
--   model { strip = {blocks}, blocks = {blocks} }
--   o { width (the popup's), inset, font_size }
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
    local body = FrameContainer:new{ bordersize = 0, margin = 0,
        padding_left = o.inset, padding_right = o.inset,
        padding_top = Space.px(14), padding_bottom = o.inset,
        stack(ctx, model.blocks or {}, Space.px(10)) }
    return strip, body, ctx.layout
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
