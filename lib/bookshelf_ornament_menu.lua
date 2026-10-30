-- lib/bookshelf_ornament_menu.lua
-- Long-press an ornament on the shelf: adjust it where it stands. Size,
-- padding and height nudge live (the shelf redraws under the menu); hang,
-- mirror and a tap action; swap it for another piece, or shuffle them all;
-- reset to what its pack says.
--
-- Every change is the READER's (lib/bookshelf_ornaments readerSet), kept in
-- the ornaments folder's own ornaments.json keyed by the piece's relative
-- path, so it follows the piece onto every shelf and survives a pack update.
-- The file is written once, when the menu closes.
--
-- The nudge rows follow the bookends line editor: glyph buttons either side
-- of the value, a tap is a small step and a hold a big one, and tapping the
-- value resets it. Up and down are its Nerd Font chevrons.
local _ = require("lib/bookshelf_i18n").gettext
local T = require("ffi/util").template

local M = {}

local CHEV_UP   = "\xEE\xA1\x82"   -- U+E842 mdi-chevron-up
local CHEV_DOWN = "\xEE\xA0\xBF"   -- U+E83F mdi-chevron-down
-- Earlier / Later in the order: the shelf editor's own move chevrons.
local CHEV_LEFT  = "\xEE\xA1\x80"  -- U+E840 mdi-chevron-left
local CHEV_RIGHT = "\xEE\xA1\x81"  -- U+E841 mdi-chevron-right
local GLYPH_SIZE = 28
-- The steppers' minus and plus: the symbols font's pair, one width.
local MINUS_GLYPH = "\xEF\x81\xA8"   -- U+F068
local PLUS_GLYPH  = "\xEF\x91\x8D"   -- U+F44D
-- The piece's picture, top left beside its name: what is being edited, even
-- while it is switched off and gone from the shelf. A tall piece may rise a
-- quarter of its height above the dialog's frame, over a drop shadow cast by
-- a flat-colour copy of itself (maintainer).
M.HEADER_DP = 56        -- the header row inside the frame
M.OVERHANG  = 0.25      -- how much of the picture may stand above it
M.SHADOW_DP = 3         -- the shadow's offset, right and down

-- Steps (small, big). Size in its own multiple; padding in the books' stand
-- height; height (lift) in the piece's own height. The big step is the
-- outer "10" buttons (and a hold on the small ones): ten points of each.
-- Height's small step is ONE point: seating a piece so it looks centred on
-- the plank needs finer control than 2% of its height (maintainer).
M.STEPS = {
    scale = { 0.05, 0.10 },
    pad   = { 0.01, 0.10 },
    lift  = { 0.01, 0.10 },
}

local function O() return require("lib/bookshelf_ornaments") end
-- A piece on or off as the shelf on screen's theme has it: that theme's set,
-- or the collection's (bookshelf_theme_pack.switches, the one seam).
local function SW() return require("lib/bookshelf_theme_pack").switches() end
local Deck = require("lib/bookshelf_ornament_deck")

local function pct(v) return string.format("%+d%%", math.floor((v or 0) * 100 + 0.5)) end

-- nudged(entry, field, delta) -> the new value, clamped, rounded to the step
-- grid so repeated taps do not drift (0.1 + 0.2 ~= 0.3). From the reader's
-- own adjustment, not the piece's value: a pack's size and height are the
-- reader's 100% and 0% (Ornaments.RELATIVE).
function M.nudged(entry, field, delta)
    local cur = O().readerValue(entry, field) or O().FIELDS[field].default or 0
    local v = O().cleanField(field, cur + delta)
    return math.floor(v * 100 + 0.5) / 100
end

-- offsetFor(piece, screen_h, menu_h) -> the vertical move that keeps the menu
-- off the piece being adjusted: a quarter screen down for a piece in the top
-- half, up for one in the bottom half, so the live preview stays in sight.
-- Never past the screen's edge: a tall menu on a short screen moves only as
-- far as the room either side of it (device report: slightly off screen).
function M.offsetFor(piece, screen_h, menu_h)
    if not (piece and piece.y and screen_h) then return 0 end
    local mid = piece.y + (piece.h or 0) / 2
    local q = math.floor(screen_h / 4)
    if menu_h then q = math.max(0, math.min(q, math.floor((screen_h - menu_h) / 2))) end
    return (mid < screen_h / 2) and q or -q
end

-- show(entry, bw, piece): the menu for one piece; piece is where it stands
-- on screen (its dimen), for keeping the menu clear of it.
--
-- A panel (STYLE.md; maintainer: the same room or less than the button grid
-- it replaced): the actions on a bar under the title (Swap, Shuffle,
-- Switch off; Reset at its end), then two columns of labelled controls:
-- the piece in its slot (Size, Height, Padding) and the rest (Place,
-- Mirror, Anchor); Tap a row of its own under them, with a tip. Size,
-- Height and Padding step by - and + (a hold: the big step) and by the
-- -10 / +10 cards outside them; a tap on a value resets it. The X closes.
function M.show(entry, bw, piece, widget, opts)
    opts = opts or {}
    local UIManager       = require("ui/uimanager")
    local Device          = require("device")
    local Screen          = Device.screen
    local Blitbuffer      = require("ffi/blitbuffer")
    local Font            = require("ui/font")
    local Geom            = require("ui/geometry")
    local GestureRange    = require("ui/gesturerange")
    local Size            = require("ui/size")
    local Widget          = require("ui/widget/widget")
    local FrameContainer  = require("ui/widget/container/framecontainer")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local LeftContainer   = require("ui/widget/container/leftcontainer")
    local InputContainer  = require("ui/widget/container/inputcontainer")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan  = require("ui/widget/horizontalspan")
    local VerticalGroup   = require("ui/widget/verticalgroup")
    local VerticalSpan    = require("ui/widget/verticalspan")
    local LineWidget      = require("ui/widget/linewidget")
    local TextWidget      = require("lib/bookshelf_colour_text")
    local Kit             = require("lib/bookshelf_popup_kit")
    local Space           = require("lib/bookshelf_space")
    local Orn = O()
    -- The LIVE entry for this piece: the shelf's own may be older than the
    -- last rescan (see Orn.current). Every label below reads this upvalue.
    entry = Orn.current(entry)
    local dialog, place
    local shelf = bw and bw.chip

    local FS   = 18
    local face = Font:getFace("cfont", FS)
    local small = Font:getFace("cfont", FS - 3)
    local h    = TextWidget:new{ text = "Hg", face = face }:getSize().h + 2 * Space.px(10)
    local gap  = Space.px(10)
    local inset = Space.px(16)
    local width = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.9)
    local inner_w = width - 2 * Size.border.window - 2 * inset

    local function nightNow()
        local night = false
        pcall(function() night = require("lib/bookshelf_night_mode_sync").active() and true or false end)
        return night
    end
    -- The picture's placement: a box one header row tall plus the quarter it
    -- may rise, no wider than half again the row. Its size ignores the
    -- piece's own size nudge, so the header holds still while you nudge.
    local header_h = Screen:scaleBySize(M.HEADER_DP)
    local function picture()
        return Orn.previewPlacement(entry, math.floor(header_h * (1 + M.OVERHANG)),
                                    math.floor(header_h * 1.6))
    end
    -- The drawn size: the crop when the file carries transparent room.
    local function shown(pl)
        if pl.crop then return pl.crop.w, pl.crop.h end
        return pl.w, pl.h
    end
    local function overhangFor(pl) return math.max(0, select(2, shown(pl)) - header_h) end

    -- kbutton(o): a kit button, a grey card unless o.outline; o.glyph from
    -- the symbols font; o.on_hold the big step.
    local function kbutton(o)
        local btn = Kit.button{ text = o.text, face = o.text and face or nil,
            icon_glyph = o.glyph, icon_face = o.glyph and Font:getFace("symbols", o.glyph_size or (FS + 6)) or nil,
            height = h, width = o.width, pad_h = o.pad_h, gap = o.gap, enabled = o.enabled,
            border = (not o.outline) and 0 or nil,
            on_tap = o.on_tap, on_hold = o.on_hold }
        if not o.outline then Kit.cardify(btn[1]) end
        return btn
    end
    local function text(t, o)
        o = o or {}
        return TextWidget:new{ text = t, face = o.face or face, bold = o.bold,
            fgcolor = o.fgcolor, max_width = o.max_width }
    end

    -- headerWidget(): the picture at the left (a plain picture, not a live
    -- ornament, so a hold on it cannot open a second menu), standing on the
    -- row's foot and rising out of the top; the name and the pack beside it;
    -- the X at the right.
    local function headerWidget(close)
        local pl = picture()
        local night = nightNow()
        local d = Screen:scaleBySize(M.SHADOW_DP)
        local rise = overhangFor(pl)
        local sw, sh = shown(pl)
        local c = pl.crop or { x = 0, y = 0, w = pl.w, h = pl.h }
        local pic = Widget:new{ dimen = Geom:new{ w = sw + d, h = header_h } }
        function pic:paintTo(bb, x, y)
            local top = (rise > 0) and (y - rise) or (y + math.floor((header_h - sh) / 2))
            local shadow = Orn.shadowFor(pl, night)
            if shadow then
                pcall(function() bb:alphablitFrom(shadow, x + d, top + d, c.x, c.y, c.w, c.h) end)
            end
            Orn.paintPlacement(bb, x, top, pl, night)
        end
        local right = require("ui/widget/iconbutton"):new{
            icon = "close", width = math.floor(h * 0.6), height = math.floor(h * 0.6),
            padding = Space.px(4), callback = close }
        local text_w = math.max(1, inner_w - pic.dimen.w - gap - right:getSize().w - gap)
        local sub = entry.pack or ""
        if SW().isOff(entry.name) then
            sub = (sub ~= "" and (sub .. " \xC2\xB7 ") or "") .. _("switched off")   -- U+00B7 middle dot
        end
        local lines = VerticalGroup:new{ align = "left",
            text(Orn.displayName(entry), { bold = true, max_width = text_w }) }
        if sub ~= "" then
            lines[#lines + 1] = text(sub, { face = small, fgcolor = Blitbuffer.COLOR_DARK_GRAY,
                max_width = text_w })
        end
        return HorizontalGroup:new{ align = "center",
            pic, HorizontalSpan:new{ width = gap },
            LeftContainer:new{ dimen = Geom:new{ w = text_w, h = header_h }, lines },
            HorizontalSpan:new{ width = gap }, right,
        }, { right }
    end

    local function redraw()
        if bw and bw._rebuild then
            -- The piece's size moves where rows, and so pages, break later
            -- on: those are re-learnt, and this page keeps its start.
            if bw._dropOrnPages then bw:_dropOrnPages(true) end
            bw:_rebuild()
            UIManager:setDirty(bw, "ui")
        end
        -- The panel built again, where it was (place): the picture follows
        -- the piece (its mirroring), the values theirs.
        if dialog then dialog:reinit(); place() end
    end
    local function set(field, value)
        Orn.readerSet(entry, field, value)
        entry = Orn.current(entry)
        redraw()
    end
    -- setAnchor(v): pinned to the plank ("bottom") or under the shelf above
    -- ("top"), from the anchor itself: the old height meant somewhere else.
    -- Stored, not cleared, so a pack's own top piece can still be stood.
    local function setAnchor(v)
        Orn.readerSet(entry, "anchor", v)
        Orn.readerSet(entry, "lift", 0)
        entry = Orn.current(entry)
        redraw()
    end
    local function nudge(field, sign, big)
        local step = M.STEPS[field][big and 2 or 1]
        set(field, M.nudged(entry, field, sign * step))
    end

    -- The pieces that are on, in this shelf's saved order: what "place"
    -- counts and what left and right step through. Every shelf has its own
    -- deck, and the one held is the one on screen.
    local function onNames()
        Deck.sync(Orn.listAll(), shelf)
        local names = {}
        -- The shelf's own pool: what it deals (its theme's pieces, even if
        -- that pack is off in the collection; else the reader's own).
        local TP = require("lib/bookshelf_theme_pack")
        for i, e in ipairs(Deck.order(Orn.listFor(TP.ornamentsFor(shelf)), shelf)) do names[i] = e.name end
        return names
    end
    local function step(delta)
        if Deck.move(entry.name, delta, onNames(), shelf) then redraw() end
    end

    -- A value: tap it to reset (what the pack says), a plain label while it
    -- is already that.
    local val_w = math.max(text("+100%", { bold = true }):getSize().w,
                           text("100%", { bold = true }):getSize().w) + Space.px(16)
    local function valueCell(label, field, w)
        w = w or val_w
        local t = text(label, { bold = true })
        local box = CenterContainer:new{ dimen = Geom:new{ w = w, h = h }, t }
        if Orn.readerValue(entry, field) == nil then return box end
        return Kit.tapCell(box, w, h, function() set(field, nil) end, true, nil, true)
    end
    local function pctOf(field) return pct(Orn.readerValue(entry, field)) end
    local function sizeLabel()
        return string.format("%d%%", math.floor((Orn.readerValue(entry, "scale") or 1) * 100 + 0.5))
    end

    local function build(close)
        local rows = {}          -- the keys' rows, top to bottom
        local head, head_keys = headerWidget(close)
        rows[#rows + 1] = head_keys

        -- The action bar on the grey strip under the title (STYLE.md): the
        -- deal's actions at the left -- Swap (the collection's icon: the
        -- pieces to swap in), Shuffle this shelf, Switch off -- and Reset at
        -- the right. Pin here joins them where it can pin. The deal's are
        -- not for a pinned piece (opts.pinned): it stands where it was
        -- pinned, out of the shelf's deal.
        local function barButton(label, icon, fn)
            return Kit.headerButton{ text = label, icon = icon, font_size = FS, on_tap = fn }
        end
        local left_btns = {}
        if not opts.pinned then
            left_btns[#left_btns + 1] = barButton(_("Swap"), Orn.COLLECTION_ICON, function()
                close()
                -- The browser in pick mode: the chosen piece takes this one's
                -- place in the order, and this one the chosen's.
                require("lib/bookshelf_ornament_browser").show(function()
                    if bw and bw._rebuild then bw:_rebuild(); UIManager:setDirty(bw, "ui") end
                end, { pool = (function()
                    -- Only the pieces this shelf deals from: a shelf that
                    -- wears a theme deals that pack's pieces alone. A theme
                    -- whose set is edited may switch on any piece: all.
                    local sp = require("lib/bookshelf_theme_pack").ornamentsFor(shelf)
                    if sp == "mine" or type(sp) == "table" then return nil end
                    return function(e) return e.pack ~= nil and e.pack == sp end
                end)(), pick = function(chosen)
                    -- A piece never in the order yet (it was off) joins it first.
                    Deck.sync(Orn.listAll(), shelf)
                    Deck.swap(entry.name, chosen.name, shelf)
                end })
            end)
            -- A new order for this shelf's deck (the "Bookshelf: shuffle
            -- ornaments" action), which also clears its swaps. Asks first:
            -- an arrangement may have had a lot of care put into it.
            left_btns[#left_btns + 1] = barButton(_("Shuffle this shelf"), nil, function()
                local ConfirmBox = require("ui/widget/confirmbox")
                UIManager:show(ConfirmBox:new{
                    text = _("Shuffle this shelf's ornaments into a new order? Its swaps and moves are lost."),
                    ok_text = _("Shuffle"),
                    ok_callback = function()
                        close()
                        if bw and bw.onBookshelfShuffleOrnaments then bw:onBookshelfShuffleOrnaments() end
                    end,
                })
            end)
            -- Out of the deck and back, the menu still open: a piece switched
            -- off keeps its place in the saved order, so switching it back on
            -- puts it where it stood (maintainer).
            local sw = SW()
            left_btns[#left_btns + 1] = barButton(sw.isOff(entry.name) and _("Switch on") or _("Switch off"), nil,
                function()
                    sw.setOff(entry.name, not sw.isOff(entry.name))
                    redraw()
                end)
        end
        -- Fixed where it stands: an Ornament module among the shelf's books,
        -- moved from then on like any shelf module. The piece's widget (a
        -- long-press hands its rect as `piece`, the widget after it); a tall
        -- piece's own-row copy speaks for the piece (_pin_of).
        local src = widget or piece
        src = src and (src._pin_of or src)
        -- Not with Micro modules > On the shelf off: a pinned piece is a
        -- module among the books, which that turns off.
        local on_shelf = require("lib/bookshelf_settings_store").microOnShelf()
        if on_shelf and src and src.pin_after_idx and bw and bw._pinOrnament then
            left_btns[#left_btns + 1] = barButton(_("Pin here"), nil, function()
                close()
                bw:_pinOrnament(entry, src)
            end)
        end
        local reset = barButton(_("Reset"), "\u{E76E}", function()   -- backup-restore
            Orn.readerReset(entry)
            entry = Orn.current(entry)
            redraw()
        end)
        local left_group
        if #left_btns > 0 then
            left_group = HorizontalGroup:new{ align = "center" }
            for i, b in ipairs(left_btns) do
                if i > 1 then left_group[#left_group + 1] = HorizontalSpan:new{ width = Space.px(10) } end
                left_group[#left_group + 1] = b
            end
        end
        local bar_keys = {}
        for _i, b in ipairs(left_btns) do bar_keys[#bar_keys + 1] = b end
        bar_keys[#bar_keys + 1] = reset
        rows[#rows + 1] = bar_keys
        local strip = Kit.headerRow{ width = width - 2 * Size.border.window, inset = inset,
            left = left_group, buttons = { reset } }

        local function line(items, g)
            local hg = HorizontalGroup:new{ align = "center" }
            for i, wdg in ipairs(items) do
                if i > 1 then hg[#hg + 1] = HorizontalSpan:new{ width = g } end
                hg[#hg + 1] = wdg
            end
            return hg
        end
        -- stepper(dec, inc, value, labels) -> "- value +" (or chevrons): a tap
        -- the small step, a hold the big one; dec/inc { tap, hold, glyph,
        -- enabled }.
        local function stepper(dec, inc, value)
            local function b(o, text_)
                return kbutton{ text = (not o.glyph) and text_ or nil, glyph = o.glyph,
                    -- The minus and plus a size down, to sit with the chevrons.
                    glyph_size = (o.glyph == MINUS_GLYPH or o.glyph == PLUS_GLYPH) and FS + 2 or nil,
                    width = h, enabled = o.enabled, on_tap = o.tap, on_hold = o.hold }
            end
            -- The symbols font's minus and plus (U+F068, U+F44D): one width,
            -- where the text minus ran wider than its +.
            if not dec.glyph then dec.glyph = MINUS_GLYPH end
            if not inc.glyph then inc.glyph = PLUS_GLYPH end
            local minus, plus = b(dec), b(inc)
            -- The big step as cards of its own outside them ("-10" "+10";
            -- maintainer: there is room, and a hint for a hold is not needed).
            if dec.big then
                local big_minus = kbutton{ glyph = MINUS_GLYPH, glyph_size = FS - 4, text = "10", gap = Space.px(1),
                    pad_h = Space.px(6), on_tap = dec.big }
                local big_plus  = kbutton{ glyph = PLUS_GLYPH, glyph_size = FS - 4, text = "10", gap = Space.px(1),
                    pad_h = Space.px(6), on_tap = inc.big }
                return line({ big_minus, HorizontalSpan:new{ width = Space.px(3) }, minus, value, plus,
                    HorizontalSpan:new{ width = Space.px(3) }, big_plus }, 0),
                    { big_minus, minus, plus, big_plus }
            end
            return line({ minus, value, plus }, 0), { minus, plus }
        end
        -- nudger(field) -> its - and + : a tap the small step, a hold (or the
        -- -10 / +10 cards, big) the big one.
        local function nudger(field)
            local function big(sign) return function() nudge(field, sign, true) end end
            return { tap = function() nudge(field, -1, false) end, hold = big(-1), big = big(-1) },
                   { tap = function() nudge(field, 1, false) end, hold = big(1), big = big(1) }
        end

        -- Place: its place in this shelf's deal, earlier and later (wrapping
        -- round, the deck is a loop); greyed for a piece switched off or
        -- alone, and for a pinned one, out of the deal.
        local placed = not opts.pinned
        local i_on, n_on
        if placed then i_on, n_on = Deck.position(entry.name, onNames()) end
        local can_move = placed and i_on ~= nil and n_on > 1
        local place_t = text(placed and (i_on and T(_("%1 of %2"), i_on, n_on) or _("off")) or "\xE2\x80\x94",
            { face = small })
        local place_w = math.max(val_w, place_t:getSize().w + Space.px(12))
        local place_ctl, place_keys = stepper(
            { glyph = CHEV_LEFT, enabled = can_move, tap = function() step(-1) end },
            { glyph = CHEV_RIGHT, enabled = can_move, tap = function() step(1) end },
            CenterContainer:new{ dimen = Geom:new{ w = place_w, h = h }, place_t })
        local s_dec, s_inc = nudger("scale")
        local size_ctl, size_keys = stepper(s_dec, s_inc, valueCell(sizeLabel(), "scale"))
        local p_dec, p_inc = nudger("pad")
        local pad_ctl, pad_keys = stepper(p_dec, p_inc, valueCell(pctOf("pad"), "pad"))
        -- Height: down and up, as the piece moves.
        local l_dec, l_inc = nudger("lift")
        l_dec.glyph, l_inc.glyph = CHEV_DOWN, CHEV_UP
        local height_ctl, height_keys = stepper(l_dec, l_inc, valueCell(pctOf("lift"), "lift"))

        -- Mirror and the anchor (what Height counts from), segmented.
        local seg_face = Font:getFace("cfont", FS - 2)
        local mirror, mirror_keys = Kit.segmented{ face = seg_face, pad_v = Space.px(8), pad_h = Space.px(10),
            items = { { key = "off", label = _("Off") }, { key = "always", label = _("Always") },
                      { key = "alternate", label = _("Alternate") } },
            active = entry.mirror or "off",
            on_pick = function(k) set("mirror", k) end }
        local anchor, anchor_keys = Kit.segmented{ face = seg_face, pad_v = Space.px(8), pad_h = Space.px(10),
            items = { { key = "bottom", label = _("Bottom") }, { key = "top", label = _("Top") } },
            active = entry.anchor == "top" and "top" or "bottom",
            on_pick = function(k) setAnchor(k) end }

        -- Two columns, each a label and its control, the labels one width a
        -- column so the controls line up: the piece in its slot (Size,
        -- Height, Padding) and the rest (Place, Mirror and Anchor together)
        -- (maintainer). One column when two do not fit (a small screen).
        -- What a tap on the piece does: the action chooser.
        local tap = entry.tap
        local tap_btn = kbutton{ text = (tap and ((tap.zoom and _("Zoom")) or tap.label or _("set"))
            or _("None")) .. " \xE2\x80\xBA",
            on_tap = function() M.chooseTap(entry, redraw) end }
        local cols = {
            { { _("Size"), size_ctl, size_keys }, { _("Height"), height_ctl, height_keys },
              { _("Padding"), pad_ctl, pad_keys } },
            { { _("Place"), place_ctl, place_keys }, { _("Mirror"), mirror, mirror_keys[1] },
              { _("Anchor"), anchor, anchor_keys[1] } },
        }
        local col_gap = Space.px(16)
        -- The left column's label width, shared with the Tap row under it.
        local tap_label = text(_("Tap"), { face = small })
        local function column(list, extra)
            local lw = extra and extra:getSize().w or 0
            for _i, r in ipairs(list) do lw = math.max(lw, text(r[1], { face = small }):getSize().w) end
            local vg = VerticalGroup:new{ align = "left" }
            for i, r in ipairs(list) do
                if i > 1 then vg[#vg + 1] = VerticalSpan:new{ width = Space.px(6) } end
                vg[#vg + 1] = line({ LeftContainer:new{ dimen = Geom:new{ w = lw, h = h },
                    text(r[1], { face = small }) }, r[2] }, gap)
            end
            return vg, lw
        end
        local c1, left_lw = column(cols[1], tap_label)
        local c2 = column(cols[2])
        local grid
        if c1:getSize().w + col_gap + c2:getSize().w <= inner_w then
            grid = HorizontalGroup:new{ align = "top", c1, HorizontalSpan:new{ width = col_gap }, c2 }
            -- The keys walk across a line, then down.
            for i = 1, math.max(#cols[1], #cols[2]) do
                local r = {}
                for c = 1, 2 do
                    for _j, k in ipairs(cols[c][i] and cols[c][i][3] or {}) do r[#r + 1] = k end
                end
                rows[#rows + 1] = r
            end
        else
            grid = VerticalGroup:new{ align = "left", c1, VerticalSpan:new{ width = Space.px(6) }, c2 }
            for c = 1, 2 do
                for i = 1, #cols[c] do rows[#rows + 1] = cols[c][i][3] end
            end
        end

        -- Tap: a row of its own under the columns, so the button grows with
        -- the action's name, and a tip in the room beside it (maintainer).
        -- Only while none is set: the button names the action once it is.
        local tip = not tap and _("Give this ornament a job!") or nil
        local tap_used = left_lw + gap + tap_btn:getSize().w + gap
        local tap_items = { LeftContainer:new{ dimen = Geom:new{ w = left_lw, h = h }, tap_label }, tap_btn }
        if tip then
            tap_items[#tap_items + 1] = text(tip, { face = small, fgcolor = Blitbuffer.COLOR_DARK_GRAY,
                max_width = math.max(Space.px(40), inner_w - tap_used) })
        end
        local tap_row = line(tap_items, gap)
        rows[#rows + 1] = { tap_btn }

        local body = VerticalGroup:new{ align = "left",
            grid, VerticalSpan:new{ width = Space.px(6) },
            tap_row,
        }
        local frame = FrameContainer:new{
            background = Blitbuffer.COLOR_WHITE,
            bordersize = Size.border.window,
            radius     = Size.radius.window,
            padding    = 0,
            width      = width,
            VerticalGroup:new{ align = "left",
                FrameContainer:new{ bordersize = 0, padding = inset, padding_top = Space.px(8),
                    padding_bottom = Space.px(8), head },
                LineWidget:new{ background = Blitbuffer.COLOR_DARK_GRAY,
                    dimen = Geom:new{ w = width - 2 * Size.border.window, h = Size.line.thin } },
                strip,
                FrameContainer:new{ bordersize = 0, padding = inset, padding_top = Space.px(14), body },
            },
        }
        return frame, rows
    end

    -- The panel: the frame, centred across and moved clear of the piece
    -- (offsetFor), with room above it for the picture to rise into. A tap
    -- outside does nothing (rapid nudges land outside now and then and must
    -- not close it); the X or Back closes.
    local Panel = InputContainer:extend{}
    dialog = Panel:new{ dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() } }
    local function close() UIManager:close(dialog) end
    local FocusManager = require("ui/widget/focusmanager")
    function dialog:reinit()
        local frame, rows = build(close)
        self.frame = frame
        self.overhang = overhangFor(picture())
        self.fm = FocusManager:new{ layout = rows, show_parent = self, frame }
        self[1] = self.fm
    end
    -- place(): where the frame sits, worked out against its height each time
    -- it is built (its rows can change size), and refreshed there.
    local rect
    place = function()
        local sz = dialog.frame:getSize()
        local sw, sh = Screen:getWidth(), Screen:getHeight()
        local dy = M.offsetFor(piece, sh, sz.h + dialog.overhang)
        local y = math.floor((sh - sz.h) / 2) + dy
        y = math.max(dialog.overhang, math.min(sh - sz.h, y))
        local prev = rect
        rect = Geom:new{ x = math.floor((sw - sz.w) / 2), y = y - dialog.overhang,
            w = sz.w, h = sz.h + dialog.overhang }
        dialog.frame_y = y
        local both = prev and prev:combine(rect) or rect
        UIManager:setDirty(dialog, function() return "ui", both end)
    end
    function dialog:paintTo(bb, x, y)
        if not rect then return end
        self.fm:paintTo(bb, x + rect.x, y + self.frame_y)
    end
    dialog.ges_events = {
        -- Swallowed outside the frame: nothing under it reacts either.
        TapOutside  = { GestureRange:new{ ges = "tap",  range = dialog.dimen } },
        HoldOutside = { GestureRange:new{ ges = "hold", range = dialog.dimen } },
    }
    function dialog:onTapOutside() return true end
    function dialog:onHoldOutside() return true end
    if Device:hasKeys() then
        dialog.key_events = { Close = { { Device.input.group.Back } } }
    end
    function dialog:onClose() close(); return true end
    -- However it closes (the X, Back, an action that closes it): write the
    -- reader's file once, and repaint what it covered.
    function dialog:onCloseWidget()
        Orn.saveReader()
        local r = rect
        if r then UIManager:setDirty(nil, function() return "ui", r end) end
    end
    dialog:reinit()
    place()
    UIManager:show(dialog)
    return dialog
end

-- chooseTap(entry, done, set): the Action module's chooser, plus "no action"
-- and Zoom. set(value) stores the choice (an action table, "zoom", or nil):
-- by default on the piece's own file; the Ornament module stores it on its
-- card instead.
function M.chooseTap(entry, done, set)
    set = set or function(v) O().readerSet(entry, "tap", v) end
    local UIManager    = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")
    local Chooser      = require("lib/bookshelf_action_chooser")
    local d
    local function close(fn)
        return function() UIManager:close(d); if fn then fn() end end
    end
    local rows = Chooser.actionRows(close, function(fields)
        set({
            action = fields.action, plugin = fields.plugin,
            internal = fields.internal, label = fields.label,
        })
        if done then done() end
    end)
    table.insert(rows, 1, {{
        text = _("No action"),
        callback = close(function()
            set(nil)
            if done then done() end
        end),
    }, {
        -- The piece full screen, with its info (or its name) under it.
        text = _("Zoom"),
        callback = close(function()
            set("zoom")
            if done then done() end
        end),
    }})
    d = ButtonDialog:new{ title = _("Tap action"), title_align = "center",
                          width_factor = 0.65, buttons = rows }
    UIManager:show(d)
end

return M
