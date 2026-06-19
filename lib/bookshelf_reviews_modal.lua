-- bookshelf_reviews_modal.lua
-- A small modal that renders Hardcover review HTML (built + sanitised by
-- bookshelf_tokens.reviewsHtml) through KOReader's MuPDF-backed
-- ScrollHtmlWidget, so reviewer names can be italic, headers bold, and the
-- review body keeps its own paragraph/emphasis formatting.
--
-- This replaces the previous plain-text TextViewer for reviews: TextViewer
-- has no inline markup. We keep a title bar plus Refresh / Close buttons and
-- close on a tap outside the frame, mirroring the standard popup idiom.

local Blitbuffer      = require("ffi/blitbuffer")
local ButtonTable     = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Font            = require("ui/font")
local FontList        = require("fontlist")
local FrameContainer  = require("ui/widget/container/framecontainer")
local ffiutil         = require("ffi/util")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LineWidget      = require("ui/widget/linewidget")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local Size            = require("ui/size")
local TextWidget      = require("ui/widget/textwidget")
local TitleBar        = require("ui/widget/titlebar")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local Store           = require("lib/bookshelf_settings_store")
local Screen          = Device.screen
local _               = require("lib/bookshelf_i18n").gettext

-- Reader-adjustable font size for the HTML body (description + reviews share
-- this modal, so they share one setting). Stored as a base point size and run
-- through Screen:scaleBySize like KOReader's dictionary popup. The A- / A+
-- footer buttons step it within [MIN, MAX] and persist the choice.
local DESC_FONT_KEY     = "desc_font_size"
local DESC_FONT_DEFAULT = 20
local DESC_FONT_MIN     = 12
local DESC_FONT_MAX     = 40
local DESC_FONT_STEP    = 2

-- Nerd Font zoom glyphs for the font-size buttons, rendered via KOReader's
-- built-in "symbols" face (the bundled Nerd Font symbols font).
-- U+F00E = nf-fa-search_plus, U+F010 = nf-fa-search_minus.
-- The buttons set font_bold=false: the symbols font has no bold variant, so
-- the ButtonTable default bold would FAUX-bold (synthesise) the glyph and
-- thicken/distort it. Non-bold renders the icon as designed.
local ZOOM_IN_GLYPH  = "\xEF\x80\x8E"
local ZOOM_OUT_GLYPH = "\xEF\x80\x90"

-- Minimal stylesheet for the MuPDF HTML renderer. Keep it conservative --
-- the engine supports a CSS subset. The body margin gives a little side
-- breathing room since the frame itself has no inner horizontal padding.
-- NOTE: the body side margin is intentionally NOT set here -- it's appended
-- in init() as a fixed (DPI-scaled, font-independent) pixel value so that
-- bumping the font size doesn't also widen the side gutter (issue: increasing
-- font shrinks the text column). Paragraph spacing is a clear bottom gap so
-- separate paragraphs read as separate, matching the hero blurb's blank-line
-- separation rather than running together.
local REVIEW_CSS = [[
    @page  { margin: 0; }
    body   { margin: 0; padding: 0; font-family: sans-serif; }
    h1     { font-size: 1.8em; margin: 0 0 0.15em 0; padding: 0; }
    p      { margin: 0 0 0.7em 0; text-align: left; }
    .stars   { font-family: "nerdstars"; font-size: 1.15em; }
    p.stars  { margin: 0.5em 0 0.05em 0; }
    p.rating { margin: 0 0 0.5em 0; }
    p.byline { margin: 0 0 0.25em 0; }
    hr     { border: 0; border-top: 1px solid #888888; margin: 0.7em 0 0.4em 0; }
    i, em       { font-style: italic; }
    b, strong   { font-weight: bold; }
    blockquote  { margin: 0.4em 1em; color: #444444; }
    ul, ol      { margin: 0.3em 0 0.3em 1.2em; }
]]

-- A minimal browser-style tab strip: text-width tabs (equal padding, no
-- separators between them), a solid bottom baseline spanning the full width,
-- and the active tab drawn as a box (top + sides, square corners) whose bottom
-- is open -- the baseline is broken under it so it reads as connected to the
-- content below. Tapping an inactive tab fires on_select(index).
local TabBar = InputContainer:extend{
    tabs       = nil,   -- { "Book", "Hardcover", ... }
    active     = 1,
    width      = nil,
    left_inset = nil,   -- x of the first tab; align with the body text's left
    on_select  = nil,
}

function TabBar:init()
    self.left_inset = self.left_inset or Screen:scaleBySize(10)
    self.top_pad    = Screen:scaleBySize(12)   -- gap above the tabs (below title bar)
    self.pad_h      = Screen:scaleBySize(14)
    self.pad_v      = Screen:scaleBySize(6)
    self.border     = Screen:scaleBySize(2)
    self.face       = Font:getFace("cfont", Screen:scaleBySize(16))

    self._labels, self._tab_x, self._tab_w = {}, {}, {}
    local x = self.left_inset
    local label_h = 0
    for i, label in ipairs(self.tabs) do
        local tw = TextWidget:new{ text = label, face = self.face }
        self._labels[i] = tw
        local sz = tw:getSize()
        self._tab_w[i] = sz.w + 2 * self.pad_h
        self._tab_x[i] = x
        x = x + self._tab_w[i]
        if sz.h > label_h then label_h = sz.h end
    end
    self.dimen = Geom:new{
        x = 0, y = 0,
        w = self.width,
        h = self.top_pad + label_h + 2 * self.pad_v + self.border,
    }
    if Device:isTouchDevice() then
        self.ges_events = {
            TapTab = { GestureRange:new{ ges = "tap", range = self.dimen } },
        }
    end
end

function TabBar:getSize() return self.dimen end

function TabBar:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local border      = self.border
    local box_top     = y + self.top_pad     -- gap above the tabs
    local baseline_y  = y + self.dimen.h - border
    local box_h       = baseline_y - box_top
    -- Full-width baseline.
    bb:paintRect(x, baseline_y, self.dimen.w, border, Blitbuffer.COLOR_BLACK)
    -- Active tab box: top + left + right (no bottom), square corners.
    local ax = x + self._tab_x[self.active]
    local aw = self._tab_w[self.active]
    bb:paintRect(ax, box_top, aw, border, Blitbuffer.COLOR_BLACK)                  -- top
    bb:paintRect(ax, box_top, border, box_h, Blitbuffer.COLOR_BLACK)              -- left
    bb:paintRect(ax + aw - border, box_top, border, box_h, Blitbuffer.COLOR_BLACK) -- right
    -- Open the bottom: erase the baseline under the active tab's interior so it
    -- connects to the content below.
    bb:paintRect(ax + border, baseline_y, aw - 2 * border, border, Blitbuffer.COLOR_WHITE)
    -- Labels.
    for i, tw in ipairs(self._labels) do
        tw:paintTo(bb, x + self._tab_x[i] + self.pad_h, box_top + self.pad_v)
    end
end

function TabBar:onTapTab(_arg, ges)
    if not (ges and ges.pos) then return false end
    local rel = ges.pos.x - self.dimen.x
    for i = 1, #self.tabs do
        if rel >= self._tab_x[i] and rel < self._tab_x[i] + self._tab_w[i] then
            if i ~= self.active and self.on_select then self.on_select(i) end
            return true
        end
    end
    return true   -- swallow taps elsewhere on the strip
end

local ReviewsModal = InputContainer:extend{
    title      = nil,
    subtitle   = nil,   -- optional second line under the title (e.g. source note)
    html_body  = nil,
    tabs       = nil,   -- optional { {label=, html=}, ... }; >1 shows a tab bar
    active_tab = nil,   -- 1-based index of the initially-selected tab
    on_tab_close = nil, -- optional fn(active_tab_index) fired once on dismiss
    width      = nil,
    height     = nil,
    on_refresh = nil,   -- optional callback fired by the Refresh button
    on_close   = nil,   -- optional callback fired once when the modal is
                        -- genuinely dismissed (NOT on Refresh, which reopens).
                        -- Used to return to the caller (e.g. the book menu)
                        -- when opened from there; left nil for the hero
                        -- "N reviews" tap, which just closes.
}

function ReviewsModal:init()
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    -- Near-fullscreen with the standard screen-edge inset (matches TextViewer).
    self.width  = self.width  or (screen_w - Screen:scaleBySize(30))
    self.height = self.height or (screen_h - Screen:scaleBySize(30))

    -- Persisted, reader-adjustable body font size (shared by description +
    -- reviews). Clamp on read so a hand-edited settings file can't break layout.
    local saved = tonumber(Store.read(DESC_FONT_KEY, DESC_FONT_DEFAULT)) or DESC_FONT_DEFAULT
    if saved < DESC_FONT_MIN then saved = DESC_FONT_MIN end
    if saved > DESC_FONT_MAX then saved = DESC_FONT_MAX end
    self.font_size = saved

    -- Source tabs (e.g. File vs Hardcover description). Only meaningful with 2+.
    self._tabs = (type(self.tabs) == "table" and #self.tabs > 0) and self.tabs or nil
    self._active_tab = self.active_tab or 1
    if self._tabs and (self._active_tab < 1 or self._active_tab > #self._tabs) then
        self._active_tab = 1
    end

    -- Horizontal content padding (px), shared by the HTML body's CSS padding and
    -- the tab strip's left inset so the first tab lines up with the body text.
    self._side_pad = Screen:scaleBySize(56)

    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    if Device:isTouchDevice() then
        local full = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h }
        self.ges_events = {
            TapClose = {
                GestureRange:new{ ges = "tap", range = full },
            },
            -- #171: any multiswipe closes the window, matching KOReader's
            -- fullscreen widgets (TextViewer etc.) -- consistent with the
            -- native Show-info description window the reporter referenced.
            MultiSwipe = {
                GestureRange:new{ ges = "multiswipe", range = full },
            },
        }
    end

    self.titlebar = TitleBar:new{
        width            = self.width,
        align            = "left",
        with_bottom_line = true,
        title            = self.title or _("Hardcover reviews"),
        subtitle         = self.subtitle,
        close_callback   = function() self:onClose() end,
        show_parent      = self,
    }

    -- Refresh only makes sense when the caller supplied an on_refresh (the
    -- reviews use it to re-fetch). Reused for plain HTML content (e.g. a book
    -- description), where there's nothing to refresh, it's omitted and only
    -- Close remains.
    local button_row = {}
    if self.on_refresh then
        button_row[#button_row + 1] = {
            text = _("Refresh"),
            callback = function()
                local cb = self.on_refresh
                -- Refresh reopens the modal, so suppress the
                -- return-on-close callback for this close.
                self._suppress_close_cb = true
                self:onClose()
                if cb then cb() end
            end,
        }
    end
    -- Font size controls (description text was reported as too small and not
    -- adjustable, issue #116). Step down / up within the clamp; the change
    -- re-renders the HTML in place and persists.
    button_row[#button_row + 1] = {
        text = ZOOM_OUT_GLYPH,
        font_face = "symbols",
        font_bold = false,
        callback = function() self:_changeFontSize(-DESC_FONT_STEP) end,
    }
    button_row[#button_row + 1] = {
        text = ZOOM_IN_GLYPH,
        font_face = "symbols",
        font_bold = false,
        callback = function() self:_changeFontSize(DESC_FONT_STEP) end,
    }
    button_row[#button_row + 1] = {
        text = _("Close"),
        callback = function() self:onClose() end,
    }
    local buttons = ButtonTable:new{
        width = self.width,
        buttons = { button_row },
        show_parent = self,
    }

    -- Source tab bar (File / Hardcover, …). Built only when there are 2+ tabs;
    -- a single source needs no switcher.
    self._tab_row = self:_buildTabRow()
    local tabs_h = self._tab_row and self._tab_row:getSize().h or 0

    local titlebar_h = self.titlebar:getSize().h
    local buttons_h  = buttons:getSize().h
    local html_h     = self.height - titlebar_h - buttons_h - tabs_h
    if html_h < Screen:scaleBySize(80) then
        html_h = Screen:scaleBySize(80)
    end

    -- Embed the Nerd Font symbols face via @font-face so the star rows use the
    -- exact same glyphs (F005/F123/F006) as the ratings UI. MuPDF's HTML engine
    -- doesn't fall back to that font for Private-Use-Area codepoints, but it
    -- DOES honour an @font-face that points at the file directly (same path the
    -- rest of KOReader loads it from). If the font can't be resolved we just
    -- skip the rule and the glyphs fall back to blank -- no crash.
    local css = REVIEW_CSS
    local symbols_path = ffiutil.realpath(FontList.fontdir .. "/nerdfonts/symbols.ttf")
    if symbols_path then
        css = string.format(
            '@font-face { font-family: "nerdstars"; src: url("%s"); }\n%s',
            symbols_path, REVIEW_CSS)
    end
    -- Content padding via CSS body padding in PIXELS. With @page margin zeroed
    -- (above), MuPDF doesn't scale CSS pixels, so px padding stays fixed as the
    -- A+/A- font size changes. Padding (not a layout inset) keeps the scroll
    -- widget full-width, so its scrollbar sits at the frame edge rather than
    -- floating inward. Top/bottom padding too, so text doesn't hug the title
    -- bar / footer line.
    local h_pad = self._side_pad
    local v_pad = Screen:scaleBySize(28)
    css = css .. string.format("\nbody { padding: %dpx %dpx; }", v_pad, h_pad)
    -- Kept so _changeFontSize can re-render via htmlbox_widget:setContent
    -- without rebuilding the @font-face rule.
    self._css = css

    self.scroll_html = ScrollHtmlWidget:new{
        html_body         = self:_activeHtml(),
        css               = css,
        default_font_size = Screen:scaleBySize(self.font_size),
        width             = self.width,
        height            = html_h,
        dialog            = self,
    }

    -- Separator line between the scrollable reviews and the button row, so
    -- the buttons read as a distinct footer (the title bar already has its
    -- own bottom line).
    local button_separator = LineWidget:new{
        background = Blitbuffer.COLOR_DARK_GRAY,
        dimen = Geom:new{
            w = self.width,
            h = Size.line.medium,
        },
    }

    self._vgroup = VerticalGroup:new{
        align = "left",
        self.titlebar,
    }
    -- Remember where the tab row sits so _switchTab can swap it in place.
    if self._tab_row then
        self._vgroup[#self._vgroup + 1] = self._tab_row
        self._tabrow_pos = #self._vgroup
    end
    self._vgroup[#self._vgroup + 1] = self.scroll_html
    self._vgroup[#self._vgroup + 1] = button_separator
    self._vgroup[#self._vgroup + 1] = buttons

    self.frame = FrameContainer:new{
        background  = Blitbuffer.COLOR_WHITE,
        radius      = Size.radius.window,
        bordersize  = Size.border.window,
        padding     = 0,
        self._vgroup,
    }

    -- Fixed, centred -- no MovableContainer, so it can't be dragged around.
    self[1] = CenterContainer:new{
        dimen = Geom:new{ w = screen_w, h = screen_h },
        self.frame,
    }
end

-- _changeFontSize(delta): step the body font size, persist it, and re-render
-- the HTML in place (no modal reopen, so the buttons stay put). Clamped to
-- [DESC_FONT_MIN, DESC_FONT_MAX]; a no-op at the clamp edges.
function ReviewsModal:_changeFontSize(delta)
    local new = (self.font_size or DESC_FONT_DEFAULT) + delta
    if new < DESC_FONT_MIN then new = DESC_FONT_MIN end
    if new > DESC_FONT_MAX then new = DESC_FONT_MAX end
    if new == self.font_size then return end
    self.font_size = new
    -- Deferred: users tap A-/A+ repeatedly hunting for a comfortable
    -- size, and each sync save cost a full settings-file write between
    -- re-renders. Flushed once at onCloseWidget.
    Store.saveDeferred(DESC_FONT_KEY, new)
    self._font_size_dirty = true
    -- Re-render at the new size. setContent recomputes the page count; reset
    -- to the top so the scrollbar and page state stay consistent.
    self:_renderHtml(self:_activeHtml())
    UIManager:setDirty(self, function() return "ui", self.frame.dimen end)
end

-- _activeHtml(): the HTML body to display -- the active tab's, or the single
-- html_body when there are no tabs.
function ReviewsModal:_activeHtml()
    if self._tabs then
        local t = self._tabs[self._active_tab]
        return (t and t.html) or ""
    end
    return self.html_body or ""
end

-- _renderHtml(html): re-render the scroll widget in place at the current font
-- size. setContent re-layouts but leaves the previously rendered page bitmap
-- cached (HtmlBoxWidget:_render short-circuits while self.bb is non-nil, so
-- paintTo would re-blit the OLD render); freeBb drops it so the next paint
-- re-renders. resetScroll returns to the top so the scrollbar stays consistent.
function ReviewsModal:_renderHtml(html)
    if self.scroll_html and self.scroll_html.htmlbox_widget then
        local hb = self.scroll_html.htmlbox_widget
        hb:setContent(html or "", self._css, Screen:scaleBySize(self.font_size), false)
        hb:freeBb()
        self.scroll_html:resetScroll()
    end
end

-- _buildTabRow(): the source tab strip, or nil when fewer than 2 sources.
function ReviewsModal:_buildTabRow()
    if not self._tabs or #self._tabs < 2 then return nil end
    local labels = {}
    for i, t in ipairs(self._tabs) do labels[i] = t.label or tostring(i) end
    return TabBar:new{
        tabs       = labels,
        active     = self._active_tab,
        width      = self.width,
        left_inset = self._side_pad,
        on_select  = function(i) self:_switchTab(i) end,
    }
end

-- _switchTab(i): show tab i's content and move the active highlight. The tab
-- strip's geometry is stable (labels don't change weight), so flipping
-- .active + repainting is enough -- no rebuild/relayout.
function ReviewsModal:_switchTab(i)
    if not self._tabs or i == self._active_tab
            or i < 1 or i > #self._tabs then return end
    self._active_tab = i
    if self._tab_row then self._tab_row.active = i end
    self:_renderHtml(self:_activeHtml())
    UIManager:setDirty(self, function() return "ui", self.frame.dimen end)
end

function ReviewsModal:onShow()
    UIManager:setDirty(self, function()
        return "ui", self.frame.dimen
    end)
    return true
end

function ReviewsModal:onCloseWidget()
    -- Settle the deferred font-size write (see _changeFontSize) now the
    -- tap burst is definitely over.
    if self._font_size_dirty then
        self._font_size_dirty = nil
        if Store.flush then Store.flush() end
    end
    UIManager:setDirty(nil, function()
        return "ui", self.frame.dimen
    end)
end

-- #171: any multiswipe closes, mirroring KOReader's fullscreen widgets where
-- a plain swipe-south can't close (it may scroll), so any multiswipe does.
function ReviewsModal:onMultiSwipe(_arg, _ges)
    self:onClose()
    return true
end

function ReviewsModal:onClose()
    UIManager:close(self)
    -- Report the tab being viewed at dismiss time (once), so the caller can
    -- adopt that source. Independent of the Refresh-suppress flag.
    if self.on_tab_close and not self._tab_close_fired then
        self._tab_close_fired = true
        self.on_tab_close(self._active_tab)
    end
    -- Fire the optional return-to-caller callback exactly once, and never
    -- when Refresh is reopening the modal.
    if self.on_close and not self._on_close_fired and not self._suppress_close_cb then
        self._on_close_fired = true
        self.on_close()
    end
    self._suppress_close_cb = nil
    return true
end

-- Tapping outside the frame does NOT close the modal -- it's too easy to
-- dismiss accidentally by clipping the screen edge. Only the bottom "Close"
-- button and the title bar's X (close_callback) close it. Outside taps are
-- swallowed (return true) so they don't fall through to the home screen
-- underneath; taps inside fall through (return false) so the ScrollHtmlWidget
-- can still handle tap-to-scroll.
function ReviewsModal:onTapClose(_arg, ges)
    if ges and ges.pos and self.frame and self.frame.dimen
            and not ges.pos:intersectWith(self.frame.dimen) then
        return true
    end
    return false
end

return ReviewsModal
