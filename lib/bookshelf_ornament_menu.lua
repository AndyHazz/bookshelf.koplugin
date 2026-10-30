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
-- A panel in the layout editor's toolbar style (STYLE.md; maintainer: the
-- same room or less than the button grid it replaced). The d-pad moves the
-- piece as it looks: left and right its place in the deal, up and down its
-- height. Size and padding are steppers. A tap is the small step, a hold
-- the big one, and a tap on a value resets it. Mirror and the anchor are
-- segmented, the tap action a row, the rest grey cards; the X closes.
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
            icon_glyph = o.glyph, icon_face = o.glyph and Font:getFace("symbols", FS + 6) or nil,
            height = h, width = o.width, pad_h = o.pad_h, enabled = o.enabled,
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
    -- the collection's icon (manage every piece from this one, maintainer)
    -- and the X at the right.
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
        local manage = Kit.iconButton{ icon = Orn.COLLECTION_ICON, font_size = FS,
            on_tap = function()
                close()
                require("lib/bookshelf_ornament_browser").show(function()
                    if bw and bw._rebuild then bw:_rebuild(); UIManager:setDirty(bw, "ui") end
                end)
            end }
        local x = require("ui/widget/iconbutton"):new{
            icon = "close", width = math.floor(h * 0.6), height = math.floor(h * 0.6),
            padding = Space.px(4), callback = close }
        local right = HorizontalGroup:new{ align = "center", manage, HorizontalSpan:new{ width = gap }, x }
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
        }, { manage, x }
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
    local function valueCell(label, field)
        local t = text(label, { bold = true })
        local box = CenterContainer:new{ dimen = Geom:new{ w = val_w, h = h }, t }
        if Orn.readerValue(entry, field) == nil then return box end
        return Kit.tapCell(box, val_w, h, function() set(field, nil) end, true, nil, true)
    end
    local function pctOf(field) return pct(Orn.readerValue(entry, field)) end
    local function sizeLabel()
        return string.format("%d%%", math.floor((Orn.readerValue(entry, "scale") or 1) * 100 + 0.5))
    end

    local function build(close)
        local rows = {}          -- the keys' rows, top to bottom
        local head, head_keys = headerWidget(close)
        rows[#rows + 1] = head_keys

        -- The d-pad: left and right the place in the deal (wrapping round,
        -- the deck is a loop; greyed for a piece switched off or alone, and
        -- for a pinned one, out of the deal), up and down the height.
        local placed = not opts.pinned
        local i_on, n_on
        if placed then i_on, n_on = Deck.position(entry.name, onNames()) end
        local can_move = placed and i_on ~= nil and n_on > 1
        local function chev(glyph, fn, hold)
            return kbutton{ glyph = glyph, pad_h = Space.px(12), on_tap = fn, on_hold = hold }
        end
        local up    = chev(CHEV_UP,   function() nudge("lift", 1, false) end, function() nudge("lift", 1, true) end)
        local down  = chev(CHEV_DOWN, function() nudge("lift", -1, false) end, function() nudge("lift", -1, true) end)
        local left  = kbutton{ glyph = CHEV_LEFT, pad_h = Space.px(12), enabled = can_move,
            on_tap = function() step(-1) end }
        local right = kbutton{ glyph = CHEV_RIGHT, pad_h = Space.px(12), enabled = can_move,
            on_tap = function() step(1) end }
        local cell = h
        for _i, b in ipairs({ up, down, left, right }) do cell = math.max(cell, b:getSize().w) end
        local place_t = text(placed and (i_on and T(_("%1 of %2"), i_on, n_on) or _("off")) or "",
            { face = small, fgcolor = Blitbuffer.COLOR_DARK_GRAY })
        local mid_w = math.max(cell, place_t:getSize().w + Space.px(8))
        local dgap = Space.px(4)
        local function slot(b, w)
            w = w or cell
            if b then return CenterContainer:new{ dimen = Geom:new{ w = w, h = h }, b } end
            return HorizontalSpan:new{ width = w }
        end
        local function line(items, g)
            local hg = HorizontalGroup:new{ align = "center" }
            for i, wdg in ipairs(items) do
                if i > 1 then hg[#hg + 1] = HorizontalSpan:new{ width = g } end
                hg[#hg + 1] = wdg
            end
            return hg
        end
        local dpad = VerticalGroup:new{ align = "left",
            line({ slot(), slot(up, mid_w), slot() }, dgap),
            VerticalSpan:new{ width = dgap },
            line({ slot(left), slot(place_t, mid_w), slot(right) }, dgap),
            VerticalSpan:new{ width = dgap },
            line({ slot(), slot(down, mid_w), slot() }, dgap),
        }

        -- Beside it: Size and Padding as steppers, Height's value (the d-pad
        -- moves it), one label width so the values line up.
        local function stepper(field)
            local minus = kbutton{ text = "\xE2\x88\x92", width = h,
                on_tap = function() nudge(field, -1, false) end, on_hold = function() nudge(field, -1, true) end }
            local plus = kbutton{ text = "+", width = h,
                on_tap = function() nudge(field, 1, false) end, on_hold = function() nudge(field, 1, true) end }
            return line({ minus, valueCell(field == "scale" and sizeLabel() or pctOf(field), field), plus }, 0),
                { minus, plus }
        end
        local size_ctl, size_keys = stepper("scale")
        local pad_ctl, pad_keys = stepper("pad")
        local height_ctl = line({ HorizontalSpan:new{ width = h }, valueCell(pctOf("lift"), "lift") }, 0)
        local labels = { _("Size"), _("Padding"), _("Height") }
        local lw = 0
        for _i, l in ipairs(labels) do lw = math.max(lw, text(l):getSize().w) end
        local function labelled(l, ctl)
            return line({ LeftContainer:new{ dimen = Geom:new{ w = lw, h = h }, text(l) }, ctl }, gap)
        end
        local side = VerticalGroup:new{ align = "left",
            labelled(labels[1], size_ctl), VerticalSpan:new{ width = dgap },
            labelled(labels[2], pad_ctl), VerticalSpan:new{ width = dgap },
            labelled(labels[3], height_ctl),
        }
        -- The keys walk the d-pad and its steppers as they look (one row a
        -- line of the pad).
        rows[#rows + 1] = { up, size_keys[1], size_keys[2] }
        rows[#rows + 1] = { left, right, pad_keys[1], pad_keys[2] }
        rows[#rows + 1] = { down }
        local top = line({ dpad, side }, Space.px(24))

        -- Mirror and the anchor (what Height counts from), segmented, on one
        -- line when they fit.
        local seg_face = Font:getFace("cfont", FS - 2)
        local mirror, mirror_keys = Kit.segmented{ face = seg_face, pad_v = Space.px(8), pad_h = Space.px(12),
            items = { { key = "off", label = _("Off") }, { key = "always", label = _("Always") },
                      { key = "alternate", label = _("Alternate") } },
            active = entry.mirror or "off",
            on_pick = function(k) set("mirror", k) end }
        local anchor, anchor_keys = Kit.segmented{ face = seg_face, pad_v = Space.px(8), pad_h = Space.px(12),
            items = { { key = "bottom", label = _("Bottom") }, { key = "top", label = _("Top") } },
            active = entry.anchor == "top" and "top" or "bottom",
            on_pick = function(k) setAnchor(k) end }
        local function pair(l, ctl) return line({ text(l, { face = small }), ctl }, Space.px(8)) end
        local m_line, a_line = pair(_("Mirror"), mirror), pair(_("Anchor"), anchor)
        local looks
        if m_line:getSize().w + Space.px(24) + a_line:getSize().w <= inner_w then
            looks = line({ m_line, a_line }, Space.px(24))
            rows[#rows + 1] = { mirror_keys[1][1], mirror_keys[1][2], mirror_keys[1][3],
                                anchor_keys[1][1], anchor_keys[1][2] }
        else
            looks = VerticalGroup:new{ align = "left", m_line, VerticalSpan:new{ width = dgap }, a_line }
            rows[#rows + 1] = mirror_keys[1]
            rows[#rows + 1] = anchor_keys[1]
        end

        -- What a tap on the piece does.
        local tap = entry.tap
        local tap_label = tap and T(_("Tap: %1"), (tap.zoom and _("Zoom")) or tap.label or _("set"))
                       or _("Tap: none")
        local tap_btn = kbutton{ text = tap_label .. " \xE2\x80\xBA",
            on_tap = function() M.chooseTap(entry, redraw) end }

        -- The rest as grey cards. Swap, Shuffle and Switch off are not for a
        -- pinned piece (opts.pinned): it stands where it was pinned, out of
        -- the shelf's deal.
        local actions = {}
        if not opts.pinned then
            actions[#actions + 1] = kbutton{ text = _("Swap"), on_tap = function()
                close()
                -- The browser in pick mode: the chosen piece takes this one's
                -- place in the order, and this one takes the chosen piece's.
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
            end }
            -- A new order for this shelf's deck (the "Bookshelf: shuffle
            -- ornaments" action), which also clears its swaps. Asks first:
            -- an arrangement may have had a lot of care put into it.
            actions[#actions + 1] = kbutton{ text = _("Shuffle this shelf"), on_tap = function()
                local ConfirmBox = require("ui/widget/confirmbox")
                UIManager:show(ConfirmBox:new{
                    text = _("Shuffle this shelf's ornaments into a new order? Its swaps and moves are lost."),
                    ok_text = _("Shuffle"),
                    ok_callback = function()
                        close()
                        if bw and bw.onBookshelfShuffleOrnaments then bw:onBookshelfShuffleOrnaments() end
                    end,
                })
            end }
            -- Out of the deck and back, the menu still open: a piece switched
            -- off keeps its place in the saved order, so switching it back on
            -- puts it where it stood (maintainer).
            local sw = SW()
            actions[#actions + 1] = kbutton{ text = sw.isOff(entry.name) and _("Switch on") or _("Switch off"),
                on_tap = function()
                    sw.setOff(entry.name, not sw.isOff(entry.name))
                    redraw()
                end }
        end
        actions[#actions + 1] = kbutton{ text = _("Reset"), on_tap = function()
            Orn.readerReset(entry)
            entry = Orn.current(entry)
            redraw()
        end }
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
            actions[#actions + 1] = kbutton{ text = _("Pin here"), on_tap = function()
                close()
                bw:_pinOrnament(entry, src)
            end }
        end
        -- Wrapped to the width, a keys row a line.
        local cards = VerticalGroup:new{ align = "left" }
        local cur, cur_w, cur_keys = nil, 0, nil
        local all_cards = { tap_btn }
        for _i, b in ipairs(actions) do all_cards[#all_cards + 1] = b end
        for _i, b in ipairs(all_cards) do
            local bw_ = b:getSize().w
            if cur and cur_w + gap + bw_ > inner_w then
                cards[#cards + 1] = cur
                cards[#cards + 1] = VerticalSpan:new{ width = gap }
                cur = nil
            end
            if not cur then
                cur, cur_w, cur_keys = HorizontalGroup:new{ align = "center" }, 0, {}
                rows[#rows + 1] = cur_keys
            else
                cur[#cur + 1] = HorizontalSpan:new{ width = gap }
                cur_w = cur_w + gap
            end
            cur[#cur + 1] = b
            cur_keys[#cur_keys + 1] = b
            cur_w = cur_w + bw_
        end
        if cur then cards[#cards + 1] = cur end

        local hint = text(_("Hold a button to step by 10. Tap a value to reset it."),
            { face = small, fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = inner_w })

        local body = VerticalGroup:new{ align = "left",
            top, VerticalSpan:new{ width = gap },
            looks, VerticalSpan:new{ width = gap },
            cards, VerticalSpan:new{ width = gap },
            hint,
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
