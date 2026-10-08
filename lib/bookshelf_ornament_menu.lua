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

-- OrnDialog: a ButtonDialog whose region reaches above its frame by
-- self.overhang px, a strip that paints nothing (the shelf shows through)
-- but that the dialog owns, so opening refreshes it and closing repaints
-- what is under it. Without it the risen part of the picture would ghost.
local OrnDialog
local function dialogClass()
    if OrnDialog then return OrnDialog end
    local ButtonDialog = require("ui/widget/buttondialog")
    OrnDialog = ButtonDialog:extend{ overhang = 0 }
    function OrnDialog:init()
        ButtonDialog.init(self)
        if (self.overhang or 0) > 0 and self.movable and self.movable[1] then
            local VerticalGroup = require("ui/widget/verticalgroup")
            local VerticalSpan  = require("ui/widget/verticalspan")
            self.movable[1] = VerticalGroup:new{
                align = "left",
                VerticalSpan:new{ width = self.overhang },
                self.movable[1],
            }
        end
    end
    return OrnDialog
end

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
function M.show(entry, bw, piece)
    local UIManager    = require("ui/uimanager")
    local Orn = O()
    -- The LIVE entry for this piece: the shelf's own may be older than the
    -- last rescan (see Orn.current). Every label below reads this upvalue.
    entry = Orn.current(entry)
    local dialog

    local Screen = require("device").screen
    -- Worked out against the menu's own height each time it is (re)built:
    -- its rows can change size.
    local function place()
        if not (dialog and dialog.movable) then return end
        local h
        pcall(function() h = dialog.movable[1]:getSize().h end)
        local dy = M.offsetFor(piece, Screen:getHeight(), h)
        if dy ~= 0 then dialog.movable:setMovedOffset({ x = 0, y = dy }) end
    end
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
    -- headerWidget(): the picture top left (a plain picture, not a live
    -- ornament, so a hold on it cannot open a second menu), the name and the
    -- pack beside it. parent = the dialog: ButtonDialog keeps added widgets
    -- that have one across a reinit.
    local function headerWidget()
        local Widget          = require("ui/widget/widget")
        local HorizontalGroup = require("ui/widget/horizontalgroup")
        local HorizontalSpan  = require("ui/widget/horizontalspan")
        local VerticalGroup   = require("ui/widget/verticalgroup")
        local CenterContainer = require("ui/widget/container/centercontainer")
        local LeftContainer   = require("ui/widget/container/leftcontainer")
        local TextWidget      = require("lib/bookshelf_colour_text")
        local Font            = require("ui/font")
        local Geom            = require("ui/geometry")
        local avail = dialog:getAddedWidgetAvailableWidth()
        local pl = picture()
        local night = nightNow()
        local d = Screen:scaleBySize(M.SHADOW_DP)
        local rise = overhangFor(pl)
        -- The slot is the header row; a taller picture stands on its foot and
        -- rises out of the top, a shorter one is centred in it.
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
        local gap = Screen:scaleBySize(10)
        -- The collection's own icon, top right: the way to manage every
        -- piece from the one being edited (maintainer).
        local Button = require("ui/widget/button")
        local manage = Button:new{
            text = Orn.COLLECTION_ICON, text_font_face = "symbols",
            text_font_size = GLYPH_SIZE, bordersize = 0, padding = Screen:scaleBySize(6),
            show_parent = dialog,
            callback = function()
                UIManager:close(dialog)
                require("lib/bookshelf_ornament_browser").show(function()
                    if bw and bw._rebuild then bw:_rebuild(); UIManager:setDirty(bw, "ui") end
                end)
            end,
        }
        local text_w = math.max(1, avail - pic.dimen.w - gap - manage:getSize().w)
        local sub = entry.pack or ""
        if SW().isOff(entry.name) then
            sub = (sub ~= "" and (sub .. " \xC2\xB7 ") or "") .. _("switched off")   -- U+00B7 middle dot
        end
        local lines = VerticalGroup:new{ align = "left",
            TextWidget:new{ text = Orn.displayName(entry), face = Font:getFace("x_smalltfont"),
                            bold = true, max_width = text_w },
        }
        if sub ~= "" then
            lines[#lines + 1] = TextWidget:new{ text = sub, face = Font:getFace("x_smallinfofont"),
                                                max_width = text_w }
        end
        local box = HorizontalGroup:new{ align = "center",
            pic,
            HorizontalSpan:new{ width = gap },
            LeftContainer:new{ dimen = Geom:new{ w = text_w, h = header_h }, lines },
            manage,
        }
        box.parent, box.not_focusable = dialog, true
        return box
    end
    local function redraw()
        if bw and bw._rebuild then
            -- The piece's size moves where rows, and so pages, break later
            -- on: those are re-learnt, and this page keeps its start.
            if bw._dropOrnPages then bw:_dropOrnPages(true) end
            bw:_rebuild()
            UIManager:setDirty(bw, "ui")
        end
        -- reinit builds a new MovableContainer: put the offset back. The
        -- picture follows the piece (its mirroring).
        if dialog then
            dialog._added_widgets = { headerWidget() }
            dialog:reinit(); place()
        end
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
    local function glyph(text, field, sign)
        return {
            text = text, font_face = "symbols", font_size = GLYPH_SIZE,
            callback      = function() nudge(field, sign, false) end,
            hold_callback = function() nudge(field, sign, true) end,
        }
    end
    -- bigButton(field, sign): the outer ten-point step, for getting far
    -- quickly (maintainer); the inner buttons fine-tune.
    local function bigButton(field, sign)
        return {
            text = (sign > 0 and "+" or "\xE2\x88\x92") .. "10",
            callback = function() nudge(field, sign, true) end,
        }
    end
    local function plusMinus(field, label_func)
        return {
            bigButton(field, -1),
            { text = "\xE2\x88\x92", callback = function() nudge(field, -1, false) end,   -- U+2212 minus
              hold_callback = function() nudge(field, -1, true) end },
            { text_func = label_func, callback = function() set(field, nil) end },
            { text = "+", callback = function() nudge(field, 1, false) end,
              hold_callback = function() nudge(field, 1, true) end },
            bigButton(field, 1),
        }
    end

    -- The pieces that are on, in this shelf's saved order: what "place"
    -- counts and what Earlier / Later step through. Every shelf has its own
    -- deck, and the one held is the one on screen.
    local shelf = bw and bw.chip
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
    -- placeGlyph(glyph, delta): a move chevron. Unlike the shelf editor's it
    -- wraps round past either end (the deck is a loop), so it is greyed out
    -- only for a piece that is switched off or alone.
    local function placeGlyph(text, delta)
        return {
            text = text, font_face = "symbols", font_size = GLYPH_SIZE, font_bold = false,
            enabled_func = function()
                local on = onNames()
                local i = Deck.position(entry.name, on)
                return i ~= nil and #on > 1
            end,
            callback = function() step(delta) end,
        }
    end

    local MIRROR_NEXT = { off = "always", always = "alternate", alternate = "off" }
    local MIRROR_LABEL = {
        off       = _("Mirror: off"),
        always    = _("Mirror: always"),
        alternate = _("Mirror: alternate"),
    }

    local function closeAnd(fn)
        return function()
            UIManager:close(dialog)
            if fn then fn() end
        end
    end

    local buttons = {
        -- Where it comes round, first: what a reader arranging a shelf
        -- reaches for most.
        {
            placeGlyph(CHEV_LEFT, -1),
            { text_func = function()
                local i, n = Deck.position(entry.name, onNames())
                if not i then return _("Place: off") end
                return T(_("Place: %1 of %2"), i, n)
            end, callback = function() end },
            placeGlyph(CHEV_RIGHT, 1),
        },
        plusMinus("scale", function()
            return T(_("Size: %1"), string.format("%d%%", math.floor((Orn.readerValue(entry, "scale") or 1) * 100 + 0.5)))
        end),
        plusMinus("pad", function()
            return T(_("Padding: %1"), pct(Orn.readerValue(entry, "pad")))
        end),
        -- Down on the left, up on the right, as - and + are on the rows above.
        {
            bigButton("lift", -1),
            glyph(CHEV_DOWN, "lift", -1),
            { text_func = function() return T(_("Height: %1"), pct(Orn.readerValue(entry, "lift"))) end,
              callback = function() set("lift", nil) end },
            glyph(CHEV_UP, "lift", 1),
            bigButton("lift", 1),
        },
        -- One row, short labels: the menu has to fit a small screen whole.
        -- The anchor between them (maintainer): what Height counts from.
        {
            { text_func = function() return MIRROR_LABEL[entry.mirror or "off"] end,
              callback = function() set("mirror", MIRROR_NEXT[entry.mirror or "off"]) end },
            { text_func = function()
                return entry.anchor == "top" and _("Anchor: top") or _("Anchor: bottom")
            end, callback = function() setAnchor(entry.anchor == "top" and "bottom" or "top") end },
            { text_func = function()
                local tap = entry.tap
                return tap and T(_("Tap: %1"), (tap.zoom and _("Zoom")) or tap.label or _("set"))
                       or _("Tap: none")
            end, callback = function() M.chooseTap(entry, redraw) end },
        },
        {
            { text = _("Swap"), callback = closeAnd(function()
                -- The browser in pick mode: the chosen piece takes this one's
                -- place in the order, and this one takes the chosen piece's.
                require("lib/bookshelf_ornament_browser").show(function()
                    if bw and bw._rebuild then bw:_rebuild(); UIManager:setDirty(bw, "ui") end
                end, { pool = (function()
                    -- Only the pieces this shelf deals from: a shelf that
                    -- wears a theme deals that pack's pieces alone.
                    -- A theme whose set is edited may switch on any piece:
                    -- all of them.
                    local sp = require("lib/bookshelf_theme_pack").ornamentsFor(shelf)
                    if sp == "mine" or type(sp) == "table" then return nil end
                    return function(e) return e.pack ~= nil and e.pack == sp end
                end)(), pick = function(chosen)
                    -- A piece never in the order yet (it was off) joins it first.
                    Deck.sync(Orn.listAll(), shelf)
                    Deck.swap(entry.name, chosen.name, shelf)
                end })
            end) },
            -- A new order for this shelf's deck (the "Bookshelf: shuffle
            -- ornaments" action), which also clears its swaps.
            -- Asks first: an arrangement may have had a lot of care put into it
            -- (maintainer).
            { text = _("Shuffle this shelf"), callback = function()
                local ConfirmBox = require("ui/widget/confirmbox")
                UIManager:show(ConfirmBox:new{
                    text = _("Shuffle this shelf's ornaments into a new order? Its swaps and moves are lost."),
                    ok_text = _("Shuffle"),
                    ok_callback = function()
                        UIManager:close(dialog)
                        if bw and bw.onBookshelfShuffleOrnaments then bw:onBookshelfShuffleOrnaments() end
                    end,
                })
            end },
            -- Out of the deck and back, with the menu still open: a piece
            -- switched off keeps its place in the saved order, so switching
            -- it back on puts it where it stood (maintainer).
            { text_func = function() return SW().isOff(entry.name) and _("Switch on") or _("Switch off") end,
              callback = function()
                local sw = SW()
                sw.setOff(entry.name, not sw.isOff(entry.name))
                redraw()
            end },
        },
        {
            { text = _("Reset"), callback = function()
                Orn.readerReset(entry)
                entry = Orn.current(entry)
                redraw()
            end },
            { text = _("Done"), callback = closeAnd() },
        },
    }
    dialog = dialogClass():new{
        buttons = buttons,
        overhang = overhangFor(picture()),
        -- Rapid nudges land outside now and then; a tap there must not close
        -- it (as every nudge dialog). Done or Back closes.
        dismissable = false,
    }
    -- However it closes (Done, a tap outside, Back): write the reader's file
    -- once. ButtonDialog has no close callback of its own for all three.
    dialog:addWidget(headerWidget())
    place()
    local closeWidget = dialog.onCloseWidget
    function dialog:onCloseWidget(...)
        Orn.saveReader()
        if closeWidget then return closeWidget(self, ...) end
    end
    UIManager:show(dialog)
    return dialog
end

-- chooseTap(entry, done): the Action module's chooser, plus "no action".
function M.chooseTap(entry, done)
    local UIManager    = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")
    local Chooser      = require("lib/bookshelf_action_chooser")
    local d
    local function close(fn)
        return function() UIManager:close(d); if fn then fn() end end
    end
    local rows = Chooser.actionRows(close, function(fields)
        O().readerSet(entry, "tap", {
            action = fields.action, plugin = fields.plugin,
            internal = fields.internal, label = fields.label,
        })
        if done then done() end
    end)
    table.insert(rows, 1, {{
        text = _("No action"),
        callback = close(function()
            O().readerSet(entry, "tap", nil)
            if done then done() end
        end),
    }, {
        -- The piece full screen, with its info (or its name) under it.
        text = _("Zoom"),
        callback = close(function()
            O().readerSet(entry, "tap", "zoom")
            if done then done() end
        end),
    }})
    d = ButtonDialog:new{ title = _("Tap action"), title_align = "center",
                          width_factor = 0.65, buttons = rows }
    UIManager:show(d)
end

return M
