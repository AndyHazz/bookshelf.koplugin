--- bookshelf_library_modal -- shared chrome widget for the library pickers
--- (collections, folders, ornaments, themes, modules...). Renders header,
--- optional tabs, search input, chip strip, paginated list-or-grid result
--- area, and footer. Laid out to the popup style guide (STYLE.md): search,
--- chips and the screen's own actions (config.header_actions) on one grey
--- strip under the title; the footer edge to edge, closing the frame. With
--- config.over it opens as a page of the menu under it. Domain-specific data
--- and per-row rendering are supplied by the caller via a config table.
---
--- First ported from bookends.koplugin/menu/library_modal.lua so bookshelf
--- works standalone; it has since grown its own (paging, pages of a menu,
--- the style guide) and no longer tracks upstream.

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
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Space = require("lib/bookshelf_space")
local BFont = require("lib/bookshelf_fonts")
local PopupKit = require("lib/bookshelf_popup_kit")
local _ = require("lib/bookshelf_i18n").gettext

-- Uniform gap applied everywhere below the title bar separator.
local MARGIN = Space.px(10)
-- A picker's intro line (config.intro): Kit.hintText at this size.
local HINT_FS = 19

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
    -- Grid focus: arrow keys + Press navigate and select cells, then hand
    -- off to the footer (+ New tag / Cancel / Save) when Down is pressed at
    -- the bottom of the grid -- see onGridFocusDown/Up. Only registered when
    -- the caller provides a cell_renderer (grid mode).
    -- config.focus_on_key (optional): function() -> the cell the focus
    -- should show on: the ring stays hidden until the first key press, which
    -- shows it there (when on the page shown, else on the page's first cell)
    -- rather than moving it. For a picker that marks its choice with a frame
    -- of its own, where a ring seeded on another cell looked like that mark.
    if Device:hasDPad() and self.config.cell_renderer then
        -- No ring until the first key press, on any picker: seeded on the
        -- first card, it looked like that card was the one chosen (the
        -- outline that marks the one in use). The first press shows it.
        self._focus_zone = "grid"  -- or "footer", see onGridFocusUp/Down
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
--
-- Close the keyboard too. InputText:onCloseWidget frees its keyboard but never
-- takes it off the window stack (stock InputDialog closes it itself), so any
-- path that closed the modal with the keyboard up - a cell tap or Close after
-- typing in the search box - left a modal VirtualKeyboard on top. It swallowed
-- every tap and KOReader looked frozen until restarted (the same bug bookends
-- fixed in its own copy, 5.30.0). Doing it here covers every close path at
-- once: cell and footer taps, the title's X, Back.
-- config.over: open as a page of the menu underneath rather than a window
-- over it: in that menu's frame (over.rect(), at least its height), titled
-- with its breadcrumb (over.crumbs) and a back chevron, the X leaving the
-- whole menu (over.on_exit). The back chevron is the footer's lone Close or
-- Back. Only that box is refreshed as it opens and closes.
function LibraryModal:onShow()
    if self.config and self.config.over and self._shown_rect then
        UIManager:setDirty(self, "ui", Geom:new(self._shown_rect))
    end
end

function LibraryModal:onCloseWidget()
    local input = self._search_input
    if input and input.isKeyboardVisible and input:isKeyboardVisible() then
        input:onCloseKeyboard()
    end
    if self.config and self.config.over and self._shown_rect then
        UIManager:setDirty("all", "ui", Geom:new(self._shown_rect))
    else
        UIManager:setDirty("all", "ui")
    end
    -- config.on_closed: the caller's once-per-close hook, however the modal
    -- was closed (a footer button, the title's X, Back).
    if self.config and self.config.on_closed then pcall(self.config.on_closed) end
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

-- Back on the keys: a page of a menu (config.over) goes back a page, as its
-- chevron does (STYLE.md); a picker of its own closes.
function LibraryModal:onClose()
    local back = self.config and self.config.over and self:_backAction()
    if back then
        back.on_tap()
        return true
    end
    UIManager:close(self)
    return true
end

-- _cellsPerPage(content_w) -> config.cells_per_page, or as many rows as fill
-- the page when it is a page of the editor (refresh: self._fill_rows).
function LibraryModal:_cellsPerPage(content_width)
    if self._fill_rows and self.config.cell_renderer then
        return self._fill_rows * self:_gridCols()
    end
    return self.config.cells_per_page and self.config.cells_per_page(content_width) or 1
end

-- _revealFocus() -> true when the focus ring was hidden (every picker opens
-- with it hidden) and this key press showed it instead of moving it: on the
-- cell config.focus_on_key() names when it is on the page, else the first.
function LibraryModal:_revealFocus()
    if self._dpad_idx ~= nil then return false end
    local total = self.config.item_count and self.config.item_count() or 0
    if total == 0 then return false end
    local per = self:_cellsPerPage(self.content_w)
    local first = ((self.page or 1) - 1) * per + 1
    local last = math.min(total, first + per - 1)
    local want = self.config.focus_on_key and self.config.focus_on_key()
    if not (want and want >= first and want <= last) then want = first end
    self._dpad_idx = want
    self._focus_zone = "grid"
    self:refresh()
    return true
end

-- Grid dpad navigation. `delta` is ±1 (Left/Right) or ±cols (Up/Down).
-- Clamps at [1, total] and pages automatically when crossing a page boundary.
function LibraryModal:_gridNav(delta)
    local total = self.config.item_count and self.config.item_count() or 0
    if total == 0 then return end
    local cells_per_page = self:_cellsPerPage(self.content_w)
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

-- Clamp a footer column into whatever width row `row` actually has (rows can
-- have a different button count, e.g. a lone "+ New tag" above "Cancel"/"Save").
function LibraryModal:_clampFooterCol(row, col)
    local r = self._footer_layout and self._footer_layout[row]
    if not r or #r == 0 then return 1 end
    return math.max(1, math.min(#r, col))
end

-- Grid <-> footer dpad handoff: Left/Right/Up/Down behave as plain grid nav
-- (or plain footer nav) most of the time, but Down at the LAST grid row
-- moves focus into the footer's first row, and Up at the footer's FIRST row
-- moves back into the grid -- so the whole modal (tag grid + Cancel/Save/
-- + New tag) is reachable in one continuous dpad chain, matching how the
-- book-detail popup's own tabs/pills/buttons chain together (see
-- [[project_dpad_focus_navigation]]).
-- The strip (its chips, a sort switch, header buttons) is a third zone, over
-- the grid: _strip_layout, rows of its widgets, rebuilt by each refresh.
-- _stripPos() -> the widget the keys are on there (row and column clamped).
function LibraryModal:_stripPos()
    local rows = self._strip_layout
    if not (rows and #rows > 0) then return nil end
    self._strip_row = math.max(1, math.min(#rows, self._strip_row or #rows))
    local row = rows[self._strip_row]
    self._strip_col = math.max(1, math.min(#row, self._strip_col or 1))
    return row[self._strip_col]
end

function LibraryModal:onGridFocusLeft()
    if self._focus_zone == "strip" then
        self._strip_col = (self._strip_col or 1) - 1
        self:_stripPos(); self:refresh()
        return true
    end
    if self:_revealFocus() then return true end
    if self._focus_zone == "footer" then
        self._footer_col = self:_clampFooterCol(self._footer_row or 1, (self._footer_col or 1) - 1)
        self:refresh()
    else
        self:_gridNav(-1)
    end
    return true
end

function LibraryModal:onGridFocusRight()
    if self._focus_zone == "strip" then
        self._strip_col = (self._strip_col or 1) + 1
        self:_stripPos(); self:refresh()
        return true
    end
    if self:_revealFocus() then return true end
    if self._focus_zone == "footer" then
        self._footer_col = self:_clampFooterCol(self._footer_row or 1, (self._footer_col or 1) + 1)
        self:refresh()
    else
        self:_gridNav(1)
    end
    return true
end

function LibraryModal:onGridFocusUp()
    if self._focus_zone == "strip" then
        if (self._strip_row or 1) > 1 then
            self._strip_row = self._strip_row - 1
            self:_stripPos(); self:refresh()
        end
        return true
    end
    -- From the grid's top row (or an empty grid), up to the strip.
    local strip = self._strip_layout and #self._strip_layout > 0
    if strip and self._focus_zone ~= "footer"
            and (self._dpad_idx == nil or self._dpad_idx - self:_gridCols() < 1) then
        local total = self.config.item_count and self.config.item_count() or 0
        if self._dpad_idx ~= nil or total == 0 then
            self._focus_zone = "strip"
            self._strip_row, self._strip_col = #self._strip_layout, 1
            self:_stripPos(); self:refresh()
            return true
        end
    end
    if self:_revealFocus() then return true end
    if self._focus_zone == "footer" then
        if (self._footer_row or 1) <= 1 then
            self._focus_zone = "grid"  -- back to wherever _dpad_idx last was
        else
            self._footer_row = (self._footer_row or 1) - 1
            self._footer_col = self:_clampFooterCol(self._footer_row, self._footer_col or 1)
        end
        self:refresh()
    else
        self:_gridNav(-self:_gridCols())
    end
    return true
end

function LibraryModal:onGridFocusDown()
    if self._focus_zone == "strip" then
        if (self._strip_row or 1) < #self._strip_layout then
            self._strip_row = self._strip_row + 1
            self:_stripPos()
        else
            -- Below the strip: the grid, where the keys last were.
            self._focus_zone = "grid"
            if self._dpad_idx == nil then return self:_revealFocus() or true end
        end
        self:refresh()
        return true
    end
    if self:_revealFocus() then return true end
    if self._focus_zone == "footer" then
        local rows = self._footer_layout and #self._footer_layout or 0
        if (self._footer_row or 1) < rows then
            self._footer_row = (self._footer_row or 1) + 1
            self._footer_col = self:_clampFooterCol(self._footer_row, self._footer_col or 1)
            self:refresh()
        end
        -- Already on the last footer row -- nothing below it, no-op.
    else
        local before = self._dpad_idx
        self:_gridNav(self:_gridCols())
        if self._dpad_idx == before and self._footer_layout then
            -- Down was a no-op (already at the grid's last row/item) and
            -- there's a footer to hand off to.
            self._focus_zone = "footer"
            self._footer_row = 1
            self._footer_col = 1
            self:refresh()
        end
    end
    return true
end

function LibraryModal:onGridPress()
    if self._focus_zone == "strip" then
        -- A tap at the widget's middle, as KOReader's FocusManager sends one.
        local w = self:_stripPos()
        local d = w and w.dimen
        if d and d.x then
            local Geom_ = require("ui/geometry")
            w:handleEvent(require("ui/event"):new("Gesture", { ges = "tap", time = require("ui/time").now(),
                pos = Geom_:new{ x = d.x + math.floor(d.w / 2), y = d.y + math.floor(d.h / 2), w = 0, h = 0 } }))
        end
        return true
    end
    if self:_revealFocus() then return true end
    if self._focus_zone == "footer" then
        local row = self._footer_layout and self._footer_layout[self._footer_row or 1]
        local btn = row and row[self._footer_col or 1]
        if btn and btn.callback then btn.callback() end
        return true
    end
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
        self:_dirty()
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
        -- A page of the menu underneath: outside it is going back, as the
        -- chevron does.
        local back = self.config.over and self:_backAction()
        if back then back.on_tap() else UIManager:close(self) end
        return true
    end
    return false
end

-- rowsForShare(share) -> a rows_per_page whose grid area is about that share
-- of the screen's height: the modal's grid is rows_per_page cards of 64dp,
-- so a fixed count is a different share at every DPI and screen size.
function LibraryModal.rowsForShare(share)
    local Screen = Device.screen
    local unit = Screen:scaleBySize(64) + MARGIN
    return math.max(2, math.floor(Screen:getHeight() * share / unit))
end

function LibraryModal:_buildFrame()
    local Screen = Device.screen
    -- Modal width: 85% of screen. Less wide than the 90% it was — visible
    -- breathing room around the dialog for context.
    local over = self.config.over and self.config.over.rect()
    self._over_rect = over
    -- modal_w is inside the frame's border; over.w is the menu's outside, so
    -- a page of it takes the border off, or it stood a border proud of the
    -- menu it covers on each side.
    self.modal_w = over and (over.w - 2 * Size.border.window) or math.floor(Screen:getWidth() * 0.85)
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
        -- A page of a menu takes the menu's corners.
        radius = over and Space.radius.window or Space.px(8),
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{ align = "left" },
    }
    -- The footer's buttons run to the frame's edge and paint square white
    -- boxes: draw the rounded border again over them, or its bottom corners
    -- are cut off.
    local frame = self.frame
    function frame:paintTo(bb, x, y)
        FrameContainer.paintTo(self, bb, x, y)
        local sz = self:getSize()
        bb:paintBorder(x, y, sz.w, sz.h, self.bordersize, Blitbuffer.COLOR_BLACK, self.radius)
    end
    if over then
        -- Where the menu underneath is, not centred.
        local holder = WidgetContainer:new{
            dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() }, self.frame }
        function holder:paintTo(bb) frame:paintTo(bb, over.x, over.y) end
        self[1] = holder
    else
        self[1] = CenterContainer:new{
            dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() },
            self.frame,
        }
    end
    self:refresh()
end

function LibraryModal:_renderTitleBar(content_width, modal_w)
    local over = self.config.over
    if over then
        -- The menu's own title bar: its breadcrumb, back, and X.
        local back = self:_backAction()
        local bar = require("ui/widget/titlebar"):new{
            title_face = PopupKit.titleFace(),
            width            = modal_w,
            title            = over.crumbs or self.config.title,
            with_bottom_line = true,
            bottom_v_padding = 0,
            left_icon        = "chevron.left",
            left_icon_tap_callback = function() if back then back.on_tap() end end,
            close_callback   = function()
                UIManager:close(self)
                if over.on_exit then over.on_exit() end
            end,
            show_parent      = self,
        }
        -- The shelf's name in the breadcrumb with its pictures.
        PopupKit.iconTitle(bar, over.crumbs or self.config.title)
        PopupKit.centreTitle(bar)
        return PopupKit.backLabel(bar)
    end
    local Font = require("ui/font")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local LeftContainer = require("ui/widget/container/leftcontainer")
    local LineWidget = require("ui/widget/linewidget")
    local TextWidget = require("lib/bookshelf_colour_text")
    local Screen = Device.screen
    -- Equal top/bottom padding so the title text reads as vertically centred.
    local bar_pad = Space.px(8)

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
    -- A footer of Close alone is the title's X instead (as the book popup's),
    -- not a whole row for one thin button.
    local close = self:_closeOnlyAction()
    if close then
        local IconButton = require("ui/widget/iconbutton")
        local size = Screen:scaleBySize(28)
        local x_btn = IconButton:new{ icon = "close", width = size, height = size,
            padding = Space.px(6), callback = function() close.on_tap() end,
            show_parent = self }
        right_widget = HorizontalGroup:new{ align = "center", right_widget,
            HorizontalSpan:new{ width = Space.px(8) }, x_btn }
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

-- _closeOnlyAction() -> the footer's one action when it is Close alone
-- (key "close" or labelled Close), else nil.
function LibraryModal:_closeOnlyAction()
    local rows = self.config.footer_rows or { self.config.footer_actions or {} }
    local only
    for _i, row in ipairs(rows) do
        for _j, a in ipairs(row) do
            if only then return nil end
            only = a
        end
    end
    -- A `done` action is the way on after a multi-select: a real button.
    if only and only.done then return nil end
    if only and (only.key == "close" or only.label == _("Close")
            or (self.config.over and only.label == _("Back"))) then return only end
    return nil
end

-- _backAction() -> what going back a page runs (config.over): the footer's
-- lone Close or Back, else its Done (a multi-select: back keeps the ticks,
-- as Done does), else its Cancel (a Cancel | Save picker: back leaves what
-- was picked, as Cancel does).
function LibraryModal:_backAction()
    local only = self:_closeOnlyAction()
    if only then return only end
    for _i, row in ipairs(self.config.footer_rows or { self.config.footer_actions or {} }) do
        for _j, a in ipairs(row) do
            if a.done or a.label == _("Cancel") then return a end
        end
    end
    return nil
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
    local TextWidget = require("lib/bookshelf_colour_text")
    local Screen = Device.screen
    local seg_pad_h = Space.px(12)

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

-- _renderSearchInput(content_width) -> the search row: field, Search, clear.
-- content_width is what the row may take (less any header buttons beside it).
function LibraryModal:_renderSearchInput(content_width)
    local Font = require("ui/font")
    local GestureRange = require("ui/gesturerange")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local TextWidget = require("lib/bookshelf_colour_text")
    local Screen = Device.screen

    local placeholder = self.config.search_placeholder
        and self.config.search_placeholder(self.active_tab)
        or _("Search…")

    -- Button labels match the tab pill font (cfont/14) so the row reads as
    -- one family. The input itself stays at cfont/16 for typing legibility.
    local btn_face = (BFont:getFace("cfont", 14))
    local input_face = (BFont:getFace("cfont", 16))
    local btn_pad_h = Space.px(12)
    local gap = Space.px(6)
    -- InputText wraps its TextWidget in a FrameContainer with bordersize +
    -- padding, so its rendered outer width is `width + 2 * (border + padding)`.
    -- Subtract that overhead from input_w so the search row totals exactly
    -- content_width, otherwise the row pushes the modal frame wider than
    -- modal_w and asymmetric right-edge gaps appear.
    --
    -- Input + button borders. Use Size.border.default (thicker than thin)
    -- so the focused-black border reads as a strong outline rather than a
    -- hairline that could pass for unfocused-gray on glance.
    local input_border = PopupKit.BORDER
    local input_padding = Space.padding.default
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
            self:_dirty()
            return r
        end
        -- Slightly rounded corners on the input border distinguish the
        -- search row from the segmented (square) chip strip below. The
        -- inner FrameContainer is what InputText renders the border
        -- through (inputtext.lua:569), so set radius there before paint.
        input._frame_textwidget.radius = PopupKit.RADIUS
        -- It sits on the grey strip: a white field.
        input._frame_textwidget.background = Blitbuffer.COLOR_WHITE
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
    local function chipButton(label, on_tap)
        return PopupKit.button{ text = label, face = btn_face, height = row_h,
            pad_h = btn_pad_h, on_tap = on_tap }
    end

    local search_btn = chipButton(_("Search"), function()
        local q = self._search_input and self._search_input:getText() or ""
        self:_dismissKeyboard()
        self:_onSearchSubmit(q)
    end)
    local clear_btn = chipButton("\xE2\x9C\x95", function()
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
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local TextWidget = require("lib/bookshelf_colour_text")

    if not self.config.chip_strip then return nil end
    local chips = self.config.chip_strip(self.active_tab)
    if not chips or #chips == 0 then return nil end

    -- chip.is_active from the config callback wins when present (lets the
    -- domain show NO chip as selected, e.g. the cold gallery state);
    -- otherwise the widget-tracked active_chip.
    local items, active = {}, nil
    for _i, chip in ipairs(chips) do
        items[#items + 1] = { key = chip.key, label = chip.label }
        local on
        if chip.is_active ~= nil then on = chip.is_active else on = chip.key == self.active_chip end
        if on then active = chip.key end
    end
    -- The popup's segmented control, wrapped to at most two rows; the rest
    -- behind More, a list (the chip picked from it then shows in the strip).
    local face = BFont:getFace("cfont", 14)
    local strip, strip_rows = PopupKit.segmentedWrap{
        items = items, active = active, face = face,
        pad_h = Space.px(12), pad_v = Space.px(6),
        max_w = content_width, max_rows = 2, gap = MARGIN,
        on_pick = function(key) self:_onChipTap(key) end,
        more_label = _("More\xE2\x80\xA6"),
        on_more = function(hidden) self:_showMoreChips(hidden) end,
    }
    -- Its cells, row by row, for the keys (_strip_layout).
    for _i, r in ipairs(strip_rows or {}) do self._strip_build[#self._strip_build + 1] = r end

    -- Optional status text beside the chips (config.chip_strip_status), for
    -- transient feedback like "Loading gallery…", so it reads as part of the
    -- modal rather than a separate popup.
    local status_text = self.config.chip_strip_status
        and self.config.chip_strip_status(self.active_tab) or nil
    if status_text and #status_text > 0 then
        local status_gap = Space.px(12)
        local status_max = content_width - strip:getSize().w - status_gap
        if status_max > 0 then
            local status_face = BFont:getFace("cfont", 13)
            strip = HorizontalGroup:new{ align = "center", strip,
                HorizontalSpan:new{ width = status_gap },
                TextWidget:new{ text = status_text, face = status_face,
                    max_width = status_max, fgcolor = require("lib/bookshelf_popup_kit").DIM_ON_GREY } }
        end
    end
    return strip
end

-- _renderHeaderButtons() -> the screen's own actions (config.header_actions:
-- an array, or a function returning one, of { label, icon, on_tap,
-- enabled_when, on_when, at_left }) as the kit's header buttons, or nil.
-- on_when: black while it is the choice in use. at_left: at the strip's
-- left end when nothing else is there (no chips, no search beside it), so
-- a strip of actions alone is not all at one end (the Theme library's Add
-- theme pack, maintainer). Returns the right-hand buttons, then the left.
function LibraryModal:_renderHeaderButtons()
    local actions = self.config.header_actions
    if type(actions) == "function" then actions = actions(self.active_tab) end
    if not actions or #actions == 0 then return nil end
    local btns, left = {}, {}
    for _i, a in ipairs(actions) do
        local enabled = true
        if a.enabled_when then enabled = a.enabled_when() end
        local into = a.at_left and left or btns
        into[#into + 1] = PopupKit.headerButton{ text = a.label, icon = a.icon,
            font_size = 16, enabled = enabled, inverted = a.on_when and a.on_when() or false,
            on_tap = function()
                self:_dismissKeyboard()
                a.on_tap()
            end }
    end
    -- The keys reach them after the chips, on a row of their own.
    local keys = {}
    for _i, b in ipairs(left) do keys[#keys + 1] = b end
    for _i, b in ipairs(btns) do keys[#keys + 1] = b end
    if #keys > 0 then self._strip_build[#self._strip_build + 1] = keys end
    return btns, (#left > 0) and left or nil
end

-- _renderStrip(cw) -> the grey strip under the title: the search box, then
-- the chips with the header buttons at the right end (stacked when they
-- don't fit), edge to edge with the kit's shadow. nil when it would be empty.
function LibraryModal:_renderStrip(cw)
    self._strip_build = {}
    local chips = self:_renderChipStrip(cw)
    local buttons, at_left = self:_renderHeaderButtons()
    if at_left then
        if chips or not self.config.no_search then
            -- Something is at the left already: they join the others.
            for i, b in ipairs(at_left) do table.insert(buttons, i, b) end
        else
            local row = require("ui/widget/horizontalgroup"):new{ align = "center" }
            for i, b in ipairs(at_left) do
                if i > 1 then row[#row + 1] = HorizontalSpan:new{ width = Space.px(10) } end
                row[#row + 1] = b
            end
            return PopupKit.headerRow{ width = self.modal_w, inset = MARGIN,
                left = row, buttons = buttons, pad_top = MARGIN, pad_bottom = MARGIN }
        end
    end
    local search
    -- config.chips_beside_search: a short switch (a picker's A-Z | Most books)
    -- sits at the right end of the search row with any header buttons, while
    -- that leaves the field at least half the row.
    if chips and not self.config.no_search and self.config.chips_beside_search then
        local right = { chips }
        local rw = chips:getSize().w + MARGIN
        for _i, b in ipairs(buttons or {}) do
            right[#right + 1] = b
            rw = rw + b:getSize().w + MARGIN
        end
        -- The widest it has been: the switch's bold active label changes its
        -- width, and a field that changed width would be rebuilt, dropping
        -- what was typed in it.
        self._beside_w = math.max(self._beside_w or 0, rw)
        local sw = self._beside_w
        if cw - sw >= cw / 2 then
            if self._search_row_w ~= cw - sw then self._search_input = nil end
            self._search_row_w = cw - sw
            search = self:_renderSearchInput(cw - sw)
            return PopupKit.headerRow{ width = self.modal_w, inset = MARGIN,
                left = search, buttons = right, pad_top = MARGIN, pad_bottom = MARGIN }
        end
    end
    if not self.config.no_search then
        -- No chips: the header buttons share the search row, while that
        -- leaves the field at least half the row (one strip line, not two).
        local bw = 0
        if buttons and not chips then
            for _i, b in ipairs(buttons) do bw = bw + b:getSize().w + MARGIN end
        end
        if bw > 0 and cw - bw >= cw / 2 then
            -- The row is rebuilt when it changes width (it keeps the field).
            if self._search_row_w ~= cw - bw then self._search_input = nil end
            self._search_row_w = cw - bw
            search = self:_renderSearchInput(cw - bw)
            return PopupKit.headerRow{ width = self.modal_w, inset = MARGIN,
                left = search, buttons = buttons, pad_top = MARGIN, pad_bottom = MARGIN }
        end
        if self._search_row_w ~= cw then self._search_input = nil end
        self._search_row_w = cw
        search = self:_renderSearchInput(cw)
    end
    if not (search or chips or buttons) then return nil end
    return PopupKit.headerRow{ width = self.modal_w, inset = MARGIN,
        top = search, left = chips, buttons = buttons,
        pad_top = MARGIN, pad_bottom = MARGIN }
end

-- _showMoreChips(hidden): the chips past the strip's two rows, as a list.
function LibraryModal:_showMoreChips(hidden)
    local ButtonDialog = require("ui/widget/buttondialog")
    local d
    local buttons = {}
    for _i, it in ipairs(hidden) do
        local key = it.key
        buttons[#buttons + 1] = { { text = it.label, callback = function()
            UIManager:close(d)
            self:_onChipTap(key)
        end } }
    end
    -- Sized to its labels, not the screen (maintainer): a short list of
    -- filters in a full-width menu read as a different kind of window.
    d = ButtonDialog:new{ buttons = buttons, shrink_unneeded_width = true }
    require("lib/bookshelf_gesture_zones").passSwipesOn(d)
    UIManager:show(d)
end

function LibraryModal:_onChipTap(chip_key)
    if self.active_chip == chip_key then return end
    -- Dismiss the keyboard before refreshing so the user isn't trapped under
    -- it after applying a chip filter.
    self:_dismissKeyboard()
    self.active_chip = chip_key
    self.page = 1
    -- A new list from its first page, not a page turn (on_page_shown).
    self._page_shown = 1
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
    local cells_per_page = self:_cellsPerPage(content_width)
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
    local cols = self:_gridCols()
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


    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local vg = VerticalGroup:new{ align = "left" }
    local hg = HorizontalGroup:new{ align = "top" }
    local in_row = 0
    -- buildCell(idx, item) -> the card as cell_renderer draws it, with the
    -- keys' ring. Kept per item (_cell_slots) for refreshCell.
    local modal = self
    local function buildCell(idx, item)
        -- Ringed only while the keys are on the grid (not the strip or
        -- the footer: two rings at once).
        local focused = modal._focus_zone == "grid" and modal._dpad_idx ~= nil and idx == modal._dpad_idx
        local cell_widget = modal.config.cell_renderer(item, Geom:new{ w = cell_w, h = cell_h }, focused)
        if focused then
            -- The kit's focus ring, inverted inside the card's edge at its
            -- corner: a heavy outline round it read as the card in use.
            local inner = cell_widget
            cell_widget = WidgetContainer:new{ dimen = Geom:new{ w = cell_w, h = cell_h }, inner }
            function cell_widget:paintTo(bb, x, y)
                inner:paintTo(bb, x, y)
                local sz = inner:getSize()
                PopupKit.invertRing(bb, x, y, sz.w, sz.h, PopupKit.focusWidth(), PopupKit.RADIUS)
            end
        end
        return cell_widget
    end
    self._cell_slots = {}
    self._build_cell = buildCell
    for idx = start_idx, end_idx do
        local item = self.config.item_at(idx)
        if item then
            local cell_dimen = Geom:new{ w = cell_w, h = cell_h }
            local cell_widget = buildCell(idx, item)
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
                    -- The card shows pressed at once, then the tap acts.
                    ic.onTapSelect = function()
                        -- config.select_on_tap: a tap marks the card picked at
                        -- once (the Theme library), which is its feedback; a
                        -- pressed look first was one paint too many.
                        if self.config.select_on_tap then
                            self.config.on_cell_tap(item)
                        else
                            PopupKit.pressThen(ic, PopupKit.findCard(cell_widget),
                                function() self.config.on_cell_tap(item) end)
                        end
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
                self._cell_slots[item] = { ic = ic, idx = idx }
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

-- refreshCell(item): draw that card again where it is, and refresh its box
-- alone: a tick in a multi-select picker changes one card, where refresh()
-- built the whole picker again and refreshed all of it. Anything else (an
-- item not on this page, a picker in list mode) falls back to refresh().
function LibraryModal:refreshCell(item)
    local slot = self._cell_slots and self._cell_slots[item]
    local d = slot and slot.ic.dimen
    if not (slot and self._build_cell and d and d.x) then return self:refresh() end
    slot.ic[1] = self._build_cell(slot.idx, item)
    UIManager:setDirty(self, function() return "ui", d end)
end

function LibraryModal:_renderPagination(content_width)
    local Button = require("ui/widget/button")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local LineWidget = require("ui/widget/linewidget")
    local T = require("ffi/util").template
    local Screen = Device.screen

    local total = self.config.item_count and self.config.item_count() or 0
    -- The footer page count MUST use the same per-page divisor the active layout
    -- paginates by, or the footer disagrees with navigation (the "Page 3 of 2"
    -- bug). Grid mode sets cells_per_page and navigates by it (see
    -- _renderGridArea/_total_pages); list mode sets rows_per_page. A grid caller
    -- may ALSO set rows_per_page purely to tune the grid area height (it has no
    -- bearing on grid paging), so cells_per_page must win here when present.
    local per_page = (self.config.cells_per_page and self:_cellsPerPage(content_width))
        or self.config.rows_per_page
        or 1
    if type(per_page) == "function" then
        per_page = per_page()
    end
    local total_pages = math.max(1, math.ceil(total / per_page))

    -- Shared pagination control (identical look in the collection manager).
    local page_nav = require("lib/bookshelf_pagination").buildNav{
        page        = self.page,
        total_pages = total_pages,
        show_parent = self,
        on_goto     = function(p) self.page = p; self:refresh() end,
    }

    -- No rules around it: the footer's own line closes the content.
    -- Single-page lists hide the chevrons but keep their height, so the
    -- modal stays the same size.
    if total_pages <= 1 then
        return VerticalSpan:new{ width = page_nav:getSize().h }
    end
    return CenterContainer:new{
        dimen = Geom:new{ w = content_width, h = page_nav:getSize().h },
        page_nav,
    }
end

-- Builds the footer AND, as a side effect, self._footer_layout -- the same
-- rows, but as plain arrays of the Button widgets themselves (dpad-focus
-- targets; see onGridFocusUp/Down/Left/Right's footer handoff below). nil
-- when there's no footer, so navigation code can just check its presence.
function LibraryModal:_renderFooter(content_width)
    -- content_width is the modal's full inner width: the footer runs edge to
    -- edge under a full-width line, so its separators meet the frame.
    self._footer_layout = nil
    if self:_closeOnlyAction() then return nil end

    -- footer_rows (array of action-rows) renders a stacked multi-row bar,
    -- mirroring ButtonDialog (e.g. a full-width "+ New" above a Cancel/Save
    -- pair). footer_actions stays the single-row shorthand.
    local rows = self.config.footer_rows
    if not rows then
        local actions = self.config.footer_actions or {}
        if #actions == 0 then return nil end
        rows = { actions }
    end
    -- Drop empty rows so a conditional action set can't leave a blank band.
    local nonempty = {}
    for _i = 1, #rows do
        if rows[_i] and #rows[_i] > 0 then nonempty[#nonempty + 1] = rows[_i] end
    end
    if #nonempty == 0 then return nil end

    -- Each row: the kit's footer row (a full-width rule above it, like
    -- ButtonDialog's), its buttons for the keys (_footer_layout).
    local VerticalGroup = require("ui/widget/verticalgroup")
    local vg = VerticalGroup:new{ align = "center" }
    self._footer_layout = {}
    for _i = 1, #nonempty do
        local actions = {}
        for j, a in ipairs(nonempty[_i]) do
            local enabled = true
            if a.enabled_when then enabled = a.enabled_when() end
            -- label_func (the preset modal's Apply / Install) wins over label.
            actions[j] = { text = a.label_func and a.label_func() or a.label,
                primary = a.primary, enabled = enabled, callback = a.on_tap }
        end
        local row, btns = PopupKit.footerRow(actions, content_width, { radius = self.frame.radius })
        vg[#vg + 1] = row
        self._footer_layout[#self._footer_layout + 1] = btns
    end
    return vg
end

-- _repaintIfResized(old): a refresh that changed the modal's size (it is
-- sized to its content, centred) leaves part of where it was uncovered, and
-- the modal's own dirty rect does not reach it: the windows underneath are
-- repainted there (PW5: a copy of the title bar stayed on screen). old is the
-- rectangle the last refresh recorded (self._shown_rect, centred as the
-- CenterContainer centres it): frame.dimen will not do, FrameContainer sizes
-- it once at its first paint and only moves it after, so it is also dropped
-- on a resize, or taps outside the modal are judged by the old size.
function LibraryModal:_repaintIfResized(old)
    local size = self.frame:getSize()
    local Screen = Device.screen
    local at = self._over_rect
    self._shown_rect = { x = at and at.x or math.floor((Screen:getWidth() - size.w) / 2),
                         y = at and at.y or math.floor((Screen:getHeight() - size.h) / 2),
                         w = size.w, h = size.h }
    if not old or (size.w == old.w and size.h == old.h) then return end
    self.frame.dimen = nil
    UIManager:setDirty("all", "ui", Geom:new{ x = old.x, y = old.y, w = old.w, h = old.h })
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
    local strip = self:_renderStrip(cw)
    -- What the keys can reach on it: its controls that can act, row by row.
    local layout = {}
    for _i, r in ipairs(self._strip_build or {}) do
        local row = {}
        for _j, w in ipairs(r) do if w.enabled ~= false then row[#row + 1] = w end end
        if #row > 0 then layout[#layout + 1] = row end
    end
    self._strip_layout = layout
    if self._focus_zone == "strip" and #layout == 0 then self._focus_zone = "grid" end
    local pagination = self:_renderPagination(cw)
    local footer = self:_renderFooter(self.modal_w)
    -- Where the modal was, for _repaintIfResized below.
    local old = self._shown_rect

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
    -- config.area_height(content_w, room): the caller's own height for the
    -- cards' area, when its cards are not 64dp rows (the Theme library: a
    -- page of cards of its own height, the modal no taller than they need).
    -- room: the most the area can have with the modal on the screen, or the
    -- editor's page it is (a small screen whose strip wraps to two rows ran
    -- the cards and the page row off the bottom).
    local function room(limit)
        local chrome = title:getSize().h + (strip and strip:getSize().h or 0) + 2 * MARGIN
            + pagination:getSize().h + 2 * self.frame.bordersize
            + (footer and (MARGIN + footer:getSize().h) or (MARGIN + math.floor(MARGIN / 2)))
        local intro = self.config.intro
        if type(intro) == "function" then intro = intro() end
        if intro and intro ~= "" then
            chrome = chrome + PopupKit.hintText(intro, HINT_FS, cw):getSize().h + MARGIN
        end
        limit = limit or self._over_rect and self._over_rect.h or (Screen:getHeight() - 2 * MARGIN)
        return limit - chrome
    end
    self._fill_rows = nil
    if self.config.area_height then
        local r = room()
        if self._over_rect then
            -- A page of the editor: at least the picker's own height, as far
            -- as the screen goes below the editor's top, as a cell picker
            -- has its own rows below. The front page alone was the room, and
            -- the module packs' second row of tabs left one row of squashed
            -- cards under the page row (PW5).
            local own = self.config.area_height(cw, nil)
            r = math.max(r, math.min(own, room(Screen:getHeight() - self._over_rect.y - MARGIN)))
        end
        area_height = self.config.area_height(cw, r)
        -- The caller may now show fewer a page: the page row counts again.
        pagination = self:_renderPagination(cw)
    elseif self._over_rect and self.config.cell_renderer then
        -- A page of the editor is the editor's height (one size, less to
        -- paint): as many rows of cards at their own height as fill it, not
        -- the picker's own count with an empty band under it (maintainer:
        -- Collections from the bulk menu).
        -- A short page (Genre's lists) gives at least the picker's own
        -- rows, as far as the screen goes below the editor's top: two rows
        -- were 73 pages of genres (PW5).
        local function fit(h) return math.floor((h + MARGIN) / (intrinsic_card_h + MARGIN)) end
        local screen_h = Screen:getHeight() - self._over_rect.y - MARGIN
        local rows = math.max(2, math.max(fit(room()), math.min(rows_per_page, fit(room(screen_h)))))
        self._fill_rows = rows
        area_height = rows * intrinsic_card_h + (rows - 1) * MARGIN
        pagination = self:_renderPagination(cw)
    end

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
    }
    if strip then table.insert(body, strip) end      -- spans full modal_w
    table.insert(body, VerticalSpan:new{ width = MARGIN })
    -- config.intro: a line or two saying what a tap does (the collection
    -- editor's manage and bulk modes), as grey hint text. Over the grid, or
    -- under it with config.intro_below (the ornament browser's line about
    -- whose set its boxes are: it explains the grid, so it follows it,
    -- maintainer).
    local intro = self.config.intro
    if type(intro) == "function" then intro = intro() end
    local has_intro = intro and intro ~= ""
    if has_intro and not self.config.intro_below then
        table.insert(body, padded(PopupKit.hintText(intro, HINT_FS, cw)))
        table.insert(body, VerticalSpan:new{ width = MARGIN })
    end
    table.insert(body, padded(result_area))
    table.insert(body, VerticalSpan:new{ width = MARGIN })
    if has_intro and self.config.intro_below then
        table.insert(body, padded(PopupKit.hintText(intro, HINT_FS, cw)))
        table.insert(body, VerticalSpan:new{ width = MARGIN })
    end
    -- The page row: last, at the bottom of a page of the editor (the spare
    -- height goes above it, below).
    local page_at = #body + 1
    table.insert(body, padded(pagination))
    -- The same gap under the page row as over it: before the footer, or
    -- (no footer) the frame's own bottom padding alone.
    if footer then
        table.insert(body, VerticalSpan:new{ width = MARGIN })
        self.frame.padding_bottom = 0
    else
        -- A little over MARGIN: the gap above the row also holds the grid's
        -- slack and the cards' shadow (measured 38 px over, 31 under).
        self.frame.padding_bottom = MARGIN + math.floor(MARGIN / 2)
    end

    -- A page of the menu underneath covers all of it, the spare height above
    -- the footer so the footer still closes the frame.
    if self._over_rect then
        local pad = self.frame.padding_bottom + 2 * self.frame.bordersize
        local short = self._over_rect.h - (body:getSize().h + (footer and footer:getSize().h or 0) + pad)
        if short > 0 then
            -- Above the page row, so it stays at the bottom. A new group:
            -- body has measured itself, and keeps those offsets.
            local parts = { align = "left" }
            for i, w in ipairs(body) do
                if i == page_at then parts[#parts + 1] = VerticalSpan:new{ width = short } end
                parts[#parts + 1] = w
            end
            if page_at > #body then parts[#parts + 1] = VerticalSpan:new{ width = short } end
            body = VerticalGroup:new(parts)
        end
    end
    -- Edge to edge, down to the frame's bottom border. In a group of its
    -- own: body may have been measured above, and a VerticalGroup keeps the
    -- offsets it measured, so a child added after paints from a nil one (a
    -- page of the editor with a footer crashed).
    if footer then body = VerticalGroup:new{ align = "left", body, footer } end
    self.frame[1] = body
    self:_repaintIfResized(old)
    -- The grid highlights its own focused cell inline (cell_renderer reads
    -- self._dpad_idx at render time above), but footer buttons are stock
    -- Button instances rebuilt fresh every refresh() -- their onFocus/invert
    -- state doesn't survive that, so re-apply it here when footer has focus.
    if self._focus_zone == "footer" and self._footer_layout then
        local row = self._footer_layout[self._footer_row or 1]
        local btn = row and row[self._footer_col or 1]
        if btn then btn:onFocus() end
    end
    -- The strip's controls are rebuilt too: the one the keys are on, again.
    if self._focus_zone == "strip" then
        local w = self:_stripPos()
        if w and w.onFocus then w:onFocus() end
    end
    -- Self-bounded dirty rect is sufficient now that the modal is a fixed,
    -- content-derived size. setDirty(nil, ...) was triggering full-screen
    -- repaints that stacked ~1s each on e-ink.
    self:_dirty()
    -- config.on_page_shown(page): a page other than the last one shown is on
    -- screen, however it got there (arrows, swipe, go to page, keys). Not
    -- for the page the modal opened on. After the paint is queued, so a
    -- caller that does real work here does not hold the page back.
    if self.config.on_page_shown and self.page ~= self._page_shown then
        local first = (self._page_shown == nil)
        self._page_shown = self.page
        if not first then pcall(self.config.on_page_shown, self.page) end
    end
end

-- _dirty(): repaint the modal and refresh only its own box. Naming the window
-- limits what is painted, not what is refreshed: with no region the "ui"
-- covered the whole screen, and UIManager merged it with the flashui of a
-- dialog closing as the modal opened (Filters > Genre) into one whole-screen
-- flash.
function LibraryModal:_dirty()
    UIManager:setDirty(self, function()
        local r = self._shown_rect
        return "ui", r and Geom:new{ x = r.x, y = r.y, w = r.w, h = r.h } or nil
    end)
end

-- KOReader's own gestures (the menu, brightness) keep working around it,
-- as over the shelf (GestureZones.overlayEvent; maintainer, PW5).
function LibraryModal:handleEvent(event)
    return require("lib/bookshelf_gesture_zones").overlayEvent(self, event, InputContainer,
        function(pos)
            -- The keyboard up: every tap is the search box's business.
            local input = self._search_input
            if input and input.isKeyboardVisible and input:isKeyboardVisible() then return true end
            local d = self.frame and self.frame.dimen
            return not (d and d.x) or not pos:notIntersectWith(d)
        end)
end

return LibraryModal
