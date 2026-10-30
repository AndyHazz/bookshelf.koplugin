-- bookshelf_page_dialog.lua (see STYLE.md)
-- A popup of its own laid out as a page of blocks (lib/bookshelf_editor_page),
-- for a screen outside the shelf editor that would otherwise be a stock
-- ButtonDialog: the title with its X, the page's strip and body, and a footer
-- when there is something to confirm (Cancel | Apply). Centred; it pages past
-- the room on the screen as the editor's pages do.
--   PageDialog.show{
--     title,                      the title line
--     page = function() -> model  { strip = {blocks}, blocks = {blocks} },
--                                 laid out afresh on every refresh()
--     footer = { { text, callback, enabled_func, primary } ... } (optional)
--     on_close = function()       the X, a tap outside, Back (after closing)
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
}

local FS = 20

function PageDialog:init()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    -- The shelf editor's width, so the two read as one kind of popup.
    self.width = math.floor(math.min(sw, sh) * 0.85)
    self.inset = Space.px(16)
    self.pg = 1
    self.frame = FrameContainer:new{
        radius = Space.radius.window, padding = 0, margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{},
    }
    -- The footer runs to the frame's edge: its border is drawn again over it.
    local frame = self.frame
    function frame:paintTo(bb, x, y)
        FrameContainer.paintTo(self, bb, x, y)
        local sz = self:getSize()
        bb:paintBorder(x, y, sz.w, sz.h, self.bordersize, Blitbuffer.COLOR_BLACK, self.radius)
    end
    self[1] = CenterContainer:new{ dimen = Geom:new{ w = sw, h = sh }, frame }
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
    local Button          = require("ui/widget/button")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local LineWidget      = require("ui/widget/linewidget")
    local BFont           = require("lib/bookshelf_fonts")
    local n = #self.footer
    local each = math.floor(w / n)
    local hg = HorizontalGroup:new{ align = "center" }
    local btns = {}
    for i, a in ipairs(self.footer) do
        local enabled = true
        if a.enabled_func then enabled = a.enabled_func() end
        local face, bold = BFont:getFace("cfont", 16, { bold = a.primary == true })
        local btn = Button:new{
            text = a.text, face = face, bold = bold,
            bordersize = 0, radius = 0, padding_v = Space.px(12),
            width = (i == n) and (w - each * (n - 1)) or each,
            enabled = enabled,
            callback = function() if enabled then a.callback() end end,
            show_parent = self,
        }
        -- Rounded as the frame is, so the end buttons' white boxes don't
        -- square off its corners. (Not a nil background: a Button's tap
        -- feedback inverts it.)
        if btn.frame then btn.frame.radius = Space.radius.window end
        -- The keys' focus as the kit's ring inside it, not the button
        -- inverted (which reads as "on").
        local Kit = require("lib/bookshelf_popup_kit")
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

function PageDialog:_build()
    local TitleBar     = require("ui/widget/titlebar")
    local FocusManager = require("ui/widget/focusmanager")
    local EditorPage   = require("lib/bookshelf_editor_page")
    local title_bar = TitleBar:new{
        width = self.width, title = self.title,
        with_bottom_line = true, bottom_v_padding = 0,
        close_callback = function() self:_dismiss() end,
        show_parent = self,
    }
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
    self.frame[1] = VerticalGroup:new{ align = "left", title_bar,
        FocusManager:new{ layout = layout, show_parent = self, vg } }
end

-- refresh(): lay the page out again from its model and repaint it in place;
-- what it no longer covers (a shorter page) is repainted from underneath.
function PageDialog:refresh()
    if not UIManager:isWidgetShown(self) then return end
    local d = self.frame.dimen
    local prev = d and d.x and Geom:new{ x = d.x, y = d.y, w = d.w, h = d.h }
    self:_build()
    local size = self.frame:getSize()
    if prev and (size.w ~= prev.w or size.h ~= prev.h) then
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
    local crumbs = { self.title }
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
    if d and ges and ges.pos and ges.pos:notIntersectWith(d) then self:_dismiss() end
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
    return require("lib/bookshelf_gesture_zones").overlayEvent(self, event, InputContainer,
        function(pos)
            local d = self.frame and self.frame.dimen
            return not (d and d.x) or not pos:notIntersectWith(d)
        end)
end

return PageDialog
