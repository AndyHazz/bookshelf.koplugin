-- bookshelf_page_dialog.lua (see STYLE.md)
-- A popup of its own laid out as a page of blocks (lib/bookshelf_editor_page),
-- for a screen outside the shelf editor that would otherwise be a stock
-- ButtonDialog: the title with its X, the page's strip and body, and a footer
-- when there is something to confirm (Cancel | Apply). Centred; it pages past
-- the room on the screen as the editor's pages do.
--   PageDialog.show{
--     title,                      the title line, or a function returning
--                                 it, read on every refresh (a value in it)
--     page = function() -> model  { strip = {blocks}, blocks = {blocks} },
--                                 laid out afresh on every refresh()
--     footer = { { text, callback, enabled_func, primary } ... } (optional)
--     on_close = function()       the X, a tap outside, Back (after closing)
--     dismissable = false         a tap outside does nothing (a nudge: rapid
--                                 taps fell through and closed it mid-edit)
--     at_bottom = true            a slim panel low on the screen, so more
--                                 of a live preview stays in sight
--     anchor = rect | function() -> rect   open under that rect (above it
--                                 when there is no room), not centred: a
--                                 nudge for the thing at the rect
--   } -> the dialog; dialog:refresh() lays it out again in place.

local Blitbuffer      = require("ffi/blitbuffer")
local Device          = require("device")
local FrameContainer  = require("ui/widget/container/framecontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local InputContainer  = require("ui/widget/container/inputcontainer")
local Size            = require("ui/size")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local Space           = require("lib/bookshelf_space")
local Screen          = Device.screen

local PageDialog = InputContainer:extend{
    title    = nil,
    page     = nil,
    footer   = nil,
    on_close = nil,
    dismissable = true,
    anchor   = nil,
    at_bottom = nil,
}

local FS = 20

function PageDialog:init()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    -- The shelf editor's width, so the two read as one kind of popup.
    self.width = math.floor(math.min(sw, sh) * 0.85)
    self.inset = Space.px(16)
    self.pg = 1
    -- The keys' cursor across rebuilds (Kit.keyFocus).
    self._key_state = {}
    self.frame = FrameContainer:new{
        radius = Space.radius.window, padding = 0, margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{},
    }
    -- Dragged out of the way, as KOReader's own dialogs can be (maintainer).
    -- Not a long-press: MovableContainer makes that a see-through toggle, and
    -- a long-press on a nudge's button is its big step.
    local MovableContainer = require("ui/widget/container/movablecontainer")
    self.movable = MovableContainer:new{ ignore_events = { "hold", "hold_release", "hold_pan" },
        self.frame }
    -- The footer runs to the frame's edge: its border is drawn again over it.
    local frame = self.frame
    function frame:paintTo(bb, x, y)
        FrameContainer.paintTo(self, bb, x, y)
        local sz = self:getSize()
        bb:paintBorder(x, y, sz.w, sz.h, self.bordersize, Blitbuffer.COLOR_BLACK, self.radius)
    end
    if self.anchor or self.at_bottom then
        -- Under the anchor's rect, centred across; above it with no room
        -- below; centred when the anchor has no rect now.
        local dialog = self
        local WidgetContainer = require("ui/widget/container/widgetcontainer")
        local holder = WidgetContainer:new{ dimen = Geom:new{ w = sw, h = sh }, dialog.movable }
        function holder:paintTo(bb, x, y)
            local a = dialog:_anchorRect()
            dialog._anchor_seen = a and Geom:new{ x = a.x, y = a.y, w = a.w, h = a.h } or false
            local sz = frame:getSize()
            local fx, fy = math.floor((sw - sz.w) / 2), math.floor((sh - sz.h) / 2)
            if dialog.at_bottom and not (a and a.y) then
                fy = sh - sz.h - Space.px(24)
            elseif a and a.y and a.h then
                local gap = Space.px(8)
                if a.y + a.h + gap + sz.h <= sh then fy = a.y + a.h + gap
                else fy = math.max(0, a.y - gap - sz.h) end
            end
            dialog.movable:paintTo(bb, x + fx, y + fy)
        end
        self[1] = holder
    else
        self[1] = CenterContainer:new{ dimen = Geom:new{ w = sw, h = sh }, self.movable }
    end
    if Device:isTouchDevice() then
        self.ges_events = { TapClose = { GestureRange:new{ ges = "tap",
            range = Geom:new{ x = 0, y = 0, w = sw, h = sh } } } }
    end
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    self:_build()
end

-- footerRow(w) -> the footer: equal buttons edge to edge under a full-width
-- line, thin separators between them, and the keys' row for them.
function PageDialog:_footerRow(w)
    local actions = {}
    for i, a in ipairs(self.footer) do
        local enabled = true
        if a.enabled_func then enabled = a.enabled_func() end
        actions[i] = { text = a.text, primary = a.primary, enabled = enabled, callback = a.callback }
    end
    return require("lib/bookshelf_popup_kit").footerRow(actions, w,
        { radius = Space.radius.window, show_parent = self })
end

-- _titleText() -> the title now: a function's answer, else the text.
function PageDialog:_titleText()
    if type(self.title) == "function" then return self.title() end
    return self.title
end

function PageDialog:_build()
    local TitleBar     = require("ui/widget/titlebar")
    local FocusManager = require("ui/widget/focusmanager")
    local EditorPage   = require("lib/bookshelf_editor_page")
    local title_bar = TitleBar:new{
        title_face = require("lib/bookshelf_popup_kit").titleFace(),
        width = self.width, title = self:_titleText(),
        with_bottom_line = true, bottom_v_padding = 0,
        close_callback = function() self:_dismiss() end,
        show_parent = self,
    }
    require("lib/bookshelf_popup_kit").centreTitle(title_bar)
    local footer, footer_btns
    if self.footer and #self.footer > 0 then
        footer, footer_btns = self:_footerRow(self.width)
    end
    local max_h = Screen:getHeight() - Space.px(96) - title_bar:getSize().h
        - (footer and footer:getSize().h or 0) - 2 * Size.border.window
    local strip, body, layout = EditorPage.render(self.page(), {
        width = self.width, inset = self.inset, font_size = FS, max_h = max_h,
        page = self.pg,
        on_page = function(n) self.pg = n; self:refresh() end,
    })
    if footer_btns then layout[#layout + 1] = footer_btns end
    local vg = VerticalGroup:new{ align = "left" }
    if strip then vg[#vg + 1] = strip end
    vg[#vg + 1] = body
    if footer then vg[#vg + 1] = footer end
    local fm = FocusManager:new{ layout = layout, show_parent = self, vg }
    -- The cursor on the first control, shown at the first key (STYLE.md);
    -- each page of a paged dialog seeds afresh.
    require("lib/bookshelf_popup_kit").keyFocus(fm, self._key_state, 1, self.pg)
    self.frame[1] = VerticalGroup:new{ align = "left", title_bar, fm }
end

-- _anchorRect() -> where the anchor is now (a rect, or a function's answer).
function PageDialog:_anchorRect()
    local a = self.anchor
    if type(a) == "function" then a = a() end
    return a
end

-- refresh(): lay the page out again from its model and repaint it in place;
-- what it no longer covers (a shorter page) is repainted from underneath.
function PageDialog:refresh()
    if not UIManager:isWidgetShown(self) then return end
    local d = self.frame.dimen
    local prev = d and d.x and Geom:new{ x = d.x, y = d.y, w = d.w, h = d.h }
    self:_build()
    local size = self.frame:getSize()
    -- Anchored: only when what it is anchored to moved (a module nudged
    -- along the shelf) is it somewhere else; the windows underneath were
    -- repainted on every tap (the whole shelf behind a size page).
    local moved = false
    if self.anchor then
        local a, seen = self:_anchorRect(), self._anchor_seen
        moved = (a and a.x and seen) and (a.x ~= seen.x or a.y ~= seen.y or a.h ~= seen.h) or false
    end
    if prev and (size.w ~= prev.w or size.h ~= prev.h or moved) then
        -- Centred: a change of size moves it too.
        UIManager:setDirty("all", "ui", prev)
        self.frame.dimen = nil
    end
    UIManager:setDirty(self, function()
        local now = self.frame.dimen
        return "ui", (now and now.x) and now or prev
    end)
end

-- over(tail) -> a LibraryModal config.over: a picker opened from this page
-- opens as a page of it, in its frame, titled "title > tail", its X closing
-- the whole dialog.
function PageDialog:over(tail)
    local dialog = self
    local crumbs = { self:_titleText() }
    for _i, t in ipairs(tail or {}) do crumbs[#crumbs + 1] = t end
    return {
        rect = function()
            local d = dialog.frame.dimen
            if not (d and d.x) then return nil end
            local size = dialog.frame:getSize()
            return { x = d.x, y = d.y, w = size.w, h = size.h }
        end,
        crumbs = table.concat(crumbs, " \xE2\x80\xBA "),
        on_exit = function() dialog:_dismiss() end,
    }
end

function PageDialog:_dismiss()
    UIManager:close(self)
    if self.on_close then self.on_close() end
end

function PageDialog:onTapClose(_arg, ges)
    local d = self.frame.dimen
    if self.dismissable ~= false and d and ges and ges.pos and ges.pos:notIntersectWith(d) then
        self:_dismiss()
    end
    return true
end

function PageDialog:onClose()
    self:_dismiss()
    return true
end

function PageDialog:onShow()
    UIManager:setDirty(self, function() return "ui", self.frame.dimen end)
    return true
end

function PageDialog:onCloseWidget()
    local d = self.frame.dimen
    UIManager:setDirty(nil, function() return "ui", d end)
end

function PageDialog.show(o)
    local dialog = PageDialog:new(o)
    UIManager:show(dialog)
    return dialog
end

-- KOReader's own gestures (the menu, brightness) keep working around it,
-- as over the shelf (GestureZones.overlayEvent; maintainer, PW5).
function PageDialog:handleEvent(event)
    -- Outside the frame KOReader's zones go first (the top menu, brightness:
    -- maintainer), then a tap no zone took closes it (onTapClose).
    -- A swipe from the top menu band opens KOReader's menu even over the
    -- dialog (GestureZones.onWindow): at the top, it covers that band.
    local GZ = require("lib/bookshelf_gesture_zones")
    return GZ.overlayEvent(self, event, InputContainer,
        GZ.onWindow(event, function(pos)
            local d = self.frame and self.frame.dimen
            return not (d and d.x) or not pos:notIntersectWith(d)
        end))
end

return PageDialog
