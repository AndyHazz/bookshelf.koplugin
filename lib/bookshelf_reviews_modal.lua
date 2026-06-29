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
local Event           = require("ui/event")
local ffiutil         = require("ffi/util")
local FocusManager    = require("ui/widget/focusmanager")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LineWidget      = require("ui/widget/linewidget")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local Size            = require("ui/size")
local TextWidget      = require("ui/widget/textwidget")
local TitleBar        = require("ui/widget/titlebar")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local Store           = require("lib/bookshelf_settings_store")
local BFont           = require("lib/bookshelf_fonts")
local TextSegments    = require("lib/bookshelf_text_segments")
local Screen          = Device.screen
local _               = require("lib/bookshelf_i18n").gettext

-- FrameContainer that pixel-inverts its own rect after painting (selected
-- chips). Renders black-on-white then flips via a blitbuffer primitive so the
-- inversion is device-independent -- some Kindle builds don't honour TextWidget
-- fgcolor. Mirrors the nav chip bar's InvertedFrame.
local InvertedFrame = FrameContainer:extend{}
function InvertedFrame:paintTo(bb, x, y)
    FrameContainer.paintTo(self, bb, x, y)
    if self._invert and self.dimen then
        bb:invertRect(x, y, self.dimen.w, self.dimen.h)
    end
end

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
    tabs        = nil,   -- { "Book", "Hardcover", ... }
    active      = 1,
    active_dark = false, -- active tab's body is dark -> keep its open-bottom black
    width       = nil,
    left_inset  = nil,   -- x of the first tab; align with the body text's left
    on_select   = nil,
}

function TabBar:init()
    self.left_inset = self.left_inset or Screen:scaleBySize(10)
    self.top_pad    = Screen:scaleBySize(12)   -- gap above the tabs (below title bar)
    self.pad_h      = Screen:scaleBySize(14)
    self.pad_v      = Screen:scaleBySize(6)
    self.border     = Screen:scaleBySize(2)
    self.corner_r   = Screen:scaleBySize(3)   -- slight rounding on the active tab's top corners
    self.face       = Font:getFace("cfont", Screen:scaleBySize(13))

    -- Pack tabs into rows that fit self.width, wrapping when the next tab would
    -- overflow (so a narrow screen / high DPI keeps every tab reachable instead
    -- of clipping the right-hand ones off-screen). Each tab records its row.
    self._labels, self._tab_x, self._tab_w, self._tab_row = {}, {}, {}, {}
    local x = self.left_inset
    local row = 1
    local label_h = 0
    for i, label in ipairs(self.tabs) do
        local tw = TextWidget:new{ text = label, face = self.face }
        self._labels[i] = tw
        local sz = tw:getSize()
        local w  = sz.w + 2 * self.pad_h
        if x > self.left_inset and (x + w) > self.width then
            row = row + 1            -- wrap
            x = self.left_inset
        end
        self._tab_x[i]   = x
        self._tab_w[i]   = w
        self._tab_row[i] = row
        x = x + w
        if sz.h > label_h then label_h = sz.h end
    end
    self._n_rows = row
    self._row_h  = label_h + 2 * self.pad_v
    self.dimen = Geom:new{
        x = 0, y = 0,
        w = self.width,
        h = self.top_pad + self._n_rows * self._row_h + self.border,
    }
    if Device:isTouchDevice() then
        self.ges_events = {
            TapTab = { GestureRange:new{ ges = "tap", range = self.dimen } },
        }
    end

    -- Per-tab focus cells for the modal's dpad FocusManager. Each is a virtual
    -- focus target (never painted itself): on Focus it sets _focused_idx so
    -- paintTo highlights that tab; its dimen (set in paintTo) is where
    -- FocusManager sends the synthetic tap on Press, which onTapTab turns into a
    -- tab switch. The whole row is inserted into the modal's layout.
    local tb = self
    self.focus_cells = {}
    for i = 1, #self.tabs do
        local cell = InputContainer:new{ dimen = Geom:new{ x = 0, y = 0, w = 0, h = 0 } }
        cell.onFocus = function() tb._focused_idx = i; return true end
        cell.onUnfocus = function()
            if tb._focused_idx == i then tb._focused_idx = nil end
            return true
        end
        self.focus_cells[i] = cell
    end
end

function TabBar:getSize() return self.dimen end

function TabBar:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local border  = self.border
    local box_top = y + self.top_pad
    -- A baseline under each row (the last row's is the content boundary).
    for r = 1, self._n_rows do
        local base_y = box_top + r * self._row_h
        bb:paintRect(x, base_y, self.dimen.w, border, Blitbuffer.COLOR_BLACK)
    end
    -- Active tab box (top + left + right) on its own row. The bottom is left as
    -- the (black) baseline rather than erased open: the Edit tab's content
    -- starts with a black heading strip, so an open white bottom punched a white
    -- notch into it; the continuous baseline merges cleanly into the strip and
    -- still reads fine above white content.
    local r       = self._tab_row[self.active]
    local ax      = x + self._tab_x[self.active]
    local aw      = self._tab_w[self.active]
    local top     = box_top + (r - 1) * self._row_h
    local base_y  = box_top + r * self._row_h
    local box_h   = base_y - top
    local rad = math.min(self.corner_r or 0, math.floor(aw / 2), box_h)
    if rad > border then
        -- Top + sides with slightly rounded top corners (bottom stays open).
        bb:paintRect(ax + rad, top, aw - 2 * rad, border, Blitbuffer.COLOR_BLACK)        -- top edge
        bb:paintRect(ax, top + rad, border, box_h - rad, Blitbuffer.COLOR_BLACK)         -- left edge
        bb:paintRect(ax + aw - border, top + rad, border, box_h - rad, Blitbuffer.COLOR_BLACK) -- right edge
        -- Two corner arcs, an annulus `border` thick with outer radius `rad`.
        for px = -rad, 0 do
            for py = -rad, 0 do
                local d = math.sqrt(px * px + py * py)
                if d > rad - border and d <= rad then
                    bb:paintRect(ax + rad + px,            top + rad + py, 1, 1, Blitbuffer.COLOR_BLACK)  -- top-left
                    bb:paintRect(ax + aw - 1 - rad - px,   top + rad + py, 1, 1, Blitbuffer.COLOR_BLACK)  -- top-right
                end
            end
        end
    else
        bb:paintRect(ax, top, aw, border, Blitbuffer.COLOR_BLACK)                    -- top
        bb:paintRect(ax, top, border, box_h, Blitbuffer.COLOR_BLACK)                 -- left
        bb:paintRect(ax + aw - border, top, border, box_h, Blitbuffer.COLOR_BLACK)   -- right
    end
    -- Open bottom: erase the baseline under the active tab so it reads as a
    -- folder opening into the content. Skipped when the active tab's body is
    -- dark (e.g. the Edit tab's black heading strip) -- there the white erase
    -- punched a notch, so the (black) baseline is left to merge into the strip.
    if not self.active_dark then
        bb:paintRect(ax + border, base_y, aw - 2 * border, border, Blitbuffer.COLOR_WHITE)
    end
    -- Labels, each on its row. Also pin each focus cell's dimen to its tab rect
    -- (FocusManager taps the cell centre on Press).
    for i, tw in ipairs(self._labels) do
        local rr = self._tab_row[i]
        local tx = x + self._tab_x[i]
        local ty = box_top + (rr - 1) * self._row_h
        tw:paintTo(bb, tx + self.pad_h, ty + self.pad_v)
        if self.focus_cells and self.focus_cells[i] then
            self.focus_cells[i].dimen = Geom:new{
                x = tx, y = ty, w = self._tab_w[i], h = self._row_h }
        end
    end
    -- dpad focus highlight: invert the focused tab's interior (distinct from the
    -- active tab's folder box, since you can focus a tab without switching yet).
    if self._focused_idx and self._tab_x[self._focused_idx] then
        local fr = self._tab_row[self._focused_idx]
        bb:invertRect(
            x + self._tab_x[self._focused_idx] + border,
            box_top + (fr - 1) * self._row_h,
            self._tab_w[self._focused_idx] - 2 * border,
            self._row_h - border)
    end
end

function TabBar:onTapTab(_arg, ges)
    if not (ges and ges.pos) then return false end
    local rel_x = ges.pos.x - self.dimen.x
    local rel_y = ges.pos.y - self.dimen.y - self.top_pad
    local row   = math.floor(rel_y / self._row_h) + 1
    for i = 1, #self.tabs do
        if self._tab_row[i] == row
                and rel_x >= self._tab_x[i] and rel_x < self._tab_x[i] + self._tab_w[i] then
            if i ~= self.active and self.on_select then self.on_select(i) end
            return true
        end
    end
    return true   -- swallow taps elsewhere on the strip
end

-- FocusManager (not plain InputContainer) so dpad / keyboard arrows navigate
-- across the tab row, the active tab body, and the footer buttons. FocusManager
-- extends InputContainer, so touch is unaffected. self.layout is (re)built each
-- _assemble; widgets it references must be FRESH each assemble (mergeLayout nils
-- a merged child's layout), so the body and footer are rebuilt per assemble.
local ReviewsModal = FocusManager:extend{
    title      = nil,
    subtitle   = nil,   -- optional second line under the title (e.g. source note)
    html_body  = nil,
    tabs       = nil,   -- optional { {label=, html=}, ... }; >1 shows a tab bar
    active_tab = nil,   -- 1-based index of the initially-selected tab
    on_tab_close = nil, -- optional fn(active_tab_index) fired once on dismiss
    width      = nil,
    height     = nil,
    -- tabs entries may be HTML ({ label, html, id }) or native ({ label, id,
    -- widget_builder = function(avail_w, avail_h, show_parent) -> widget }).
    -- A widget tab's body (e.g. the scrollable tag pills) is mounted only while
    -- that tab is active, so its scroller never coexists with the HTML scroller.
    -- Optional function(avail_w) -> widget, shown at the top in place of a title
    -- bar (the book-detail cover + metadata header). Rebuilt on each re-layout.
    header_builder = nil,
    on_refresh = nil,   -- optional callback fired by the Refresh button
    on_open    = nil,   -- optional; wires an "Open" footer button (opens the book)
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

    -- A tab may carry multiple HTML "sources" (e.g. Embedded vs Hardcover
    -- description), toggled by a chip bar above the body rather than a top-level
    -- tab each. Track the selected source per tab.
    if self._tabs then
        for _i, t in ipairs(self._tabs) do
            if type(t.sources) == "table" and #t.sources > 0 then
                t._active_source = t.active_source or 1
                if t._active_source < 1 or t._active_source > #t.sources then
                    t._active_source = 1
                end
            end
        end
    end

    -- Horizontal content inset, shared by the HTML body's CSS padding, the tab
    -- strip's left inset, the tag tab's pill inset, and the header's L/R + top
    -- padding -- so tabs, bodies and header all line up.
    self._side_pad = Screen:scaleBySize(28)

    -- ADD to key_events, don't replace it: FocusManager:_init already populated
    -- it with the focus-move (arrow) + Press bindings we rely on for dpad nav.
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
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

    -- Book-detail header (cover + title/author/metadata) sits where a title bar
    -- would, built by the caller (header_builder). No title bar: the header
    -- already shows the title, and the footer has a Close button. The header's
    -- cover bb is one-shot (freed after paint), so it's rebuilt fresh on every
    -- _assemble (mirrors the long-press menu's _reinitDialog); here we build one
    -- only to measure its height for the body budget.
    local header_h = 0
    if self.header_builder then
        local probe = self:_buildHeader()
        header_h = probe and probe:getSize().h or 0
    end

    -- Footer row: Close | (Refresh) | zoom - | zoom + | Open. Close on the left,
    -- Open on the right; the zoom controls sit between.
    local button_row = {}
    button_row[#button_row + 1] = {
        text = _("Close"),
        callback = function() self:onClose() end,
    }
    -- Refresh only when a caller supplied on_refresh (unused by the book-detail
    -- popup; reviews load cache-first). Kept for any other caller.
    if self.on_refresh then
        button_row[#button_row + 1] = {
            text = _("Refresh"),
            callback = function()
                local cb = self.on_refresh
                self._suppress_close_cb = true
                self:onClose()
                if cb then cb() end
            end,
        }
    end
    -- Font size controls (description text was reported as too small and not
    -- adjustable, issue #116). Step down / up within the clamp; the change
    -- re-renders the HTML in place and persists.
    -- Long-press either zoom button to reset to the default size (a quick way
    -- to find the baseline; not meant to be especially discoverable).
    local function resetFontSize()
        self:_changeFontSize(DESC_FONT_DEFAULT - (self.font_size or DESC_FONT_DEFAULT))
    end
    button_row[#button_row + 1] = {
        text = ZOOM_OUT_GLYPH,
        font_face = "symbols",
        font_bold = false,
        callback = function() self:_changeFontSize(-DESC_FONT_STEP) end,
        hold_callback = resetFontSize,
    }
    button_row[#button_row + 1] = {
        text = ZOOM_IN_GLYPH,
        font_face = "symbols",
        font_bold = false,
        callback = function() self:_changeFontSize(DESC_FONT_STEP) end,
        hold_callback = resetFontSize,
    }
    -- Open the book (closes the popup first). Only when a caller wired on_open.
    if self.on_open then
        button_row[#button_row + 1] = {
            text = _("Open"),
            callback = function()
                local cb = self.on_open
                self:onClose()
                if cb then cb() end
            end,
        }
    end
    -- Keep the row spec; the footer ButtonTable is rebuilt FRESH each _assemble
    -- (merging its layout into the modal's nils it, so a reused one would lose
    -- its focus layout after the first tab switch).
    self._button_row = button_row

    -- Source/section tab bar. Built only when there are 2+ tabs.
    self._tab_row = self:_buildTabRow()
    local tabs_h = self._tab_row and self._tab_row:getSize().h or 0

    local buttons_h  = self:_buildButtons():getSize().h
    local html_h     = self.height - header_h - buttons_h - tabs_h
    if html_h < Screen:scaleBySize(80) then
        html_h = Screen:scaleBySize(80)
    end
    -- Body height, shared by the HTML scroller and any native (widget) tab.
    self._body_h = html_h

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

    -- Stash the chrome pieces _assemble reuses, plus the screen size for the
    -- centring container.
    self._button_separator = button_separator
    self._screen_w         = screen_w
    self._screen_h         = screen_h
    self:_assemble()
end

-- Build a FRESH footer ButtonTable (zoom -/+, Close, optional Refresh) from the
-- stored row spec. Fresh each assemble so its focus layout survives merging.
function ReviewsModal:_buildButtons()
    return ButtonTable:new{
        width       = self.width,
        buttons     = { self._button_row },
        show_parent = self,
    }
end

-- Build a FRESH book-detail header (cover + metadata) inset by the header pads,
-- or nil if no header_builder. Fresh each call because the cover bb is one-shot
-- (freed after paint); a reused header would paint garbage on the next layout.
function ReviewsModal:_buildHeader()
    if not self.header_builder then return nil end
    -- Cache the header for the modal's lifetime. The cover/title/metadata don't
    -- change while the popup is open (cover-changing actions reopen it), so
    -- _assemble (every tab switch / chip toggle / rating tap) can reuse the same
    -- widget instead of re-decoding the cover each time -- the main per-assemble
    -- allocation. The header keeps its cover bb alive (header_builder returns it
    -- as _owned_cover_bb); we free it once in onCloseWidget.
    if self._header_widget then return self._header_widget end
    local pad = self._side_pad  -- L/R + top match the tabs / body inset
    local inner = self.header_builder(self.width - 2 * pad)
    if not inner then return nil end
    self._owned_cover_bb = inner._owned_cover_bb
    self._header_widget = FrameContainer:new{
        bordersize     = 0,
        margin         = 0,
        padding_left   = pad,
        padding_right  = pad,
        padding_top    = pad,
        padding_bottom = Screen:scaleBySize(8),  -- tight to the tab bar below
        inner,
    }
    return self._header_widget
end

-- Active tab's body widget. Returns (widget, is_native, focus_widget). Built
-- FRESH each call (no cache) so its focus layout is intact when merged into the
-- modal's (merging nils it). focus_widget is the body's focusable element (a
-- ButtonTable, e.g. the Edit tab) or nil (HTML / pills); the builder attaches it
-- as `.focus_table`. HTML tabs reuse the single scroll_html.
function ReviewsModal:_activeBody()
    local tab = self._tabs and self._tabs[self._active_tab]
    if tab and tab.widget_builder then
        local w = tab.widget_builder(self.width, self._body_h, self)
        return w, true, (type(w) == "table" and w.focus_table) or nil
    end
    if tab and tab.sources and #tab.sources > 1 then
        -- Multi-source body: a chip bar above its own HTML scroller (built fresh
        -- here so a chip switch / font change rebuilds it). Treated like an HTML
        -- tab for cropping (the scroller manages its own painting).
        return self:_buildSourcedBody(tab, self.width, self._body_h), false, nil
    end
    return self.scroll_html, false, nil
end

-- A small "EMBEDDED | HARDCOVER" segmented control toggling a tab's active HTML
-- source -- same style as the nav chip bar: uppercase labels, square corners,
-- cells butted together with thin separators inside one bordered frame, the
-- selected cell inverted. Built fresh each assemble; tapping an inactive chip
-- switches the source and reassembles. Left-inset to align with the body text.
function ReviewsModal:_buildSourceChips(tab)
    local sep_w   = Size.border.thin
    local h_pad   = Size.padding.large
    local v_pad   = Size.padding.small
    local size    = Screen:scaleBySize(12)

    -- Build the label widgets first (uppercased, UTF-8-aware so accented
    -- letters fold correctly -- issue #130) to find a uniform cell height.
    local labels, cell_h = {}, 0
    for i, src in ipairs(tab.sources) do
        local face, bold = BFont:getFace("infofont", size, { bold = true })
        labels[i] = TextWidget:new{
            text    = TextSegments.upper(src.label or tostring(i)),
            face    = face,
            bold    = bold,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
        cell_h = math.max(cell_h, labels[i]:getSize().h)
    end
    cell_h = cell_h + 2 * v_pad

    local row = HorizontalGroup:new{ align = "center" }
    for i, src in ipairs(tab.sources) do
        if i > 1 then
            row[#row + 1] = LineWidget:new{
                background = Blitbuffer.COLOR_BLACK,
                dimen = Geom:new{ w = sep_w, h = cell_h },
            }
        end
        local cell_w = labels[i]:getSize().w + 2 * h_pad
        local body = InvertedFrame:new{
            _invert    = (i == tab._active_source),
            bordersize = 0, margin = 0, padding = 0,
            background = Blitbuffer.COLOR_WHITE,
            CenterContainer:new{
                dimen = Geom:new{ w = cell_w, h = cell_h },
                labels[i],
            },
        }
        local chip = InputContainer:new{
            dimen = Geom:new{ w = cell_w, h = cell_h }, body }
        chip.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = chip.dimen } } }
        chip.onTap = function()
            if i ~= tab._active_source then
                tab._active_source = i
                self:_assemble()
                UIManager:setDirty(self, function() return "ui", self.frame.dimen end)
            end
            return true
        end
        row[#row + 1] = chip
    end
    local framed = FrameContainer:new{
        bordersize = Size.border.thin, margin = 0, padding = 0, row }
    return FrameContainer:new{
        bordersize = 0, margin = 0,
        padding_left = self._side_pad, padding_right = self._side_pad,
        -- Symmetric: the description content below drops its own top padding
        -- when chips show (see _buildSourcedBody), so the chip bar owns the gap.
        padding_top = Screen:scaleBySize(16), padding_bottom = Screen:scaleBySize(16),
        framed,
    }
end

-- Free every cached sourced-description body (their MuPDF docs + bbs).
function ReviewsModal:_freeSourcedCache()
    if self._sourced_cache then
        for _i, body in pairs(self._sourced_cache) do
            body:handleEvent(Event:new("CloseWidget"))
        end
    end
    self._sourced_cache = {}
end

-- True when a body must NOT be freed on an _assemble swap because it's retained
-- for reuse: the shared scroll_html, or a cached sourced-description body.
function ReviewsModal:_isRetainedBody(w)
    if not w then return false end
    if w == self.scroll_html then return true end
    if self._sourced_cache then
        for _i, body in pairs(self._sourced_cache) do
            if body == w then return true end
        end
    end
    return false
end

-- Chip bar + an HTML scroller sized to the remaining body height. CACHED per
-- source (Embedded / Hardcover): switching the chip or tabbing back reuses the
-- already-rendered body instead of allocating a fresh MuPDF render each time.
-- The cache is keyed by source index and invalidated when the font size changes
-- (the render depends on it); the retained bodies are freed at close (or on
-- font change) -- see _freeSourcedCache.
function ReviewsModal:_buildSourcedBody(tab, w, h)
    local idx = tab._active_source or 1
    if self._sourced_cache_font ~= self.font_size then
        self:_freeSourcedCache()
        self._sourced_cache_font = self.font_size
    end
    self._sourced_cache = self._sourced_cache or {}
    if self._sourced_cache[idx] then return self._sourced_cache[idx] end

    local chips  = self:_buildSourceChips(tab)
    local chip_h = chips:getSize().h
    local src    = tab.sources[idx] or tab.sources[1]
    -- Drop the body's top padding: the chip bar's bottom padding already
    -- supplies the gap, so the description text sits right under the chips.
    -- (A later rule overrides just padding-top from the shared `body { padding }`.)
    local css = self._css .. "\nbody { padding-top: 0; }"
    local scroller = ScrollHtmlWidget:new{
        html_body         = (src and src.html) or "<p></p>",
        css               = css,
        default_font_size = Screen:scaleBySize(self.font_size),
        width             = w,
        height            = math.max(Screen:scaleBySize(80), h - chip_h),
        dialog            = self,
    }
    local body = VerticalGroup:new{ align = "left", chips, scroller }
    self._sourced_cache[idx] = body
    return body
end

-- (Re)build the vgroup + frame from the current active tab's body, and the dpad
-- focus layout (tab cells row > body focusables > footer). Called at init and on
-- every tab switch / state change. Body + footer are rebuilt fresh each time
-- (mergeLayoutInVertical nils a merged child's layout).
function ReviewsModal:_assemble()
    -- Free the PREVIOUS tab body's native resources before replacing it.
    -- _assemble runs on every tab/chip switch, font change and rebuildTab (e.g.
    -- every star tap), so the orphaned body would otherwise never receive
    -- onCloseWidget -- leaking its MuPDF html doc + the scroll container's
    -- screen-sized blitbuffer (HtmlBoxWidget's own comment says free() MUST be
    -- called when a widget is replaced). The shared scroll_html is reused across
    -- HTML tabs, so it's exempt here (freed in onCloseWidget instead).
    if self._tab_body and not self:_isRetainedBody(self._tab_body) then
        self._tab_body:handleEvent(Event:new("CloseWidget"))
    end
    local body, is_native, body_focus = self:_activeBody()
    self._tab_body = body
    -- Crop inner self-repaints (pill tap-feedback inverts) to the native scroll
    -- body when it's active; HTML tabs manage their own painting.
    self.cropping_widget = is_native and body or nil
    local buttons = self:_buildButtons()
    local vg = VerticalGroup:new{ align = "left" }
    local header = self:_buildHeader()
    if header then vg[#vg + 1] = header end
    if self._tab_row then
        vg[#vg + 1] = self._tab_row
        self._tabrow_pos = #vg
    end
    vg[#vg + 1] = body
    vg[#vg + 1] = self._button_separator
    vg[#vg + 1] = buttons
    self._vgroup = vg
    self.frame = FrameContainer:new{
        background  = Blitbuffer.COLOR_WHITE,
        radius      = Size.radius.window,
        bordersize  = Size.border.window,
        padding     = 0,
        vg,
    }
    -- Fixed, centred -- no MovableContainer, so it can't be dragged around.
    self[1] = CenterContainer:new{
        dimen = Geom:new{ w = self._screen_w, h = self._screen_h },
        self.frame,
    }

    -- Focus layout: row of tab cells (if a tab bar), then the body's focusables,
    -- then the footer buttons. Up/Down crosses all three.
    self.layout = {}
    if self._tab_row and self._tab_row.focus_cells and #self._tab_row.focus_cells > 0 then
        table.insert(self.layout, self._tab_row.focus_cells)
    end
    local body_start = #self.layout + 1
    if body_focus and body_focus.layout then
        self:mergeLayoutInVertical(body_focus)
    end
    local had_body = #self.layout >= body_start
    self:mergeLayoutInVertical(buttons)
    -- Default focus into the body when it has buttons (e.g. the Edit tab opens
    -- ready to act); otherwise the first row (tabs if present, else footer).
    local fy = had_body and body_start or 1
    self.selected = { x = 1, y = fy }
    -- Paint the initial focus highlight only on dpad/key devices. On touch-only
    -- devices (no dpad) there's no focus cursor, so showing the inverted block
    -- would be spurious -- FocusManager itself enables focus nav only when
    -- Device:hasDPad(), so match that.
    if Device:hasDPad() then
        local row = self.layout[fy]
        if row and row[1] then row[1]:handleEvent(Event:new("Focus")) end
    end
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
    -- Re-render the HTML scroller at the new size, then reassemble. _assemble
    -- rebuilds the active body fresh, so native tabs (pills sized from
    -- self.font_size) pick up the new size too.
    self:_renderHtml(self:_activeHtml())
    self:_assemble()
    UIManager:setDirty(self, function() return "ui", self.frame.dimen end)
end

-- _activeHtml(): the HTML body to display -- the active tab's, or the single
-- html_body when there are no tabs. When the active tab is a native (widget)
-- tab it has no html, so fall back to the first HTML tab (the scroll widget
-- needs valid content even while it's offscreen), else an empty paragraph.
function ReviewsModal:_activeHtml()
    if self._tabs then
        local t = self._tabs[self._active_tab]
        if t and t.sources and t._active_source then
            local s = t.sources[t._active_source]
            if s and s.html then return s.html end
        end
        if t and t.html then return t.html end
        for _i, tt in ipairs(self._tabs) do
            if tt.html then return tt.html end
        end
        return "<p></p>"
    end
    return self.html_body or "<p></p>"
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
    local active = self._tabs[self._active_tab]
    return TabBar:new{
        tabs        = labels,
        active      = self._active_tab,
        active_dark = active and active.dark_body or false,
        width       = self.width,
        left_inset  = self._side_pad,
        on_select   = function(i) self:_switchTab(i) end,
    }
end

-- setTabHtml(i, html): replace a tab's content after construction (used for an
-- async tab, e.g. Hardcover reviews that load after the popup is shown). Updates
-- the stored html and, if that tab is the active one, re-renders in place. Safe
-- to call after dismiss -- it no-ops once the widget is gone.
function ReviewsModal:setTabHtml(i, html)
    if self._dismissed then return end
    if self._tabs and self._tabs[i] then
        self._tabs[i].html = html
        if i == self._active_tab then
            self:_renderHtml(self:_activeHtml())
            UIManager:setDirty(self, function() return "ui", self.frame.dimen end)
        end
    elseif i == 1 and not self._tabs then
        -- Single-source modal (no tab bar): the body is html_body.
        self.html_body = html
        self:_renderHtml(html)
        UIManager:setDirty(self, function() return "ui", self.frame.dimen end)
    end
end

-- rebuildTab(): reassemble in place (rebuilds the active body fresh). Used by
-- the Edit tab after an immediate action so its buttons re-read live state
-- (status tick, rating stars, favourite +/-). No-ops safely after dismiss.
function ReviewsModal:rebuildTab()
    if self._dismissed then return end
    self:_assemble()
    UIManager:setDirty(self, function() return "ui", self.frame.dimen end)
end

-- _switchTab(i): show tab i's body and move the active highlight. HTML tabs
-- re-render the shared scroll widget in place; switching to/from a native
-- (widget) tab swaps which body is mounted, so the frame is reassembled.
function ReviewsModal:_switchTab(i)
    if not self._tabs or i == self._active_tab
            or i < 1 or i > #self._tabs then return end
    self._active_tab = i
    local tab = self._tabs[i]
    if self._tab_row then
        self._tab_row.active = i
        self._tab_row.active_dark = tab and tab.dark_body or false
    end
    if not tab.widget_builder then
        -- HTML tab: load its content into the shared scroll widget first.
        self:_renderHtml(self:_activeHtml())
    end
    self:_assemble()
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
    -- Free the shared HTML scroller's native resources (MuPDF doc + bb). When a
    -- native tab (Edit/Tags) is active at close, scroll_html isn't in the live
    -- widget tree, so the normal CloseWidget cascade never reaches it -- free it
    -- explicitly. HtmlBoxWidget:free is idempotent, so a double-free (when it IS
    -- the active body) is harmless.
    if self.scroll_html then
        self.scroll_html:handleEvent(Event:new("CloseWidget"))
    end
    if self._tab_body and not self:_isRetainedBody(self._tab_body) then
        self._tab_body:handleEvent(Event:new("CloseWidget"))
    end
    -- Free the retained per-source description bodies (their MuPDF docs).
    self:_freeSourcedCache()
    -- The cached header kept its cover bb alive across repaints (non-disposable);
    -- free it now that the popup is gone.
    if self._owned_cover_bb and self._owned_cover_bb.free then
        pcall(function() self._owned_cover_bb:free() end)
        self._owned_cover_bb = nil
    end
    -- Reclaim the popup's churned Lua garbage now: modal close is an infrequent,
    -- natural boundary, and the book-detail popup allocates a fair amount per
    -- tab/chip/rating interaction. Native resources are already freed above.
    collectgarbage("collect")
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

-- A book opening underneath us (e.g. the Edit tab's "Open Incognito" plugin
-- button, or any action that enters the reader) broadcasts ShowingReader as the
-- reader takes over -- close so we don't linger on top of the opening book.
-- Mirrors the old long-press menu's onShowingReader handler.
function ReviewsModal:onShowingReader()
    self:onClose()
end

function ReviewsModal:onClose()
    self._dismissed = true  -- so a late async tab fill (setTabHtml) no-ops
    UIManager:close(self)
    -- Report the tab being viewed at dismiss time (once), so the caller can
    -- adopt that source. Independent of the Refresh-suppress flag.
    if self.on_tab_close and not self._tab_close_fired then
        self._tab_close_fired = true
        self.on_tab_close(self._active_tab)
    end
    -- Persist any multi-source tab's chosen source (e.g. the description chip:
    -- Embedded vs Hardcover). Fires once, on dismiss -- and the Open button
    -- routes through onClose, so the choice is saved before the book opens.
    if self._tabs and not self._source_close_fired then
        self._source_close_fired = true
        for _i, t in ipairs(self._tabs) do
            if t.sources and t.on_source_close and t._active_source then
                t.on_source_close(t._active_source)
            end
        end
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
