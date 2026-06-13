--- bookshelf_library_modal -- shared chrome widget for the source pickers
--- (collection, genre, author). Renders header, optional tabs, search input,
--- chip strip (with two-row wrap), paginated list-or-grid result area, and
--- footer. Domain-specific data and per-row rendering are supplied by the
--- caller via a config table.
---
--- Ported from bookends.koplugin/menu/library_modal.lua so bookshelf works
--- standalone without requiring the bookends plugin. The only difference
--- from upstream is the i18n require path.

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local BFont = require("lib/bookshelf_fonts")
local _ = require("lib/bookshelf_i18n").gettext

-- Uniform gap applied everywhere below the title bar separator.
local MARGIN = Device.screen:scaleBySize(10)

-- Extend InputContainer (rather than WidgetContainer) so we can register a
-- modal-level tap handler that dismisses the on-screen keyboard. Child
-- gestures (button/chip/tile taps) still get first crack via WidgetContainer's
-- propagateEvent; our handler only fires on uncaught taps.
local LibraryModal = InputContainer:extend{
    name = "library_modal",
    config = nil,           -- domain config table (see spec)
    -- KOReader's UIManager:sendEvent only dispatches gestures to the topmost
    -- non-toast widget by default; when the on-screen keyboard is shown it
    -- becomes the top widget and our modal stops receiving taps. Marking the
    -- modal is_always_active opts it into the secondary dispatch loop so taps
    -- that fall through the keyboard reach our onTapDismissKeyboard handler.
    is_always_active = true,
    -- runtime state
    active_tab = nil,       -- key of active tab, or nil if no tabs
    active_chip = nil,      -- key of active chip, or nil
    page = 1,
    search_query = nil,     -- current submitted query, or nil
}

--- Multi-term substring AND match. Public for unit testing.
--- Empty or 1-char query returns false (avoids surfacing thousands of matches
--- on a single keystroke).
function LibraryModal._matchesQuery(text, query)
    if not query or #query < 2 then return false end
    local lc = (text or ""):lower()
    for term in query:lower():gmatch("%S+") do
        if not lc:find(term, 1, true) then return false end
    end
    return true
end

function LibraryModal:init()
    assert(self.config, "LibraryModal requires a config table")
    -- Pre-populate runtime state from config defaults
    if self.config.tabs and #self.config.tabs > 0 then
        self.active_tab = self.config.tabs[1].key
    end
    -- Default chip = the explicit is_active=true winner. When chips
    -- advertise explicit is_active values but none is true (e.g. gallery
    -- cold state where neither Latest nor Popular has been engaged yet),
    -- treat that as a deliberate "no active chip" and leave self.active_chip
    -- nil — otherwise the chips[1] fallback would make _onChipTap's
    -- "already-active, return" branch silently swallow the user's first tap
    -- on whatever chips[1] happens to be.
    local chips = self.config.chip_strip and self.config.chip_strip(self.active_tab) or {}
    local any_explicit = false
    for _i, chip in ipairs(chips) do
        if chip.is_active ~= nil then any_explicit = true end
        if chip.is_active then self.active_chip = chip.key; break end
    end
    if not self.active_chip and not any_explicit and chips[1] then
        self.active_chip = chips[1].key
    end
    -- Modal-wide tap fallback: if a tap isn't consumed by a child widget AND
    -- the keyboard is up, dismiss the keyboard. Children's TapSelect handlers
    -- run first via WidgetContainer.propagateEvent; this only fires for taps
    -- that fall through (e.g. on empty modal area or when InputText has
    -- focused-state precedence over downstream widgets).
    local full_screen = Geom:new{
        x = 0, y = 0,
        w = Device.screen:getWidth(),
        h = Device.screen:getHeight(),
    }
    self.ges_events = {
        TapDismissKeyboard = {
            GestureRange:new{ ges = "tap", range = full_screen },
        },
        -- Swipe to page, matching the main shelf (west = next, east = prev).
        SwipeNextPage = {
            GestureRange:new{ ges = "swipe", direction = "west", range = full_screen },
        },
        SwipePrevPage = {
            GestureRange:new{ ges = "swipe", direction = "east", range = full_screen },
        },
    }
    -- On key-bearing devices (Kindle, Kobo with buttons, desktop SDL) register
    -- the Back key so users are never trapped inside the modal without a
    -- hardware exit path.
    if Device:hasKeys() then
        self.key_events = {
            Close = { { Device.input.group.Back } },
        }
    end
    -- Grid focus: arrow keys + Press navigate and select cells. Only
    -- registered when the caller provides a cell_renderer (grid mode).
    if Device:hasDPad() and self.config.cell_renderer then
        local total = self.config.item_count and self.config.item_count() or 0
        if total > 0 then self._dpad_idx = 1 end
        self.key_events = self.key_events or {}
        self.key_events.GridFocusUp    = { { "Up" } }
        self.key_events.GridFocusDown  = { { "Down" } }
        self.key_events.GridFocusLeft  = { { "Left" } }
        self.key_events.GridFocusRight = { { "Right" } }
        self.key_events.GridPress      = { { "Press" } }
    end
    -- Build the modal frame on init; populated lazily via :refresh()
    self:_buildFrame()
end

--- Dismiss the on-screen keyboard if any, and clear the input's focused
--- visual state so the thick focused-border doesn't linger after the
--- keyboard hides. Called from tab/chip handlers, the search-row button
--- callbacks, the tap-outside fallback, and from preset_manager_modal's
--- card/star/preview/apply paths via self.modal_widget:_dismissKeyboard().
-- Force a fullscreen UI refresh from inside the close path. UIManager fires
-- CloseWidget before the widget is removed from the window stack and before
-- the caller's Button:onTapSelectButton drains the refresh queue with
-- forceRePaint(). Stock Button-feedback flow runs:
--    highlight → forceRePaint → callback → forceRePaint
-- so the second forceRePaint drains everything queued *during* the callback —
-- but UIManager:close() with no refresh args enqueues nothing, and a deferred
-- markDirty (e.g. via Bookends:markDirty → nextTick) doesn't land in the
-- queue until *after* that drain. Result on Kobo / kodev emulator: only the
-- button's own ~80px fast refresh lands, the rest of the modal area never
-- gets refreshed, and the modal pixels linger until the next user-triggered
-- repaint. Issue #34.
--
-- setDirty("all", "ui") here marks every window-stack widget dirty and
-- enqueues a fullscreen "ui" refresh — both *before* the close finishes
-- removing us — so the trailing forceRePaint drains a refresh that actually
-- covers the modal area. The closing widget gets unmarked again by
-- UIManager:close itself a few lines later (self._dirty[w] = nil during
-- removal), so we don't paint a corpse.
function LibraryModal:onCloseWidget()
    UIManager:setDirty("all", "ui")
end

-- Stub for InputText's parent contract. Upstream inputtext.lua:157 calls
-- self.parent:getFocusableWidgetXY(self) inside `if Device:hasDPad() then`,
-- which is true on desktop SDL (arrow keys), Kindle Keyboard, some Kobos with
-- hardware buttons, and certain Android configs. Without this, the search
-- field crashes on first tap on those devices. We don't use FocusManager grid
-- navigation here, so returning nothing matches FocusManager's own behaviour
-- when self.layout is unset (focusmanager.lua:551) and the upstream
-- `if x and y then moveFocusTo(...)` branch correctly no-ops.
function LibraryModal:getFocusableWidgetXY() end

function LibraryModal:onClose()
    UIManager:close(self)
    return true
end

-- Grid dpad navigation. `delta` is ±1 (Left/Right) or ±cols (Up/Down).
-- Clamps at [1, total] and pages automatically when crossing a page boundary.
function LibraryModal:_gridNav(delta)
    local total = self.config.item_count and self.config.item_count() or 0
    if total == 0 then return end
    local cells_per_page = self.config.cells_per_page
        and self.config.cells_per_page(self.content_w) or 1
    local new_idx = math.max(1, math.min(total, (self._dpad_idx or 1) + delta))
    if new_idx == self._dpad_idx then return end
    self._dpad_idx = new_idx
    local new_page = math.ceil(new_idx / cells_per_page)
    if new_page ~= self.page then self.page = new_page end
    self:refresh()
end

function LibraryModal:_gridCols()
    if self.config.grid_cols then
        return type(self.config.grid_cols) == "function"
            and self.config.grid_cols() or self.config.grid_cols
    end
    local target = Device.screen:scaleBySize(220)
    return math.max(3, math.floor(self.content_w / target))
end

function LibraryModal:onGridFocusLeft()  self:_gridNav(-1);              return true end
function LibraryModal:onGridFocusRight() self:_gridNav(1);               return true end
function LibraryModal:onGridFocusUp()    self:_gridNav(-self:_gridCols()); return true end
function LibraryModal:onGridFocusDown()  self:_gridNav(self:_gridCols());  return true end

function LibraryModal:onGridPress()
    if not self._dpad_idx then return true end
    local item = self.config.item_at and self.config.item_at(self._dpad_idx)
    if item and self.config.on_cell_tap then
        self.config.on_cell_tap(item)
    end
    return true
end

function LibraryModal:_dismissKeyboard()
    local input = self._search_input
    if not input then return end
    if input.isKeyboardVisible and input:isKeyboardVisible() then
        input:onCloseKeyboard()
    end
    if input.focused then
        -- :unfocus() also flips _frame_textwidget.color from BLACK→DARK_GRAY,
        -- which is the visible "focus border" the user is asking for.
        -- Setting input.focused = false alone wouldn't update the color.
        input:unfocus()
        UIManager:setDirty(self, "ui")
    end
end

function LibraryModal:onTapDismissKeyboard(_arg, ges)
    -- This handler only fires for taps that no deeper widget consumed (per
    -- WidgetContainer's propagateEvent). For child-consumed taps (chip/tab/
    -- button/tile/keyboard-key) the deeper handler runs and dismisses the
    -- keyboard explicitly via :_dismissKeyboard(). This catches the
    -- empty-modal-area case.
    --
    -- We also gate dismissal on the tap being OUTSIDE the keyboard's bounds
    -- so that taps on keyboard keys (which propagate up unconsumed in some
    -- KOReader gesture paths) don't accidentally dismiss the keyboard before
    -- the user's keystroke registers. Pattern lifted from bookends_line_editor.
    if self._search_input and self._search_input.isKeyboardVisible
            and self._search_input:isKeyboardVisible() then
        local kb = self._search_input.keyboard
        if kb and kb.dimen and ges and ges.pos
                and ges.pos:notIntersectWith(kb.dimen) then
            self:_dismissKeyboard()
        end
        return false
    end
    -- Keyboard not up: a tap that missed every child AND lands outside the
    -- visible modal frame is treated as "dismiss the modal". Issue #39.
    -- Hit-testing uses self.frame.dimen so accidental taps in the empty
    -- gap *inside* the frame (e.g. between pagination buttons) don't close.
    if self.frame and self.frame.dimen and ges and ges.pos
            and ges.pos:notIntersectWith(self.frame.dimen) then
        UIManager:close(self)
        return true
    end
    return false
end

function LibraryModal:_buildFrame()
    local Screen = Device.screen
    -- Modal width: 85% of screen. Less wide than the 90% it was — visible
    -- breathing room around the dialog for context.
    self.modal_w = math.floor(Screen:getWidth() * 0.85)
    -- Width of inner content (search box, chip strip, cards, etc.) once the
    -- per-section MARGIN insets are applied in refresh().
    self.content_w = self.modal_w - 2 * MARGIN

    -- Frame has zero left/right padding so the title bar separator can run
    -- edge-to-edge. Each non-title section wraps itself in MARGIN padding
    -- via the padHorizontal helper inside refresh().
    self.frame = FrameContainer:new{
        bordersize = Size.border.window,
        padding = 0,
        padding_top = 0,
        padding_bottom = MARGIN,
        padding_left = 0,
        padding_right = 0,
        margin = 0,
        radius = Screen:scaleBySize(8),
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{ align = "left" },
    }
    self[1] = CenterContainer:new{
        dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() },
        self.frame,
    }
    self:refresh()
end

function LibraryModal:_renderTitleBar(content_width, modal_w)
    local Font = require("ui/font")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local LeftContainer = require("ui/widget/container/leftcontainer")
    local LineWidget = require("ui/widget/linewidget")
    local TextWidget = require("ui/widget/textwidget")
    local Screen = Device.screen
    -- Equal top/bottom padding so the title text reads as vertically centred.
    local bar_pad = Screen:scaleBySize(8)

    local title_face, title_bold = BFont:getFace("cfont", 22, { bold = true })
    local title_w = TextWidget:new{
        text = self.config.title,
        face = title_face,
        bold = title_bold,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }

    -- Title bar height = text height + equal top/bottom padding.
    -- Passed to _renderTabSegments so each segment can fill the full bar height.
    local title_bar_h = title_w:getSize().h + 2 * bar_pad

    local right_widget
    if self.config.tabs then
        -- Build segmented [Tab1 | Tab2] pill row; active tab is filled black,
        -- inactive is outlined. Tap on an inactive tab fires on_tab_change.
        right_widget = self:_renderTabSegments(title_bar_h)
    else
        right_widget = HorizontalSpan:new{ width = 0 }
    end

    -- Title left, tab segments right, with the gap absorbed by a flexible spacer.
    local row = HorizontalGroup:new{
        align = "center",
        LeftContainer:new{
            dimen = Geom:new{ w = content_width - right_widget:getSize().w, h = title_bar_h },
            title_w,
        },
        right_widget,
    }

    -- Separator runs the full frame width (modal_w) so it spans edge-to-edge,
    -- ignoring the frame's content_pad side insets. Thicker than line.thin so
    -- the separator reads as a deliberate structural divider, not a hairline.
    return VerticalGroup:new{
        row,
        LineWidget:new{
            background = Blitbuffer.COLOR_BLACK,
            dimen = Geom:new{ w = modal_w, h = Device.screen:scaleBySize(3) },
        },
    }
end

function LibraryModal:_showHelp()
    local TextViewer = require("ui/widget/textviewer")
    UIManager:show(TextViewer:new{
        title = self.config.help_title or self.config.title or "",
        text = self.config.help_text or "",
        justified = false,
    })
end

function LibraryModal:_renderTabSegments(title_bar_h)
    -- Returns a HorizontalGroup of tap-able segment widgets. Active segment
    -- has black bg + white text; inactive has white bg + black text. On tap,
    -- :_onTabSelect(key) is called, which updates active_tab + invokes
    -- self.config.on_tab_change + self:refresh().
    local Font = require("ui/font")
    local GestureRange = require("ui/gesturerange")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local TextWidget = require("ui/widget/textwidget")
    local Screen = Device.screen
    local seg_pad_h = Screen:scaleBySize(12)

    local function seg(label, is_active, on_tap)
        local fg = is_active and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
        local bg = is_active and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
        local seg_face, seg_bold = BFont:getFace("cfont", 14, { bold = is_active })
        local tw = TextWidget:new{
            text = label, face = seg_face, bold = seg_bold, fgcolor = fg,
        }
        local pill_w = tw:getSize().w + 2 * seg_pad_h
        -- No border on either state — the active fill alone signals selection,
        -- which reads cleaner than a black-bordered inactive pill next to a
        -- black-filled active pill.
        local fc = FrameContainer:new{
            bordersize = 0,
            padding = 0,
            padding_left = seg_pad_h, padding_right = seg_pad_h,
            padding_top = 0, padding_bottom = 0,
            margin = 0, background = bg,
            dimen = Geom:new{ w = pill_w, h = title_bar_h },
            CenterContainer:new{
                dimen = Geom:new{ w = pill_w - 2 * seg_pad_h, h = title_bar_h },
                tw,
            },
        }
        local ic = InputContainer:new{ dimen = Geom:new{ w = pill_w, h = title_bar_h }, fc }
        ic.ges_events = { TapSelect = { GestureRange:new{ ges = "tap", range = ic.dimen } } }
        ic.onTapSelect = function() on_tap(); return true end
        return ic
    end

    -- Tabs butt together so they read as one segmented control rather than two
    -- floating pills (no HorizontalSpan between segments).
    local hg = HorizontalGroup:new{ align = "center" }
    for _i, tab in ipairs(self.config.tabs) do
        local is_active = tab.key == self.active_tab
        table.insert(hg, seg(tab.label, is_active, function() self:_onTabSelect(tab.key) end))
    end
    return hg
end

function LibraryModal:_onTabSelect(tab_key)
    if self.active_tab == tab_key then return end
    self.active_tab = tab_key
    self.search_query = nil
    self.page = 1
    -- Default chip on the new tab: same logic as init() at line 64. Honour
    -- explicit is_active=true; when chips advertise explicit is_active but
    -- none is true (gallery cold state), leave active_chip nil so the first
    -- chip tap on the new tab actually fires _onChipTap rather than being
    -- swallowed by the same-key short-circuit.
    local chips = self.config.chip_strip and self.config.chip_strip(self.active_tab) or {}
    local any_explicit = false
    self.active_chip = nil
    for _i, chip in ipairs(chips) do
        if chip.is_active ~= nil then any_explicit = true end
        if chip.is_active then self.active_chip = chip.key; break end
    end
    if not self.active_chip and not any_explicit and chips[1] then
        self.active_chip = chips[1].key
    end
    -- The search placeholder may differ per tab. Dismiss any open keyboard,
    -- then release the persisted InputText so _renderSearchInput rebuilds
    -- it with the new hint.
    self:_dismissKeyboard()
    self._search_input = nil
    if self.config.on_tab_change then self.config.on_tab_change(tab_key) end
    self:refresh()
end

function LibraryModal:_renderSearchInput(content_width)
    local Font = require("ui/font")
    local GestureRange = require("ui/gesturerange")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local TextWidget = require("ui/widget/textwidget")
    local Screen = Device.screen

    local placeholder = self.config.search_placeholder
        and self.config.search_placeholder(self.active_tab)
        or _("Search…")

    -- Button labels match the tab pill font (cfont/14) so the row reads as
    -- one family. The input itself stays at cfont/16 for typing legibility.
    local btn_face = (BFont:getFace("cfont", 14))
    local input_face = (BFont:getFace("cfont", 16))
    local btn_pad_h = Screen:scaleBySize(12)
    local gap = Screen:scaleBySize(6)
    -- InputText wraps its TextWidget in a FrameContainer with bordersize +
    -- padding, so its rendered outer width is `width + 2 * (border + padding)`.
    -- Subtract that overhead from input_w so the search row totals exactly
    -- content_width, otherwise the row pushes the modal frame wider than
    -- modal_w and asymmetric right-edge gaps appear.
    --
    -- Input + button borders. Use Size.border.default (thicker than thin)
    -- so the focused-black border reads as a strong outline rather than a
    -- hairline that could pass for unfocused-gray on glance.
    local input_border = Size.border.default
    local input_padding = Size.padding.default
    local input_overhead = 2 * (input_border + input_padding)

    -- Pre-measure button labels so we can size the input first and then
    -- build buttons whose outer height matches the input's. Both Search and
    -- × are kept: Enter on the keyboard ALSO submits, but tapping outside
    -- only dismisses the keyboard without submitting, so an explicit Search
    -- button is the natural way to commit a query without a keystroke.
    -- Chip-style buttons share the input's border thickness so the row
    -- reads as one unit. input_border is set above.
    local function measureLabel(label, opts)
        local tw = TextWidget:new{
            text = label, face = btn_face,
            fgcolor = Blitbuffer.COLOR_BLACK,
            bold = opts and opts.bold or false,
        }
        return tw, tw:getSize().w + 2 * btn_pad_h + 2 * input_border
    end
    local search_label, search_btn_w = measureLabel(_("Search"))
    -- ✕ (U+2715 MULTIPLICATION X) reads as a deliberate close/clear glyph,
    -- where × (U+00D7 MULTIPLICATION SIGN) reads as math typography.
    -- Bold weight balances the visual mass against the longer Search label.
    local clear_label, clear_btn_w = measureLabel("\xE2\x9C\x95", { bold = true })
    local input_w = content_width - search_btn_w - clear_btn_w - 2 * gap - input_overhead

    -- Persist the InputText across refreshes so the keyboard's reference to
    -- it stays valid. Rebuilding it on every refresh leaves the keyboard
    -- pointing at a destroyed widget, which crashes on the next keystroke.
    if not self._search_input then
        local InputText = require("ui/widget/inputtext")
        self._search_input = InputText:new{
            text       = self.search_query or "",
            hint       = placeholder,
            parent     = self,
            width      = input_w,
            face       = input_face,
            bordersize = input_border,
            padding    = input_padding,
            margin     = 0,
            scroll     = false,
            focused    = false,
            enter_callback = function()
                local q = self._search_input:getText()
                self:_dismissKeyboard()
                self:_onSearchSubmit(q)
            end,
        }
        -- onTapTextBox in KOReader's InputText sets self.focused = true but
        -- never calls :focus() — the latter is what flips
        -- self._frame_textwidget.color from DARK_GRAY → BLACK (the visible
        -- "focused border"). Without :focus(), the color stays gray until
        -- some other path triggers the update (typing the first character).
        -- Wrap onTapTextBox to call :focus() ourselves and mark the modal
        -- dirty so the color change shows up immediately.
        local input = self._search_input
        local orig_onTapTextBox = input.onTapTextBox
        input.onTapTextBox = function(this, arg, ges)
            local r = orig_onTapTextBox(this, arg, ges)
            if not this.focused or this._frame_textwidget.color ~= Blitbuffer.COLOR_BLACK then
                this:focus()
            end
            UIManager:setDirty(self, "ui")
            return r
        end
        -- Slightly rounded corners on the input border distinguish the
        -- search row from the segmented (square) chip strip below. The
        -- inner FrameContainer is what InputText renders the border
        -- through (inputtext.lua:569), so set radius there before paint.
        input._frame_textwidget.radius = Size.radius.default
    else
        local desired = self.search_query or ""
        if self._search_input:getText() ~= desired then
            self._search_input:setText(desired)
        end
    end

    -- Match the buttons' outer height to the InputText's so the row reads
    -- as one unit. FrameContainer.getSize adds 2*bordersize to its inner
    -- content size, so we shrink the inner CenterContainer.dimen.h by that
    -- amount to keep the button's outer rendered height == row_h.
    local row_h = self._search_input:getSize().h
    local function chipButton(tw, btn_w, on_tap)
        local inner_h = row_h - 2 * input_border
        local fc = FrameContainer:new{
            bordersize = input_border,    -- match input border for visual unity
            padding = 0,
            padding_left = btn_pad_h, padding_right = btn_pad_h,
            padding_top = 0, padding_bottom = 0,
            margin = 0,
            -- Slightly rounded corners — same radius as the InputText so
            -- the search row reads as a unit, distinct from the square
            -- (segmented) chip strip below.
            radius = Size.radius.default,
            background = Blitbuffer.COLOR_WHITE,
            CenterContainer:new{
                dimen = Geom:new{ w = btn_w - 2 * btn_pad_h - 2 * input_border, h = inner_h },
                tw,
            },
        }
        local ic = InputContainer:new{ dimen = Geom:new{ w = btn_w, h = row_h }, fc }
        ic.ges_events = { TapSelect = { GestureRange:new{ ges = "tap", range = ic.dimen } } }
        ic.onTapSelect = function() on_tap(); return true end
        return ic
    end

    local search_btn = chipButton(search_label, search_btn_w, function()
        local q = self._search_input and self._search_input:getText() or ""
        self:_dismissKeyboard()
        self:_onSearchSubmit(q)
    end)
    local clear_btn = chipButton(clear_label, clear_btn_w, function()
        self:_dismissKeyboard()
        if self._search_input then self._search_input:setText("") end
        self:_onSearchSubmit("")
    end)

    return HorizontalGroup:new{
        align = "center",
        self._search_input,
        HorizontalSpan:new{ width = gap },
        search_btn,
        HorizontalSpan:new{ width = gap },
        clear_btn,
    }
end

function LibraryModal:_onSearchSubmit(q)
    if not q or #q < 2 then
        self.search_query = nil
    else
        self.search_query = q
    end
    self.page = 1
    if self.config.on_search_submit then self.config.on_search_submit(self.search_query) end
    self:refresh()
end

function LibraryModal:_renderChipStrip(content_width)
    local Font = require("ui/font")
    local GestureRange = require("ui/gesturerange")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local TextWidget = require("ui/widget/textwidget")
    local Screen = Device.screen

    if not self.config.chip_strip then return nil end
    local chips = self.config.chip_strip(self.active_tab)
    if not chips or #chips == 0 then return nil end

    local pad_h = Screen:scaleBySize(10)
    local pad_v = Screen:scaleBySize(4)
    -- Zero gap so chips butt together into a segmented-control strip.
    local chip_gap = 0
    local row_gap = MARGIN

    local function buildChip(chip)
        -- Honor chip.is_active from the config callback when present (lets
        -- the domain show NO chip as selected — e.g. cold gallery state
        -- where neither Latest nor Popular has been engaged yet). Fall back
        -- to widget-tracked active_chip when the callback omits the flag.
        local is_active
        if chip.is_active ~= nil then
            is_active = chip.is_active
        else
            is_active = chip.key == self.active_chip
        end
        local fg = is_active and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
        local bg = is_active and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
        local chip_face, chip_bold = BFont:getFace("cfont", 13, { bold = is_active })
        local tw = TextWidget:new{
            text = chip.label, face = chip_face, bold = chip_bold, fgcolor = fg,
        }
        -- Border thickness stays constant across active/inactive so the chip
        -- widths don't shift when selection changes (avoids the "jiggle" of
        -- adjacent chips contracting/expanding by ~3px on tap). Active chip
        -- uses black border color which merges into its black fill, so the
        -- border is invisible there but still occupies the same space.
        local fc = FrameContainer:new{
            bordersize = Size.border.thin,
            color = Blitbuffer.COLOR_BLACK,
            padding = 0,
            padding_left = pad_h, padding_right = pad_h,
            padding_top = pad_v, padding_bottom = pad_v,
            -- Square corners: with chip_gap=0 the chips share a vertical edge,
            -- so we square them off to read as one continuous segmented control.
            -- Rounded outer corners would require per-corner radius which the
            -- FrameContainer doesn't support.
            margin = 0, background = bg, radius = 0,
            tw,
        }
        local ic = InputContainer:new{ dimen = Geom:new{ w = fc:getSize().w, h = fc:getSize().h }, fc }
        ic.ges_events = { TapSelect = { GestureRange:new{ ges = "tap", range = ic.dimen } } }
        ic.onTapSelect = function() self:_onChipTap(chip.key); return true end
        return ic
    end

    -- Chip strip wraps to at most MAX_ROWS rows; chips that would land on
    -- a third row are silently dropped. The previous shape -- a bottom-of-
    -- loop `if #rows >= 2 then break end` plus an unconditional post-loop
    -- insert -- could produce a 3rd row containing the single chip that
    -- triggered the second overflow: the overflow branch pushed row 2,
    -- started a fresh current_row with that chip, the bottom check then
    -- broke, and the trailing insert appended current_row as row 3.
    local MAX_ROWS = 2
    local rows = {}
    local current_row = HorizontalGroup:new{ align = "center" }
    local current_w = 0
    local capped = false
    for i, chip in ipairs(chips) do
        local cw = buildChip(chip)
        local cw_w = cw:getSize().w
        local needed = (i == 1) and cw_w or (current_w + chip_gap + cw_w)
        if needed > content_width and #current_row > 0 then
            table.insert(rows, current_row)
            if #rows >= MAX_ROWS then
                -- Don't even start a row that would overflow the cap;
                -- this chip and any beyond it are dropped from the strip.
                capped = true
                break
            end
            current_row = HorizontalGroup:new{ align = "center", cw }
            current_w = cw_w
        else
            if i > 1 and current_w > 0 then
                table.insert(current_row, HorizontalSpan:new{ width = chip_gap })
                current_w = current_w + chip_gap
            end
            table.insert(current_row, cw)
            current_w = current_w + cw_w
        end
    end
    if not capped then
        table.insert(rows, current_row)
    end

    -- Optional inline status text rendered alongside the chips on the first
    -- row, in the empty space to their right. The domain returns a string
    -- (or nil) via `chip_strip_status` — used for transient feedback like
    -- "Loading gallery…" so the message reads as part of the modal chrome
    -- rather than a separate KOReader popup. Matches the slot the legacy
    -- bespoke chrome used for the approval-queue count.
    local status_text = self.config.chip_strip_status
        and self.config.chip_strip_status(self.active_tab) or nil
    if status_text and #status_text > 0 and rows[1] then
        local row1 = rows[1]
        local row1_w = 0
        for _i, child in ipairs(row1) do
            local sz = child.getSize and child:getSize() or { w = 0 }
            row1_w = row1_w + (sz.w or 0)
        end
        local status_gap = Screen:scaleBySize(12)
        local status_max = content_width - row1_w - status_gap
        if status_max > 0 then
            table.insert(row1, HorizontalSpan:new{ width = status_gap })
            local status_face, status_bold = BFont:getFace("cfont", 13)
            table.insert(row1, TextWidget:new{
                text = status_text,
                face = status_face,
                bold = status_bold,
                max_width = status_max,
                fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            })
        end
    end

    local vg = VerticalGroup:new{ align = "left" }
    for i, row in ipairs(rows) do
        if i > 1 then table.insert(vg, VerticalSpan:new{ width = row_gap }) end
        table.insert(vg, row)
    end
    return vg
end

function LibraryModal:_onChipTap(chip_key)
    if self.active_chip == chip_key then return end
    -- Dismiss the keyboard before refreshing so the user isn't trapped under
    -- it after applying a chip filter.
    self:_dismissKeyboard()
    self.active_chip = chip_key
    self.page = 1
    if self.config.on_chip_tap then self.config.on_chip_tap(chip_key) end
    self:refresh()
end

function LibraryModal:_renderListArea(content_width, area_height)
    -- rows_per_page may be a function so callers can vary it per orientation
    -- (mirrors the grid_cols/cells_per_page contract for the grid mode).
    local rows_per_page = self.config.rows_per_page or 5
    if type(rows_per_page) == "function" then
        rows_per_page = rows_per_page()
    end
    local total = self.config.item_count and self.config.item_count() or 0

    if total == 0 and self.config.empty_state then
        local panel = self.config.empty_state(content_width, area_height)
        if panel then return panel end
    end

    local total_pages = math.max(1, math.ceil(total / rows_per_page))
    if self.page > total_pages then self.page = total_pages end
    self._total_pages = total_pages -- for swipe-paging bounds

    local start_idx = (self.page - 1) * rows_per_page + 1
    local end_idx = math.min(start_idx + rows_per_page - 1, total)

    -- Stack: rows × card + (rows-1) × MARGIN inter-row gap, no top/bottom inset.
    -- The MARGIN above the first card and below the last card is supplied by
    -- refresh()'s inter-section gap so the spacing matches the search box's.
    local row_height = math.floor(
        (area_height - (rows_per_page - 1) * MARGIN) / rows_per_page)
    local vg = VerticalGroup:new{ align = "left" }
    for idx = start_idx, end_idx do
        local item = self.config.item_at(idx)
        if item then
            if idx > start_idx then table.insert(vg, VerticalSpan:new{ width = MARGIN }) end
            local slot_dimen = Geom:new{ w = content_width, h = row_height }
            table.insert(vg, self.config.row_renderer(item, slot_dimen))
        end
    end
    local rendered = end_idx - start_idx + 1
    if rendered < rows_per_page then
        for _i = rendered + 1, rows_per_page do
            table.insert(vg, VerticalSpan:new{ width = MARGIN })
            table.insert(vg, VerticalSpan:new{ width = row_height })
        end
    end
    return CenterContainer:new{
        dimen = Geom:new{ w = content_width, h = area_height },
        vg,
    }
end

function LibraryModal:_renderGridArea(content_width, area_height)
    local cells_per_page = self.config.cells_per_page(content_width)
    local total = self.config.item_count and self.config.item_count() or 0
    local total_pages = math.max(1, math.ceil(total / cells_per_page))
    if self.page > total_pages then self.page = total_pages end
    self._total_pages = total_pages -- for swipe-paging bounds

    if total == 0 and self.config.empty_state then
        local panel = self.config.empty_state(content_width, area_height)
        if panel then return panel end
    end

    -- Cols: prefer explicit config.grid_cols (avoids the scaleBySize-driven
    -- heuristic, which gets fooled by KOReader's display scale factor and
    -- silently drops to 3 cols when the caller wanted 4). Fall back to a
    -- target-width heuristic for callers that don't declare cols.
    -- grid_cols may be a function so consumers can vary it per active chip.
    local cols
    if self.config.grid_cols then
        cols = type(self.config.grid_cols) == "function"
            and self.config.grid_cols()
            or self.config.grid_cols
    else
        local target_cell_w = Device.screen:scaleBySize(220)
        cols = math.max(3, math.floor(content_width / target_cell_w))
    end
    local rows = math.ceil(cells_per_page / cols)
    -- Cell dimensions subtract MARGIN gaps in both axes so the grid has
    -- visible breathing room horizontally as well as vertically. Without
    -- the (cols-1)*MARGIN subtraction the columns butt right up against
    -- each other and the cards lose their card-ness.
    local cell_w = math.floor((content_width - (cols - 1) * MARGIN) / cols)
    local cell_h = math.floor((area_height - (rows - 1) * MARGIN) / rows)

    -- Clamp dpad focus to valid range (items may have been removed).
    if self._dpad_idx and self._dpad_idx > total then
        self._dpad_idx = total > 0 and total or nil
    end

    local start_idx = (self.page - 1) * cells_per_page + 1
    local end_idx = math.min(start_idx + cells_per_page - 1, total)

    -- Focus ring: a thin border frame applied around the focused cell.
    -- The cell renderer receives a dimen shrunk by the border width on each
    -- side so the outer cell slot stays exactly cell_w × cell_h.
    local FOCUS = Device.screen:scaleBySize(2)

    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local vg = VerticalGroup:new{ align = "left" }
    local hg = HorizontalGroup:new{ align = "top" }
    local in_row = 0
    for idx = start_idx, end_idx do
        local item = self.config.item_at(idx)
        if item then
            local focused = self._dpad_idx ~= nil and idx == self._dpad_idx
            local render_dimen = focused
                and Geom:new{ w = cell_w - 2 * FOCUS, h = cell_h - 2 * FOCUS }
                or  Geom:new{ w = cell_w, h = cell_h }
            local cell_dimen = Geom:new{ w = cell_w, h = cell_h }
            local cell_widget = self.config.cell_renderer(item, render_dimen, focused)
            if focused then
                cell_widget = FrameContainer:new{
                    bordersize = FOCUS,
                    padding    = 0,
                    margin     = 0,
                    cell_widget,
                }
            end
            -- Always wrap cells in an InputContainer so tap (and optional
            -- long-tap) gestures route through to the domain handlers.
            -- on_cell_tap fires the action (insert glyph, etc.); cell_long_tap
            -- is optional (e.g. show name tooltip on long-press).
            if self.config.on_cell_tap or self.config.cell_long_tap then
                local GestureRange = require("ui/gesturerange")
                local ic = InputContainer:new{
                    dimen = Geom:new{ w = cell_w, h = cell_h },
                    cell_widget,
                }
                ic.ges_events = {}
                if self.config.on_cell_tap then
                    ic.ges_events.TapSelect = {
                        GestureRange:new{ ges = "tap", range = ic.dimen }
                    }
                    ic.onTapSelect = function()
                        self.config.on_cell_tap(item)
                        return true
                    end
                end
                if self.config.cell_long_tap then
                    ic.ges_events.Hold = {
                        GestureRange:new{ ges = "hold", range = ic.dimen }
                    }
                    ic.onHold = function()
                        self.config.cell_long_tap(item)
                        return true
                    end
                end
                cell_widget = ic
            end
            if in_row > 0 then
                table.insert(hg, HorizontalSpan:new{ width = MARGIN })
            end
            table.insert(hg, cell_widget)
            in_row = in_row + 1
            if in_row >= cols then
                if #vg > 0 then table.insert(vg, VerticalSpan:new{ width = MARGIN }) end
                table.insert(vg, hg)
                hg = HorizontalGroup:new{ align = "top" }
                in_row = 0
            end
        end
    end
    if in_row > 0 then
        if #vg > 0 then table.insert(vg, VerticalSpan:new{ width = MARGIN }) end
        table.insert(vg, hg)
    end
    -- Top-align the grid: a partially-filled page (e.g. Dynamic with 4
    -- entries in a 9-cell grid) shouldn't float in the vertical centre
    -- of the area; users expect the content to start at the top.
    local TopContainer = require("ui/widget/container/topcontainer")
    return TopContainer:new{
        dimen = Geom:new{ w = content_width, h = area_height },
        vg,
    }
end

function LibraryModal:_renderPagination(content_width)
    local Button = require("ui/widget/button")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local LineWidget = require("ui/widget/linewidget")
    local T = require("ffi/util").template
    local Screen = Device.screen

    local total = self.config.item_count and self.config.item_count() or 0
    local per_page = self.config.rows_per_page
        or (self.config.cells_per_page and self.config.cells_per_page(content_width))
        or 1
    if type(per_page) == "function" then
        per_page = per_page()
    end
    local total_pages = math.max(1, math.ceil(total / per_page))

    local chev_size = Screen:scaleBySize(32)

    -- show_parent is required for icon buttons to resolve their icon atlas path.
    local function chev(icon_name, enabled, cb)
        return Button:new{
            icon = icon_name, icon_width = chev_size, icon_height = chev_size,
            bordersize = 0, enabled = enabled,
            callback = enabled and cb or function() end,
            show_parent = self,
        }
    end
    -- Fresh span per slot — sharing one widget across HGroup positions
    -- corrupts paint geometry.
    local pn_span = Screen:scaleBySize(32)
    local function gap() return HorizontalSpan:new{ width = pn_span } end

    local page_nav = HorizontalGroup:new{
        align = "center",
        chev("chevron.first", self.page > 1,          function() self.page = 1;              self:refresh() end),
        gap(),
        chev("chevron.left",  self.page > 1,          function() self.page = self.page - 1;  self:refresh() end),
        gap(),
        Button:new{
            text = T(_("Page %1 of %2"), self.page, total_pages),
            text_font_size = 15,
            bordersize = 0,
            callback = function() end,
            show_parent = self,
        },
        gap(),
        chev("chevron.right", self.page < total_pages, function() self.page = self.page + 1; self:refresh() end),
        gap(),
        chev("chevron.last",  self.page < total_pages, function() self.page = total_pages;   self:refresh() end),
    }

    local function divider()
        -- Fresh widget per slot; sharing one across paint positions corrupts
        -- KOReader's geometry calculations. Line spans the full content_width
        -- so its endpoints align with the card rows above and below.
        return LineWidget:new{
            background = Blitbuffer.COLOR_DARK_GRAY,
            dimen = Geom:new{ w = content_width, h = Size.line.thin },
        }
    end

    -- Single-page lists (incl. empty / cold-gallery / single-page-fits-all)
    -- hide the chevrons + top divider but keep the BOTTOM divider so the
    -- footer (Close/Manage/Install) still has a separator line above it.
    -- Reserve equivalent total height so the modal stays the same size.
    if total_pages <= 1 then
        local nav_h = page_nav:getSize().h
        return VerticalGroup:new{
            align = "left",
            VerticalSpan:new{ width = Size.line.thin + MARGIN + nav_h + MARGIN },
            divider(),
        }
    end

    -- Pagination: divider above + MARGIN breathing room + chevron row + MARGIN
    -- + divider below. The lower divider visually separates the pagination
    -- from the footer action buttons.
    return VerticalGroup:new{
        align = "left",
        divider(),
        VerticalSpan:new{ width = MARGIN },
        CenterContainer:new{
            dimen = Geom:new{ w = content_width, h = page_nav:getSize().h },
            page_nav,
        },
        VerticalSpan:new{ width = MARGIN },
        divider(),
    }
end

function LibraryModal:_renderFooter(content_width)
    local Button = require("ui/widget/button")
    local Font = require("ui/font")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local LineWidget = require("ui/widget/linewidget")

    local actions = self.config.footer_actions or {}
    if #actions == 0 then return nil end

    -- Width must be passed at construction; Button bakes it into inner
    -- containers in :init, so post-assigning self.width has no effect.
    local btn_width = #actions > 1 and math.floor(content_width / #actions) or content_width

    local btns = {}
    for _i, action in ipairs(actions) do
        local enabled = true
        if action.enabled_when then enabled = action.enabled_when() end
        -- Dynamic label needed for Apply/Install switching in preset modal;
        -- label_func() takes precedence over the static label fallback.
        local btn_text = action.label_func and action.label_func() or action.label
        local act_face, act_bold = BFont:getFace("cfont", 16, { bold = action.primary == true })
        table.insert(btns, Button:new{
            text = btn_text,
            face = act_face,
            bold = act_bold,
            bordersize = 0,
            radius = 0,
            width = btn_width,
            callback = function() if enabled then action.on_tap() end end,
            enabled = enabled,
        })
    end

    if #btns == 1 then return btns[1] end

    local hg = HorizontalGroup:new{ align = "center" }
    for i, btn in ipairs(btns) do
        if i > 1 then
            table.insert(hg, LineWidget:new{
                background = Blitbuffer.COLOR_DARK_GRAY,
                dimen = Geom:new{ w = Size.line.thin, h = Device.screen:scaleBySize(28) },
            })
        end
        table.insert(hg, btn)
    end
    return hg
end

-- Swipe paging, same convention as the main shelf: west = next, east = prev.
-- _total_pages is set by the grid/list area render; clamp so a swipe at an
-- edge is a no-op. Returns true to consume the gesture.
function LibraryModal:onSwipeNextPage()
    if self.page < (self._total_pages or 1) then
        self.page = self.page + 1
        self:refresh()
    end
    return true
end

function LibraryModal:onSwipePrevPage()
    if self.page > 1 then
        self.page = self.page - 1
        self:refresh()
    end
    return true
end

function LibraryModal:refresh()
    local Screen = Device.screen
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local cw = self.content_w
    -- modal_w is passed so _renderTitleBar can draw an edge-to-edge separator.
    local title = self:_renderTitleBar(cw, self.modal_w)
    -- Domains with a handful of items (e.g. the module picker) can opt out
    -- of the search row entirely via config.no_search.
    local search = not self.config.no_search and self:_renderSearchInput(cw) or nil
    local chips = self:_renderChipStrip(cw)
    local pagination = self:_renderPagination(cw)
    local footer = self:_renderFooter(cw)

    -- Sized to fit content rather than a screen fraction, so the dialog isn't
    -- bigger than necessary. Uses the row renderer's intrinsic card height
    -- (matches preset_manager's Screen:scaleBySize(64)) so the area accommodates
    -- exactly rows_per_page cards plus inter/outer MARGIN gaps.
    local rows_per_page = self.config.rows_per_page
    if type(rows_per_page) == "function" then
        rows_per_page = rows_per_page()
    end
    -- Grid mode (cell_renderer) doesn't set rows_per_page; default it to a
    -- comfortable 5-rows-of-card-height area in portrait, one row less in
    -- landscape so the modal doesn't dominate the shorter dimension. Same
    -- shave applies to list-mode if its config returned the same value in
    -- both orientations (no-op when the caller already varies by orientation).
    rows_per_page = rows_per_page or 5
    local landscape = Screen:getWidth() > Screen:getHeight()
    if landscape and self.config.cell_renderer then
        rows_per_page = math.max(2, rows_per_page - 1)
    end
    local intrinsic_card_h = Screen:scaleBySize(64)
    -- area_height = card stack + inter-row gaps. The MARGIN above the first
    -- card and below the last card is the refresh() inter-section gap.
    local area_height = rows_per_page * intrinsic_card_h
        + (rows_per_page - 1) * MARGIN

    -- Frame's padding_left/right are 0 so the title bar separator runs edge-
    -- to-edge. Each non-title section is padded with HorizontalSpan(MARGIN)
    -- on either side so its content sits inside the same MARGIN inset.
    local function padded(widget)
        if not widget then return nil end
        return HorizontalGroup:new{
            align = "center",
            HorizontalSpan:new{ width = MARGIN },
            widget,
            HorizontalSpan:new{ width = MARGIN },
        }
    end

    local result_area
    if self.config.cell_renderer then
        result_area = self:_renderGridArea(cw, area_height)
    else
        result_area = self:_renderListArea(cw, area_height)
    end

    local body = VerticalGroup:new{
        align = "left",
        title,                                       -- spans full modal_w (separator inside)
        VerticalSpan:new{ width = MARGIN },
    }
    if search then
        table.insert(body, padded(search))
        table.insert(body, VerticalSpan:new{ width = MARGIN })
    end
    if chips then
        table.insert(body, padded(chips))
        table.insert(body, VerticalSpan:new{ width = MARGIN })
    end
    table.insert(body, padded(result_area))
    table.insert(body, VerticalSpan:new{ width = MARGIN })
    table.insert(body, padded(pagination))
    if footer then
        table.insert(body, VerticalSpan:new{ width = MARGIN })
        table.insert(body, padded(footer))
    end

    self.frame[1] = body
    -- Self-bounded dirty rect is sufficient now that the modal is a fixed,
    -- content-derived size. setDirty(nil, ...) was triggering full-screen
    -- repaints that stacked ~1s each on e-ink.
    UIManager:setDirty(self, "ui")
end

return LibraryModal
