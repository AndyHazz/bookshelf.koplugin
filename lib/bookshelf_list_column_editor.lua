--[[
lib/bookshelf_list_column_editor.lua

One editor per TEXT ROW of the list view. Settings > List view has two entries
into it -- "Single row columns" and "Second row columns" -- and each opens this
same widget bound to its own key. The rows are independent (row 2 may be empty,
may repeat a column from row 1), so two editors is the honest shape; one editor
with a row selector would have to invent a mode the data model does not have.

── Why it looks like the start menu ────────────────────────────────────────

The maintainer's ruling on the ButtonDialog picker this replaces: "the design
feels off - can we base it on the start menu design perhaps? that has checkbox
glyphs and we could easily add up/down buttons in a matching style. No need to
add/remove columns we just keep them all listed with checkbox toggles."

So the STYLE is borrowed from lib/bookshelf_start_menu.lua and nothing else is:
this is not built in the start menu and does not use its flyouts (the
maintainer ruled that out explicitly after I first over-read the note). What is
borrowed, and kept deliberately identical so the two surfaces read as one
family:

  * the checkbox glyphs, U+F14A fa-check-square / U+F096 fa-square-o
    (bookshelf_start_menu.lua:119-120);
  * the row shape -- pad, fixed-width icon column, gap, label, trailing
    controls -- from its _buildRow (:516);
  * the row height, Screen:scaleBySize(40) (:452), and the pad/icon-column
    proportions around it (:447-451).

The up/down controls are mdi-chevron-up / -down, the same glyph family the
start-menu and chip editors already use for "move this entry", rendered in the
same face and column width as the checkbox so the three glyphs on a row sit on
one grid.

── Why every column is always listed ───────────────────────────────────────

"No need to add/remove columns we just keep them all listed with checkbox
toggles." Add and remove are gone, and with them the second dialog the old
picker opened to offer the unused ones.

That has a structural payoff beyond the ruling: the row COUNT is now constant.
A toggle can only change glyphs and order, never the height of the panel, so a
tap can repaint the rows in place instead of tearing the dialog down and
building a new one (which is what the old picker did on every single tap, and
what its header spends a paragraph explaining).

── The order the rows are in ───────────────────────────────────────────────

Selected columns first, in the row's own order; everything else below in
catalogue order. Decided by Columns.editorRows, which documents why. Only a
selected column can move, and only within the selected block -- an unselected
column has nowhere to be, because the saved shape stores selected ids and
nothing else.

── One row has no checkbox ─────────────────────────────────────────────────

The title is REQUIRED in row 1, so that row is drawn with no checkbox at all
(not a disabled one) and still reorders. It is an ordinary toggleable entry in
row 2, where nothing is required because the whole row is optional.

Which columns those are, and the guarantee that a titleless row 1 cannot exist
whatever is on disk, are Columns.REQUIRED_IDS' business -- enforced on READ in
Columns.layout(), not here. This file only asks whether to draw the control.

── What this file does NOT decide ──────────────────────────────────────────

Any of it. The rules live in lib/bookshelf_list_columns.lua: savedIds reads
(through layout(), so the pre-branch single-key migration is inherited rather
than re-implemented), editorRows orders, toggled and moved mutate, saveRow
writes. This is a renderer.
]]

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LineWidget      = require("ui/widget/linewidget")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local Size            = require("ui/size")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local Screen          = Device.screen
local BFont           = require("lib/bookshelf_fonts")
local Columns         = require("lib/bookshelf_list_columns")
local _               = require("lib/bookshelf_i18n").gettext

-- The start menu's own glyphs, byte for byte (bookshelf_start_menu.lua:119).
local CHECK_ON_ICON  = "\xEF\x85\x8A" -- U+F14A fa-check-square
local CHECK_OFF_ICON = "\xEF\x82\x96" -- U+F096 fa-square-o
-- mdi-chevron-up / -down: what bookshelf_start_menu_edit.lua:240 and the chip
-- editor already mean by "move this entry one place".
local MOVE_UP_ICON   = "\xEE\xA1\x82" -- U+E842 mdi-chevron-up
local MOVE_DOWN_ICON = "\xEE\xA0\xBF" -- U+E83F mdi-chevron-down

local Editor = InputContainer:extend{
    -- 1 or 2: which text row this instance edits.
    row      = 1,
    -- Fires once, when the editor closes, whichever way it was closed. The
    -- shelf rebuild hangs off this rather than off every tap: the editor is a
    -- modal over the shelf, so repainting the shelf under it on each toggle
    -- would be work nobody can see.
    on_close = nil,
}

function Editor:init()
    self.dimen = Geom:new{ x = 0, y = 0,
        w = Screen:getWidth(), h = Screen:getHeight() }

    -- Chrome, in the start menu's proportions (bookshelf_start_menu.lua:447).
    -- No font-scale term: that menu scales by start_menu_font_scale, which is
    -- its own setting and has no business sizing a settings dialog.
    self._pad        = Screen:scaleBySize(10)
    self._row_h      = Screen:scaleBySize(40)
    self._icon_col_w = Screen:scaleBySize(30)
    self._icon_gap   = math.floor(self._pad / 2)
    -- The move controls get a wider column than the checkbox: the checkbox is
    -- read, the chevrons are aimed at, and a 30dp target next to another 30dp
    -- target is a mis-tap on any e-ink screen.
    self._ctrl_w     = Screen:scaleBySize(44)
    self._row_face   = BFont:getFace("cfont", 18)
    self._icon_face  = BFont:getFace("cfont", 22)
    self._title_face, self._title_bold = BFont:getFace("cfont", 18,
        { bold = true })

    self._ids = Columns.savedIds(self.row)

    self:_build()

    if Device:isTouchDevice() then
        self.ges_events = {
            TapDismiss = { GestureRange:new{ ges = "tap", range = self.dimen } },
        }
    end
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
end

-- save() -- ids to disk, then flush. Every tap is an action boundary here:
-- there is no OK button to batch behind, and the next thing the user does may
-- be to put the device to sleep.
function Editor:_save()
    -- Through Columns, not Store: that module owns both halves of the saved
    -- shape, names the key, copies the array and flushes. This file never
    -- spells a settings key and never decides what a valid one looks like.
    Columns.saveRow(self.row, self._ids)
end

-- One glyph in a fixed-width, row-tall cell. `dimmed` is the start menu's own
-- treatment for a control that is present but cannot act (its unresolved rows,
-- :518): dark grey rather than absent, so the row keeps its shape and the
-- column of chevrons stays a straight line down the dialog.
function Editor:_glyphCell(glyph, w, dimmed)
    return CenterContainer:new{
        dimen = Geom:new{ w = w, h = self._row_h },
        TextWidget:new{
            text = glyph,
            face = self._icon_face,
            fgcolor = dimmed and Blitbuffer.COLOR_DARK_GRAY
                or Blitbuffer.COLOR_BLACK,
        },
    }
end

-- One editor row: [checkbox] label [up] [down], padded out to exactly
-- content_w so its tap range covers the full width of the dialog.
--
-- ONE InputContainer per row, with the three targets separated by hit-testing
-- ges.pos inside the handler -- the same move the start menu's module rows
-- make (bookshelf_start_menu.lua:888, `local lx = ges.pos.x - self.dimen.x`).
--
-- The obvious alternative, a small InputContainer around each chevron nested
-- inside the row's, is BROKEN, and it looks correct until you test it. Gesture
-- dispatch does reach children first, so the reasoning starts out sound -- but
-- once a container's GestureRange matches, InputContainer:onGesture raises a
-- plain `Tap` event on ITSELF, and WidgetContainer:handleEvent offers that to
-- its children before its own handler. The nested chevron has an onTap, so it
-- consumes a Tap raised by the row, wherever on the row the finger actually
-- landed. Measured offscreen: tapping the left edge of the Title row moved
-- Title down a place.
--
-- Two named gesture events on one row (one range each) would not fix it
-- either: ges_events is walked with pairs(), so which of the overlapping
-- ranges wins is undefined.
function Editor:_buildRow(entry, content_w, n_on)
    local on = entry.on
    local id = entry.column.id
    local label_w = content_w - self._pad - self._icon_col_w - self._icon_gap
                    - 2 * self._ctrl_w - self._pad
    if label_w < Screen:scaleBySize(40) then
        label_w = Screen:scaleBySize(40)
    end

    local can_up   = on and entry.pos > 1
    local can_down = on and entry.pos < n_on
    local this = self

    -- An unchecked column's label is dark grey, the start menu's own
    -- treatment for a row that is present but not live (:518). It says "this
    -- one is not in the row" a second time, next to the empty checkbox, at no
    -- cost in furniture.
    local label = TextWidget:new{
        text = entry.column.label or id,
        face = self._row_face,
        max_width = label_w,
        fgcolor = on and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY,
    }
    -- A required column gets no checkbox at all -- a blank cell the width of
    -- one, so the labels stay on the same vertical line. Not a greyed or
    -- disabled checkbox: there is nothing to toggle, and a control that cannot
    -- act should not be drawn (the same reason the picker this replaces never
    -- appended a delete glyph to its undeletable row). Which columns those are
    -- is Columns.REQUIRED_IDS' business, not this file's.
    local check = " "
    if not entry.required then
        check = on and CHECK_ON_ICON or CHECK_OFF_ICON
    end
    local group = HorizontalGroup:new{
        align = "center",
        HorizontalSpan:new{ width = self._pad },
        self:_glyphCell(check, self._icon_col_w, false),
        HorizontalSpan:new{ width = self._icon_gap },
        label,
    }
    -- Push the two controls to the right edge with a measured filler, the way
    -- _buildRow pads out to its chevron slot: the label is left-aligned
    -- against the checkbox, the chevrons form one straight column down the
    -- dialog, and the row's own width is exactly content_w whatever the label
    -- measures.
    local used = self._pad + self._icon_col_w + self._icon_gap
                 + label:getSize().w
    group[#group + 1] = HorizontalSpan:new{
        width = math.max(0, content_w - used - 2 * self._ctrl_w - self._pad),
    }
    group[#group + 1] = self:_glyphCell(MOVE_UP_ICON, self._ctrl_w, not can_up)
    group[#group + 1] = self:_glyphCell(MOVE_DOWN_ICON, self._ctrl_w,
        not can_down)
    group[#group + 1] = HorizontalSpan:new{ width = self._pad }

    local row = InputContainer:new{
        dimen = Geom:new{ w = content_w, h = self._row_h },
        group,
    }
    if not Device:isTouchDevice() then return row end
    row.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = row.dimen } },
    }
    -- The three zones, measured from the row's own painted left edge so they
    -- track the dialog wherever it is and whatever the label measures. Same
    -- arithmetic as the filler above; the trailing pad is not a target.
    local ctrl_w, pad = self._ctrl_w, self._pad
    local function move(delta)
        this._ids = Columns.moved(this._ids, id, delta)
        this:_save()
        this:_refreshRows()
    end
    row.onTap = function(rself, _arg, ges)
        local rx = (ges and ges.pos and rself.dimen)
            and (ges.pos.x - rself.dimen.x) or 0
        local right = rself.dimen.w - pad
        if rx >= right - ctrl_w and rx < right then
            -- A dead chevron swallows its own tap rather than falling through
            -- to the checkbox: the finger was aimed at the control it is
            -- sitting on, and toggling the column instead would be the one
            -- thing the user definitely did not ask for.
            if can_down then move(1) end
            return true
        end
        if rx >= right - 2 * ctrl_w and rx < right - ctrl_w then
            if can_up then move(-1) end
            return true
        end
        local next_ids = Columns.toggled(this._ids, id, this.row)
        -- Refused (a required column, or the last column of row 1): leave the
        -- screen alone rather than repaint an identical dialog and imply
        -- something happened.
        if next_ids == this._ids then return true end
        this._ids = next_ids
        this:_save()
        this:_refreshRows()
        return true
    end
    return row
end

-- A full-width centred label row, in the same proportions as an entry row.
-- Used for the title and for Close, so the dialog is one stack of rows rather
-- than rows with dialog furniture bolted on.
function Editor:_labelRow(text, content_w, bold, on_tap)
    local inner = CenterContainer:new{
        dimen = Geom:new{ w = content_w, h = self._row_h },
        TextWidget:new{
            text = text,
            face = bold and self._title_face or self._row_face,
            bold = bold and self._title_bold or false,
            max_width = content_w - 2 * self._pad,
        },
    }
    if not on_tap or not Device:isTouchDevice() then return inner end
    local row = InputContainer:new{
        dimen = Geom:new{ w = content_w, h = self._row_h },
        inner,
    }
    row.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = row.dimen } },
    }
    row.onTap = function() on_tap() return true end
    return row
end

-- The same rule the start menu draws between groups of entries: COLOR_GRAY at
-- Size.line.medium (its _buildDividerRow, :915). Not Size.line.thin, which is
-- scaleBySize(0.5) and can round away to nothing on a low-DPI panel.
function Editor:_divider(w)
    return LineWidget:new{
        background = Blitbuffer.COLOR_GRAY,
        dimen = Geom:new{ w = w, h = Size.line.medium },
    }
end

-- Widest label plus the row's fixed chrome, clamped. The dialog is sized to
-- its content rather than to a fraction of the screen, so it does not sprawl
-- in landscape and does not truncate "Progress" on a 600px Kindle.
function Editor:_contentWidth()
    local widest = 0
    for _i, c in ipairs(Columns.CATALOGUE) do
        local probe = TextWidget:new{ text = c.label or c.id, face = self._row_face }
        local w = probe:getSize().w
        probe:free()
        if w > widest then widest = w end
    end
    local chrome = self._pad + self._icon_col_w + self._icon_gap
                   + 2 * self._ctrl_w + self._pad
    local border = Size.border.window
    local screen_w = Screen:getWidth()
    local max_w = math.floor(screen_w * 0.92) - 2 * border
    local min_w = math.floor(screen_w * 0.55)
    local want  = widest + chrome
    if want < min_w then want = min_w end
    if want > max_w then want = max_w end
    return want
end

-- Fill (or refill) the scrolling rows group from the current ids. The child
-- COUNT and every child's height are the same on every call -- one row per
-- catalogue column, plus exactly one divider -- so the group's size never
-- changes and neither does the dialog's.
function Editor:_fillRows(vg, content_w)
    for k in pairs(vg) do
        if type(k) == "number" then vg[k] = nil end
    end
    -- Emptying the children does NOT drop VerticalGroup's cached _size and
    -- _offsets; paintTo indexes _offsets per child, so a refill against a
    -- stale cache paints rows on top of each other. resetLayout is the
    -- supported way to drop both (same gotcha bookshelf_sort_priority_list.lua
    -- and bookshelf_widget.lua's in-place row swap both document).
    if vg.resetLayout then vg:resetLayout() end
    local entries = Columns.editorRows(self._ids, self.row)
    -- Counted off the ENTRIES, not off #self._ids: the two agree today
    -- (savedIds resolves and de-duplicates before the editor ever sees them),
    -- and if they ever stopped agreeing the divider would go missing and the
    -- dialog would change height under the in-place repaint.
    local n_on = 0
    for _i, entry in ipairs(entries) do
        if entry.on then n_on = n_on + 1 end
    end
    -- The divider goes after the last selected row -- at the very top when
    -- nothing is selected, at the very bottom when everything is. Always
    -- exactly one, wherever it lands, which is what keeps the height constant.
    if n_on == 0 then vg[#vg + 1] = self:_divider(content_w) end
    for _i, entry in ipairs(entries) do
        vg[#vg + 1] = self:_buildRow(entry, content_w, n_on)
        if entry.on and entry.pos == n_on then
            vg[#vg + 1] = self:_divider(content_w)
        end
    end
end

-- Repaint the rows in place after a toggle or a move. Scoped to the dialog's
-- own rect: the shelf underneath has not changed and must not flash.
function Editor:_refreshRows()
    if not self._rows_vg then return end
    -- _rows_w, not the dialog width: the rows are narrower than the dialog
    -- whenever the vertical scrollbar is present (see _build).
    self:_fillRows(self._rows_vg, self._rows_w)
    UIManager:setDirty(self, "ui", self._panel_region)
end

function Editor:close()
    UIManager:close(self)
    if self.on_close then self.on_close() end
end

function Editor:_build()
    local content_w = self:_contentWidth()

    -- Cap the scrolling area so the dialog always fits: title + divider +
    -- rows + divider + Close, inside the frame's border. Fourteen columns at
    -- 40dp clears a 1648px panel easily and is tight on a 600x800 Kindle, so
    -- the cap is what keeps the small end honest rather than an optimisation.
    local border  = Size.border.window
    local chrome_h = 2 * self._row_h + 2 * Size.line.medium + 2 * border
    local max_rows_h = math.floor(Screen:getHeight() * 0.92) - chrome_h
    if max_rows_h < self._row_h then max_rows_h = self._row_h end

    -- Decided BEFORE the rows are built, from the row count rather than from a
    -- measurement, because it changes how wide they are: when the vertical
    -- scrollbar is going to appear, ScrollableContainer crops its content to
    -- dimen.w minus THREE bar widths (gap | bar | gap) and decides horizontal
    -- overflow against that crop -- so rows built flush to dimen.w read as
    -- overflowing sideways and it grows a horizontal scrollbar too, which then
    -- eats a row's worth of height off the bottom. Seen offscreen at 600x480.
    -- (bookshelf_widget.lua's SnugScroll reclaims those gaps instead; it is a
    -- local in that file, and one dialog does not justify lifting it out.)
    local rows_h = #Columns.CATALOGUE * self._row_h + Size.line.medium
    local scrolling = rows_h > max_rows_h
    local bar_reserve = scrolling
        and (3 * (ScrollableContainer.scroll_bar_width or 0)) or 0
    self._rows_w = content_w - bar_reserve

    local vg = VerticalGroup:new{ align = "left" }
    self._rows_vg = vg
    self:_fillRows(vg, self._rows_w)

    local view_h = math.min(vg:getSize().h, max_rows_h)

    -- ScrollableContainer is a pass-through when the content fits (it sets
    -- _is_scrollable = false and paints the child straight through), so this
    -- costs nothing on the screens that do not need it.
    local scroll = ScrollableContainer:new{
        dimen = Geom:new{ w = content_w, h = view_h },
        show_parent = self,
        vg,
    }
    self.cropping_widget = scroll

    local body = VerticalGroup:new{
        align = "left",
        self:_labelRow(self.row == 2 and _("Second row columns")
                                      or _("Single row columns"),
            content_w, true),
        self:_divider(content_w),
        scroll,
        self:_divider(content_w),
        self:_labelRow(_("Close"), content_w, false, function()
            self:close()
        end),
    }

    local frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = border,
        padding    = 0,
        margin     = 0,
        body,
    }
    local fs = frame:getSize()
    self[1] = CenterContainer:new{
        dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() },
        frame,
    }
    -- Where CenterContainer will put it. Used both to scope the in-place
    -- repaint and to tell an inside tap from an outside one.
    self._panel_region = Geom:new{
        x = math.floor((Screen:getWidth() - fs.w) / 2),
        y = math.floor((Screen:getHeight() - fs.h) / 2),
        w = fs.w, h = fs.h,
    }
end

-- Tap outside the dialog dismisses it, matching every other modal in the
-- plugin. A tap INSIDE that no row claimed (the title, the gap beside a
-- label) is swallowed rather than declined: declining would let it fall
-- through to the shelf below, which would act on it.
function Editor:onTapDismiss(_a, ges)
    if ges and ges.pos and self._panel_region
       and ges.pos:intersectWith(self._panel_region) then
        return true
    end
    self:close()
    return true
end

function Editor:onClose()
    self:close()
    return true
end

function Editor:onCloseWidget()
    -- Repaint what the dialog was covering.
    UIManager:setDirty(nil, "ui", self._panel_region)
end

-- Editor.show{ row = 1|2, on_close = fn }
function Editor.show(opts)
    opts = opts or {}
    local e = Editor:new{
        row      = (opts.row == 2) and 2 or 1,
        on_close = opts.on_close,
    }
    -- Scoped to the dialog's own rect: nothing outside it changes, and a
    -- full-screen refresh here is a visible flash on e-ink for no reason.
    UIManager:show(e, "ui", e._panel_region)
    return e
end

return Editor
